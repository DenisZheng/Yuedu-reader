import Foundation

/// 只持有系统复制导入的结果，不持久化外部URL，也不删除用户文件。
final class ImportedDocumentCopy: Sendable {
    let url: URL
    private let hasAccess: Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(url: URL,
         startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stopAccess = stopAccess
        hasAccess = startAccess(url)
    }

    deinit {
        if hasAccess { stopAccess(url) }
    }
}

/// 外部文档的读取边界；只在后台导入用例调用，不承担解析或持久化。
enum DocumentImportReader {
    enum Failure: Error {
        case tooLarge(Int)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let attributes = try readableURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard attributes.isDirectory != true else { throw CocoaError(.fileReadUnknown) }
                if let size = attributes.fileSize, size > maximumBytes { throw Failure.tooLarge(size) }
                let data = try Data(contentsOf: readableURL, options: .mappedIfSafe)
                guard data.count <= maximumBytes else { throw Failure.tooLarge(data.count) }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
