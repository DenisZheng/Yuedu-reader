import Foundation
import CoreFoundation

/// 主脚本只编排已有宿主调用，不拥有另一份请求、变量或缓存。
enum MainJsSource {
    enum Failure: LocalizedError {
        case invalidConfiguration, missingFunction(String), invalidResult(String), javascript, tooLarge, backgroundRequired
        var errorDescription: String? {
            switch self {
            case .missingFunction(let name): return String(format: localized("主腳本缺少必要函式：%@"), name)
            case .invalidResult(let name): return String(format: localized("主腳本函式 %@ 傳回的資料格式不正確。"), name)
            case .invalidConfiguration: return localized("主腳本配置不完整或不符合支援的協定。")
            case .javascript: return localized("主腳本執行失敗，請查看來源診斷。")
            case .tooLarge: return localized("主腳本超過 8 MiB，無法匯入。")
            case .backgroundRequired: return localized("主腳本匯入必須在背景執行。")
            }
        }
    }

    struct Call: Decodable, Sendable {
        let exists: Bool
        let value: String?
        let book: String?
    }

    /// 函数和调用表达式在同一新scope中，返回值的getter／toJSON也在同一执行预算内。
    static func functionScript(_ script: String, name: String, arguments: [String]) -> String {
        let expression = name + "(" + arguments.joined(separator: ",") + ")"
        let book = arguments.contains("book") ? "JSON.stringify(book)" : "null"
        return script + "\n;" + """
        JSON.stringify((function(){
            if(typeof \(name)!=='function') return {exists:false,value:null,book:\(book)};
            var value=\(expression);
            return {exists:true,value:value==null?null:(typeof value==='string'?value:JSON.stringify(value)),book:\(book)};
        })())
        """
    }

    private static let metadataSession = BookSourceSession(
        source: BookSource(bookSourceUrl: "mainjs-metadata", bookSourceName: "主脚本元数据"), metadataOnly: true
    )

    /// 沿现有同步后台导入API与同一SourceScriptHost；绝不在主线程阻塞等待宿主。
    static func extract(_ script: String) throws -> BookSource {
        guard !Thread.isMainThread else { throw Failure.backgroundRequired }
        guard script.utf8.count <= 8 * 1024 * 1024 else { throw Failure.tooLarge }
        return try metadataSession.withBridge { bridge in
            Result { try bridge.extractMainJsConfiguration(script) }
        }.get()
    }

    static let functionNames = ["search", "explore", "getBookInfo", "getChapters", "getContent", "getContentBatch", "login", "loginUi", "loginAction", "getReviewSummary", "getReviewDetail", "getReviewReplies"]
    static func configurationScript(_ script: String) -> String {
        let functions = functionNames.map { "\"\($0)\":typeof \($0)==='function'" }.joined(separator: ",")
        return script + "\n;" + """
        JSON.stringify((function(){
            var primary=typeof config==='undefined'?null:config;
            var legacy=typeof source==='undefined'?null:source;
            var complete=primary && typeof primary.bookSourceUrl==='string' && primary.bookSourceUrl.trim() &&
                typeof primary.bookSourceName==='string' && primary.bookSourceName.trim();
            return {config:(primary && (!legacy || complete))?primary:legacy,functions:{\(functions)}};
        })())
        """
    }

    static func source(from json: String, script: String) throws -> BookSource {
        guard json.utf8.count <= 1024 * 1024 else { throw Failure.invalidConfiguration }
        guard let envelope = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              var config = envelope["config"] as? [String: Any],
              let functions = envelope["functions"] as? [String: Bool],
              let key = config["bookSourceUrl"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = config["bookSourceName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidConfiguration
        }
        for field in ["mainJs", "ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent", "ruleReview"] { config.removeValue(forKey: field) }
        for (field, required) in [("exploreUrl", "title"), ("loginUi", "name")] {
            if let array = config[field] as? [Any] {
                if array.isEmpty { config.removeValue(forKey: field) }
                else {
                    guard array.allSatisfy({ ($0 as? [String: Any])?[required] is String }) else { throw Failure.invalidConfiguration }
                    config[field] = String(decoding: try JSONSerialization.data(withJSONObject: array), as: UTF8.self)
                }
            }
        }
        config["mainJs"] = script
        var source = try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: config))
        let required = source.bookSourceType == 3 ? ["search", "getBookInfo"] : ["search", "getChapters", "getContent"]
        for name in required where functions[name] != true { throw Failure.missingFunction(name) }
        if !source.exploreUrl.isEmpty, functions["explore"] != true { throw Failure.missingFunction("explore") }
        if functions["loginUi"] == true {
            // 动态登录仍是后置协议；明确拒绝，不能伪装成旧式表单。
            throw Failure.invalidConfiguration
        }
        if !source.loginUi.isEmpty, functions["login"] != true { throw Failure.missingFunction("login") }
        if let size = config["maxBatchSize"] {
            guard let number = size as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue, number.doubleValue > 1,
                  functions["getContentBatch"] == true else { throw Failure.invalidConfiguration }
            source.ruleContent.maxBatchSize = min(number.intValue, 50)
        } else if functions["getContentBatch"] == true { throw Failure.invalidConfiguration }
        return source
    }

    static func objects(_ json: String?, function: String) throws -> [[String: Any]] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        guard let array = decoded as? [Any] else { throw Failure.invalidResult(function) }
        return array.compactMap { $0 as? [String: Any] }
    }

    static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    static func variables(_ value: Any?) throws -> [String: String] {
        let object: [String: Any]?
        if let value = value as? [String: Any] { object = value }
        else if let value = value as? String { object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] }
        else { object = nil }
        return object?.mapValues { text($0) } ?? [:]
    }

    static func book(_ object: [String: Any], source: BookSource, variables: [String: String] = [:]) throws -> OnlineBook {
        var runtime = variables
        for (key, value) in try self.variables(object["variable"]) { runtime["book.variable." + key] = value }
        let allBookTypes = 4 | 8 | 32 | 64 | 128
        let sourceBookType: Int
        switch source.bookSourceType {
        case 1: sourceBookType = 32
        case 2: sourceBookType = 64
        case 3: sourceBookType = 128
        case 4: sourceBookType = 4
        default: sourceBookType = 8
        }
        // 书源分类与书籍位标记是两个域，不能直接把bookSourceType塞进book.type。
        let rawType = (object["type"] as? NSNumber)?.intValue
        runtime["book.type"] = String(rawType.flatMap { $0 > 0 && $0 & ~allBookTypes == 0 ? $0 : nil } ?? sourceBookType)
        let book = OnlineBook(name: text(object["name"]), author: text(object["author"]), intro: text(object["intro"]),
            coverUrl: text(object["coverUrl"]), bookUrl: text(object["bookUrl"]), tocUrl: text(object["tocUrl"]),
            wordCount: text(object["wordCount"]), lastChapter: text(object["latestChapterTitle"]), kind: text(object["kind"]),
            sourceId: source.id, sourceName: source.bookSourceName, runtimeVariables: runtime)
        return book
    }
}
