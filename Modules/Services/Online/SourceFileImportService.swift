import Foundation

/// 文件型书源只补用例：请求沿共享宿主/执行器，文件交给现有本地导入，不创建第二套解析器。
enum SourceFileImportService {
    enum Failure: LocalizedError {
        case sourceUnavailable, noDownloads, unsupportedFormat, staleConfiguration, httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .sourceUnavailable: localized("找不到這本書的來源配置")
            case .noDownloads: localized("文件源沒有可下載的檔案")
            case .unsupportedFormat: localized("此檔案格式目前不支援匯入")
            case .staleConfiguration: localized("來源配置已變更，請重新載入下載列表")
            case .httpStatus(let code): String(format: localized("檔案下載失敗（HTTP %d）"), code)
            }
        }
    }

    static let maximumBytes = 64 * 1_024 * 1_024

    static func load(book: OnlineBook, source: BookSource, fetcher: any BookSourceFetching) async throws -> OnlineBook {
        guard source.bookSourceType == 3 else { throw Failure.sourceUnavailable }
        let result = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source,
            runtimeVariables: book.runtimeVariables, knownBook: book)
        guard result.downloadUrls?.isEmpty == false else { throw Failure.noDownloads }
        return result.onlineBook
    }

    static func importFile(rawURL: String, book: OnlineBook, source: BookSource, sources: BookSourceStore,
                           store: BookStore, requestSession: URLSession = LegadoJSBridge.requestSession,
                           limit: Int = maximumBytes) async throws -> ReadingBook {
        let credentialRevision = LoginManager.shared.loginInfoRevision(sourceUrl: source.bookSourceUrl)
        func validate() throws {
            try Task.checkCancellation()
            guard let current = sources.source(id: source.id), current.hasSameContent(as: source),
                  LoginManager.shared.loginInfoRevision(sourceUrl: source.bookSourceUrl) == credentialRevision else {
                throw Failure.staleConfiguration
            }
        }
        try validate()
        guard source.bookSourceType == 3, book.downloadUrls?.contains(rawURL) == true else { throw Failure.noDownloads }
        let session = BookSourceSession.session(for: source, requestSession: requestSession)
        let prepared = try await session.parse { bridge in
            let data = RuleData(); data.variableMap = book.runtimeVariables ?? [:]
            return try bridge.prepareRuleWebRequest(rawURL, scope: data,
                runtimeVariables: book.detailStageRuntimeVariables(book.runtimeVariables))
        }
        try validate()
        let executor = SourceRequestExecutor(session: requestSession, rate: source.concurrentRate,
            rateKey: source.bookSourceUrl, cookieJarEnabled: source.enabledCookieJar, maximumBytes: limit)
        let result = try await SourcePerfTrace.spanAsync("source.file.download", "main=\(Thread.isMainThread)") {
            try await executor.data(for: prepared.request)
        }
        try validate()
        guard let http = result.1 as? HTTPURLResponse else { throw Failure.httpStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.httpStatus(http.statusCode) }
        let suffix = try fileExtension(type: prepared.fileType, response: http)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceFileImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { AppLogger.cache("文件源临时目录清理失败", context: ["code": (error as NSError).code]) }
        }
        let file = directory.appendingPathComponent("book." + suffix)
        try SourcePerfTrace.span("source.file.stage", "main=\(Thread.isMainThread) bytes=\(result.0.count)") {
            try result.0.write(to: file, options: .atomic)
        }
        try validate()
        let imported = try await LocalBookImportService.importBook(at: file, title: book.name, author: book.author, store: store)
        do { try validate() }
        catch {
            // 既有导入器已经拥有文件：只撤销本次新建的ID，不删除或替换任何已有书。
            await store.delete(bookId: imported.id)
            await BookStore.queuedWritesLanded()
            throw error
        }
        return imported
    }

    static func fileExtension(type: String?, response: HTTPURLResponse) throws -> String {
        // URL options 的 type 优先；否则响应文件名、最终URL、MIME。只准入既有本地格式。
        let candidates = [type?.lowercased(), response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() },
                          response.url?.pathExtension.lowercased(), response.mimeType.flatMap { BookFileFormat(mediaType: $0)?.extensions.first }]
        for suffix in candidates.compactMap({ $0 }) where !suffix.isEmpty {
            if BookFileFormat.localImportExtensions.contains(suffix) { return suffix }
            // 显式指定但不支持的格式不能改名成另一种格式假装可读。
            if type?.isEmpty == false { throw Failure.unsupportedFormat }
        }
        throw Failure.unsupportedFormat
    }
}
