import Foundation
import WebKit

/// 网页加载只记录类型化元数据，不读取/输出错误文案、URL、头、正文或证书。
/// 不放宽SourceDiagnosticContext；调用点在源脚本执行作用域之外，仍走现有AppLogger/DiagnosticLog。
enum RSSWebLoadDiagnostics {
    enum Phase: String, Sendable {
        case runtime, document, browser, html, cookies, resources, scripts, webkit, provisional, navigation, webProcess
    }
    enum Event: String, Sendable { case started, received, submitted, finished, failed }

    struct Attempt: Sendable {
        let id = UUID().uuidString
        let source: String
        let key: String
        private let started = ContinuousClock.now

        init(source: RSSSource) {
            self.source = String(RSSIdentity.digest([source.id]).prefix(16))
            key = String(RSSIdentity.digest([source.sourceKey]).prefix(16))
        }

        func message(_ event: Event, phase: Phase, failure: Error? = nil,
                     statusCode: Int? = nil, bytes: Int? = nil) -> String {
            let duration = started.duration(to: ContinuousClock.now).components
            let ms = max(0, duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
            var parts = ["[RSSWebLoad]", "attempt=\(id)", "source=\(source)", "key=\(key)",
                         "phase=\(phase.rawValue)", "event=\(event.rawValue)", "ms=\(ms)"]
            if let statusCode, (100...999).contains(statusCode) { parts.append("httpStatus=\(statusCode)") }
            if let bytes { parts.append("bytes=\(max(0, bytes))") }
            if let failure { parts += RSSWebLoadDiagnostics.failureFields(failure) }
            return parts.joined(separator: " ")
        }
    }

    static func record(_ attempt: Attempt?, _ event: Event, phase: Phase, failure: Error? = nil,
                       statusCode: Int? = nil, bytes: Int? = nil) {
        guard let attempt else { return }
        AppLogger.network(attempt.message(event, phase: phase, failure: failure, statusCode: statusCode, bytes: bytes),
                          level: event == .failed ? .warning : .info)
        // 仅文档失败/完成时异步落盘；不在主线程等待、不逐资源写文件。
        if event == .failed || event == .finished { DiagnosticLog.shared.flush() }
    }

    private static func failureFields(_ failure: Error) -> [String] {
        if let scraper = failure as? ScraperError {
            switch scraper {
            case .httpStatus(let code):
                return ["domain=scraper", "kind=httpStatus"] + ((100...999).contains(code) ? ["httpStatus=\(code)"] : [])
            case .invalidURL: return ["domain=scraper", "kind=invalidURL"]
            case .invalidRule: return ["domain=scraper", "kind=invalidRule"]
            case .httpError: return ["domain=scraper", "kind=httpError"]
            case .encodingError: return ["domain=scraper", "kind=encodingError"]
            case .noArticlesFound: return ["domain=scraper", "kind=noArticlesFound"]
            case .atsBlocked: return ["domain=scraper", "kind=atsBlocked"]
            case .scriptFailure: return ["domain=scraper", "kind=scriptFailure"]
            case .interactionRequired: return ["domain=scraper", "kind=interactionRequired"]
            case .runtimeStateUnavailable: return ["domain=scraper", "kind=runtimeStateUnavailable"]
            case .executionTimedOut: return ["domain=scraper", "kind=executionTimedOut"]
            case .contentIncomplete: return ["domain=scraper", "kind=contentIncomplete"]
            }
        }
        if let web = failure as? RSSWebFailure {
            let kind: String
            switch web {
            case .actionUnavailable: kind = "actionUnavailable"
            case .navigationBlocked: kind = "navigationBlocked"
            case .formBodyUnavailable: kind = "formBodyUnavailable"
            case .resourceRuleUnsupported: kind = "resourceRuleUnsupported"
            case .resourceUnavailable: kind = "resourceUnavailable"
            case .imageFormatRestricted: kind = "imageFormatRestricted"
            case .viewportUnavailable: kind = "viewportUnavailable"
            }
            return ["domain=rss", "kind=\(kind)"]
        }
        var result: [String] = []
        var current: NSError? = failure as NSError
        var seen = Set<ObjectIdentifier>()
        // 用户输入可伪造NSError并形成循环；最多三层，只保留已知系统域的数值错误码。
        for depth in 0..<3 {
            guard let error = current, seen.insert(ObjectIdentifier(error)).inserted else { break }
            let domain: String
            switch error.domain {
            case NSURLErrorDomain: domain = "url"
            case WKError.errorDomain: domain = "webkit"
            case NSCocoaErrorDomain: domain = "cocoa"
            case NSPOSIXErrorDomain: domain = "posix"
            case NSOSStatusErrorDomain: domain = "osstatus"
            case "kCFErrorDomainCFNetwork": domain = "cfnetwork"
            case "kCFErrorDomainCFNetworkPAC": domain = "pac"
            default: domain = "other"
            }
            let prefix = depth == 0 ? "" : "underlying\(depth)."
            result.append("\(prefix)domain=\(domain)")
            if domain != "other" { result.append("\(prefix)code=\(error.code)") }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}
