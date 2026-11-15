import Foundation
import CoreFoundation
import CryptoKit

enum LegadoSourceJSONParser {
    /// Parse a Legado-format RSS subscription JSON array into RSSSource objects.
    static func parse(data: Data) throws -> [RSSSource] {
        let raw = try JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let dict = raw as? [String: Any] {
            array = [dict]
        } else if let arr = raw as? [Any] {
            array = arr
        } else {
            throw ParseError.invalidFormat
        }

        return try array.map { item in
            guard let json = item as? [String: Any] else { throw ParseError.invalidFormat }
            return try parseSource(from: json)
        }
    }

    /// Export RSSSource objects to Legado-format JSON array data.
    static func export(sources: [RSSSource]) throws -> Data {
        let array = try sources.map { try exportJSON(from: $0) }
        return try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Private

    static func parseSource(from json: [String: Any]) throws -> RSSSource {
        try parseSourceWithReport(from: json).source
    }

    static func parseSourceWithReport(from json: [String: Any]) throws -> (source: RSSSource, correctedFields: Int) {
        let normalized = try normalizedFields(json)
        return (try parseNormalizedSource(from: normalized.fields), normalized.count)
    }

    private static func parseNormalizedSource(from json: [String: Any]) throws -> RSSSource {
        guard let url = json["sourceUrl"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.invalidFormat }
        let suppliedName = json["sourceName"] as? String
        let name = suppliedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? suppliedName! : safeName(for: url)
        // 外包_id仅当未知配置保存，永远不分配给本地source.id。
        var source = RSSSource(
            name: name,
            url: url,
            faviconURL: json["sourceIcon"] as? String,
            sortOrder: json["customOrder"] as? Int ?? 0,
            enabled: json["enabled"] as? Bool ?? true,
            sourceGroup: json["sourceGroup"] as? String,
            sourceIcon: json["sourceIcon"] as? String,
            ruleArticles: json["ruleArticles"] as? String,
            ruleTitle: json["ruleTitle"] as? String,
            ruleLink: json["ruleLink"] as? String,
            ruleDescription: json["ruleDescription"] as? String,
            ruleContent: json["ruleContent"] as? String,
            rulePubDate: json["rulePubDate"] as? String,
            ruleImage: json["ruleImage"] as? String,
            header: json["header"] as? String,
            sortUrl: json["sortUrl"] as? String,
            articleStyle: json["articleStyle"] as? Int ?? 0,
            customOrder: json["customOrder"] as? Int ?? 0,
            enableJs: json["enableJs"] as? Bool ?? true,
            enabledCookieJar: json["enabledCookieJar"] is NSNull ? false : (json["enabledCookieJar"] as? Bool ?? true),
            lastUpdateTime: json["lastUpdateTime"] as? Double ?? 0,
            loadWithBaseUrl: json["loadWithBaseUrl"] as? Bool ?? true,
            // Legado's RssSource default is false; the old `?? true` here broke
            // web-page detection for every source that omitted the field.
            singleUrl: json["singleUrl"] as? Bool ?? false,
            ruleNextPage: json["ruleNextPage"] as? String,
            sourceComment: json["sourceComment"] as? String,
            variableComment: json["variableComment"] as? String,
            concurrentRate: json["concurrentRate"] as? String,
            loginUrl: json["loginUrl"] as? String,
            loginUi: json["loginUi"] as? String,
            loginCheckJs: json["loginCheckJs"] as? String,
            coverDecodeJs: json["coverDecodeJs"] as? String,
            jsLib: json["jsLib"] as? String,
            style: json["style"] as? String,
            injectJs: json["injectJs"] as? String,
            contentWhitelist: json["contentWhitelist"] as? String,
            contentBlacklist: json["contentBlacklist"] as? String,
            shouldOverrideUrlLoading: json["shouldOverrideUrlLoading"] as? String,
            importedFromLegado: true
        )
        source.configurationVersion = 1
        source.contentType = (json["type"] as? Int).map(RSSContentType.init(rawValue:))
        source.startHtml = json["startHtml"] as? String
        source.startStyle = json["startStyle"] as? String
        source.startJs = json["startJs"] as? String
        source.nextContentUrl = json["nextContentUrl"] as? String
        source.searchUrl = json["searchUrl"] as? String
        source.variable = json["variable"] as? String
        source.preloadJs = json["preloadJs"] as? String
        source.preload = json["preload"] as? Bool
        source.cacheFirst = json["cacheFirst"] as? Bool
        source.showWebLog = json["showWebLog"] as? Bool
        source.enableReadRecord = json["enableReadRecord"] as? Bool
        let preserved = json.filter { !knownFields.contains($0.key) || $0.value is NSNull }
        if !preserved.isEmpty {
            source.preservedLegadoFields = try JSONSerialization.data(withJSONObject: preserved, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return source
    }

    static func exportJSON(from source: RSSSource) throws -> [String: Any] {
        var json = try preservedFields(of: source)
        let required: [String: Any] = [
            "sourceName": source.name,
            "sourceUrl": source.url,
            "enabled": source.enabled,
            "articleStyle": source.articleStyle,
            "customOrder": source.customOrder,
            "enableJs": source.enableJs,
            "enabledCookieJar": source.enabledCookieJar,
            "lastUpdateTime": source.lastUpdateTime,
            "loadWithBaseUrl": source.loadWithBaseUrl,
            "singleUrl": source.singleUrl
        ]
        json.merge(required) { original, current in
            original is NSNull ? original : current
        }
        if source.enabledCookieJar { json["enabledCookieJar"] = true }
        if let v = source.contentType { json["type"] = v.rawValue }
        if let v = source.startHtml { json["startHtml"] = v }
        if let v = source.startStyle { json["startStyle"] = v }
        if let v = source.startJs { json["startJs"] = v }
        if let v = source.nextContentUrl { json["nextContentUrl"] = v }
        if let v = source.searchUrl { json["searchUrl"] = v }
        if let v = source.variable { json["variable"] = v }
        if let v = source.preloadJs { json["preloadJs"] = v }
        if let v = source.preload { json["preload"] = v }
        if let v = source.cacheFirst { json["cacheFirst"] = v }
        if let v = source.showWebLog { json["showWebLog"] = v }
        if let v = source.enableReadRecord { json["enableReadRecord"] = v }

        if let v = source.sourceGroup { json["sourceGroup"] = v }
        if let v = source.displayFaviconURL { json["sourceIcon"] = v }
        if let v = source.ruleArticles { json["ruleArticles"] = v }
        if let v = source.ruleTitle { json["ruleTitle"] = v }
        if let v = source.ruleLink { json["ruleLink"] = v }
        if let v = source.ruleDescription { json["ruleDescription"] = v }
        if let v = source.ruleContent { json["ruleContent"] = v }
        if let v = source.rulePubDate { json["rulePubDate"] = v }
        if let v = source.ruleImage { json["ruleImage"] = v }
        if let v = source.header { json["header"] = v }
        if let v = source.sortUrl { json["sortUrl"] = v }
        if let v = source.ruleNextPage { json["ruleNextPage"] = v }
        if let v = source.sourceComment { json["sourceComment"] = v }
        if let v = source.variableComment { json["variableComment"] = v }
        if let v = source.concurrentRate { json["concurrentRate"] = v }
        if let v = source.loginUrl { json["loginUrl"] = v }
        if let v = source.loginUi { json["loginUi"] = v }
        if let v = source.loginCheckJs { json["loginCheckJs"] = v }
        if let v = source.coverDecodeJs { json["coverDecodeJs"] = v }
        if let v = source.jsLib { json["jsLib"] = v }
        if let v = source.style { json["style"] = v }
        if let v = source.injectJs { json["injectJs"] = v }
        if let v = source.contentWhitelist { json["contentWhitelist"] = v }
        if let v = source.contentBlacklist { json["contentBlacklist"] = v }
        if let v = source.shouldOverrideUrlLoading { json["shouldOverrideUrlLoading"] = v }

        return json
    }

    static func preservedFields(of source: RSSSource) throws -> [String: Any] {
        guard let data = source.preservedLegadoFields else { return [:] }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidFormat
        }
        return fields
    }

    static func unknownFieldCount(in source: RSSSource) throws -> Int {
        try preservedFields(of: source).keys.filter { !knownFields.contains($0) }.count
    }

    private static let stringFields: Set<String> = [
        "sourceName", "sourceUrl", "sourceGroup", "sourceIcon", "ruleArticles", "ruleTitle",
        "ruleLink", "ruleDescription", "ruleContent", "rulePubDate", "ruleImage", "header",
        "sortUrl", "ruleNextPage", "sourceComment", "variableComment", "concurrentRate",
        "loginUrl", "loginUi", "loginCheckJs", "coverDecodeJs", "jsLib", "style", "injectJs",
        "contentWhitelist", "contentBlacklist", "shouldOverrideUrlLoading", "startHtml",
        "startStyle", "startJs", "nextContentUrl", "searchUrl", "variable", "preloadJs"
    ]
    private static let boolFields: Set<String> = [
        "enabled", "enableJs", "enabledCookieJar", "loadWithBaseUrl", "singleUrl",
        "preload", "cacheFirst", "showWebLog", "enableReadRecord"
    ]
    private static let integerFields: Set<String> = ["type", "articleStyle", "customOrder"]
    static let knownFields = stringFields.union(boolFields).union(integerFields).union(["lastUpdateTime"])

    /// 与基准Gson的String/Int适配器一致：对象转JSON字符串，JSON数字截断，非数字整数回默认值。
    /// 修正仅发生在导入边界；未知字段和已合法的字段不改写。
    private static func normalizedFields(_ json: [String: Any]) throws -> (fields: [String: Any], count: Int) {
        var fields = json
        var count = 0
        for (key, value) in json {
            if stringFields.contains(key), !(value is String), !(value is NSNull) {
                if let number = value as? NSNumber {
                    fields[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                        ? (number.boolValue ? "true" : "false") : number.stringValue
                } else {
                    fields[key] = String(decoding: try JSONSerialization.data(withJSONObject: value,
                        options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                }
                count += 1
            } else if integerFields.contains(key), !(value is NSNull) {
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                    let integer = Int(Int32(truncatingIfNeeded: number.int64Value))
                    if value as? Int != integer { count += 1 }
                    fields[key] = integer
                } else { fields[key] = NSNull(); count += 1 }
            } else if boolFields.contains(key), !(value is NSNull) {
                if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { continue }
                fields[key] = (value as? String).map { $0.lowercased() == "true" } ?? false
                count += 1
            } else if key == "lastUpdateTime", !(value is NSNull) {
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { continue }
                fields[key] = (value as? String).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 0
                count += 1
            }
        }
        guard let key = fields["sourceUrl"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.invalidFormat
        }
        return (fields, count)
    }

    private static func safeName(for key: String) -> String {
        if let host = URLComponents(string: RSSSource.strippingLegadoURLOptions(key))?.host,
           !host.isEmpty { return String(host.prefix(80)) }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return localized("未命名訂閱源") + " " + digest
    }
}

enum ParseError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return localized("無效的 Legado 訂閱源格式")
        }
    }
}
