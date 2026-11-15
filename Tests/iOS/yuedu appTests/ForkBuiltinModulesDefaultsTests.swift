import Foundation
import Testing
@testable import yuedu_app

@Suite("Fork内置模块默认停用", .serialized)
@MainActor struct ForkBuiltinModulesDefaultsTests {
    @Test("默认策略只修改内置开关，不改变自建模块和隐藏配置")
    func preservesImportedModules() async throws {
        let suite = "builtin-preserve-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer { preferences.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
        }
        preferences.set(["user.hidden"], forKey: "ruleModules.hiddenInLibrary")
        preferences.set(["user.disabled"], forKey: "ruleModules.disabled")
        let store = RuleModuleStore(directory: directory)
        try store.install(Data(#"{"id":"user.custom","title":"Custom","version":"1.0","requiredVersion":"2.0","hosts":["example.invalid"],"modules":[],"search":{"request":{"url":"https://example.invalid?q={{keyword}}"},"list":{"items":"li","title":"h3@text"}}}"#.utf8), from: nil)
        let library = RuleModuleLibrary(store: store, officialFiles: { [] }, availability: nil, preferences: preferences)
        await library.load()
        #expect(library.modules.map(\.module.id) == ["user.custom"])
        #expect(library.disabled.contains("user.disabled"))
        #expect(library.hiddenInLibrary == ["user.hidden"])
        #expect(!library.isPublicLibraryEnabled(.aozora) && !library.isPublicLibraryEnabled(.gutenberg))
    }

    @Test("六个JSON插件与两公共书库默认关闭，仍可手动启用并跨启动保持")
    func defaultsAndOptIn() async throws {
        let suite = "builtin-defaults-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer { preferences.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
        }
        let store = RuleModuleStore(directory: directory)
        let files = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Assets")
        let library = RuleModuleLibrary(store: store, officialFiles: { OfficialRuleModules.files(in: files) }, availability: nil, preferences: preferences)
        await library.load()
        #expect(library.official.count == 6)
        #expect(library.modules.isEmpty)
        for id in ["bangumi", "anilist", "openbd", "openlibrary", "narou", "trends", "app:builtin.aozora", "app:builtin.gutenberg"] {
            #expect(!library.isEnabled(id))
        }
        #expect(library.isEnabled("app:aiRecommendations"))
        let connections = OPDSCatalogStore(storageDirectory: directory.appendingPathComponent("opds"), importLegacyWebDAV: false)
        let registry = SourceProviderRegistry(connections: connections, modules: library)
        #expect(registry.browsableProviders().isEmpty)
        #expect(LibraryListing.available(connections: [], librariesAvailable: true, modules: library).isEmpty)
        library.setEnabled(true, id: "bangumi")
        library.setEnabled(true, id: "app:builtin.aozora")
        let reopened = RuleModuleLibrary(store: store, officialFiles: { OfficialRuleModules.files(in: files) }, availability: nil, preferences: preferences)
        await reopened.load()
        #expect(reopened.modules.map(\.module.id) == ["bangumi"])
        #expect(reopened.isEnabled("app:builtin.aozora"))
        #expect(!reopened.isEnabled("app:builtin.gutenberg"))
        let optedIn = SourceProviderRegistry(connections: connections, modules: reopened)
        #expect(optedIn.browsableProviders().map(\.instance) == [SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)])
        #expect(LibraryListing.available(connections: [], librariesAvailable: true, modules: reopened).map(\.key.type) == [.aozora])
    }
}
