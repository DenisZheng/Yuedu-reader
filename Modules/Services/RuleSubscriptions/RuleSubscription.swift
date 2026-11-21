import Foundation

/// 配置包订阅，不是RSS内容来源，也不是会员订阅。
struct RuleSubscription: Identifiable, Codable, Equatable, Sendable {
    enum Kind: Int, Codable, CaseIterable, Identifiable, Sendable {
        case bookSources = 0, rssSources = 1, replaceRules = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .bookSources: localized("書源")
            case .rssSources: localized("RSS 訂閱")
            case .replaceRules: localized("替換規則")
            }
        }
    }
    var id = UUID()
    var name: String
    var url: String
    var type: Kind = .bookSources
    var autoUpdate = false
    /// 与Android一致，记录最近一次检查尝试；成功时间另存，失败不会伪造成功。
    var update: Int64 = 0
    var updateInterval = 24
    var silentUpdate = false
    var customOrder = 0
    var js: String?
    var showRule: String?
    var sourceUrl: String?
    var lastSuccessfulCheck: Int64?
    /// 远端作者版本与BookSourceStore本地写入时钟分开，避免手动导入后的本地时间阻挡更新。
    var authorVersions: [String: Int64]?
    var replacementIDs: [String: String]?

    func isDue(at now: Date) -> Bool {
        let milliseconds = now.timeIntervalSince1970 * 1_000
        return update == 0 || milliseconds < Double(update)
            || milliseconds - Double(update) >= Double(updateInterval) * 3_600_000
    }

    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1_024,
              url.utf8.count <= 32_768, let address = URL(string: url), RSSImportService.validURL(address),
              (0...8_760).contains(updateInterval) else { throw RuleSubscriptionFailure.invalidConfiguration }
        return self
    }
}

enum RuleSubscriptionFailure: LocalizedError {
    case invalidConfiguration, invalidPack, unsupportedPack, stale, unsupportedVersion, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: localized("請填寫有效的名稱、HTTP網址和更新間隔")
        case .invalidPack: localized("配置包格式無效，未修改本地來源")
        case .unsupportedPack: localized("配置包包含目前不支援的規則，未套用更新")
        case .stale: localized("配置或本地來源已變更，請重新檢查更新")
        case .unsupportedVersion: localized("規則訂閱資料版本不支援，未覆寫原檔案")
        case .tooLarge: localized("規則訂閱或配置包超過大小上限")
        }
    }
}

actor RuleSubscriptionDisk {
    struct Snapshot: Codable, Sendable {
        var format = 1
        var subscriptions: [RuleSubscription]
    }
    let file: URL
    init(file: URL) { self.file = file }
    func load() throws -> [RuleSubscription] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try SourcePerfTrace.span("rule.subscription.load", "main=\(Thread.isMainThread)") {
            let data = try DocumentImportReader.read(file, maximumBytes: 8 * 1_024 * 1_024)
            let value = try JSONDecoder().decode(Snapshot.self, from: data)
            guard value.format == 1 else { throw RuleSubscriptionFailure.unsupportedVersion }
            guard value.subscriptions.count <= 128,
                  Set(value.subscriptions.map(\.id)).count == value.subscriptions.count else { throw RuleSubscriptionFailure.invalidConfiguration }
            return try value.subscriptions.map { try $0.validated() }
        }
    }
    func save(_ subscriptions: [RuleSubscription]) throws {
        try SourcePerfTrace.span("rule.subscription.persist", "main=\(Thread.isMainThread) subscriptions=\(subscriptions.count)") {
            let data = try JSONEncoder().encode(Snapshot(subscriptions: subscriptions))
            guard data.count <= 8 * 1_024 * 1_024 else { throw RuleSubscriptionFailure.tooLarge }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
    }
}
