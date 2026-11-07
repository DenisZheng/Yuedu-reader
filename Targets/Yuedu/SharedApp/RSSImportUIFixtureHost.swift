#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// 显式PoC宿主的UI验收适配。只传入测试创建的文件与临时store，业务仍是生产导入sheet。
struct RSSImportUIFixtureHost: View {
    let file: URL
    let directory: URL
    @State private var store: RSSStore?

    var body: some View {
        Group {
            if let store {
                FixtureControls(file: file, store: store)
            } else {
                Color.clear
            }
        }
        .task {
            guard directory.lastPathComponent.hasPrefix("RSSImportUI-"),
                  file.lastPathComponent == "rss-import-fixture.json" else { return }
            store = RSSStore(storageDirectory: directory)
        }
    }

    private struct FixtureControls: View {
        let file: URL
        @ObservedObject var store: RSSStore
        @State private var review: RSSImportReviewRequest?

        var body: some View {
            NavigationStack {
                Form {
                    Text(String(store.sources.count)).accessibilityIdentifier("rss-fixture-saved-count")
                    Button(localized("匯入 Legado JSON")) { review = .init(input: .file(file)) }
                        .accessibilityIdentifier("rss-fixture-open")
                }
            }
            .sheet(item: $review) { request in
                RSSImportReviewSheet(input: request.input, store: store)
            }
        }
    }
}
#endif
