import Foundation

/// RSSStore的版本化运行状态文件；与S3的旧sourceID→键值表兼容。
/// opaque的source.setVariable与java.put键值表各占独立字段，不占用脚本可写的保留key。
struct RSSRuntimeStateFile: Codable, Sendable {
    var schemaVersion = 1
    var values: [String: [String: String]]
    var options: [String: String]

    init(values: [String: [String: String]], options: [String: String]) {
        self.values = values
        self.options = options
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, values, options }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version: Int?
        do { version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) }
        catch DecodingError.typeMismatch {
            // 旧表可有一个名为schemaVersion的sourceID，但其值必须仍是键值表。
            // 其他错误类型不会被接受；下面的旧格式decoder会继续校验整个对象。
            version = nil
        }
        if let version {
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                       debugDescription: "Unsupported RSS runtime state version")
            }
            schemaVersion = version
            values = try container.decode([String: [String: String]].self, forKey: .values)
            options = try container.decode([String: String].self, forKey: .options)
        } else {
            values = try decoder.singleValueContainer().decode([String: [String: String]].self)
            options = [:]
        }
    }
}
