import Foundation
import CryptoKit

/// 分类、查询和Feed是不同身份域；页码和求值后的请求URL不参与身份。
struct RSSArticleScope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case feed, category, search }
    var kind: Kind
    var key: String
    static let feed = Self(kind: .feed, key: "")
    static func category(_ entry: RSSSortEntry) -> Self {
        .init(kind: .category, key: RSSIdentity.digest([entry.name, entry.url]))
    }
    static func search(_ query: String) -> Self { .init(kind: .search, key: query) }
}

enum RSSIdentity {
    static let version = 1
    static func article(sourceID: String, scope: RSSArticleScope, rawKey: String) -> String {
        "rss1:" + digest([sourceID, scope.kind.rawValue, scope.key, rawKey])
    }
    static func attachment(articleID: String, key: String) -> String {
        "rss-media1:" + digest([articleID, key])
    }
    /// 长度前缀区分任意分隔符和Unicode，不能用拼接或剥离URL参数做去重。
    static func digest(_ parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RSSRequestTicket: Equatable, Sendable {
    var sourceID: String
    var configurationRevision: UInt64
    var authenticationRevision: UInt64
}

struct RSSMediaProgress: Codable, Equatable, Sendable {
    var position: Double
    var duration: Double?
}

/// 附件类型与源类型不同域；保留旧版rawValue对象和未知值，不能让未知附件破坏整库读取。
struct RSSAttachmentKind: RawRepresentable, Codable, Equatable, Sendable {
    var rawValue: Int
    static let other = Self(rawValue: 0)
    static let image = Self(rawValue: 1)
    static let video = Self(rawValue: 2)
    static let audio = Self(rawValue: 3)
    private enum CodingKeys: String, CodingKey { case rawValue }
    init(rawValue: Int) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let integer = try? value.decode(Int.self) { rawValue = integer }
        else { rawValue = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .rawValue) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(rawValue, forKey: .rawValue)
    }
}

struct RSSMediaReference: Codable, Equatable, Sendable, Identifiable {
    /// 原始附件key或明确角色，不使用签名URL作为进度身份。
    var key: String
    var articleID: String
    var kind: RSSAttachmentKind
    var url: String
    var id: String { RSSIdentity.attachment(articleID: articleID, key: key) }
}
