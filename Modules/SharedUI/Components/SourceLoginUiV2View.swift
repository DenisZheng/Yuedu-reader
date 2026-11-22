import SwiftUI

/// 原生动态登入页。表单草稿只在本次呈现存活；不会把编辑、返回或关闭变成保存。
struct SourceLoginUiV2View: View {
    let title: String
    let service: SourceLoginUiV2Service
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SourceLoginUiV2Service.Snapshot?
    @State private var draft: [String: String] = [:]
    @State private var fieldErrors: [String: String] = [:]
    @State private var failure: LoginUiV2.Failure?
    @State private var deadlines: [String: ContinuousClock.Instant] = [:]
    @State private var isBusy = true
    @State private var refresh = UUID()
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            if let snapshot {
                Section {
                    ForEach(snapshot.rows) { row in
                        field(row)
                    }
                }
                .listRowBackground(DSColor.surface)
                .disabled(isBusy)
            }
            if isBusy {
                ProgressView().accessibilityLabel(localized("載入中"))
            }
            let messages = unmappedErrors
            if !messages.isEmpty {
                Section { ForEach(messages, id: \.key) { Text($0.value).foregroundStyle(DSColor.destructive) } }
            }
            if let failure {
                Section {
                    Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                    if snapshot == nil || failure == .invalidated {
                        Button(localized("重試")) { refresh = UUID() }.disabled(isBusy)
                    }
                }
            }
        }
        .navigationTitle(String(format: localized("登入：%@"), title))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if onDone != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: finish) {
                        Label(localized("關閉"), systemImage: "xmark").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("source.login.v2.close")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .task(id: refresh) { await load() }
        .onDisappear { work?.cancel(); work = nil }
    }

    private var unmappedErrors: [(key: String, value: String)] {
        let keys = Set(snapshot?.rows.compactMap(\.key) ?? [])
        return fieldErrors.filter { !keys.contains($0.key) }.sorted { $0.key < $1.key }
    }

    @ViewBuilder private func field(_ row: LoginUiV2.Row) -> some View {
        if row.kind == .label { Text(row.name) }
        else if let key = row.key {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                input(row, key: key).accessibilityIdentifier("source.login.v2.field." + key)
                if let message = fieldErrors[key] {
                    Text(message).font(DSFont.footnote).foregroundStyle(DSColor.destructive)
                }
            }
        } else if let action = row.action {
            if let deadline = deadlines[action] {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = secondsLeft(deadline)
                    actionButton(row, action: action, left: left)
                        .onChange(of: left, initial: true) { _, seconds in
                            if seconds == 0 { deadlines[action] = nil }
                        }
                }
            } else { actionButton(row, action: action, left: 0) }
        }
    }

    @ViewBuilder private func input(_ row: LoginUiV2.Row, key: String) -> some View {
        let value = Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 })
        let hint = row.hint.map { Text($0) }
        switch row.kind {
        case .text:
            TextField(row.name, text: value, prompt: hint).textInputAutocapitalization(.never).autocorrectionDisabled()
        case .password:
            SecureField(row.name, text: value, prompt: hint).textContentType(.password)
        case .select:
            Picker(row.name, selection: value) {
                ForEach(row.options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        case .toggle:
            Toggle(row.name, isOn: Binding(get: { value.wrappedValue == "true" }, set: { enabled in
                value.wrappedValue = enabled ? "true" : "false"
                if let action = row.action { perform(action, countdown: nil) }
            }))
        case .label, .button: EmptyView()
        }
    }

    private func actionButton(_ row: LoginUiV2.Row, action: String, left: Int) -> some View {
        let name = left == 0 ? row.name : String(format: localized("%@（%d秒）"), row.name, left)
        return Button(name) { perform(action, countdown: row.countdown) }
            .accessibilityIdentifier("source.login.v2.action." + action)
            .disabled(left > 0 || failure == .invalidated)
    }

    private func secondsLeft(_ deadline: ContinuousClock.Instant) -> Int {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        return max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
    }

    private func load() async {
        isBusy = true; failure = nil
        let token = refresh
        do {
            let next = try await service.load()
            try Task.checkCancellation()
            guard token == refresh else { return }
            apply(next)
            fieldErrors = [:]
        } catch {
            guard !Task.isCancelled, token == refresh else { return }
            failure = error as? LoginUiV2.Failure ?? (error is CancellationError ? .invalidated : .render)
        }
        if token == refresh { isBusy = false }
    }

    private func perform(_ action: String, countdown: Int?) {
        guard !isBusy, failure != .invalidated, let snapshot,
              deadlines[action].map(secondsLeft) ?? 0 == 0 else { return }
        let form = Dictionary(uniqueKeysWithValues: snapshot.rows.compactMap { row in
            row.key.map { ($0, draft[$0] ?? "") }
        })
        isBusy = true; failure = nil; fieldErrors = [:]
        work = Task {
            defer { isBusy = false; work = nil }
            do {
                let result = try await service.perform(action, in: snapshot, form: form)
                try Task.checkCancellation()
                if result.close { finish(); return }
                if result.rerendered { apply(result.snapshot) }
                else { self.snapshot = result.snapshot }
                failure = result.renderFailure
                fieldErrors = result.errors
                if result.errors.isEmpty, let countdown, countdown > 0 {
                    deadlines[action] = ContinuousClock.now.advanced(by: .seconds(countdown))
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = error as? LoginUiV2.Failure ?? (error is CancellationError ? .invalidated : .action)
            }
        }
    }

    private func apply(_ model: SourceLoginUiV2Service.Snapshot) {
        for row in model.rows {
            guard let key = row.key else { continue }
            draft[key] = row.resolve(edited: draft[key], stored: model.stored[key])
        }
        snapshot = model
    }

    private func finish() {
        if let onDone { onDone() }
        else { dismiss() }
    }
}

#Preview("動態來源登入") {
    var source = BookSource(bookSourceUrl: "https://login-preview.invalid", bookSourceName: "Preview")
    source.loginUi = LoginUiV2.marker
    source.loginUrl = #"@js:function loginUi(state){return {rows:[{type:'text',name:'User',key:'user'},{type:'password',name:'Password',key:'pass'},{type:'button',name:'Continue',action:'ok'}]};} function loginAction(){return {close:true};}"#
    return NavigationStack { SourceLoginUiV2View(title: source.bookSourceName, service: .init(target: .book(source)), onDone: {}) }
}
