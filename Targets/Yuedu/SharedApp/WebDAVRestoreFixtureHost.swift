#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// 强杀测试独占的合成数据目录；不读取用户store、云端、账号或原始源包。
struct WebDAVRestoreFixtureHost: View {
    let root: URL
    @State private var model: WebDAVRestoreFixtureModel?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                if let model {
                    Text(verbatim: model.phase).accessibilityIdentifier("webdav.fixture.state")
                    Button(localized("還原所選分類")) { model.start() }
                        .accessibilityIdentifier("webdav.fixture.restore")
                        .disabled(model.task != nil)
                    if model.phase == "paused" {
                        Button(localized("繼續")) { model.resume() }
                            .accessibilityIdentifier("webdav.fixture.resume")
                    }
                } else if failed {
                    Text(localized("還原失敗，原始資料副本已保留，請勿繼續同步"))
                } else { ProgressView() }
            }
            .navigationTitle("WebDAV restore fixture")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do { model = try await WebDAVRestoreFixtureModel.prepare(root: root) }
                catch { failed = true }
            }
        }
    }
}

@MainActor @Observable
private final class WebDAVRestoreFixtureModel {
    let root: URL
    let rss: RSSStore
    var phase: String
    var task: Task<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?

    private init(root: URL, rss: RSSStore, phase: String) {
        self.root = root; self.rss = rss; self.phase = phase
    }

    static func prepare(root: URL) async throws -> WebDAVRestoreFixtureModel {
        let seeded = root.appendingPathComponent("seeded")
        let first = await Task.detached { !FileManager.default.fileExists(atPath: seeded.path) }.value
        let rss = RSSStore(storageDirectory: root)
        if first {
            let file = root.appendingPathComponent("book_sources.json")
            try await Task.detached { try Data(" [ ]\n".utf8).write(to: file) }.value
            let source = RSSSource(id: "original", name: "Original", url: "https://original.invalid/rss")
            rss.addSource(source)
            rss.mergeFetchedItems([RSSItem(id: "article", title: "Original", link: "https://original.invalid/article",
                contentHTML: "<p>original body</p>", sourceId: source.id)], for: source.id)
            rss.setVariables(["original": "synthetic-value"], for: source.id)
            try await rss.flushPersistence()
            try await Task.detached { try Data().write(to: seeded) }.value
        }
        let sourceFile = root.appendingPathComponent("book_sources.json")
        let sourceOriginal = try await Task.detached { try Data(contentsOf: sourceFile) == Data(" [ ]\n".utf8) }.value
        let bodyOriginal = rss.articles(for: "original").first?.contentHTML == "<p>original body</p>"
        let variablesOriginal = rss.variables(for: "original") == ["original": "synthetic-value"]
        return WebDAVRestoreFixtureModel(root: root, rss: rss,
            phase: sourceOriginal && bodyOriginal && variablesOriginal ? "ready-original" : "ready-changed")
    }

    func start() {
        task = Task {
            do {
                var local = WebDAVProductionLocalData(rss: rss, bookStore: nil,
                    fileOverrides: [.bookSources: root.appendingPathComponent("book_sources.json")],
                    recoveryDirectory: root.appendingPathComponent("journal"))
                let boundary = ProcessInfo.processInfo.environment["WEBDAV_RESTORE_BOUNDARY"] ?? "rss"
                local.afterCategoryWrite = { [weak self] category in
                    guard category.rawValue == boundary else { return }
                    await self?.pause()
                }
                let empty = try await RSSBackupCodec.encode(sources: [], folders: [], records: [:], statuses: [:])
                try await local.apply([(.bookSources, Data("[]".utf8)), (.rss, empty)])
                phase = "committed"
            } catch { phase = "failed" }
            task = nil
        }
    }

    private func pause() async {
        phase = "paused"
        // UI测试等待此真实写入边界再终止进程；继续按钮/离屏恢复continuation，不靠计时暂停。
        await withCheckedContinuation { paused = $0 }
    }

    func resume() { paused?.resume(); paused = nil }
}

#Preview { WebDAVRestoreFixtureHost(root: URL.temporaryDirectory.appendingPathComponent("WebDAVRestoreUITests-preview")) }
#endif
