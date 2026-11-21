import SwiftUI

/// 文件源的主要操作是选择下载并导入；沿原生Form进入既有本地阅读器，不显示虚构目录。
struct SourceFileBookView: View {
    @State private var model: SourceFileImportModel
    @State private var readingID: UUID?
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies

    init(book: OnlineBook) { _model = State(initialValue: SourceFileImportModel(book: book)) }

    var body: some View {
        Form {
            Section {
                Text(model.book.name).font(DSFont.headline)
                if !model.book.author.isEmpty { Text(model.book.author).foregroundStyle(DSColor.textSecondary) }
            }.interfaceSectionSurface()
            Section {
                switch model.phase {
                case .loading:
                    ProgressView(localized("載入下載列表…"))
                    Button(localized("取消"), role: .cancel) { model.cancel() }
                case .failed:
                    ContentUnavailableView(localized("無法載入下載列表"), systemImage: "exclamationmark.triangle",
                        description: Text(model.message ?? localized("檔案載入失敗，請重試")))
                    Button(localized("重試")) { Task { await load() } }
                case .ready, .importing:
                    ForEach(Array((model.book.downloadUrls ?? []).enumerated()), id: \.element) { index, raw in
                        Button {
                            model.startImport(raw, sources: .shared, store: store)
                        } label: {
                            Label(String(format: localized("下載檔案 %d"), index + 1), systemImage: "arrow.down.document")
                        }
                        .disabled(model.phase == .importing)
                    }
                    if model.phase == .importing {
                        ProgressView(localized("下載並匯入中…"))
                        Button(localized("取消"), role: .cancel) { model.cancel() }
                    }
                    if let message = model.message { Text(message).foregroundStyle(DSColor.textSecondary) }
                case .imported:
                    Label(localized("檔案已匯入書架"), systemImage: "checkmark.circle")
                    Button(localized("開始閱讀")) { readingID = model.importedBookID }
                }
            } header: {
                Text(localized("可下載的檔案"))
            } footer: {
                Text(localized("選擇檔案後下載並匯入書架；單一檔案上限為64 MiB。"))
                    .dsSectionFooter()
            }.interfaceSectionSurface()
        }
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .global).ignoresSafeArea())
        .pageBackgroundToolbar(for: .global)
        .navigationTitle(localized("文件型書源"))
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sourceFile.detail")
        .task { await load() }
        .onDisappear { model.cancel() }
        .navigationDestination(item: $readingID) { id in
            BookReaderView(bookId: id).environmentObject(store)
        }
    }

    private func load() async { await model.load(fetcher: dependencies.bookSourceFetcher, sources: .shared) }
}

#Preview {
    NavigationStack {
        SourceFileBookView(book: OnlineBook(name: "合成文件书", author: "示例作者", intro: "", coverUrl: "",
            bookUrl: "https://example.invalid/book", tocUrl: "", wordCount: "", lastChapter: "", kind: "",
            sourceId: UUID(), sourceName: "示例文件源"))
            .environmentObject(BookStore())
    }
}
