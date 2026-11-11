#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// 只用自建HTML展示生产独立网页；不读取RSSStore、用户源、账号或网络。
struct RSSWebDisplayFixtureHost: View {
    @State private var showingPage = false
    private let source = RSSSource(name: "Web display fixture", url: "https://display-fixture.invalid/")

    var body: some View {
        Button("Open web fixture") { showingPage = true }
            .accessibilityIdentifier("rss.web.fixture.open")
            .fullScreenCover(isPresented: $showingPage) {
                RSSSourcePageSheet(source: source, target: .html(Self.html, baseURL: source.url))
            }
            .preferredColorScheme(ProcessInfo.processInfo.environment["RSS_WEB_DISPLAY_DARK"] == "1" ? .dark : .light)
    }

    static let html = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    body{margin:0;font-family:system-ui;background:white;color:black}
    .panel{position:fixed;width:1300px;height:1800px;left:50%;top:50%;transform:translate(-50%,-50%);background:#ddd;border:1px solid black}
    [hidden]{display:none!important}
    .close{position:absolute;right:16px;top:16px;width:180px;height:80px;font-size:24px}
    #page-action{margin:80px 20px;min-width:150px;min-height:60px}
    </style></head><body>
    <button id="page-action" onclick="this.textContent='Action '+(++window.actions)">Action 0</button>
    <div class="panel" id="second" hidden><button class="close" onclick="document.getElementById('second').hidden=true">Close panel 2</button></div>
    <div class="panel" id="first"><button class="close" onclick="document.getElementById('first').hidden=true;document.getElementById('second').hidden=false">Close panel 1</button></div>
    <script>window.actions=0</script>
    </body></html>
    """
}

#Preview("RSS oversized panels") { RSSWebDisplayFixtureHost() }
#endif
