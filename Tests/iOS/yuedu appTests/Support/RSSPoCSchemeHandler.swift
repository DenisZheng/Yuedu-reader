import Foundation
import WebKit
import XCTest

/// 只用于S1实验：内存白名单资源，不从URL读文件、不代理网络、不接管http/https。
@MainActor
final class RSSPoCSchemeHandler: NSObject, WKURLSchemeHandler {
    struct Resource {
        var data: Data
        var mime: String
    }
    private let resources: [String: Resource]
    private let heldPaths: Set<String>
    private var held: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private(set) var startedRequests: [[String: String]] = []
    var startedPaths: [String] { startedRequests.compactMap { $0["path"] } }
    private(set) var stoppedPaths: [String] = []
    var onHeld: (() -> Void)?
    var onStopped: (() -> Void)?
    var pendingCount: Int { held.count }

    init(resources: [String: Resource], heldPaths: Set<String> = []) {
        self.resources = resources
        self.heldPaths = heldPaths
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "fixture", startedRequests.count < 128 else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        startedRequests.append(["path": url.path, "method": task.request.httpMethod ?? "GET", "range": task.request.value(forHTTPHeaderField: "Range") ?? "none"])
        guard resources[url.path] != nil else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        if heldPaths.contains(url.path) {
            held[ObjectIdentifier(task)] = task
            onHeld?()
        } else {
            deliver(task)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        if held.removeValue(forKey: ObjectIdentifier(task)) != nil {
            stoppedPaths.append(task.request.url?.path ?? "")
            onStopped?()
        }
    }

    /// 只交付仍然活跃的任务；stop之后不能再调用WKURLSchemeTask的任何结果方法。
    func releaseHeld() -> Int {
        let live = Array(held.values)
        held.removeAll()
        live.forEach(deliver)
        return live.count
    }

    private func deliver(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url, let resource = resources[url.path] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var body = resource.data
        var status = 200
        var headers = ["Content-Type": resource.mime, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if let range = task.request.value(forHTTPHeaderField: "Range") {
            if let bounds = VideoStillFixtureServer.bounds(range, count: body.count) {
                headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(body.count)"
                body = body.subdata(in: bounds)
                status = 206
            } else {
                headers["Content-Range"] = "bytes */\(body.count)"
                body = Data()
                status = 416
            }
        }
        headers["Content-Length"] = "\(body.count)"
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        if task.request.httpMethod != "HEAD" { task.didReceive(body) }
        task.didFinish()
    }
}
