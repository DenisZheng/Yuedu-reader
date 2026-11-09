import Foundation
import WebKit

/// Legado `showWebLog`：只在源显式开启时把网页console记入诊断日志。
/// 只做脱敏后的有界记录，不返回值、不调用原生动作；页面可以伪造日志，所以日志只是诊断线索。
final class RSSWebConsoleLog: NSObject, WKScriptMessageHandler {
    static let name = "readerRSSConsole"
    static let script = """
    (function(){
      if (window.__readerRSSConsoleInstalled) return; window.__readerRSSConsoleInstalled = true;
      var post = function(level, args){
        try {
          var text = Array.prototype.map.call(args, function(v){ try { return typeof v === 'string' ? v : JSON.stringify(v); } catch(e) { return String(v); } }).join(' ');
          window.webkit.messageHandlers.\(name).postMessage({level: level, message: String(text).slice(0, 2048)});
        } catch(e) {}
      };
      ['log','info','warn','error','debug'].forEach(function(level){
        var original = console[level];
        console[level] = function(){ post(level, arguments); if (original) return original.apply(console, arguments); };
      });
      window.addEventListener('error', function(e){ post('error', [String(e.message || 'error')]); });
    })();
    """
    private let lock = NSLock()
    private var count = 0
    private var tag = ""
    static let limit = 200

    func reset(sourceName: String) {
        lock.withLock { count = 0; tag = String(sourceName.prefix(64)) }
    }
    var recorded: Int { lock.withLock { count } }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["message"] as? String,
              let level = body["level"] as? String, ["log", "info", "warn", "error", "debug"].contains(level) else { return }
        let entry = lock.withLock { () -> (Int, String)? in
            guard count < Self.limit else { return nil }
            count += 1
            return (count, tag)
        }
        guard let entry else { return }
        let redacted = DiagnosticRedactor.redact(String(text.prefix(2_048)))
        AppLogger.parse("RSS web console", context: ["source": entry.1, "level": level, "index": entry.0,
                                                    "mainFrame": message.frameInfo.isMainFrame, "message": redacted],
                        level: level == "error" ? .error : level == "warn" ? .warning : .notice)
    }
}
