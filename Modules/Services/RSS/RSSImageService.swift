import Foundation
import ImageIO
import UIKit
import Network

/// RSS图片使用原请求/脚本宿主，不借用书源store或建立第二份解码缓存。
enum RSSImageService {
    struct Image: Sendable {
        var data: Data
        var url: URL
        var mime: String
    }
    static let maximumBytes = 16 * 1_024 * 1_024

    nonisolated static func load(_ raw: String, source: RSSSource, baseURL: URL?,
        context: RSSOpenTarget.RequestContext?, owner: RSSStore?, ruleURL: Bool = false,
        rules: RSSResourceRules? = nil, session: URLSession = LegadoJSBridge.requestSession, authentication: Bool = false) async throws -> Image {
        try await context?.validate(source: source, owner: owner)
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        if authentication { return try await loadAuthenticationImage(raw, source: source, base: baseURL, context: context, runtime: runtime, rules: rules, session: session) }
        let frameURL = context?.requestURL ?? baseURL ?? source.articleLinkBaseURL
        let permitted = SourceRequestHeaderScope(urls: [frameURL].compactMap { $0 })
        return try await runtime.run { host in
            try await context?.validate(source: source, owner: owner)
            let prepared = try await host.run { bridge in
                let data = RuleData(); data.variableMap = context?.variables ?? [:]
                return try bridge.withRuleContext(content: "", baseURL: baseURL?.absoluteString ?? source.sourceKey,
                    scope: data, bindings: context?.bindings(source: source, data: data) ?? [:], stage: "rss.image.request") { _ in
                    if ruleURL { return try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(raw), scope: data) }
                    let url = try RSSWebActionRouter.pageURL(raw, base: baseURL)
                    var value = try bridge.prepareNativeWebRequest(URLRequest(url: url), scope: data)
                    if permitted.contains(url) {
                        for (key, header) in context?.headers ?? [:] where value.request.value(forHTTPHeaderField: key) == nil
                            && !["content-length", "content-type", "host"].contains(key.lowercased()) {
                            value.request.setValue(header, forHTTPHeaderField: key)
                        }
                    }
                    return value
                }
            }
            var request = prepared.request
            if ruleURL, let url = request.url { permitted.admitPrimaryURL(url) }
            if request.value(forHTTPHeaderField: "Referer") == nil, let frameURL,
               var components = URLComponents(url: frameURL, resolvingAgainstBaseURL: true) {
                components.fragment = nil
                if !permitted.contains(request.url) { components.path = "/"; components.query = nil }
                request.setValue(components.url?.absoluteString, forHTTPHeaderField: "Referer")
            }
            let executor = SourceRequestExecutor(session: session, rate: source.concurrentRate ?? "",
                // 网页图片沿浏览器Cookie生命周期；原生type=1保留源的请求Jar开关。
                rateKey: RSSRuntime.authenticationKey(for: source), cookieJarEnabled: ruleURL ? source.enabledCookieJar : true,
                runtimeState: runtime.state, cookieScope: permitted, maximumBytes: maximumBytes,
                requestValidator: { url in
                    try validateResourceURL(url, permitted: permitted, trusted: ruleURL)
                    if let rules, try !rules.allows(url) { throw RSSResourceRules.Blocked() }
                })
            let (bytes, response) = try await executor.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let url = response.url else { throw RSSWebFailure.resourceUnavailable }
            let decoded = try await host.run { bridge in
                let data = RuleData(); data.variableMap = prepared.variables
                return try bridge.withRuleContext(content: "", baseURL: url.absoluteString, scope: data,
                    bindings: context?.bindings(source: source, data: data) ?? [:], stage: "rss.image.decode") { _ in
                    guard let script = source.coverDecodeJs, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return bytes }
                    guard let value = bridge.decodeImageBytes(bytes, src: request.url?.absoluteString ?? raw, ruleJs: script),
                          !value.isEmpty, value.count <= maximumBytes else { throw RSSWebFailure.resourceUnavailable }
                    return value
                }
            }
            let mime = try inspect(decoded)
            return Image(data: decoded, url: url, mime: mime)
        }
    }
    /// 登录等待期间JS宿主仍被配置脚本占用；认证图片仅用已准备的值请求，不在这里重入JSC。
    nonisolated private static func loadAuthenticationImage(_ raw: String, source: RSSSource, base: URL?,
        context: RSSOpenTarget.RequestContext?, runtime: RSSRuntime, rules: RSSResourceRules?, session: URLSession) async throws -> Image {
        let url = try RSSWebActionRouter.pageURL(raw, base: base)
        let allowed = SourceRequestHeaderScope(urls: [context?.requestURL ?? base].compactMap { $0 })
        var request = URLRequest(url: url)
        for (name, value) in allowed.inheritedHeaders(context?.headers ?? [:], for: url)
            where !["content-length", "content-type", "host"].contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let executor = SourceRequestExecutor(session: session, rate: source.concurrentRate ?? "", rateKey: RSSRuntime.authenticationKey(for: source),
            cookieJarEnabled: true, runtimeState: runtime.state, cookieScope: allowed, maximumBytes: maximumBytes,
            requestValidator: { target in
                try validateResourceURL(target, permitted: allowed, trusted: false)
                if let rules, try !rules.allows(target) { throw RSSResourceRules.Blocked() }
            })
        let (bytes, response) = try await executor.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let actual = response.url else { throw RSSWebFailure.resourceUnavailable }
        return Image(data: bytes, url: actual, mime: try inspect(bytes))
    }

    nonisolated static func inspect(_ data: Data) throws -> String {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try SourcePerfTrace.span("rss.image.inspect", "main=\(Thread.isMainThread),bytes=\(data.count)") {
            guard data.count <= maximumBytes,
                  let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(image),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32_000_000 / height else { throw RSSWebFailure.resourceUnavailable }
            switch type as String {
            case "public.jpeg": return "image/jpeg"
            case "public.png": return "image/png"
            case "com.compuserve.gif": return "image/gif"
            case "org.webmproject.webp": return "image/webp"
            case "public.heic", "public.heif": return "image/heic"
            case "public.avif": return "image/avif"
            case "com.microsoft.bmp": return "image/bmp"
            case "com.microsoft.ico": return "image/x-icon"
            default: throw RSSWebFailure.resourceUnavailable
            }
        }
    }
    nonisolated static func displayImage(_ data: Data) async throws -> UIImage {
        try await SourceScriptThread.run {
            try SourcePerfTrace.span("rss.image.display", "main=\(Thread.isMainThread),bytes=\(data.count)") {
                guard let value = UIImage(data: data)?.preparingForDisplay() else { throw RSSWebFailure.resourceUnavailable }
                return value
            }
        }
    }
    nonisolated static func validateResourceURL(_ url: URL, permitted: SourceRequestHeaderScope, trusted: Bool) throws {
        guard SourceRequestHeaderScope.origin(url) != nil, url.user == nil, url.password == nil else { throw RSSWebFailure.navigationBlocked }
        if trusted || permitted.contains(url) { return }
        // 远程DOM不是通用HTTP代理：外站只读取公开HTTPS图片，不带/接收其他站点Cookie。
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              IPv4Address(host) == nil, IPv6Address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) == nil
        else { throw RSSWebFailure.navigationBlocked }
    }
}
