import Foundation

enum TtsModelDownloadResult {
    case success
    case failure(String)

    var isSuccess: Bool { if case .success = self { return true }; return false }
    var message: String? { if case .failure(let message) = self { return message }; return nil }
}

/// Downloads and extracts a sherpa-onnx model archive (`.tar.bz2`).
final class TtsModelDownloader {
    func downloadAndExtract(
        url: String,
        targetDir: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        Paths.createIfNeeded(targetDir)
        let tempArchive = targetDir.deletingLastPathComponent()
            .appendingPathComponent("\(targetDir.lastPathComponent).tar.bz2")

        guard let requestUrl = URL(string: url) else {
            return .failure("无效的下载地址")
        }
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 120

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("网络连接失败")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure("服务器返回错误：HTTP \(http.statusCode)")
            }
            let total = http.expectedContentLength

            FileManager.default.createFile(atPath: tempArchive.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempArchive)
            var buffer = Data()
            buffer.reserveCapacity(16384)
            var downloaded: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 16384 {
                    handle.write(buffer)
                    downloaded += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { onProgress(Float(downloaded) / Float(total)) }
                }
            }
            if !buffer.isEmpty { handle.write(buffer) }
            try? handle.close()

            guard extract(archive: tempArchive, to: targetDir) else {
                try? FileManager.default.removeItem(at: tempArchive)
                return .failure("模型解压失败")
            }
            try? FileManager.default.removeItem(at: tempArchive)
            onProgress(1)
            return .success
        } catch {
            try? FileManager.default.removeItem(at: tempArchive)
            return .failure((error as NSError).localizedDescription.isEmpty ? "网络连接失败" : (error as NSError).localizedDescription)
        }
    }

    private func extract(archive: URL, to dir: URL) -> Bool {
        let staging = dir.deletingLastPathComponent()
            .appendingPathComponent("\(dir.lastPathComponent)-staging")
        try? FileManager.default.removeItem(at: staging)
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", staging.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let sourceDir: URL
        if entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            sourceDir = entries[0]
        } else {
            sourceDir = staging
        }
        let items = (try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let destination = dir.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: item, to: destination)
        }
        try? fm.removeItem(at: staging)
        return true
    }
}
