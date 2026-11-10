import Foundation

/// 对齐 Legado `Debug.startDebug(rssSource)`：用生产路径（分类解析、列表页、正文分页）跑一遍，
/// 只记录阶段、状态、规则、数量和分页轨迹。网址只保留 scheme/host/path，正文、标题、错误原文不进日志。
/// 不写入 RSSStore 的文章或已读状态；源脚本自身的 put/cookie 副作用与正常浏览一致。
@MainActor @Observable final class RSSSourceDebugger {
    struct Line: Identifiable, Equatable {
        enum Level: Equatable { case step, info, success, failure }
        let id = UUID()
        let level: Level
        let text: String
    }
    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// `key`：空＝第一个分类；`名称::URL`＝指定分类；绝对URL＝直接调试正文；其他＝搜索关键字（Legado同语义）。
    func start(source: RSSSource, key: String, owner: RSSStore) {
        cancel()
        lines = []
        isRunning = true
        let id = generation
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == id else { return }
            await run(source: source, key: key.trimmingCharacters(in: .whitespacesAndNewlines), owner: owner)
            guard generation == id else { return }
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        if isRunning { append(.failure, localized("已取消")) }
        isRunning = false
    }

    private func append(_ level: Line.Level, _ text: String) {
        guard !Task.isCancelled else { return }
        lines.append(.init(level: level, text: text))
    }

    private func run(source: RSSSource, key: String, owner: RSSStore) async {
        append(.step, localized("開始解析"))
        do {
            if key.contains("::") {
                let parts = key.components(separatedBy: "::")
                let entry = RSSSortEntry(name: parts[0], url: parts.dropFirst().joined(separator: "::"))
                try await list(source: source, entry: entry, key: nil, owner: owner)
            } else if let url = URL(string: key), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                try await content(source: source, link: key, owner: owner)
            } else if !key.isEmpty {
                guard source.searchUrl?.isEmpty == false else { append(.failure, localized("搜尋網址為空")); return }
                append(.info, String(format: localized("搜尋規則：%@"), Self.rule(source.searchUrl)))
                try await list(source: source, entry: nil, key: key, owner: owner)
            } else {
                let entries = try await LegadoRSSScraper.resolveSortEntries(for: source, owner: owner)
                append(.info, String(format: localized("分類數：%d"), entries.count))
                try await list(source: source, entry: entries.first, key: nil, owner: owner)
            }
        } catch is CancellationError {
            return
        } catch {
            append(.failure, Self.describe(error))
        }
    }

    private func list(source: RSSSource, entry: RSSSortEntry?, key: String?, owner: RSSStore) async throws {
        append(.step, localized("列表頁"))
        append(.info, String(format: localized("列表規則：%@"), Self.rule(source.ruleArticles)))
        let page = try await LegadoRSSScraper.fetchListPage(source: source, entry: entry, page: 1, key: key, owner: owner)
        try Task.checkCancellation()
        append(.info, String(format: localized("請求：%@"), Self.redact(page.requestURL)))
        if page.finalURL != page.requestURL { append(.info, String(format: localized("最終網址：%@"), Self.redact(page.finalURL))) }
        append(.info, String(format: localized("條目數：%d"), page.items.count))
        append(.info, page.nextURL == nil ? localized("沒有下一頁") : String(format: localized("下一頁：%@"), Self.redact(page.nextURL ?? "")))
        guard let first = page.items.first else { append(.success, localized("列表頁解析成功，為空")); return }
        let fields: [(String, String?)] = [("ruleTitle", first.title), ("ruleLink", first.link), ("rulePubDate", first.pubDate.map { "\($0)" }),
                                           ("ruleImage", first.imageURL), ("ruleDescription", first.description)]
        for (name, value) in fields {
            let filled = value?.isEmpty == false
            append(filled ? .info : .failure, String(format: localized("首條 %@：%@"), name, filled ? localized("有值") : localized("空")))
        }
        guard source.ruleDescription?.isEmpty != false else { append(.success, localized("存在描述規則，不解析正文頁")); return }
        try await content(source: source, link: first.link, owner: owner)
    }

    private func content(source: RSSSource, link: String, owner: RSSStore) async throws {
        guard let rule = source.ruleContent, !rule.isEmpty else { append(.success, localized("正文規則為空，使用整個網頁")); return }
        append(.step, localized("正文頁"))
        append(.info, String(format: localized("正文規則：%@"), Self.rule(rule)))
        append(.info, String(format: localized("請求：%@"), Self.redact(link)))
        let result = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: link, owner: owner)
        try Task.checkCancellation()
        append(.info, String(format: localized("正文頁數：%d"), result.pageCount))
        append(.info, String(format: localized("正文長度：%d"), result.html.count))
        switch result.stop {
        case .complete: append(.success, localized("解析完成"))
        case .loop: append(.failure, localized("正文分頁出現循環，已停止"))
        case .duplicate: append(.failure, localized("正文分頁重複，已停止"))
        case .budget: append(.failure, localized("正文分頁超出上限，已停止"))
        case .failed: append(.failure, localized("後續正文頁失敗，保留已取得部分"))
        }
    }

    /// 任意规则、脚本和URL模板都可能内嵌凭据；诊断只展示字段名称与有无配置。
    /// 编辑器可看原配置，但日志不能复制原文或只截断后误称脱敏。
    nonisolated static func rule(_ value: String?) -> String {
        value?.isEmpty == false ? "<redacted>" : localized("空")
    }

    /// 只保留 scheme://host/path；query、fragment、userinfo、URL options 一律去掉。
    nonisolated static func redact(_ raw: String) -> String {
        let plain = AnalyzeUrl.stripOptions(from: raw)
        guard var parts = URLComponents(string: plain), parts.host != nil else { return localized("（非網址）") }
        let hadQuery = parts.query != nil || parts.fragment != nil
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return (parts.string ?? "") + (hadQuery ? "?…" : "")
    }

    /// 错误只给类别，不带服务器/脚本原文。
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        // ScraperError的文案是固定分类，不含服务器或脚本原文。
        case ScraperError.invalidRule: return localized("規則 JSON 無效")
        case let error as ScraperError: return error.errorDescription ?? localized("解析失敗")
        case is SourceRuntimeRequirement: return localized("需要登入或人工驗證")
        case is URLError: return localized("網路錯誤")
        default: return localized("解析失敗")
        }
    }
}
