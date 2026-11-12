import Foundation
import Testing
@testable import yuedu_app

@Suite("S7 WebDAV本地恢复日志", .serialized)
struct WebDAVRestoreJournalTests {
    @Test("重建日志实例恢复全部精确原字节和原本不存在的文件", arguments: WebDAVRestoreJournal.Role.allCases)
    func restartAfterEachFile(_ lastWritten: WebDAVRestoreJournal.Role) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("journal")
            var targets: [WebDAVRestoreJournal.Role: URL] = [:]
            var expected: [WebDAVRestoreJournal.Role: Data] = [:]
            for (index, role) in WebDAVRestoreJournal.Role.allCases.enumerated() {
                let file = directory.appendingPathComponent(role.rawValue + ".json")
                targets[role] = file
                if index.isMultiple(of: 2) {
                    let bytes = Data("original-\(index)\n".utf8)
                    expected[role] = bytes
                    try bytes.write(to: file)
                }
            }
            let first = WebDAVRestoreJournal(directory: root)
            _ = try await first.begin(targets: targets)
            for role in WebDAVRestoreJournal.Role.allCases {
                try Data("replaced".utf8).write(to: #require(targets[role]))
                if role == lastWritten { break }
            }
            let restarted = WebDAVRestoreJournal(directory: root)
            #expect(try await restarted.recover(targets: targets))
            for (role, url) in targets {
                if let bytes = expected[role] { #expect(try Data(contentsOf: url) == bytes) }
                else { #expect(!FileManager.default.fileExists(atPath: url.path)) }
            }
            #expect(try await !restarted.recover(targets: targets), "重复恢复幂等")
        }
    }

    @Test("成功提交不回滚，残留无active的副本不是未完成事务")
    func committedStateSurvivesRestart() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("source.json")
            try Data("old".utf8).write(to: file)
            let journal = WebDAVRestoreJournal(directory: directory.appendingPathComponent("journal"))
            let token = try await journal.begin(targets: [.bookSources: file])
            await #expect(throws: WebDAVRestoreJournal.Failure.activeTransaction) {
                _ = try await journal.begin(targets: [.bookSources: file])
            }
            try Data("new".utf8).write(to: file)
            try await journal.commit(token)
            #expect(try await !journal.recover(targets: [.bookSources: file]))
            #expect(try Data(contentsOf: file) == Data("new".utf8))
        }
    }

    @Test("副本损坏先拒绝全部恢复，标记和所有目标保留")
    func corruptedPreimageCannotPartiallyOverwrite() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("journal")
            let file = directory.appendingPathComponent("source.json")
            let rules = directory.appendingPathComponent("rules.json")
            try Data("old".utf8).write(to: file)
            try Data("old-rules".utf8).write(to: rules)
            let targets: [WebDAVRestoreJournal.Role: URL] = [.bookSources: file, .replaceRules: rules]
            let journal = WebDAVRestoreJournal(directory: root)
            _ = try await journal.begin(targets: targets)
            try Data("new".utf8).write(to: file)
            try Data("new-rules".utf8).write(to: rules)
            let saved = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent != "active.json" })
            try Data("damaged".utf8).write(to: saved.appendingPathComponent("bookSources.original"))
            await #expect(throws: WebDAVRestoreJournal.Failure.corruptOriginal) {
                try await journal.recover(targets: targets)
            }
            #expect(try Data(contentsOf: file) == Data("new".utf8))
            #expect(try Data(contentsOf: rules) == Data("new-rules".utf8), "先验证全部副本，不能提前回滚其他分类")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.json").path))
        }
    }

    @Test("未知版本、未知role及重复role拒绝，不接受目标路径", arguments: [
        "{\"format\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"entries\":[{\"role\":\"bookSources\"}]}",
        "{\"format\":1,\"id\":\"00000000-0000-0000-0000-000000000001\",\"entries\":[{\"role\":\"../../outside\"}]}",
        "{\"format\":1,\"id\":\"00000000-0000-0000-0000-000000000001\",\"entries\":[{\"role\":\"bookSources\"},{\"role\":\"bookSources\"}]}"
    ])
    func invalidRecordsFailClosed(_ json: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let active = root.appendingPathComponent("active.json")
            try Data(json.utf8).write(to: active)
            let journal = WebDAVRestoreJournal(directory: root)
            await #expect(throws: (any Error).self) { try await journal.recover(targets: [:]) }
            #expect(try Data(contentsOf: active) == Data(json.utf8))
        }
    }

    @Test("符号链接目标不能写入日志或覆盖链接的外部文件")
    func symlinkTargetIsRejected() async throws {
        try await withDirectory { directory in
            let outside = directory.appendingPathComponent("untouched.json")
            let link = directory.appendingPathComponent("link.json")
            try Data("untouched".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let journal = WebDAVRestoreJournal(directory: directory.appendingPathComponent("journal"))
            await #expect(throws: WebDAVRestoreJournal.Failure.invalidTarget) { _ = try await journal.begin(targets: [.bookSources: link]) }
            #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
        }
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("WebDAVRestoreJournalTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        try await body(directory)
    }
}
