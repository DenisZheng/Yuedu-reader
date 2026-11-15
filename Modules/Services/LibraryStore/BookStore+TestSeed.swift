import Foundation

#if DEBUG
/// UI测试书架（`-seed-shelf grouped|ungrouped -shelf-test-dir <dir>`），在BookStore读取前
/// 写入隔离目录，不覆盖默认用户书架。ungrouped为12本未分组书；grouped再增加两个
/// 各含2本书的分组，让“全部”页以两个文件夹开头。测试只滑动和操作菜单，不打开正文。
enum BookStoreTestSeed {
    /// 只接受UI测试显式提供的隔离目录；不覆盖模拟器已有书架。
    static var metadataFile: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-shelf-test-dir"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).appendingPathComponent("books_meta.json")
    }

    static func writeShelf(_ layout: String) {
        guard let file = metadataFile else {
            AppLogger.error("书架测试没有隔离目录，拒绝覆盖默认书架")
            return
        }
        let groups: [String]
        switch layout {
        case "grouped": groups = ["甲組", "乙組"]
        case "ungrouped": groups = []
        default:
            AppLogger.error("-seed-shelf: unknown layout \(layout); expected grouped or ungrouped")
            return
        }
        // The groups first, so in manual order their folders lead 全部; then enough books for
        // 全部 to scroll on any phone.
        var books: [ReadingBook] = []
        for group in groups {
            for index in 1...2 {
                var book = ReadingBook(title: "\(group)書\(index)", author: "測試作者", contentFilename: "")
                book.group = group
                books.append(book)
            }
        }
        books += (1...12).map { ReadingBook(title: "測試書\($0)", author: "測試作者", contentFilename: "") }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(books).write(to: file, options: .atomic)
        } catch {
            AppLogger.error("-seed-shelf: the shelf was not written: \(error)")
        }
    }
}
#endif
