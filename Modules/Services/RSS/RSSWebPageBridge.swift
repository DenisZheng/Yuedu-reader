import Foundation

/// 页面消息只解码有限的值/动作；绝不把页面字符串当作SourceScriptHost中的代码。
enum RSSWebPageBridge {
    enum Command: Sendable {
        case get(String), put(String, String), getVariable, setVariable(String), getKey
        case action(RSSWebAction)
        case image(String), srcset(String), originalImage(String)
    }

    static func decode(_ raw: String) async throws -> Command {
        try SourcePerfTrace.span("rss.web.message", "main=\(Thread.isMainThread) bytes=\(raw.utf8.count)") {
            guard raw.utf8.count <= 65_536,
                  let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  Set(value.keys) == ["method", "args"], let method = value["method"] as? String,
                  let args = value["args"] as? [Any], args.count <= 4 else { throw RSSWebFailure.actionUnavailable }
            func string(_ index: Int, optional: Bool = false, limit: Int = 32_768) throws -> String? {
                guard index < args.count, !(args[index] is NSNull) else {
                    if optional { return nil }
                    throw RSSWebFailure.actionUnavailable
                }
                guard let result = args[index] as? String, result.utf8.count <= limit else { throw RSSWebFailure.actionUnavailable }
                return result
            }
            switch method {
            case "resource.image":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }; return .image(try string(0, limit: 8_192)!)
            case "resource.srcset":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }; return .srcset(try string(0, limit: 16_384)!)
            case "resource.original":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }; return .originalImage(try string(0, limit: 8_192)!)
            case "source.get", "java.get":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }
                return .get(try string(0, limit: 256)!)
            case "source.put", "java.put":
                guard args.count == 2 else { throw RSSWebFailure.actionUnavailable }
                return .put(try string(0, limit: 256)!, try string(1, limit: 65_536)!)
            case "source.getVariable":
                guard args.isEmpty else { throw RSSWebFailure.actionUnavailable }; return .getVariable
            case "source.setVariable":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }
                return .setVariable(try string(0, limit: 65_536)!)
            case "source.getKey":
                guard args.isEmpty else { throw RSSWebFailure.actionUnavailable }; return .getKey
            case "java.open":
                guard args.count == 4 else { throw RSSWebFailure.actionUnavailable }
                let name = try string(0)!, url = try string(1, optional: true), title = try string(2, optional: true), origin = try string(3, optional: true)
                switch name {
                case "rss": return .action(.rss(url: url, title: title, origin: origin))
                case "sort": return .action(.sort(url: url, title: title, origin: origin))
                case "login": return .action(.login(origin: origin))
                case "search":
                    guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RSSWebFailure.actionUnavailable }
                    return .action(.search(query: title, source: origin))
                case "explore":
                    guard let url else { throw RSSWebFailure.actionUnavailable }
                    return .action(.explore(url: url, title: title, origin: origin))
                default: throw RSSWebFailure.actionUnavailable
                }
            case "java.searchBook":
                guard args.count == 2, let query = try string(0, limit: 1_024), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RSSWebFailure.actionUnavailable }
                return .action(.search(query: query, source: try string(1, optional: true)))
            case "java.showPhoto":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }; return .action(.photo(url: try string(0)!))
            case "java.addBook":
                guard args.count == 1 else { throw RSSWebFailure.actionUnavailable }; return .action(.addBook(url: try string(0)!))
            case "java.openVideoPlayer":
                guard args.count == 2 else { throw RSSWebFailure.actionUnavailable }
                return .action(.playVideo(url: try string(0)!, title: try string(1, optional: true, limit: 1_024), attachmentKey: nil))
            default: throw RSSWebFailure.actionUnavailable
            }
        }
    }

    static func bootstrap(prompt: String, preload: String) async -> String {
        await SourceScriptThread.run {
            SourcePerfTrace.span("rss.web.bootstrap", "main=\(Thread.isMainThread) bytes=\(preload.utf8.count)") {
                // prompt仅由本地UUID构成。闭包保留原生prompt，网页重写window.prompt不能截获后续数据。
                """
                (()=>{const name='\(prompt)',nativePrompt=window.prompt.bind(window),send=(method,args)=>{
                  const result=nativePrompt(name,JSON.stringify({method,args}));
                  if(result===null)throw new Error('RSS bridge rejected');return result;
                };
                Object.defineProperty(window,'__rssBridgePromptName',{value:name,configurable:false});
                window.source=Object.freeze({get:k=>send('source.get',[String(k)]),put:(k,v)=>send('source.put',[String(k),String(v)]),getVariable:()=>send('source.getVariable',[]),setVariable:v=>send('source.setVariable',[String(v)]),getKey:()=>send('source.getKey',[])});
                window.java=Object.freeze({get:source.get,put:source.put,open:(n,u,t,o)=>send('java.open',[n,u??null,t??null,o??null]),searchBook:(q,s)=>send('java.searchBook',[q,s??null]),showPhoto:u=>send('java.showPhoto',[u]),addBook:u=>send('java.addBook',[u]),openVideoPlayer:(u,t)=>send('java.openVideoPlayer',[u,t??null])});
                })();
                \(preload)
                """
            }
        }
    }

    static func execute(_ command: Command, runtime: RSSRuntime) async throws -> String {
        guard runtime.state.isCurrent else { throw CancellationError() }
        return try await runtime.run { _ in
            guard runtime.state.isCurrent else { throw CancellationError() }
            let key = RSSRuntime.authenticationKey(for: runtime.source)
            switch command {
            case .get(let name): return runtime.state.sourceValue(for: key, key: name) ?? ""
            case .put(let name, let value): runtime.state.setSourceValue(value, for: key, key: name); return value
            case .getVariable: return runtime.state.sourceVariableJSON(for: key) ?? ""
            case .setVariable(let value): runtime.state.setSourceVariableJSON(value, for: key); return value
            case .getKey: return runtime.source.sourceKey
            case .action, .image, .srcset, .originalImage: throw RSSWebFailure.actionUnavailable
            }
        }
    }
}
