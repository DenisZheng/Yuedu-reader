import Foundation
import WebKit

/// 图片专用的有界scheme，不接管http(s)，不接收任意method/body/headers，也不返回网页或脚本。
@MainActor final class RSSWebImages: NSObject, WKURLSchemeHandler {
    static let scheme = "reader-rss-image"
    private struct Active { var task: any WKURLSchemeTask; var work: Task<Void, Never>? }
    private var requests: [ObjectIdentifier: Active] = [:]
    private var pending: [ObjectIdentifier] = []
    private var pendingIndex = 0
    private var activeCount = 0
    private var images: [String: URL] = [:]
    private var reverse: [String: String] = [:]
    private var prefix = ""
    private var source: RSSSource?
    private var context: RSSOpenTarget.RequestContext?
    private var base: URL?
    private weak var owner: RSSStore?
    private var state: RSSRuntimeState?
    private var rules: RSSResourceRules?
    private(set) var needsPipeline = false
    private var generation = 0
    private var authentication = false
    var onFailure: ((Error) -> Void)?
    var onCookiesChanged: (() async throws -> Void)?

    func reset() {
        generation &+= 1
        let active = requests
        requests.removeAll()
        pending.removeAll(); pendingIndex = 0; activeCount = 0
        for value in active.values { value.work?.cancel(); value.task.didFailWithError(CancellationError()) }
        images.removeAll(); reverse.removeAll()
        source = nil; context = nil; state = nil; rules = nil
        needsPipeline = false
    }
    func bind(source: RSSSource, context: RSSOpenTarget.RequestContext?, base: URL?, runtime: RSSRuntime, in view: WKWebView, authentication: Bool = false) async throws {
        reset()
        let id = generation
        let policy = try await SourceScriptThread.run { try RSSResourceRules(source: source) }
        let compiled = try await policy.compiled()
        try Task.checkCancellation()
        guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let compiled { controller.add(compiled) }
        self.source = source; self.context = context; self.base = base; owner = runtime.owner; state = runtime.state; rules = policy
        self.authentication = authentication
        prefix = Self.scheme + "://" + UUID().uuidString.lowercased() + "/"
        needsPipeline = !authentication && source.coverDecodeJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || (context?.headers ?? [:]).contains { !SourceRequestHeaderScope.publicHeaderNames.contains($0.key.lowercased()) && $0.key.lowercased() != "cookie" }
    }
    func rewrite(_ html: String) async throws -> String {
        guard needsPipeline else { return html }
        let prefix = prefix, base = base, id = generation
        let output = try await SourceScriptThread.run { try RSSImageMarkup.rewrite(html, base: base, prefix: prefix) }
        try Task.checkCancellation()
        guard id == generation, state?.isCurrent == true else { throw CancellationError() }
        images = output.images
        reverse = Dictionary(output.images.map { ($0.value.absoluteString, $0.key) }, uniquingKeysWith: { first, _ in first })
        return output.html
    }
    func register(_ raw: String) throws -> String {
        guard needsPipeline, state?.isCurrent == true else { throw RSSWebFailure.resourceUnavailable }
        if raw.hasPrefix(prefix) { return images[String(raw.dropFirst(prefix.count))] == nil ? "" : raw }
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, SourceRequestHeaderScope.origin(url) != nil else { return raw }
        guard url.absoluteString.utf8.count <= 8_192, images.count < 2_048 else { throw RSSWebFailure.resourceUnavailable }
        if let id = reverse[url.absoluteString] { return prefix + id }
        let id = UUID().uuidString.lowercased()
        images[id] = url; reverse[url.absoluteString] = id
        return prefix + id
    }
    func registerSrcset(_ raw: String) throws -> String { try RSSImageMarkup.srcset(raw, transform: register) }
    func original(_ raw: String) -> String {
        guard raw.hasPrefix(prefix), let url = images[String(raw.dropFirst(prefix.count))] else { return raw }
        return url.absoluteString
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let raw = urlSchemeTask.request.url?.absoluteString, raw.hasPrefix(prefix),
              images[String(raw.dropFirst(prefix.count))] != nil, source != nil, state?.isCurrent == true,
              ["GET", "HEAD"].contains((urlSchemeTask.request.httpMethod ?? "GET").uppercased()), requests.count < 2_048 else {
            urlSchemeTask.didFailWithError(RSSWebFailure.resourceUnavailable)
            return
        }
        requests[id] = Active(task: urlSchemeTask)
        pending.append(id)
        pump()
    }
    private func pump() {
        while activeCount < 4, pendingIndex < pending.count {
            let id = pending[pendingIndex]; pendingIndex += 1
            guard let value = requests[id], let raw = value.task.request.url?.absoluteString,
                  let url = images[String(raw.dropFirst(prefix.count))], let source else { continue }
            begin(id, task: value.task, url: url, source: source)
        }
        if pendingIndex == pending.count { pending.removeAll(keepingCapacity: true); pendingIndex = 0 }
    }
    private func begin(_ id: ObjectIdentifier, task urlSchemeTask: any WKURLSchemeTask, url: URL, source: RSSSource) {
        let context = context, base = base, owner = owner, rules = rules, epoch = generation
        activeCount += 1
        let work = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == generation { activeCount -= 1; pump() } }
            do {
                let image = try await RSSImageService.load(url.absoluteString, source: source, baseURL: base, context: context,
                                                          owner: owner, rules: rules, authentication: authentication)
                try await onCookiesChanged?()
                try Task.checkCancellation()
                guard epoch == generation, requests[id] != nil, state?.isCurrent == true else { return }
                let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                if urlSchemeTask.request.httpMethod != "HEAD" { urlSchemeTask.didReceive(image.data) }
                urlSchemeTask.didFinish()
                requests[id] = nil
            } catch {
                guard epoch == generation, requests.removeValue(forKey: id) != nil else { return }
                if error is RSSResourceRules.Blocked, let url = urlSchemeTask.request.url {
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil))
                    urlSchemeTask.didFinish()
                    return
                }
                urlSchemeTask.didFailWithError(RSSWebFailure.resourceUnavailable)
                if !(error is CancellationError), !Task.isCancelled { onFailure?(RSSWebFailure.resourceUnavailable) }
            }
        }
        requests[id]?.work = work
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.work?.cancel()
    }

    nonisolated static func bootstrap(prompt: String) -> String {
        """
        (()=>{const name='\(prompt)',p=window.prompt.bind(window),send=(m,v)=>{const r=p(name,JSON.stringify({method:m,args:[String(v)]}));if(r===null)throw new Error('RSS image bridge rejected');return r};
        const get=Element.prototype.getAttribute,set=Element.prototype.setAttribute;
        const image=e=>e instanceof HTMLImageElement,picture=e=>e instanceof HTMLSourceElement&&e.parentElement instanceof HTMLPictureElement;
        const attr=(e,k,v)=>{if((image(e)&&k==='src')||((image(e)||picture(e))&&k==='srcset')){set.call(e,'data-reader-original-'+k,String(v));return send(k==='src'?'resource.image':'resource.srcset',v)}return v};
        Element.prototype.setAttribute=function(k,v){return set.call(this,k,attr(this,String(k).toLowerCase(),v))};
        const wrap=(type,key)=>{const d=Object.getOwnPropertyDescriptor(type.prototype,key);if(!d||!d.set)return;Object.defineProperty(type.prototype,key,{...d,set(v){d.set.call(this,attr(this,key,v))},get(){const original=get.call(this,'data-reader-original-'+key);if(original!==null){if(key==='src'){try{return new URL(original,document.baseURI).href}catch{return original}}return original}return d.get.call(this)}})};
        wrap(HTMLImageElement,'src');wrap(HTMLImageElement,'srcset');wrap(HTMLSourceElement,'srcset');
        const current=Object.getOwnPropertyDescriptor(HTMLImageElement.prototype,'currentSrc');if(current&&current.get)Object.defineProperty(HTMLImageElement.prototype,'currentSrc',{...current,get(){return send('resource.original',current.get.call(this))}});
        const tree=root=>{if(root instanceof Element){for(const e of [root,...root.querySelectorAll('img,picture source')]){if(image(e)&&get.call(e,'src')&&!get.call(e,'data-reader-original-src'))e.setAttribute('src',get.call(e,'src'));if((image(e)||picture(e))&&get.call(e,'srcset')&&!get.call(e,'data-reader-original-srcset'))e.setAttribute('srcset',get.call(e,'srcset'))}}};
        const inner=Object.getOwnPropertyDescriptor(Element.prototype,'innerHTML');if(inner&&inner.set)Object.defineProperty(Element.prototype,'innerHTML',{...inner,set(value){const template=document.createElement('template');inner.set.call(template,String(value));for(const e of template.content.children)tree(e);inner.set.call(this,inner.get.call(template))}});
        new MutationObserver(records=>{for(const r of records)for(const n of r.addedNodes)tree(n)}).observe(document,{subtree:true,childList:true});
        })();
        """
    }
}
