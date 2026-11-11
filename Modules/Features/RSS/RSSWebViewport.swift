import Foundation
import WebKit

/// 仅供用户主动调整独立网页的显示视口；不重载、不修改源规则或启用页面脚本。
enum RSSWebViewport {
    static let percentages = [10, 25, 50, 75, 100, 150, 200]

    static func label(_ percent: Int) -> String {
        String(format: localized("ReaderOverlay.Format.Percent"), percent)
    }

    @MainActor
    static func apply(_ percent: Int, revision: UInt64, in view: WKWebView) async throws -> Bool {
        guard percentages.contains(percent) else { throw RSSWebFailure.viewportUnavailable }
        let result = try await view.callAsyncJavaScript(script,
            arguments: ["scale": Double(percent) / 100, "revision": Double(revision)], contentWorld: .defaultClient)
        guard let applied = result as? Bool else { throw RSSWebFailure.viewportUnavailable }
        return applied
    }

    // 快照保存在WebKit隔离世界，不暴露给页面。只处理主文档，最多32个viewport；100%恢复原属性。
    // 修订号同时在JS侧检查，已经投递但被取消的旧选择不能覆盖新选择。
    static let script = """
    const key = '__readerRSSDisplayViewport';
    let state = globalThis[key];
    if (!state || state.document !== document) {
        state = {document, revision: -1, saved: [], created: null};
        globalThis[key] = state;
    }
    if (revision < state.revision) return false;
    state.revision = revision;
    if (scale === 1) {
        for (const original of state.saved) {
            if (original.content === null) original.node.removeAttribute('content');
            else original.node.setAttribute('content', original.content);
        }
        if (state.created) state.created.remove();
        state.saved = []; state.created = null;
        return true;
    }
    const nodes = Array.from(document.querySelectorAll('meta[name="viewport" i]'));
    const originals = nodes.filter(node => node !== state.created);
    const additional = originals.filter(node => !state.saved.some(entry => entry.node === node));
    if (!document.head || state.saved.length + additional.length > 32) throw new Error('viewport budget');
    for (const node of additional) state.saved.push({node, content: node.getAttribute('content')});
    const content = 'width=device-width, initial-scale=' + scale + ', minimum-scale=0.1, maximum-scale=2, user-scalable=yes';
    for (const node of originals) node.setAttribute('content', content);
    if (state.created) state.created.content = content;
    if (!originals.length) {
        if (!state.created) {
            state.created = document.createElement('meta');
            state.created.name = 'viewport';
        }
        state.created.content = content;
        document.head.appendChild(state.created);
    }
    return true;
    """
}
