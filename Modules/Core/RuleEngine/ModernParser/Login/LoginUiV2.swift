import CoreFoundation
import Foundation

/// V2 行、状态及命令与旧 LoginField 数组是不同协议，不交给旧的 lenient JS 解析器。
enum LoginUiV2 {
    static let marker = #"{"version":2}"#
    static let byteLimit = 256 * 1024
    static let rowLimit = 256

    /// 仅供界面路由区分对象与旧数组；完整版本校验在后台进行。
    static func isCandidate(_ text: String?) -> Bool { text?.first { !$0.isWhitespace } == "{" }

    struct State: Equatable, Sendable {
        fileprivate(set) var json: String
        static let initial = Self(json: "{}")
    }

    struct Row: Equatable, Identifiable, Sendable {
        enum Kind: String { case label, text, password, select, toggle, button }
        let id: String
        let name: String
        let kind: Kind
        let key: String?
        let hint: String?
        let value: String?
        let options: [String]
        let action: String?
        let countdown: Int?

        func resolve(edited: String?, stored: String?) -> String {
            let candidate = value ?? edited ?? stored
            switch kind {
            case .select: return candidate.flatMap { options.contains($0) ? $0 : nil } ?? options.first ?? ""
            case .toggle: return candidate == "true" ? "true" : "false"
            default: return candidate ?? ""
            }
        }
    }

    struct Command: Equatable, Sendable {
        var state: State?
        var errors: [String: String] = [:]
        var login: [String: String]?
        var close = false
    }

    enum Failure: LocalizedError, Equatable {
        case configuration, render, action, credentials, invalidated, limit
        var errorDescription: String? {
            switch self {
            case .configuration: localized("此來源的登入配置不完整。")
            case .render: localized("無法顯示來源登入表單。")
            case .action: localized("無法執行來源登入動作。")
            case .credentials: localized("無法儲存來源登入資料。")
            case .invalidated: localized("來源登入狀態已變更，請重新載入。")
            case .limit: localized("來源登入資料超過處理上限。")
            }
        }
    }

    static func verifyMarker(_ text: String) throws {
        guard isCandidate(text), let value = try object(text, failure: .configuration)["version"],
              string(value).flatMap(Int.init) == 2 else { throw Failure.configuration }
    }

    static func rows(_ result: String?) throws -> [Row] {
        guard let result, let rows = try object(result, failure: .render)["rows"] as? [[String: Any]], !rows.isEmpty else {
            throw Failure.render
        }
        guard rows.count <= rowLimit else { throw Failure.limit }
        var keys = Set<String>(), actions = Set<String>()
        return try rows.enumerated().map { offset, item in
            guard let name = string(item["name"]), notBlank(name),
                  let kind = Row.Kind(rawValue: string(item["type"]) ?? "text") else { throw Failure.render }
            let key = string(item["key"]), action = string(item["action"]), value = string(item["value"])
            let hint = string(item["hint"])
            let countdown: Int?
            if let raw = string(item["countdown"]) {
                guard let count = Int(raw), (0...86_400).contains(count) else { throw Failure.render }
                countdown = count
            } else { countdown = nil }
            let options: [String]
            let id: String
            switch kind {
            case .label:
                id = "label:\(offset)"
                options = []
            case .button:
                guard let action, notBlank(action), actions.insert(action).inserted else { throw Failure.render }
                id = "action:" + action
                options = []
            case .text, .password, .select, .toggle:
                guard let key, notBlank(key), keys.insert(key).inserted else { throw Failure.render }
                id = "field:" + key
                if kind == .select {
                    guard let array = item["options"] as? [Any], !array.isEmpty, array.count <= rowLimit else { throw Failure.render }
                    let list = array.compactMap { string($0) }
                    guard list.count == array.count, Set(list).count == list.count else { throw Failure.render }
                    options = list
                } else { options = [] }
                if kind == .toggle {
                    guard value == nil || value == "true" || value == "false" else { throw Failure.render }
                    if let action {
                        guard notBlank(action), actions.insert(action).inserted else { throw Failure.render }
                    }
                }
            }
            let takesInput = kind != .label && kind != .button
            return Row(id: id, name: name, kind: kind, key: takesInput ? key : nil, hint: hint,
                       value: value, options: options, action: kind == .button || kind == .toggle ? action : nil,
                       countdown: kind == .button ? countdown : nil)
        }
    }

    static func command(_ result: String?) throws -> Command {
        guard let result, notBlank(result) else { return Command() }
        let object = try object(result, failure: .action)
        var command = Command()
        if let state = present(object["state"]) {
            guard let state = state as? [String: Any] else { throw Failure.action }
            command.state = try State(json: encode(state))
        }
        if let errors = present(object["error"]) { command.errors = try stringMap(errors) }
        if let login = present(object["login"]) { command.login = try stringMap(login) }
        if let close = present(object["close"]) {
            guard let number = close as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.action }
            command.close = number.boolValue
        }
        return command
    }

    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= byteLimit else { throw Failure.limit }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ text: String, failure: Failure) throws -> [String: Any] {
        guard text.utf8.count <= byteLimit else { throw Failure.limit }
        do {
            guard let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw failure }
            return result
        } catch { throw failure }
    }

    private static func stringMap(_ raw: Any) throws -> [String: String] {
        guard let map = raw as? [String: Any], map.count <= rowLimit else { throw Failure.action }
        return try map.mapValues { value in
            guard let value = string(value) else { throw Failure.action }
            return value
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        }
        return nil
    }
    private static func present(_ raw: Any?) -> Any? { raw is NSNull ? nil : raw }
    private static func notBlank(_ text: String) -> Bool { text.contains { !$0.isWhitespace } }
}
