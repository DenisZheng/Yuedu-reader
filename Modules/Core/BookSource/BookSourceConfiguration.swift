import Foundation

/// 未知配置只保存原 JSON 值；解析器不会因保留字段而获得新的脚本或系统权限。
enum BookSourceConfiguration {
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    static let ruleFields: [String: Set<String>] = [
        "ruleSearch": Set(SearchRule.CodingKeys.allCases.map(\.stringValue)),
        "ruleExplore": Set(ExploreRule.CodingKeys.allCases.map(\.stringValue)),
        "ruleBookInfo": Set(BookInfoRule.CodingKeys.allCases.map(\.stringValue)),
        "ruleToc": Set(TOCRule.CodingKeys.allCases.map(\.stringValue)),
        "ruleContent": Set(ContentRule.CodingKeys.allCases.map(\.stringValue)),
        "ruleReview": Set(ReviewRule.CodingKeys.allCases.map(\.stringValue))
    ]

    static func capture(from decoder: Decoder) throws -> [String: PreservedJSON] {
        let container = try decoder.container(keyedBy: Key.self)
        let known = Set(BookSource.CodingKeys.allCases.map(\.stringValue))
        var result: [String: PreservedJSON] = [:]
        for key in container.allKeys {
            if let fields = ruleFields[key.stringValue] {
                let raw = try container.decode(PreservedJSON.self, forKey: key)
                let object: [String: PreservedJSON]
                switch raw {
                case .object(let value): object = value
                case .string(let value):
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    do {
                        object = try JSONDecoder().decode([String: PreservedJSON].self, from: Data(value.utf8))
                    } catch where key.stringValue == "ruleContent" {
                        result[key.stringValue] = raw
                        continue
                    }
                case .null: continue
                default:
                    guard key.stringValue == "ruleContent" else {
                        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "规则必须是对象或JSON字符串")
                    }
                    result[key.stringValue] = raw
                    continue
                }
                let extra = object.filter { !fields.contains($0.key) }
                if !extra.isEmpty { result[key.stringValue] = .object(extra) }
            } else if !known.contains(key.stringValue) {
                result[key.stringValue] = try container.decode(PreservedJSON.self, forKey: key)
            }
        }
        return result
    }

    /// 六套已知规则共用同一个编码边界；当前字段优先，不回放旧的已知配置。
    struct Rule<Value: Encodable>: Encodable {
        let value: Value
        let extra: PreservedJSON?
        func encode(to encoder: Encoder) throws {
            if case .object(let fields) = extra {
                var container = encoder.container(keyedBy: Key.self)
                for (key, value) in fields { try container.encode(value, forKey: Key(key)) }
            }
            try value.encode(to: encoder)
        }
    }
}
