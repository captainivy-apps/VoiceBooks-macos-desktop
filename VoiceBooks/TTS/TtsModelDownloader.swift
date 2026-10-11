import Foundation

enum TtsModelDownloadResult {
    case success
    case failure(String)

    var isSuccess: Bool { if case .success = self { return true }; return false }
    var message: String? { if case .failure(let message) = self { return message }; return nil }
}

/// Downloads and extracts a sherpa-onnx model archive (`.tar.bz2`), or fetches
/// individual model files from a base URL.
final class TtsModelDownloader {
    func downloadAndExtract(
        url: String,
        targetDir: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        Paths.createIfNeeded(targetDir)
        let tempArchive = targetDir.deletingLastPathComponent()
            .appendingPathComponent("\(targetDir.lastPathComponent).tar.bz2")

        let result = await downloadToFile(url: url, destination: tempArchive, onProgress: onProgress)
        if case .failure(let message) = result {
            try? FileManager.default.removeItem(at: tempArchive)
            return .failure(message)
        }
        guard extract(archive: tempArchive, to: targetDir) else {
            try? FileManager.default.removeItem(at: tempArchive)
            return .failure("模型解压失败")
        }
        try? FileManager.default.removeItem(at: tempArchive)
        onProgress(1)
        return .success
    }

    /// Downloads each relative path under `baseUrl` into `targetDir`, creating
    /// intermediate directories as needed. Progress is aggregated across files.
    func downloadFiles(
        baseUrl: String,
        files: [String],
        targetDir: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        guard !files.isEmpty else { return .failure("没有可下载的文件") }
        Paths.createIfNeeded(targetDir)
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let total = Float(files.count)

        for (index, relative) in files.enumerated() {
            let destination = targetDir.appendingPathComponent(relative)
            let fileProgress: (Float) -> Void = { fraction in
                onProgress((Float(index) + fraction) / total)
            }
            let result = await downloadToFile(
                url: "\(base)/\(relative)", destination: destination, onProgress: fileProgress
            )
            if case .failure(let message) = result {
                return .failure("\(relative) 下载失败：\(message)")
            }
        }
        onProgress(1)
        return .success
    }

    /// Downloads a single file from an absolute URL to `destination`,
    /// creating intermediate directories as needed.
    func downloadFile(
        url: String,
        to destination: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return await downloadToFile(url: url, destination: destination, onProgress: onProgress)
    }

    private func downloadToFile(
        url: String,
        destination: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TtsModelDownloadResult {
        guard let requestUrl = URL(string: url) else {
            return .failure("无效的下载地址")
        }
        var request = URLRequest(url: requestUrl)
        request.timeoutInterval = 120

        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                return .failure("网络连接失败")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure("服务器返回错误：HTTP \(http.statusCode)")
            }
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            onProgress(1)
            return .success
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = (error as NSError).localizedDescription
            return .failure(message.isEmpty ? "网络连接失败" : message)
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

/// Reports download progress for `URLSession.download(for:delegate:)`.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Float) -> Void

    init(onProgress: @escaping (Float) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Float(totalBytesWritten) / Float(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
