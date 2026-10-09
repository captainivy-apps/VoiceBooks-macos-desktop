import Foundation

/// Minimal EPUB parser. Unzips the container with the system `ditto`, then reads
/// the OPF package document for metadata, manifest, spine order and cover.
final class EpubParser {
    func parse(file: URL, format: BookFormat) throws -> ParsedBook {
        try parseEpub(file)
    }

    func parse(file: URL) throws -> ParsedBook {
        try parseEpub(file)
    }

    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
    }

    private func parseEpub(_ file: URL) throws -> ParsedBook {
        let temp = try unzip(file)
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let opfRelative = findOpfPath(in: temp) else {
            throw ImportError.epubParse("未找到 container.xml")
        }
        let opfURL = temp.appendingPathComponent(opfRelative)
        let opfDir = opfURL.deletingLastPathComponent()

        let document: XMLDocument
        do {
            document = try XMLDocument(contentsOf: opfURL, options: [])
        } catch {
            throw ImportError.epubParse((error as NSError).localizedDescription)
        }

        let title = firstText(in: document, localName: "title") ?? file.deletingPathExtension().lastPathComponent
        let creator = firstText(in: document, localName: "creator") ?? ""
        let description = firstText(in: document, localName: "description") ?? ""
        let summary = description.isEmpty ? "" : HtmlTextExtractor.text(from: description)
        let publisher = firstText(in: document, localName: "publisher") ?? ""
        let publishedDate = firstText(in: document, localName: "date") ?? ""
        let language = firstText(in: document, localName: "language") ?? ""
        let subjects = allTexts(in: document, localName: "subject").joined(separator: "，")
        let isbn = isbnFrom(document) ?? ""

        let manifest = manifestItems(in: document)
        let manifestById = Dictionary(uniqueKeysWithValues: manifest.map { ($0.id, $0) })
        let spineHrefs = spineOrder(in: document, manifestById: manifestById)

        var textBuilder = ""
        for href in spineHrefs {
            let resourceURL = resolve(href: href, base: opfDir)
            guard let data = try? Data(contentsOf: resourceURL) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let extracted = HtmlTextExtractor.text(from: html)
            if !extracted.isEmpty {
                textBuilder += extracted
                textBuilder += "\n"
            }
        }

        let coverBytes = coverImage(in: document, manifest: manifest, manifestById: manifestById, opfDir: opfDir)

        return ParsedBook(
            title: title,
            author: creator,
            summary: summary,
            textContent: textBuilder.trimmed,
            coverBytes: coverBytes,
            publisher: publisher,
            publishedDate: publishedDate,
            language: language,
            isbn: isbn,
            subjects: subjects
        )
    }

    // MARK: - Unzip

    private func unzip(_ file: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebook-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", file.path, temp.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            throw ImportError.epubParse("无法解压 EPUB")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError.epubParse("EPUB 解压失败")
        }
        return temp
    }

    private func findOpfPath(in root: URL) -> String? {
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let data = try? Data(contentsOf: containerURL),
              let document = try? XMLDocument(data: data, options: []) else { return nil }
        return nodes(in: document, xpath: ".//*[local-name()='rootfile']")
            .first.flatMap { attribute($0, "full-path") }
    }

    // MARK: - OPF

    private func nodes(in document: XMLDocument, xpath: String) -> [XMLNode] {
        (try? document.nodes(forXPath: xpath)) ?? []
    }

    private func attribute(_ node: XMLNode, _ name: String) -> String? {
        (node as? XMLElement)?.attribute(forName: name)?.stringValue
    }

    private func localAttribute(_ node: XMLNode, _ localName: String) -> String? {
        (node as? XMLElement)?.attributes?.first { $0.localName == localName }?.stringValue
    }

    private func firstText(in document: XMLDocument, localName: String) -> String? {
        guard let node = nodes(in: document, xpath: ".//*[local-name()='\(localName)']").first,
              let value = node.stringValue?.trimmed, !value.isEmpty else { return nil }
        return value
    }

    private func allTexts(in document: XMLDocument, localName: String) -> [String] {
        nodes(in: document, xpath: ".//*[local-name()='\(localName)']").compactMap { node in
            node.stringValue?.trimmed
        }.filter { !$0.isEmpty }
    }

    private func isbnFrom(_ document: XMLDocument) -> String? {
        for identifier in nodes(in: document, xpath: ".//*[local-name()='identifier']") {
            let scheme = localAttribute(identifier, "scheme") ?? ""
            if scheme.lowercased().contains("isbn") {
                return identifier.stringValue?.trimmed
            }
        }
        return nil
    }

    private func manifestItems(in document: XMLDocument) -> [ManifestItem] {
        nodes(in: document, xpath: ".//*[local-name()='manifest']/*[local-name()='item']").compactMap { node in
            guard let id = attribute(node, "id"),
                  let href = attribute(node, "href") else { return nil }
            let mediaType = attribute(node, "media-type") ?? ""
            return ManifestItem(id: id, href: href, mediaType: mediaType)
        }
    }

    private func spineOrder(in document: XMLDocument, manifestById: [String: ManifestItem]) -> [String] {
        nodes(in: document, xpath: ".//*[local-name()='spine']/*[local-name()='itemref']").compactMap { node in
            guard let idref = attribute(node, "idref"),
                  let item = manifestById[idref] else { return nil }
            return item.href
        }
    }

    private func coverImage(
        in document: XMLDocument,
        manifest: [ManifestItem],
        manifestById: [String: ManifestItem],
        opfDir: URL
    ) -> Data? {
        var coverHref: String?
        if let meta = nodes(in: document, xpath: ".//*[local-name()='meta'][@name='cover']").first,
           let content = attribute(meta, "content"),
           let item = manifestById[content] {
            coverHref = item.href
        }
        if coverHref == nil,
           let reference = nodes(in: document, xpath: ".//*[local-name()='guide']/*[local-name()='reference'][@type='cover']").first,
           let href = attribute(reference, "href") {
            coverHref = href
        }
        if coverHref == nil {
            coverHref = manifest.first { $0.mediaType.lowercased().hasPrefix("image/") }?.href
        }
        guard let href = coverHref else { return nil }
        return try? Data(contentsOf: resolve(href: href, base: opfDir))
    }

    private func resolve(href: String, base: URL) -> URL {
        var clean = href
        if let hash = clean.firstIndex(of: "#") { clean = String(clean[..<hash]) }
        clean = clean.removingPercentEncoding ?? clean
        if clean.hasPrefix("/") { clean = String(clean.dropFirst()) }
        return base.appendingPathComponent(clean)
    }
}
