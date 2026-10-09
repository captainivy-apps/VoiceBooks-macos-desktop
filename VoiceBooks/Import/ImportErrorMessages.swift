import Foundation

enum ImportError: Error {
    case emptyContent
    case unsupportedFormat(String)
    case invalidUrl
    case epubParse(String)
    case readFile
    case sourceMissing
    case generic(String)
}

enum AppMessages {
    static let importErrorReadFile = "无法读取文件"
    static let importErrorEmptyContent = "文件中未提取到可读正文"
    static let importErrorInvalidUrl = "URL 格式无效，请输入 http 或 https 开头的链接"
    static let importErrorDownloadHttp = "下载失败：服务器返回错误"
    static let importErrorDownloadNetwork = "下载失败：网络连接异常"
    static let importErrorSourceMissing = "源文件不存在，请重新上传"
    static let importFailed = "导入失败"

    static func unsupportedFormat(_ ext: String) -> String { "不支持的文件格式：.\(ext)" }
    static func epubParse(_ detail: String) -> String { "EPUB 解析失败：\(detail)" }
    static func importFailedDetail(_ detail: String) -> String { "导入失败：\(detail)" }
}

enum ImportErrorMessages {
    static func downloadErrorMessage(_ error: EbookDownloadError) -> String {
        switch error {
        case .invalidUrl: return AppMessages.importErrorInvalidUrl
        case .httpError: return AppMessages.importErrorDownloadHttp
        case .networkError: return AppMessages.importErrorDownloadNetwork
        case .emptyResponse: return AppMessages.importErrorDownloadNetwork
        case .unsupportedFormat: return AppMessages.unsupportedFormat("?")
        }
    }

    static func toUserMessage(_ error: Error) -> String {
        if let importError = error as? ImportError {
            switch importError {
            case .emptyContent: return AppMessages.importErrorEmptyContent
            case .invalidUrl: return AppMessages.importErrorInvalidUrl
            case .unsupportedFormat(let ext): return AppMessages.unsupportedFormat(ext)
            case .epubParse(let detail):
                return AppMessages.epubParse(detail.isEmpty ? AppMessages.importFailed : detail)
            case .readFile: return AppMessages.importErrorReadFile
            case .sourceMissing: return AppMessages.importErrorSourceMissing
            case .generic(let message):
                return message.isEmpty ? AppMessages.importFailed : message
            }
        }
        let detail = (error as NSError).localizedDescription
        return detail.isEmpty ? AppMessages.importFailed : AppMessages.importFailedDetail(detail)
    }
}
