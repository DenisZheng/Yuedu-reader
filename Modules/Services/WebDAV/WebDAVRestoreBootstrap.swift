import Foundation

/// 将旧数据还原并发布后，失败时以精确原字节补偿；进程终止则由下次启动执行该补偿。
enum WebDAVRestoreBootstrap {
    struct Configuration: Sendable {
        let directory: URL
        let targets: [WebDAVRestoreJournal.Role: URL]
    }

    static func targets(library: URL, support: URL) -> [WebDAVRestoreJournal.Role: URL] {
        var files: [WebDAVRestoreJournal.Role: URL] = [
            .bookSources: support.appendingPathComponent("book_sources.json"),
            .bookshelf: support.appendingPathComponent("books_meta.json"),
            .replaceRules: library.appendingPathComponent("replace_rules.json")
        ]
        for (role, name) in WebDAVRestoreJournal.Role.rssFiles { files[role] = library.appendingPathComponent(name) }
        return files
    }

    static func configuration() throws -> Configuration? {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if let path = ProcessInfo.processInfo.environment["WEBDAV_RESTORE_FIXTURE"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard arguments.contains("-rss-poc-isolated-host"), root.lastPathComponent.hasPrefix("WebDAVRestoreUITests-") else {
                throw WebDAVRestoreJournal.Failure.invalidTarget
            }
            return Configuration(directory: root.appendingPathComponent("journal"), targets: targets(library: root, support: root))
        }
        // 普通隔离测试不检查用户恢复日志；只有显式合成fixture启用启动恢复。
        if arguments.contains("-rss-poc-isolated-host") || arguments.contains("-rss-store-dir") { return nil }
        #endif
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Configuration(directory: WebDAVRestoreJournal.defaultDirectory,
            targets: targets(library: library, support: support))
    }

    static func recoverBeforeLaunch() async throws {
        guard let configuration = try configuration() else { return }
        let recovered = try await WebDAVRestoreJournal(directory: configuration.directory).recover(targets: configuration.targets)
        if recovered { AppLogger.sync("Recovered interrupted WebDAV restore before store initialization", level: .notice) }
    }
}
