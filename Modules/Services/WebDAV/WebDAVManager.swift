import Foundation
import Combine
import UIKit
import os

/// Diagnostic log for WebDAV backup/restore. Watch on device via Console.app
/// (filter subsystem `com.yuedu.app`, category `webdav`). Every HTTP call logs
/// its method, path, and either the status code or the URLError code, so a
/// transport-layer failure (-1005 etc.) is diagnosable without guessing.

// MARK: - WebDAV Error Types

enum WebDAVError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case connectionFailed(Int)
    case noData
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "伺服器網址格式無效"
        case .authenticationFailed: return "認證失敗，請確認帳號和密碼"
        case .connectionFailed(let code): return "連線失敗（HTTP \(code)）"
        case .noData:               return "伺服器未返回資料"
        case .fileNotFound:         return "雲端找不到備份檔案"
        }
    }
}

// MARK: - Sync Manifest (uploaded to /yuedu/manifest.json with each backup)

// MARK: - WebDAV Manager

@MainActor
final class WebDAVManager: @MainActor ObservableObject {

    static let shared = WebDAVManager()
    private let defaults: UserDefaults
    nonisolated private let transport: URLSession

    // MARK: Settings (persisted to UserDefaults)

    @Published var serverUrl: String {
        didSet { defaults.set(serverUrl, forKey: "webdav_url") }
    }
    @Published var username: String {
        didSet { defaults.set(username, forKey: "webdav_username") }
    }
    @Published var password: String {
        didSet { defaults.set(password, forKey: "webdav_password") }
    }

