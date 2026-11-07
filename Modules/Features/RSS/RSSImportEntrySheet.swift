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
                        Section(localized("Legado JSON 網址")) {
                            TextField("https://…", text: $urlString)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("rss-import-url")
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
                                if let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    request = .init(input: .remote(url))
                                }
                            } label: {
                                Label(localized("繼續"), systemImage: "checkmark").labelStyle(.iconOnly)
                            }
                            .disabled(URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || urlString.isEmpty)
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
