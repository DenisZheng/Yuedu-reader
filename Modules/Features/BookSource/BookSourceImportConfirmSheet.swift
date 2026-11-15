import SwiftUI
import WebKit

// MARK: - BookSourceImportConfirmSheet

// Confirmation + result sheet for book-source imports arriving via system deep
// link (`yuedu://import/…` / `legado://import/…`). Bound to
// `BookSourceDeepLinkHandler`; the App entry point presents this sheet when
// the handler is in any non-`.idle` phase.
//
// Presentational only — all state mutations go through the handler's
// `confirm()` / `cancel()` / `finish()` callbacks.
struct BookSourceImportConfirmSheet: View {
    @ObservedObject var handler: BookSourceDeepLinkHandler

    var body: some View {
        if case .reviewing = handler.phase {
            // The confirmation list brings its own navigation chrome and needs the full
            // height, so it replaces the compact sheet rather than nesting inside it.
            reviewList
        } else if case .reviewingRSS(let request) = handler.phase {
            RSSImportReviewSheet(input: request.input, store: handler.rssStore)
                .presentationDetents([.large])
        } else {
            NavigationStack {
                content
                    .navigationTitle(localized("匯入來源配置"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(localized("取消")) { handler.cancel() }
                        }
                    }
            }
            .presentationDetents(usesFullHeight ? [.large] : [.medium])
            .interactiveDismissDisabled(isBusy)
        }
    }

    private var reviewList: some View {
        BookSourceImportReviewSheet(
            coordinator: handler.coordinator,
            onConfirm: { handler.commitReview() },
            onCancel: { handler.cancel() }
        )
        .onAppear { usesFullHeight = true }
    }

    private var isBusy: Bool {
        if case .importing = handler.phase { return true }
        return false
    }

    /// The review list needs the full height, and the result that follows it must keep that
    /// height — otherwise confirming an import snaps the sheet from full to half.
    @State private var usesFullHeight = false

    @ViewBuilder
    private var content: some View {
        switch handler.phase {
        case .idle:
            EmptyView()
        case .confirming(let sourceURL):
            confirmingView(sourceURL: sourceURL)
        case .importing:
            importingView
        case .reviewing, .reviewingRSS:
            // 对应的业务确认页由上层分支直接呈现，不嵌套第二个sheet。
            EmptyView()
        case .succeeded(let count):
            resultView(
                systemImage: "checkmark.circle.fill",
                tint: DSColor.success,
                message: String(format: localized("成功匯入 %d 個來源配置"), count),
                actionTitle: localized("完成")
            ) { handler.finish() }
        case .failed(let message):
            resultView(
                systemImage: "exclamationmark.circle.fill",
                tint: DSColor.destructive,
                message: message,
                actionTitle: localized("完成")
            ) { handler.finish() }
        }
    }

    private func confirmingView(sourceURL: URL) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("確認從外部連結匯入來源配置？"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("來源："))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                Text(sourceURL.absoluteString)
                    .font(DSFont.subheadline.monospaced())
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.sm)
            .interfaceCardSurface()
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            Button {
                handler.confirm()
            } label: {
                Label(localized("確認匯入"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.onAccentProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var importingView: some View {
        VStack(spacing: DSSpacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(localized("匯入中，請稍候…"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(
        systemImage: String,
        tint: Color,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: DSSpacing.md) {
            Spacer()
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(tint)
                Text(message)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.md)
            }
            Spacer()
            Button(action: action) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.onAccentProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.md)
        .frame(maxHeight: .infinity)
    }
}

/// 浏览器的UIKit呈现只提供宿主；下载、分类与预览复用系统深链状态机。
struct BookSourceBrowserImportHost: View {
    @StateObject private var handler: BookSourceDeepLinkHandler
    let onDismiss: () -> Void

    init(handler: BookSourceDeepLinkHandler, onDismiss: @escaping () -> Void) {
        _handler = StateObject(wrappedValue: handler)
        self.onDismiss = onDismiss
    }
    @MainActor static func present(_ url: URL, in webView: WKWebView) {
        guard let root = webView.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let handler = BookSourceDeepLinkHandler()
        handler.handle(url: url)
        guard handler.phase != .idle else { return }
        final class ControllerBox { weak var value: UIViewController? }
        let box = ControllerBox()
        let host = UIHostingController(rootView: Self(handler: handler) { box.value?.dismiss(animated: true) })
        box.value = host
        top.present(host, animated: true)
    }

    var body: some View {
        BookSourceImportConfirmSheet(handler: handler)
            .onChange(of: handler.phase) { _, phase in if phase == .idle { onDismiss() } }
            .onDisappear { handler.cancel() }
    }
}

#Preview("源包深链确认") {
    let handler = BookSourceDeepLinkHandler()
    handler.handle(url: URL(string: "readerfork-dev://import/rssSource?src=https://example.invalid/rss.json")!)
    return BookSourceImportConfirmSheet(handler: handler)
}
