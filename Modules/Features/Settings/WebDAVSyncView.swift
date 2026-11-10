import SwiftUI
import Combine

struct WebDAVSyncView: View {

    @StateObject private var manager = WebDAVManager.shared
    @Bindable private var gs = GlobalSettings.shared

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @AppStorage("webdav_backup_categories") private var selectedCategoriesRaw =
        WebDAVBackupCategory.allCases.map(\.rawValue).joined(separator: ",")

    // MARK: - Body

    var body: some View {
        Form {
            serverSection
            versionedSection
            actionsSection
            statusSection
        }
        .softScrollEdges()
        .navigationTitle(localized("WebDAV 同步"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .disabled(manager.isSyncing)
        .overlay {
            if manager.isSyncing {
                syncingOverlay
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section(header: Text(localized("伺服器設定")).foregroundStyle(DSColor.textSecondary)) {
            HStack {
                Text(localized("網址"))
                    .foregroundColor(DSColor.textSecondary)
                TextField("https://example.com/dav", text: $manager.serverUrl)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }
            HStack {
                Text(localized("帳號"))
                    .foregroundColor(DSColor.textSecondary)
                TextField(localized("使用者名稱"), text: $manager.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            HStack {
                Text(localized("密碼"))
                    .foregroundColor(DSColor.textSecondary)
                SecureField(localized("密碼"), text: $manager.password)
            }
        }
        .interfaceSectionSurface()
    }

    /// 分類、版本化備份（Fork自己的路徑）；歷史版本在推入頁選擇還原。
    private var versionedSection: some View {
        Section {
            ForEach(WebDAVBackupCategory.allCases) { category in
                Toggle(localized(category.titleKey), isOn: Binding(
                    get: { selectedCategories.contains(category) },
                    set: { on in
                        var value = selectedCategories
                        if on { value.insert(category) } else { value.remove(category) }
                        selectedCategoriesRaw = value.map(\.rawValue).sorted().joined(separator: ",")
                    }))
                .accessibilityIdentifier("webdav.category.\(category.rawValue)")
            }
            Button {
                Task { await runVersionedBackup() }
            } label: {
                Label(localized("建立備份版本"), systemImage: "externaldrive.badge.plus")
                    .foregroundColor(DSColor.accent)
            }
            .disabled(selectedCategories.isEmpty || manager.serverUrl.isEmpty)
            .accessibilityIdentifier("webdav.versioned.backup")
            NavigationLink {
                WebDAVBackupHistoryView(manager: manager)
            } label: {
                Label(localized("備份歷史與還原"), systemImage: "clock.arrow.circlepath")
            }
            .disabled(manager.serverUrl.isEmpty)
            .accessibilityIdentifier("webdav.versioned.history")
        } header: {
            Text(localized("分類備份")).foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("每次備份保存為獨立版本，不覆蓋舊版本；還原前會先下載並校驗，校驗失敗不會修改本機資料。")).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var selectedCategories: Set<WebDAVBackupCategory> {
        Set(selectedCategoriesRaw.split(separator: ",").compactMap { WebDAVBackupCategory(rawValue: String($0)) })
    }

    private func runVersionedBackup() async {
        guard validateSettings() else { return }
        manager.isSyncing = true
        manager.statusMessage = localized("備份中…")
        defer { manager.isSyncing = false }
        do {
            let manifest = try await manager.backupVersion(categories: selectedCategories, local: manager.productionBackupData)
            manager.statusMessage = localized("備份成功")
            alertTitle = localized("備份成功")
            alertMessage = String(format: localized("已建立備份版本，共 %d 個分類"), manifest.files.count)
            showAlert = true
        } catch {
            manager.statusMessage = ""
            presentError(error)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                Label(localized("測試連線"), systemImage: "network")
                    .foregroundColor(DSColor.accent)
            }
        } footer: {
            Text(localized("RSS 備份包含配置與閱讀狀態，不含正文或媒體；還原後需刷新，登入狀態不會恢復。")).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var statusSection: some View {
        Section(header: Text(localized("狀態")).foregroundStyle(DSColor.textSecondary)) {
            if let date = manager.lastSyncDate {
                HStack {
                    Text(localized("上次同步"))
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                    Text(date, style: .relative)
                        .foregroundColor(DSColor.textPrimary)
                }
            }
            if !manager.statusMessage.isEmpty {
                Text(manager.statusMessage)
                    .foregroundColor(DSColor.textSecondary)
                    .font(DSFont.footnote)
            }
        }
        .interfaceSectionSurface()
    }

    private var syncingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text(manager.statusMessage)
                    .foregroundColor(.white)
                    .font(DSFont.subheadline)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        guard validateSettings() else { return }
        let ok = await manager.testConnection()
        await MainActor.run {
            alertTitle   = ok ? localized("連線成功") : localized("連線失敗")
            alertMessage = ok
                ? localized("已成功連線至 WebDAV 伺服器")
                : localized("無法連線，請確認網址、帳號及密碼")
            showAlert = true
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func validateSettings() -> Bool {
        guard !manager.serverUrl.isEmpty else {
            alertTitle   = localized("設定不完整")
            alertMessage = localized("請填寫伺服器網址")
            showAlert    = true
            return false
        }
        return true
    }

    private func presentError(_ error: Error) {
        Task { @MainActor in
            alertTitle   = localized("操作失敗")
            alertMessage = DiagnosticRedactor.redact(error.localizedDescription)
            showAlert    = true
        }
    }
}

/// 已提交（有 manifest）的版本，新到旧；选一个版本后可只还原其中部分分类。
struct WebDAVBackupHistoryView: View {
    @ObservedObject var manager: WebDAVManager
    @State private var versions: [WebDAVBackupManifest] = []
    @State private var state: LoadState = .loading
    @State private var selected: WebDAVBackupManifest?
    enum LoadState: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label(localized("無法讀取備份歷史"), systemImage: "exclamationmark.icloud")
                } description: { Text(message) } actions: {
                    Button(localized("重試")) { Task { await load() } }
                }
            case .loaded where versions.isEmpty:
                ContentUnavailableView(localized("尚無備份版本"), systemImage: "clock")
            case .loaded:
                ForEach(versions) { manifest in
                    Button { selected = manifest } label: {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(Self.displayName(manifest.name)).foregroundStyle(DSColor.textPrimary)
                            Text(manifest.deviceName + " · " + manifest.files.map { localized($0.category.titleKey) }.joined(separator: "、"))
                                .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("webdav.version.\(manifest.name)")
                }
            }
        }
        .navigationTitle(localized("備份歷史"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $selected) { manifest in
            WebDAVRestoreVersionView(manager: manager, manifest: manifest)
        }
    }

    private func load() async {
        state = .loading
        do { versions = try await manager.listBackupVersions(); state = .loaded }
        catch { state = .failed(DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    static func displayName(_ name: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let date = parser.date(from: String(name.prefix(16))) else { return name }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

extension WebDAVBackupManifest: Identifiable, Hashable {
    var id: String { name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct WebDAVRestoreVersionView: View {
    @ObservedObject var manager: WebDAVManager
    let manifest: WebDAVBackupManifest
    @State private var chosen: Set<WebDAVBackupCategory>
    @State private var confirming = false
    @State private var result: String?
    @State private var task: Task<Void, Never>?

    init(manager: WebDAVManager, manifest: WebDAVBackupManifest) {
        self.manager = manager
        self.manifest = manifest
        _chosen = State(initialValue: Set(manifest.files.map(\.category)))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(localized("建立時間"), value: manifest.created.formatted(date: .abbreviated, time: .standard))
                LabeledContent(localized("裝置"), value: manifest.deviceName)
                LabeledContent(localized("版本"), value: manifest.appVersion)
            }
            .interfaceSectionSurface()
            Section {
                ForEach(manifest.files, id: \.category) { entry in
                    Toggle(isOn: Binding(get: { chosen.contains(entry.category) },
                                         set: { if $0 { chosen.insert(entry.category) } else { chosen.remove(entry.category) } })) {
                        VStack(alignment: .leading) {
                            Text(localized(entry.category.titleKey))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("webdav.restore.\(entry.category.rawValue)")
                }
            } header: {
                Text(localized("還原分類")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("所選分類會覆蓋本機對應資料；RSS 不含正文、媒體與登入狀態。")).dsSectionFooter()
            }
            .interfaceSectionSurface()
            Section {
                if manager.isSyncing {
                    Button(localized("取消"), role: .cancel) { task?.cancel() }
                } else {
                    Button(localized("還原所選分類"), role: .destructive) { confirming = true }
                        .disabled(chosen.isEmpty)
                        .accessibilityIdentifier("webdav.restore.start")
                }
                if let result { Text(result).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary) }
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(WebDAVBackupHistoryView.displayName(manifest.name))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .confirmationDialog(localized("確定還原？"), isPresented: $confirming, titleVisibility: .visible) {
            Button(localized("還原所選分類"), role: .destructive) { start() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("本機對應資料會被備份內容取代。"))
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        manager.isSyncing = true
        result = localized("還原中…")
        let chosen = chosen, manifest = manifest, local = manager.productionBackupData
        task = Task {
            defer { manager.isSyncing = false }
            do {
                let restored = try await manager.restoreVersion(manifest.name, categories: chosen, local: local)
                result = String(format: localized("已還原 %d 個分類"), restored.count)
            } catch is CancellationError {
                result = localized("已取消，本機資料未修改")
            } catch {
                result = DiagnosticRedactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

#Preview("WebDAV backup history") {
    NavigationStack { WebDAVBackupHistoryView(manager: .shared) }
}

#Preview("WebDAV RSS backup scope") {
    NavigationStack { WebDAVSyncView() }
}
