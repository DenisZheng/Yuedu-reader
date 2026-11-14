import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 全部输入为自建loopback页面及临时Cookie；证明产品跨层合同，不代表真实账号/站点登录通过。
@Suite("S8 restricted cookie image flow", .serialized)
@MainActor
struct S8RestrictedCookieFlowTests {
    @Test("CookieJar关闭仍读取显式/已保存Cookie，列表→图片条目→真实资源保持路径与响应Jar合同", arguments: [false, true])
    func listArticleAndNativeImage(cookieJar: Bool) async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let savedName = "s8saved" + suffix
        let explicitName = "s8explicit" + suffix
        let issuedName = "s8issued" + suffix
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/private/list": .init(body: Data("<div class='item'><a href='/private/article'>Cookie image</a></div>".utf8),
                headers: ["Set-Cookie": issuedName + "=response; Path=/private"]),
            "/private/article": .init(body: Data("<img src='/private/pixel'>".utf8)),
            "/private/pixel": .init(body: png, type: "image/png"),
            "/public/pixel": .init(body: png, type: "image/png")
        ], maximumRequests: 8)
        let base = try await server.start()
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/private", .name: savedName, .value: "saved"]))
        try await SourceScriptThread.run { try CookieStore.shared.synchronizeWebCookies([cookie], removed: []) }
        let root = URL.temporaryDirectory.appendingPathComponent("S8CookieFlow-" + suffix)
        let store = RSSStore(storageDirectory: root)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer {
            server.stop(); session.invalidateAndCancel()
            for item in HTTPCookieStorage.shared.cookies ?? [] where [savedName, explicitName, issuedName].contains(item.name) {
                HTTPCookieStorage.shared.deleteCookie(item)
            }
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "S8 cookie image fixture", url: base.appendingPathComponent("private/list").absoluteString)
        source.importedFromLegado = true
        source.contentType = .image
        source.ruleArticles = ".item"
        source.ruleTitle = "a@text"
        source.ruleLink = "a@href"
        source.ruleContent = "img@src"
        source.header = "{\"Cookie\":\"" + explicitName + "=explicit\"}"
        source.enabledCookieJar = cookieJar
        source.newArticleNotificationsEnabled = false
        store.addSource(source)
        let browser = RSSFeedSession(source: source, store: store, session: session, maxPages: 1)
        await browser.refresh()
        try #require(browser.error == nil && browser.currentPage == 1)
        let article = try #require(store.articles(for: source.id, scope: browser.scope).first)
        #expect(article.contentType == .image)
        let model = RSSTypedArticleModel()
        await model.load(article, source: source, owner: store)
        defer { model.release() }
        guard case .image(let raw) = model.state else { Issue.record("图片型条目未解析到资源目标"); return }
        #expect(raw == base.appendingPathComponent("private/pixel").absoluteString)
        let image = try await RSSImageService.load(raw, source: source, baseURL: URL(string: article.link),
            context: nil, owner: store, ruleURL: true, session: session)
        let display = try await RSSImageService.displayImage(image.data)
        #expect(image.mime == "image/png" && display.size.width == 1 && display.size.height == 1)
        _ = try await RSSImageService.load(base.appendingPathComponent("public/pixel").absoluteString,
            source: source, baseURL: URL(string: article.link), context: nil, owner: store, ruleURL: true, session: session)
        let requests = server.requests
        #expect(requests.map(\.path) == ["/private/list", "/private/article", "/private/pixel", "/public/pixel"])
        for request in requests {
            let cookieHeader = request.headers["cookie"] ?? ""
            #expect(cookieHeader.contains(explicitName + "=explicit"))
            #expect(cookieHeader.contains(savedName + "=saved") == request.path.hasPrefix("/private/"))
            let expectsIssued = cookieJar && request.path != "/private/list" && request.path.hasPrefix("/private/")
            #expect(cookieHeader.contains(issuedName + "=response") == expectsIssued)
        }
        #expect(CookieStore.shared.requestHeader(for: base.appendingPathComponent("private/check")).contains(issuedName + "=response") == cookieJar)
        store.markRead(articleId: article.id, isRead: true)
        store.toggleFavorite(articleId: article.id)
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: root)
        let recovered = try #require(reloaded.article(id: article.id))
        #expect(recovered.isRead && recovered.isFavorite && recovered.contentType == .image)
        print("S8_COOKIE_FLOW synthetic=true jar=\(cookieJar) requests=\(requests.count) nativeImageDecoded=true explicitAndSavedCookies=true pathScoped=true responseJarRespected=true stateReloaded=true")
    }
}
