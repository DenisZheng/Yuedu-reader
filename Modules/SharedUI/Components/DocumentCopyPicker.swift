import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 文件返回与选择器关闭顺序不固定；每轮只交付一次，旧轮回调不能复活。
@MainActor
@Observable
final class DocumentCopyImportHandoff {
    private(set) var id = UUID()
    private var result: Result<ImportedDocumentCopy, Error>?
    private var hasDismissed = false
    private var finished = false

    func begin() {
        id = UUID()
        result = nil
        hasDismissed = false
        finished = false
    }

    func selected(_ value: Result<ImportedDocumentCopy, Error>, id: UUID) -> Result<ImportedDocumentCopy, Error>? {
        guard id == self.id, !finished, result == nil else { return nil }
        result = value
        return consume()
    }

    func dismissed() -> Result<ImportedDocumentCopy, Error>? {
        hasDismissed = true
        return consume()
    }

    func cancel(id: UUID) {
        guard id == self.id else { return }
        finished = true
        result = nil
    }

    private func consume() -> Result<ImportedDocumentCopy, Error>? {
        guard hasDismissed, !finished, let value = result else { return nil }
        finished = true
        result = nil
        return value
    }
}

/// 用公开复制导入API取得单个文件；不接管目录选择器或其他文件入口。
struct DocumentCopyPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var onStart: () -> UUID = { UUID() }
    let onSelection: (UUID, Result<ImportedDocumentCopy, Error>) -> Void
    let onCancel: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self, id: onStart()) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = Self.makePicker(contentTypes: contentTypes)
        picker.delegate = context.coordinator
        return picker
    }

    static func makePicker(contentTypes: [UTType]) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentCopyPicker
        private let id: UUID
        private var completed = false

        init(parent: DocumentCopyPicker, id: UUID) { self.parent = parent; self.id = id }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            AppLogger.info("[DocumentCopyImport] 选择结果", context: ["count": urls.count])
            guard urls.count == 1, let url = urls.first else {
                parent.onSelection(id, .failure(CocoaError(.fileReadUnknown)))
                return
            }
            // 在delegate还持有选择器授权时接管，直到后台读取结束才释放。
            parent.onSelection(id, .success(ImportedDocumentCopy(url: url)))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            AppLogger.info("[DocumentCopyImport] 用户取消")
            parent.onCancel(id)
        }
    }
}

private struct DocumentCopyImportPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let contentTypes: [UTType]
    let onCompletion: (Result<ImportedDocumentCopy, Error>) -> Void
    @State private var handoff = DocumentCopyImportHandoff()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                AppLogger.info("[DocumentCopyImport] 选择器已关闭")
                deliver(handoff.dismissed())
            }) {
                DocumentCopyPicker(contentTypes: contentTypes, onStart: {
                    handoff.begin()
                    return handoff.id
                }, onSelection: { requestID, result in
                    guard requestID == handoff.id else { return }
                    let completed = handoff.selected(result, id: requestID)
                    isPresented = false
                    deliver(completed)
                }, onCancel: { requestID in
                    guard requestID == handoff.id else { return }
                    handoff.cancel(id: requestID)
                    isPresented = false
                })
                .ignoresSafeArea()
            }
    }

    private func deliver(_ result: Result<ImportedDocumentCopy, Error>?) {
        if let result { onCompletion(result) }
    }
}

extension View {
    func documentCopyImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onCompletion: @escaping (Result<ImportedDocumentCopy, Error>) -> Void
    ) -> some View {
        modifier(DocumentCopyImportPresentation(isPresented: isPresented,
                                               contentTypes: allowedContentTypes,
                                               onCompletion: onCompletion))
    }
}

#Preview {
    DocumentCopyPicker(contentTypes: [.json, .data], onSelection: { _, _ in }, onCancel: { _ in })
}
