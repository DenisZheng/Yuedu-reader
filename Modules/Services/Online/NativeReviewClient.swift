import Foundation

/// 使用不可变的书源、书籍和章节快照；摘要产生的变量只传给它的详情，各分页链分别接续。
actor NativeReviewClient {
    private let source: BookSource
    private let chapter: OnlineChapterRef
    private let chapterVariables: [String: String]
    private nonisolated let session: BookSourceSession
    nonisolated let isJsSource: Bool

    init(source: BookSource, book: ReadingBook, chapter: OnlineChapterRef, session: BookSourceSession? = nil) {
        self.source = source
        self.chapter = chapter
        isJsSource = source.isJsSource
        self.session = session ?? BookSourceSession.session(for: source)
        var values = (book.runtimeVariables ?? [:]).merging(chapter.runtimeVariables ?? [:]) { _, value in value }
        values["book.name"] = book.title
        values["book.author"] = book.author
        values["book.bookUrl"] = book.bookInfoURL ?? ""
        values["book.tocUrl"] = book.tocURL ?? ""
        values["book.durChapterIndex"] = String(chapter.index)
        chapterVariables = values
    }

    nonisolated func checkAccess() throws {
        try Task.checkCancellation()
        guard session.isActive else { throw NativeReviewFailure.unavailable }
    }

    func summary() async throws -> NativeReviewSummary {
        try await read {
            guard !chapter.shouldRenderAsVolumeSeparator else { return .init(paragraphs: []) }
            if isJsSource {
                let call = try await session.parse { [chapter, chapterVariables] bridge in
                    try bridge.nativeReviewCall(name: "getReviewSummary", chapter: chapter, variables: chapterVariables,
                        paragraphIndex: 0, paragraphData: "", reviewID: nil, page: 1)
                }
                guard let value = call.result.value else {
                    return .init(paragraphs: [], runtimeVariables: call.variables)
                }
                guard let rows = try json(value) as? [[String: Any]] else { throw NativeReviewFailure.response }
                guard rows.count <= NativeReviewValues.maximumItems else { throw NativeReviewFailure.budget }
                var paragraphs: [Int: NativeReviewSummary.Paragraph] = [:]
                for row in rows {
                    guard let index = NativeReviewValues.integer(row["paraIndex"]), index == -1 || index > 0,
                          let count = NativeReviewValues.integer(row["count"]), count > 0 else { continue }
                    let data = NativeReviewValues.string(row["paraData"]).flatMap { $0.isEmpty ? nil : $0 } ?? String(index)
                    guard data.utf8.count <= 8192 else { throw NativeReviewFailure.budget }
                    paragraphs[index] = .init(index: index, data: data, count: count)
                }
                return .init(paragraphs: paragraphs.values.sorted { $0.index < $1.index }, runtimeVariables: call.variables)
            }
            guard source.ruleReview.hasSummary else { throw NativeReviewFailure.unavailable }
            let response = try await request(ruleURL: source.ruleReview.reviewSummaryUrl, locals: [:], page: 1, variables: chapterVariables)
            return try await session.parse { [chapter] bridge in
                try bridge.parseNativeReviewSummary(body: response.body, baseURL: response.baseURL, chapter: chapter, variables: response.variables)
            }
        }
    }

    func detail(paragraph: NativeReviewSummary.Paragraph, page: Int, nextURL: String? = nil,
                reviewID: String? = nil, runtimeVariables: [String: String]? = nil) async throws -> NativeReviewPage {
        try await read {
            guard (1...50).contains(page), paragraph.index == -1 || paragraph.index > 0 else { throw NativeReviewFailure.budget }
            let context = runtimeVariables ?? chapterVariables
            if isJsSource {
                let call = try await session.parse { [chapter] bridge in
                    try bridge.nativeReviewCall(name: reviewID == nil ? "getReviewDetail" : "getReviewReplies", chapter: chapter,
                        variables: context, paragraphIndex: paragraph.index, paragraphData: paragraph.data, reviewID: reviewID, page: page)
                }
                guard let value = call.result.value else {
                    if reviewID != nil { return .init(items: [], nextPageURL: nil, runtimeVariables: call.variables) }
                    throw NativeReviewFailure.response
                }
                guard let object = try json(value) as? [String: Any], let rows = object["items"] as? [[String: Any]] else {
                    throw NativeReviewFailure.response
                }
                let items = try NativeReviewValues.items(rows, base: chapter.url)
                guard rows.isEmpty || !items.isEmpty else { throw NativeReviewFailure.response }
                let next = NativeReviewValues.string(object["nextPageUrl"]).flatMap { $0.isEmpty ? nil : $0 }
                return .init(items: reviewID == nil ? items.map { item in
                    var item = item
                    item.replies = NativeReviewValues.flattenedReplies(item.replies)
                    return item
                } : NativeReviewValues.flattenedReplies(items), nextPageURL: reviewID == nil ? next : nil,
                    hasSeparateReplies: call.result.hasReviewReplies == true, runtimeVariables: call.variables)
            }
            let rule = source.ruleReview
            guard reviewID == nil ? rule.hasDetail : rule.hasReplies else { throw NativeReviewFailure.configuration }
            let locals = ["paraIndex": String(paragraph.index), "paraData": paragraph.data,
                          "reviewId": reviewID ?? "", "page": String(page)]
            let url: String
            if let nextURL, reviewID == nil { url = try Self.continuation(nextURL, page: page) }
            else { url = reviewID == nil ? rule.reviewDetailUrl : rule.reviewQuoteUrl }
            let response = try await request(ruleURL: url, locals: locals, page: page, variables: context)
            return try await session.parse { [chapter] bridge in
                try bridge.parseNativeReviewDetail(body: response.body, baseURL: response.baseURL, chapter: chapter,
                    variables: response.variables, locals: locals, repliesOnly: reviewID != nil)
            }
        }
    }

    private func read<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try checkAccess()
        do {
            let value = try await SourceDiagnosticContext.$restrictedTask.withValue(true) { try await operation() }
            try checkAccess()
            return value
        } catch {
            try checkAccess()
            if (error as? URLError)?.code == .dataLengthExceedsMaximum { throw NativeReviewFailure.budget }
            if error is MainJsSource.Failure || error is ModernParserBridgeError { throw NativeReviewFailure.rule }
            throw error
        }
    }

    private func json(_ value: String) throws -> Any {
        guard value.utf8.count <= NativeReviewValues.maximumBytes else { throw NativeReviewFailure.budget }
        do {
            return try SourcePerfTrace.span("review.json.decode", "bytes=\(value.utf8.count) main=\(Thread.isMainThread)") {
                try JSONSerialization.jsonObject(with: Data(value.utf8))
            }
        } catch { throw NativeReviewFailure.response }
    }

    private static func continuation(_ raw: String, page: Int) throws -> String {
        guard raw.utf8.count <= 8192 else { throw NativeReviewFailure.budget }
        // 服务器给的游标是数据，不是下一段源脚本。不把响应中的 JS/WebView/请求选项交回 AnalyzeUrl 执行。
        let url = raw.replacingOccurrences(of: "{{page}}", with: String(page))
        let lower = url.lowercased()
        guard !url.contains("{{"), !lower.contains("@js:"), !lower.contains("<js>"), !AnalyzeUrl.hasOptions(url),
              let target = AnalyzeUrl.requestURL(url), SourceRequestHeaderScope.origin(target) != nil,
              target.user == nil, target.password == nil else { throw NativeReviewFailure.configuration }
        return url
    }

    private func request(ruleURL: String, locals: [String: String], page: Int,
                         variables: [String: String]) async throws -> (body: String, baseURL: String, variables: [String: String]) {
        let prepared = try await session.parse { [chapter] bridge in
            try bridge.prepareNativeReviewRequest(ruleURL: ruleURL, chapter: chapter, variables: variables, locals: locals, page: page)
        }
        try checkAccess()
        let scope = SourceRequestHeaderScope(urls: [source.bookSourceUrl, chapter.url].compactMap {
            AnalyzeUrl.requestURL(AnalyzeUrl.cleanBaseURL($0))
        })
        let executor = SourceRequestExecutor(session: session.requestSession, rate: source.concurrentRate,
            rateKey: session.runtimeOverrides?.authenticationKey ?? source.bookSourceUrl,
            cookieJarEnabled: source.enabledCookieJar, runtimeState: session.runtimeOverrides?.state,
            cookieScope: scope, maximumBytes: NativeReviewValues.maximumBytes)
        let response = try await executor.response(for: prepared.request)
        guard let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativeReviewFailure.response
        }
        let transformed = try await session.parse { [chapter] bridge in
            try bridge.finishNativeReviewRequest(prepared: prepared, data: response.data, response: response.response, chapter: chapter, locals: locals)
        }
        guard transformed.body.utf8.count <= NativeReviewValues.maximumBytes else { throw NativeReviewFailure.budget }
        guard transformed.body.contains(where: { !$0.isWhitespace }) else { throw NativeReviewFailure.response }
        return (transformed.body, response.response.url?.absoluteString ?? chapter.url, transformed.variables)
    }
}
