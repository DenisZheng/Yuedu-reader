import Foundation
import Testing
@testable import yuedu_app

@Suite("Fork 本地身份与 iCloud 配置")
struct AuthAndICloudConfigurationTests {
    @Test("保留独立App Group，本版不申请iCloud、账号登录或推送权限")
    func forkEntitlementsPreserveSharedDataWithoutCloudKit() throws {
        let entitlements = try loadMainAppEntitlements()

        #expect(entitlements["com.apple.developer.applesignin"] == nil)
        #expect(entitlements["aps-environment"] == nil)
        #expect(entitlements["com.apple.security.application-groups"] as? [String] == ["group.dev.denis.readerfork.dev"])
        #expect(entitlements["com.apple.developer.icloud-services"] == nil)
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] == nil)
    }

    @Test("停用iCloud时可安全创建本地owner，状态明确为不可用")
    @MainActor
    func pausedCloudKitKeepsLocalStartupAvailable() async {
        #expect(!ICloudSyncManager.isConfigured)
        let status = await ICloudSyncManager.shared.refreshAccountStatus()
        #expect(status == .restricted)
    }

    @Test("iCloud payload covers existing sync data files")
    func iCloudPayloadCoversExistingSyncDataFiles() {
        let applicationSupportDirectory = URL(
            fileURLWithPath: "/tmp/yuedu-application-support",
            isDirectory: true
        )
        let libraryDirectory = URL(fileURLWithPath: "/tmp/yuedu-library", isDirectory: true)
        let bookSourcesFile = applicationSupportDirectory.appendingPathComponent("book_sources.json")
        let booksMetadataFile = applicationSupportDirectory.appendingPathComponent("books_meta.json")

        let files = ICloudSyncPayload.defaultFiles(
            bookSourcesFile: bookSourcesFile,
            booksMetadataFile: booksMetadataFile,
            libraryDirectory: libraryDirectory
        )

        #expect(files.map(\.recordName) == [
            "book_sources",
            "books_meta",
            "replace_rules"
        ])
        #expect(files.map(\.localURL.lastPathComponent) == [
            "book_sources.json",
            "books_meta.json",
            "replace_rules.json"
        ])
        #expect(files.map { $0.localURL.deletingLastPathComponent() } == [
            applicationSupportDirectory,
            applicationSupportDirectory,
            libraryDirectory
        ])
    }

    @Test("sign-in sync waits for choice before overwriting remote backup")
    func signInSyncWaitsForChoiceBeforeOverwritingRemoteBackup() {
        let remoteManifest = ICloudSyncManifest(
            deviceId: "other-device",
            deviceName: "Other iPhone",
            backupDate: Date(timeIntervalSince1970: 100),
            appVersion: "1.0"
        )

        #expect(ICloudSyncManager.signInAction(
            remoteManifest: nil,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .backup)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: false,
            currentDeviceId: "this-device"
        ) == .restore)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .waitForUserChoice)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "other-device"
        ) == .backup)
    }

    private func loadMainAppEntitlements() throws -> [String: Any] {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = try #require(findRepoRoot(from: fileURL))
        let entitlementsURL = repoRoot.appendingPathComponent("Resources/Yuedu-Reader.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private func findRepoRoot(from fileURL: URL) -> URL? {
        var candidate = fileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Yuedu-Reader.xcodeproj").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
