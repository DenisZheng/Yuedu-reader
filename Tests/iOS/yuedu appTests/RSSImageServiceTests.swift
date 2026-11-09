import Foundation
import UIKit
import WebKit
import Testing
@testable import yuedu_app

@Suite("RSS production image service", .serialized)
@MainActor struct RSSImageServiceTests {
    @Test("共享RSS脚本上下文实际解码图片字节；认证、显式Referer到达网络")
    func imageDecodeAndHeaders() async throws {
        let plain = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let encrypted = Data(plain.map { $0 ^ 0x5a })
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/encrypted": .init(body: encrypted, type: "application/octet-stream", requiredHeaders: ["x-fixture": "image-fixture", "referer": "https://fixture.invalid/page"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Image synthetic", url: base.absoluteString)
        source.importedFromLegado = true
        source.header = #"{"X-Fixture":"image-fixture","Referer":"https://fixture.invalid/page"}"#
        source.jsLib = "var fixtureDecodes=0;function fixtureKey(){return 0x5a}"
        source.coverDecodeJs = "@js:fixtureDecodes++;var b=result.readAllBytes();for(var i=0;i<b.length;i++)b[i]^=fixtureKey();b"
        for _ in 0..<2 {
            let image = try await RSSImageService.load("/encrypted", source: source, baseURL: base, context: nil, owner: nil)
            #expect(image.data == plain)
            #expect(image.mime == "image/png")
            let displayed = try await RSSImageService.displayImage(image.data)
            #expect(displayed.size.width == 1)
        }
        let runtime = try await RSSRuntime.make(source: source)
        let count = try await runtime.run { host in try await host.run { bridge in
            try bridge.withRuleContext(content: "", baseURL: base.absoluteString, scope: RuleData(), stage: "rss.fixture") { _ in bridge.evaluateSourceScript("String(fixtureDecodes)") }
        } }
        #expect(count == "2")
        #expect(server.requests.count == 2)
    }

    @Test("解码失败、非图片、超限响应明确失败，不展示原密文或继续下载")
    func errorsAreNotImages() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/bad": .init(body: Data("Not an image".utf8), type: "text/html"),
            "/large": .init(body: Data(repeating: 7, count: 1_025))
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Image failures", url: base.absoluteString)
        source.coverDecodeJs = "@js:throw new Error('synthetic private decode data')"
        do {
            _ = try await RSSImageService.load("/bad", source: source, baseURL: base, context: nil, owner: nil)
            Issue.record("解码异常未失败")
        } catch is CancellationError { Issue.record("非取消错误不应伪装取消") }
        catch { #expect(error.localizedDescription.contains("synthetic private") == false) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString, cookieJarEnabled: false,
                                             maximumBytes: 1_024)
        do {
            _ = try await executor.data(for: URLRequest(url: base.appendingPathComponent("large")))
            Issue.record("超限响应未被拒绝")
        } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
    }

    @Test("过滤优先级/大小写/全串正则与Android一致，原生和WebKit同一个配置")
    func filterParity() async throws {
        var source = RSSSource(name: "Filter", url: "https://fixture.invalid")
        source.contentBlacklist = "https://fixture.invalid/blocked/[0-9]+\\.png"
        source.contentWhitelist = "https://fixture.invalid/only"
        let blackSource = source
        let black = try await SourceScriptThread.run { try RSSResourceRules(source: blackSource) }
        #expect(try black.allows(URL(string: "https://fixture.invalid/blocked/7.png")!) == false)
        #expect(try black.allows(URL(string: "https://fixture.invalid/blocked/7.png?next=1")!))
        #expect(try black.allows(URL(string: "https://fixture.invalid/outside")!))
        _ = try await black.compiled()
        source.contentBlacklist = nil
        let whiteSource = source
        let white = try await SourceScriptThread.run { try RSSResourceRules(source: whiteSource) }
        #expect(try white.allows(URL(string: "https://fixture.invalid/only/1")!))
        #expect(try white.allows(URL(string: "https://fixture.invalid/Only/1")!) == false)
        _ = try await white.compiled()
        source.contentWhitelist = "https://fixture.invalid/(?<=path/)image"
        let limitedSource = source
        let limited = try await SourceScriptThread.run { try RSSResourceRules(source: limitedSource) }
        do { _ = try await limited.compiled(); Issue.record("Java lookbehind不能假装已映射到WebKit") }
        catch { #expect(error is RSSWebFailure) }
    }
}
