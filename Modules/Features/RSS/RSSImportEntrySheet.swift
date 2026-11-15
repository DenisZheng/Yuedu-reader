import SwiftUI

struct ImportLegadoJSONURLSheet: View {
    @Binding var isPresented: Bool
    let store: RSSStore
    var onFile: () -> Void = {}
    @State private var urlString = ""
    @State private var request: RSSImportReviewRequest?

    var body: some View {
        Group {
            if let request {
                RSSImportReviewSheet(input: request.input, store: store)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            Button(localized("從檔案匯入")) { onFile() }
                                .accessibilityIdentifier("rss-import-file")
                        }.interfaceSectionSurface()
                        Section {
                            TextField("https://…", text: $urlString)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("rss-import-url")
                        } header: {
                            Text(localized("Legado JSON 網址"))
                        } footer: {
                            Text(localized("可貼上 HTTP(S) 網址或 legado/yuedu 訂閱匯入連結；不需要註冊舊 App 的網址 scheme。"))
                                .dsSectionFooter()
                        }.interfaceSectionSurface()
                    }
                    .navigationTitle(localized("匯入 Legado JSON"))
                    .toolbarTitleDisplayMode(.inline)
                    .themedAppSurface(for: .rss)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { isPresented = false } label: {
                                Label(localized("取消"), systemImage: "xmark").labelStyle(.iconOnly)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if let url = BookSourceImportDeepLink.payloadURL(from: urlString) {
                                    request = .init(input: .remote(url))
                                }
                            } label: {
                                Label(localized("繼續"), systemImage: "checkmark").labelStyle(.iconOnly)
                            }
                            .disabled(BookSourceImportDeepLink.payloadURL(from: urlString) == nil)
                        }
                    }
                }
            }
        }
    }
}

#Preview("RSS import entry") {
    ImportLegadoJSONURLSheet(isPresented: .constant(true), store: RSSStore.shared)
}
