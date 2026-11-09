import SwiftUI
import Testing
import UIKit
import WebKit
import os
@testable import yuedu_app

@Suite("RSS web request contract", .serialized)
@MainActor
struct RSSWebRequestTests {
    @Test("实际首文档保留charset/bodyJs和登录检查；动态URL及POST仅执行一次")
    func preparedRequestReachesSharedResponsePipeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let body = try #require("<p id='value'>原文</p>".data(using: big5))
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/page": .init(body: body, type: "text/html; charset=utf-8", allowedMethods: ["POST"])
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let options: [String: String] = ["method": "POST", "body": "fixture=1", "charset": "big5",
            "bodyJs": "source.put('bodyRuns',String(Number(source.get('bodyRuns')||'0')+1));result.replace('原文','正文')"]
        let rule = base.appendingPathComponent("page").absoluteString + "," + String(decoding: try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]), as: UTF8.self)
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: rule, options: [.fragmentsAllowed]), as: UTF8.self)
        var source = RSSSource(name: "Response pipeline", url: base.absoluteString)
        source.importedFromLegado = true; source.singleUrl = true
        source.jsLib = "var evals=0;function entry(){source.put('evals',String(++evals));return \(literal); }"
        source.sortUrl = "@js:entry()"
        source.loginCheckJs = "source.put('loginChecked',String(result.code()));result"
        store.addSource(source)
        let target = try #require(try await RSSOpenTarget.resolve(source: source, owner: store))
        var loading = true
        var error: String?
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 }), owner: store))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!loading && error == nil)
        let web = try #require(findWeb(in: window))
        let text = try await web.evaluateJavaScript("document.getElementById('value').textContent") as? String
        #expect(text == "正文")
        #expect(store.variables(for: source.id)["loginChecked"] == "200")
        #expect(store.variables(for: source.id)["bodyRuns"] == "1")
        #expect(store.variables(for: source.id)["evals"] == "1")
        #expect(server.requests.filter { $0.path == "/page" }.count == 1)
        #expect(server.requests.first?.method == "POST")
        #expect(server.requests.first.map { String(decoding: $0.body, as: UTF8.self) } == "fixture=1")
        try await store.flushPersistence()
    }

    @Test("已准备的请求在Store登录或真实凭据修订后失效，不能重放旧头部")
    func stalePreparedRequestNeverStarts() async throws {
        for credentialOnly in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RSSStore(storageDirectory: directory)
            let server = try VideoStillFixtureServer(directory: directory)
            let base = try await server.start()
            defer {
                server.stop()
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
            var source = RSSSource(name: "Prepared", url: base.absoluteString)
            source.importedFromLegado = true; source.singleUrl = true
            store.addSource(source)
            let key = RSSRuntime.authenticationKey(for: source)
            defer { LoginManager.shared.removeLoginHeader(sourceUrl: key) }
            let target = try #require(try await RSSOpenTarget.resolve(source: source, owner: store))
            guard case .request(let request, let context) = target else { Issue.record("未生成请求"); return }
            if credentialOnly { LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: #"{"X-Login":"changed"}"#) }
            else { store.authenticationChanged(for: source.id) }
            do {
                _ = try await RSSOpenTarget.loadDocument(request, context: context, source: source, owner: store)
                Issue.record("旧请求未撤销")
            } catch is CancellationError { }
            #expect(server.requests.isEmpty)
            try await store.flushPersistence()
        }
    }

    @Test("同源其他流程更新凭据时，已排队网页不能重放旧请求")
    func queuedRequestRevalidatesCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/": .init(body: Data("<p>Must not load</p>".utf8), type: "text/html")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Queued", url: base.absoluteString)
        source.importedFromLegado = true; source.singleUrl = true
        store.addSource(source)
        let key = RSSRuntime.authenticationKey(for: source)
        LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: #"{"X-Login":"old"}"#)
        defer { LoginManager.shared.removeLoginHeader(sourceUrl: key) }
        let target = try #require(try await RSSOpenTarget.resolve(source: source, owner: store))
        guard case .request(let request, let context) = target else { Issue.record("未生成请求"); return }
        let runtime = try await RSSRuntime.make(source: source, owner: store)
        let latch = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let holder = Task {
            try await runtime.session.operation { _ in
                await withCheckedContinuation { continuation in latch.withLock { $0 = continuation } }
            }
        }
        defer {
            latch.withLock { continuation in continuation?.resume(); continuation = nil }
            holder.cancel()
        }
        var deadline = ContinuousClock.now + .seconds(6)
        while latch.withLock({ $0 == nil }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(latch.withLock { $0 != nil })
        let config = source
        let pending = Task { try await RSSOpenTarget.loadDocument(request, context: context, source: config, owner: store) }
        defer { pending.cancel() }
        deadline = ContinuousClock.now + .seconds(6)
        while runtime.session.queuedCallers == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(runtime.session.queuedCallers == 1)
        runtime.state.mutateCredentials { revision in
            LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: #"{"X-Login":"new"}"#, expectedRevision: revision)
        }
        latch.withLock { continuation in continuation?.resume(); continuation = nil }
        try await holder.value
        do {
            _ = try await pending.value
            Issue.record("已排队的旧请求在凭据变更后仍被发送")
        } catch is CancellationError { }
        #expect(server.requests.isEmpty)
        try await store.flushPersistence()
    }

    @Test("原网页URL与bodyJs继承同一文章变量和rssArticle上下文")
    func articleContextCrossesTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/article-a": .init(body: Data("Body A".utf8)),
            "/article-b": .init(body: Data("Body B".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Context", url: base.absoluteString)
        source.ruleArticles = "class.item"
        source.loginCheckJs = "source.put('login-'+rssArticle.title,java.get('seed'));result"
        store.addSource(source)
        let options = try JSONSerialization.data(withJSONObject: [
            "bodyJs": "source.put('body-'+rssArticle.title,java.get('seed'));'<p>'+rssArticle.title+'|'+rssArticle.sort+'|'+java.get('seed')+'</p>'"
        ])
        var prepared: [RSSOpenTarget] = []
        for name in ["a", "b"] {
            var item = RSSItem(id: "article-" + name, title: name, link: base.appendingPathComponent("article-" + name).absoluteString + "," + String(decoding: options, as: UTF8.self), sourceId: source.id)
            item.variables = ["seed": "seed-" + name]; item.categoryName = "Category-" + name
            store.mergeFetchedItems([item], for: source.id)
            let article = try #require(store.article(id: item.id))
            prepared.append(try await RSSOpenTarget.originalArticle(article, source: source, owner: store))
        }
        let config = source
        let documents: [RSSOpenTarget.Document]
        do {
            documents = try await withThrowingTaskGroup(of: RSSOpenTarget.Document.self) { group in
                for target in prepared {
                    guard case .request(let request, let context) = target else { Issue.record("未生成请求"); continue }
                    group.addTask { try await RSSOpenTarget.loadDocument(request, context: context, source: config, owner: store) }
                }
                var results: [RSSOpenTarget.Document] = []
                for try await document in group { results.append(document) }
                return results
            }
        } catch { try await store.flushPersistence(); throw error }
        #expect(Set(documents.map { String(decoding: $0.data, as: UTF8.self) }) == ["<p>a|Category-a|seed-a</p>", "<p>b|Category-b|seed-b</p>"])
        for name in ["a", "b"] {
            #expect(store.variables(for: source.id)["login-" + name] == "seed-" + name)
            #expect(store.variables(for: source.id)["body-" + name] == "seed-" + name)
        }
        #expect(store.variables(for: source.id)["seed"] == nil)
        #expect(server.requests.count == 2)
        try await store.flushPersistence()
    }

    @Test("HTTP403也经过源登录检查，但不伪装成正常网页")
    func errorResponseRunsLoginCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/denied": .init(body: Data("Denied".utf8), status: "403 Forbidden")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Login check", url: base.appendingPathComponent("denied").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true
        source.loginCheckJs = "source.put('checked',String(result.code()));result"
        store.addSource(source)
        let target = try #require(try await RSSOpenTarget.resolve(source: source, owner: store))
        guard case .request(let request, let context) = target else { Issue.record("未生成请求"); return }
        do {
            _ = try await RSSOpenTarget.loadDocument(request, context: context, source: source, owner: store)
            Issue.record("403不能作为成功文章")
        } catch ScraperError.httpStatus(let code) { #expect(code == 403) }
        #expect(store.variables(for: source.id)["checked"] == "403")
        try await store.flushPersistence()
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    private func findWeb(in view: UIView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWeb(in: $0) }.first
    }
}
