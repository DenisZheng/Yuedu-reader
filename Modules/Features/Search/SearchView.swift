import SwiftUI

struct SearchView: View {
    var initialQuery: String = ""
    var sessionScope: SearchSourceScope?
    /// 全局搜索与源内搜索复用实现；搜索已不是Tab，始终使用推入页标题。
    var usesUnifiedSearch = false

    var body: some View {
        BookSearchView(initialQuery: initialQuery, sessionScope: sessionScope,
                       usesUnifiedSearch: usesUnifiedSearch)
            .remoteLibraryDestinations()
            .publicLibraryDestinations()
    }
}

#Preview("搜索页") {
    NavigationStack { SearchView(usesUnifiedSearch: true) }
        .environmentObject(BookStore())
}
