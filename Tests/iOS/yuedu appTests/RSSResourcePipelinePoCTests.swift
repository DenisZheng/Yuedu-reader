import UIKit
import WebKit
import XCTest
@testable import yuedu_app

/// S1资源管道实验：使用共享脚本会话和WebKit真实加载，不代表RSS生产路径已接入。
@MainActor
final class RSSResourcePipelinePoCTests: XCTestCase {
    private var directory: URL { VideoStillFixtures.directory() }

    func testSharedScriptDecodeReachesWebKitImageAndKeepsSourceContext() async throws {
        let plain = pixel()
        let encrypted = Data(plain.map { $0 ^ 0x5a })
        XCTAssertNil(UIImage(data: encrypted))
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/encrypted.png": .init(body: encrypted, type: "application/octet-stream", requiredHeaders: ["referer": "https://fixture.invalid/page"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        let originalURL = base.appendingPathComponent("encrypted.png")
        var request = URLRequest(url: originalURL)
        request.setValue("https://fixture.invalid/page", forHTTPHeaderField: "Referer")
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let (bytes, response) = try await network.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(bytes, encrypted)

        // 仅作为现有共享桥的测试适配，不把RSS写入书源store或混用SourceType。
        var source = BookSource(bookSourceUrl: base.absoluteString, bookSourceName: "RSS image PoC")
        source.jsLib = "var fixtureDecodes=0; function fixtureKey(){return 0x5a;}"
        let session = BookSourceSession.session(for: source)
        let warm = await session.withTurn { bridge in bridge.evaluateExploreKindScript("typeof fixtureKey") }
        XCTAssertEqual(warm, "function")
        let rule = """
            @js:if(!src.endsWith('/encrypted.png')) throw new Error('unexpected fixture src');
            fixtureDecodes++;
            var b=result.readAllBytes(); for(var i=0;i<b.length;i++) b[i]^=fixtureKey(); b
            """
        let first = await SourceImageDecoder.decode(bytes, src: originalURL.absoluteString, ruleJs: rule, source: source)
        let second = await SourceImageDecoder.decode(bytes, src: originalURL.absoluteString, ruleJs: rule, source: source)
        let decoded = try XCTUnwrap(first)
        XCTAssertEqual(decoded, plain)
        XCTAssertEqual(second, plain)
        let count = await session.withTurn { bridge in bridge.evaluateExploreKindScript("String(fixtureDecodes)") }
        XCTAssertEqual(count, "2", "重复解码必须复用原会话，不重建jsLib上下文")

        let handler = RSSPoCSchemeHandler(resources: [
            "/page": .init(data: Data("<img id='decoded' src='decoded.png'><img id='raw' src='raw.png'>".utf8), mime: "text/html"),
            "/decoded.png": .init(data: decoded, mime: "image/png"),
            "/raw.png": .init(data: bytes, mime: "image/png")
        ])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: "readerfork-fixture")
        let page = try RSSPoCWebPage(configuration: config)
        defer { page.close() }
        let url = try XCTUnwrap(URL(string: "readerfork-fixture://fixture/page"))
        try await page.waiter.load { page.view.load(URLRequest(url: url)) }
        let result = try await page.view.evaluateJavaScript("[document.getElementById('decoded').naturalWidth,document.getElementById('raw').naturalWidth]") as? [Int]
        XCTAssertEqual(result, [1, 0])
        XCTAssertTrue(handler.startedPaths.contains("/decoded.png"))
    }

    func testDecodeFailureDoesNotBecomeAValidImage() async throws {
        let source = BookSource(bookSourceUrl: "https://decode-failure-\(UUID().uuidString).invalid", bookSourceName: "RSS failure fixture")
        let bytes = Data(pixel().map { $0 ^ 0x5a })
        let result = await SourceImageDecoder.decode(bytes, src: "https://fixture.invalid/bad.png", ruleJs: "@js:throw new Error('synthetic decode failure')", source: source)
        XCTAssertNil(result)
        XCTAssertNil(UIImage(data: bytes), "现有书源调用方保留原bytes不等于RSS图片成功；S6需显式报告解码失败")
    }

    func testImageFiltersPreserveBlacklistPrecedencePrefixAndFullMatch() async throws {
        let image = pixel()
        let html = """
            <img id='allowed' src='/allowed'><img id='blocked' src='/blocked/7.svg'>
            <img id='suffix' src='/blocked/7.svg?extra=1'><img id='outside' src='/outside'><img id='upper' src='/Allowed'>
            """
        var routes: [String: VideoStillFixtureServer.Response] = ["/page": .init(body: Data(html.utf8))]
        for path in ["/allowed", "/blocked/7.svg", "/outside", "/Allowed"] { routes[path] = .init(body: image, type: "image/png") }
        let server = try VideoStillFixtureServer(directory: directory, routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let origin = String(base.absoluteString.dropLast())
        // 预期来自固定Android合同：黑名单非空时不执行白名单；前缀或全串正则命中。
        let cases: [(String, [String], [String], [Int])] = [
            ("black-precedes-white", [origin + "/blocked"], [origin + "/allowed"], [1,0,0,1,1]),
            ("white-only", [], [origin + "/allowed"], [1,0,0,0,0]),
            ("full-regex-not-substring", [origin + "/blocked/[0-9]+\\.svg"], [], [1,0,1,1,1]),
            ("main-document-is-not-an-image", [origin], [], [0,0,0,0,0])
        ]
        let storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-content-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: storeDirectory) }
            catch { XCTFail("清理本次规则fixture失败：\(error)") }
        }
        let store = try XCTUnwrap(WKContentRuleListStore(url: storeDirectory))
        for (name, blacklist, whitelist, expected) in cases {
            let encoded = try imageOnlyRules(blacklist: blacklist, whitelist: whitelist)
            let compiled = try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: encoded)
            let list = try XCTUnwrap(compiled)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(list)
            let page = try RSSPoCWebPage(configuration: config)
            defer { page.close() }
            try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
            let widths = try await page.view.evaluateJavaScript("['allowed','blocked','suffix','outside','upper'].map(id=>document.getElementById(id).naturalWidth)") as? [Int]
            XCTAssertEqual(widths, expected, name)
            try await store.removeContentRuleList(forIdentifier: name)
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/page" }.count, cases.count)
    }

    func testJavaRegexCannotBeAssumedToCompileAsWebKitRule() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rss-invalid-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: path) }
            catch { XCTFail("清理规则fixture失败：\(error)") }
        }
        let store = try XCTUnwrap(WKContentRuleListStore(url: path))
        let encoded = try imageOnlyRules(blacklist: ["https://fixture.invalid/(?<=path/)image"], whitelist: [])
        do {
            _ = try await store.compileContentRuleList(forIdentifier: "lookbehind", encodedContentRuleList: encoded)
            XCTFail("WebKit不能直接承载此Java正则；S6必须披露/拒绝，而非静默放行")
        } catch {
            XCTAssertEqual((error as NSError).domain, WKError.errorDomain)
        }
    }

    /// 仅验证可表示的图片规则子集，不是RSS生产过滤器：全frame/预注入例外仍由S6接入。
    private func imageOnlyRules(blacklist: [String], whitelist: [String]) throws -> String {
        var rules: [[String: Any]] = []
        func add(_ pattern: String, action: String) {
            rules.append(["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": true, "resource-type": ["image"]], "action": ["type": action]])
        }
        let patterns = blacklist.isEmpty ? whitelist : blacklist
        let action = blacklist.isEmpty ? "ignore-previous-rules" : "block"
        if blacklist.isEmpty && !whitelist.isEmpty { add(".*", action: "block") }
        for pattern in patterns {
            add("^" + NSRegularExpression.escapedPattern(for: pattern), action: action)
            add("^(" + pattern + ")$", action: action)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }

    private func pixel() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