    // MARK: State

    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                defaults.set(date, forKey: "webdav_last_sync")
            }
        }
    }
    @Published var statusMessage: String = ""

    // MARK: Private

    /// Unique per-device ID stored in UserDefaults on first generation.
    nonisolated private static var deviceId: String {
        let key = "sync_device_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Bound at launch so a restore can reload the live bookshelf without
    /// requiring an app restart. Mirrors `ICloudSyncManager.bind(bookStore:)`.
    private weak var boundBookStore: BookStore?

    /// Dedicated session for WebDAV. `URLSession.shared` reuses pooled
    /// connections aggressively and surfaces a dropped keep-alive connection as
    /// `URLError.networkConnectionLost` (-1005) — common against jianguoyun and
    /// other WebDAV servers that close idle connections fast. A dedicated
    /// session with `waitsForConnectivity` plus the one-shot transport retry in
    /// `send(_:)` mirrors OkHttp's `retryOnConnectionFailure(true)` (see legado
    /// `HttpHelper.kt`), which is what keeps legado's WebDAV client stable
    /// against the same servers.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
    }()

    // MARK: Initialization

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        self.transport = session ?? Self.session
        serverUrl    = defaults.string(forKey: "webdav_url") ?? ""
        username     = defaults.string(forKey: "webdav_username") ?? ""
        password     = defaults.string(forKey: "webdav_password") ?? ""
        lastSyncDate = defaults.object(forKey: "webdav_last_sync") as? Date
    }

    /// Bind the live bookshelf so `restore()` can refresh it in place. Call once
    /// at app launch (mirrors the iCloud/Firestore bind in `yuedu_appApp`).
    func bind(bookStore: BookStore) {
        boundBookStore = bookStore
    }

    /// 版本化备份的生产本机数据（含已绑定书架，恢复后即时刷新）。
    var productionBackupData: WebDAVProductionLocalData {
        WebDAVProductionLocalData(rss: RSSStore.shared, bookStore: boundBookStore)
    }

    // MARK: - Transport

    /// Executes a WebDAV request on the dedicated session, retrying **once** on
    /// transient connection-level failures (`networkConnectionLost`, `timedOut`).
    /// This is NOT a fallback for a failing primary path and does NOT retry
    /// business status codes (401/404/5xx are returned as-is). It handles real
    /// TCP keep-alive drops that happen when a server closes an idle connection
    /// that the session has just reused — the same class of failure OkHttp's
    /// `retryOnConnectionFailure(true)` recovers from. Safe to delete once the
    /// WebDAV server in use stops dropping idle keep-alive connections.
    nonisolated private func send(_ request: URLRequest, maximumBytes: Int = 1_048_576) async throws -> (Data, URLResponse) {
        // 复用共享的有界字节读取、取消和重定向边界；WebDAV Basic认证不读写RSS CookieStore。
        let origin = request.url.flatMap(SourceRequestHeaderScope.origin)
        let executor = SourceRequestExecutor(session: transport, rate: "", rateKey: "webdav", cookieJarEnabled: false,
            cookieScope: SourceRequestHeaderScope(urls: []), maximumBytes: maximumBytes,
            requestValidator: { url in
                guard let origin, SourceRequestHeaderScope.origin(url) == origin else { throw URLError(.unsupportedURL) }
            })
        do {
            return try await executor.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard Self.isTransientConnectionError(error) else { throw error }
            AppLogger.sync("WebDAV transport retry", level: .notice)
            return try await executor.data(for: request)
        }
    }

    nonisolated private static func isTransientConnectionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .networkConnectionLost || urlError.code == .timedOut
    }

    // MARK: - Authentication

    nonisolated private static func authHeader(username: String, password: String) -> String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - Public Interface

    /// Test WebDAV connection; returns whether successful.
    nonisolated func testConnection() async -> Bool {
        do {
            return try await propfind(path: "/")
        } catch {
            return false
        }
    }

    // 旧的单份备份写入原版 `/yuedu/` 路径并按设备冲突覆盖，违反 ADR 0002（不覆盖原版数据）；
    // 已由 `backupVersion`/`restoreVersion`（WebDAVVersionedBackup.swift）取代。

    nonisolated func backupRSS(store: RSSStore? = nil) async throws {
        let owner = await MainActor.run { store ?? RSSStore.shared }
        try await mkcol(path: "/readerfork-dev/")
        let data = try await owner.backupData()
        try await put(data: data, path: "/readerfork-dev/rss-v1.json")
    }

    nonisolated func downloadRSSBackup() async throws -> Data? {
        do {
            let data = try await get(path: "/readerfork-dev/rss-v1.json")
            _ = try await RSSBackupCodec.decode(data)
            return data
        } catch WebDAVError.fileNotFound { return nil }
    }

    /// Only explicit shelf records and durable metadata leave this device. The
    /// reading-only registry and automatic cache pointers are never backup data.
    nonisolated static func bookshelfBackupData(from data: Data) throws -> Data {
        let books = try JSONDecoder().decode([ReadingBook].self, from: data)
        return try JSONEncoder().encode(books.filter(\.isInBookshelf).map { $0.strippedForSync() })
    }

    // MARK: - Private HTTP Methods

    /// PROPFIND: Check if path exists (HTTP 200 or 207).
    nonisolated private func propfind(path: String) async throws -> Bool {
        var request = try await makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { return false }
            AppLogger.sync("PROPFIND \(path) → \(http.statusCode)", level: .notice)
            return http.statusCode == 200 || http.statusCode == 207
        } catch {
            AppLogger.sync("PROPFIND \(path) failed: \(String(describing: (error as? URLError)?.code)) \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// PROPFIND Depth:1 的原始 multistatus；404 → fileNotFound，401 → authenticationFailed。
    nonisolated func propfindListing(path: String) async throws -> Data {
        var request = try await makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
        AppLogger.sync("PROPFIND(1) \(path) → \(http.statusCode)", level: .notice)
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        if http.statusCode == 404 { throw WebDAVError.fileNotFound }
        guard http.statusCode == 207 || http.statusCode == 200 else { throw WebDAVError.connectionFailed(http.statusCode) }
        return data
    }

    nonisolated static var backupDeviceID: String { deviceId }

    /// MKCOL: Create directory (ignore 405 = already exists).
    nonisolated func mkcol(path: String, requireNew: Bool = false) async throws {
        var request = try await makeRequest(path: path)
        request.httpMethod = "MKCOL"

        do {
            let (_, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
            AppLogger.sync("MKCOL \(path) → \(http.statusCode)", level: .notice)
            if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
            if requireNew, http.statusCode != 201 { throw WebDAVError.connectionFailed(http.statusCode) }
            if http.statusCode != 201 && http.statusCode != 405 && http.statusCode != 200 {
                throw WebDAVError.connectionFailed(http.statusCode)
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            AppLogger.sync("MKCOL \(path) failed: \(String(describing: (error as? URLError)?.code)) \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// PUT: Upload data to the specified path.
    nonisolated func put(data: Data, path: String) async throws {
        var request = try await makeRequest(path: path)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        do {
            let (_, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
            AppLogger.sync("PUT \(path) \(data.count)B → \(http.statusCode)", level: .notice)
            if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
            if !(200...299).contains(http.statusCode) {
                throw WebDAVError.connectionFailed(http.statusCode)
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            AppLogger.sync("PUT \(path) \(data.count)B failed: \(String(describing: (error as? URLError)?.code)) \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// GET: Download data from the specified path.
    nonisolated func get(path: String, maximumBytes: Int = WebDAVBackupLayout.maximumFileBytes) async throws -> Data {
        var request = try await makeRequest(path: path)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await send(request, maximumBytes: maximumBytes)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
            AppLogger.sync("GET \(path) → \(http.statusCode) \(data.count)B", level: .notice)
            if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
            if http.statusCode == 404 { throw WebDAVError.fileNotFound }
            if !(200...299).contains(http.statusCode) {
                throw WebDAVError.connectionFailed(http.statusCode)
            }
            return data
        } catch let error as WebDAVError {
            throw error
        } catch {
            AppLogger.sync("GET \(path) failed: \(String(describing: (error as? URLError)?.code)) \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    // MARK: - Utilities

    /// Reads the settings on the main actor that owns them; the request is still built here,
    /// off the main thread, as before.
    nonisolated private func makeRequest(path: String) async throws -> URLRequest {
        let (serverUrl, username, password) = await MainActor.run { (self.serverUrl, self.username, self.password) }
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw WebDAVError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Self.authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor
    private func setSync(_ syncing: Bool, message: String) {
        isSyncing = syncing
        statusMessage = message
    }
}
