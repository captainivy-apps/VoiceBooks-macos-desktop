import Foundation

enum EbookDownloadError: Error {
    case invalidUrl
    case httpError
    case networkError
    case emptyResponse
    case unsupportedFormat
}

enum EbookDownloadResult {
    case success(fileName: String)
    case failure(EbookDownloadError)
}

/// Streams an EPUB over HTTP(S), reporting progress in the 0–15 range to match
/// the Kotlin import pipeline.
final class EbookDownloader {
    func download(
        url: String,
        targetFile: URL,
        onProgress: @escaping (Int) -> Void
    ) async -> EbookDownloadResult {
        guard EbookUrlHelper.isValidHttpUrl(url) else { return .failure(.invalidUrl) }
        guard let requestUrl = URL(string: url.trimmingCharacters(in: .whitespaces)) else {
            return .failure(.invalidUrl)
        }

        let tempFile = targetFile.deletingLastPathComponent()
            .appendingPathComponent("\(targetFile.lastPathComponent).download")

        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 120
        request.httpShouldUsePipelining = true

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.networkError) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.httpError) }

            let fileName = EbookUrlHelper.resolveFileName(
                url: url,
                contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition")
            )
            let ext = EbookUrlHelper.extensionOf(fileName)
            guard EbookUrlHelper.isSupportedExtension(ext) else { return .failure(.unsupportedFormat) }

            let total = http.expectedContentLength
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempFile)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(16384)
            var downloaded: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 16384 {
                    handle.write(buffer)
                    downloaded += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 {
                        onProgress(Int(min(15, downloaded * 15 / total)))
                    }
                }
            }
            if !buffer.isEmpty {
                handle.write(buffer)
                downloaded += Int64(buffer.count)
            }
            try? handle.close()

            if FileManager.default.fileExists(atPath: targetFile.path) {
                try? FileManager.default.removeItem(at: targetFile)
            }
            try FileManager.default.moveItem(at: tempFile, to: targetFile)
            onProgress(15)
            return .success(fileName: fileName)
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            return .failure(.networkError)
        }
    }
}
