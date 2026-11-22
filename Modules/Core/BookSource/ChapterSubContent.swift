import Foundation

/// 副文与可播放地址分型存储在唯一章节artifact；不另建歌词／弹幕缓存。
struct ChapterSubContent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case lyric, danmaku }
    enum Failure: String, Codable, Sendable { case rule, request, budget }
    static let maximumBytes = 1024 * 1024
    let kind: Kind
    let text: String
    var failure: Failure? = nil

    static func kind(sourceType: Int) -> Kind? {
        switch sourceType {
        case 1: .lyric
        case 4: .danmaku
        default: nil
        }
    }
}

/// 对外只显示固定错误分类，不保存脚本异常、URL或私人响应正文。
enum SourceSubContentError: LocalizedError, Equatable {
    case rule, request, budget, format
    var errorDescription: String? {
        switch self {
        case .rule: localized("副文規則失敗，主要內容仍可使用。")
        case .request: localized("副文請求失敗，主要內容仍可使用。")
        case .budget: localized("副文超過1 MiB上限，主要內容仍可使用。")
        case .format: localized("此副文格式尚不支援顯示，播放不受影響。")
        }
    }
}
