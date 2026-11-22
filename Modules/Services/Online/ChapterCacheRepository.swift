import CryptoKit
import Foundation
import os

enum ChapterCacheWriteError: LocalizedError, Equatable, Sendable {
    case emptyContent
    case createDirectory(String)
    case writeBody(String)
    case writeMetadata(String)
    case writeArtifact(String)
    case verificationFailed
    case staleWrite

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Chapter content is empty"
        case .createDirectory(let message):
            return "Unable to create chapter cache directory: \(message)"
        case .writeBody(let message):
            return "Unable to write chapter body: \(message)"
        case .writeMetadata(let message):
            return "Unable to write chapter metadata: \(message)"
        case .writeArtifact(let message):
            return "Unable to write chapter artifact: \(message)"
        case .verificationFailed:
            return "Chapter cache verification failed"
        case .staleWrite:
            return localized("章節快取已更新，請重試。")
        }
    }
}

struct ChapterCacheRepository: Sendable {
    private let rootDirectory: URL
    private let removeItem: @Sendable (URL) throws -> Void
    // 目录路径是同步边界：两个 repository 指向同一本书时共享同一把锁。
    // 全局表只登记在途操作和票据；不拿着全局锁等待书锁或做文件操作。
    private typealias BookLock = OSAllocatedUnfairLock<[Int: UUID]>
    private struct BookMutation {
        let lock = BookLock(initialState: [:])
        var users = 0
    }
    private static let mutations = OSAllocatedUnfairLock(initialState: [String: BookMutation]())

    final class WriteTicket: Sendable {
        fileprivate let folder: String
        fileprivate let chapterIndex: Int
        fileprivate let id = UUID()

        fileprivate init(folder: String, chapterIndex: Int) {
            self.folder = folder
            self.chapterIndex = chapterIndex
        }

        deinit { ChapterCacheRepository.releaseBookLock(folder) }
    }

    func beginWrite(bookId: UUID, chapterIndex: Int) -> WriteTicket {
        let folder = cacheDir(for: bookId).path
        let lock = Self.acquireBookLock(folder)  // 由票据持有，直到离开作用域。
        let ticket = WriteTicket(folder: folder, chapterIndex: chapterIndex)
        lock.withLock { $0[chapterIndex] = ticket.id }
        return ticket
    }

    func finishWrite(_ ticket: WriteTicket) {
        Self.withBookMutation(ticket.folder) { tickets in
            if tickets[ticket.chapterIndex] == ticket.id { tickets[ticket.chapterIndex] = nil }
        }
    }

    private static func acquireBookLock(_ folder: String) -> BookLock {
        mutations.withLock { entries in
            var entry = entries[folder] ?? BookMutation()
            entry.users += 1
            entries[folder] = entry
            return entry.lock
        }
    }

    private static func releaseBookLock(_ folder: String) {
        mutations.withLock { entries in
            guard var entry = entries[folder] else { return }
            entry.users -= 1
            entries[folder] = entry.users == 0 ? nil : entry
        }
    }

    private static func withBookMutation<Result>(_ folder: String, _ body: (inout [Int: UUID]) throws -> Result) rethrows -> Result {
        let lock = acquireBookLock(folder)
        defer { releaseBookLock(folder) }
        return try lock.withLockUnchecked(body)
    }

    init(
        rootDirectory: URL? = nil,
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.rootDirectory = (rootDirectory ?? StorageLocations.onlineCache).standardizedFileURL
        self.removeItem = removeItem
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return nil
        }
        let url = chapterNormalizedHTMLPath(bookId: bookId, chapterIndex: chapterIndex)
        return try? cachedText(at: url)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return false
        }
        let url = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Upgrade legacy entries that predate the .package.json artifact so that
        // loadChapterPackageSync (which requires the artifact) can validate them.
        upgradeLegacyChapterCacheIfNeeded(bookId: bookId, chapterIndex: chapterIndex)
        return true
    }

    /// Which of `refs` have a cached body that is still theirs: the whole-list form of
    /// `isChapterCached(bookId:chapterIndex:expectedSourceURL:expectedTOCTitle:)`, for 目錄's
    /// marks. One directory listing finds the bodies (`<index>.txt`, only ever written with
    /// content), and only those have their metadata compared — a refresh that moves a chapter
    /// leaves its file at the old index (`OfflineChapterStore.reconcileBook`,
    /// `.preserveContent`). The URLs tried are the reader's
    /// (`ChapterFetchManager.cachedChapterPackage`). Unlike `isChapterCached` it writes
    /// nothing: no legacy entry is upgraded on the way.
    func cachedChapterIndices(bookId: UUID, refs: [OnlineChapterRef]) -> Set<Int> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: cacheDir(for: bookId).path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []  // Nothing of this book was ever cached.
        } catch {
            AppLogger.cache("Chapter cache listing failed", error: error, context: [
                "bookId": bookId.uuidString,
            ])
            return []
        }
        var cached: Set<Int> = []
        for name in names where name.hasSuffix(".txt") {
            guard let index = Int(name.dropLast(4)), refs.indices.contains(index) else { continue }
            let ref = refs[index]
            let sanitizedURL = ref.sanitizedContentURL
            let candidateURLs = sanitizedURL == ref.url ? [ref.url] : [sanitizedURL, ref.url]
            if candidateURLs.contains(where: {
                isCachedChapterMetadataValid(
                    bookId: bookId,
                    chapterIndex: index,
                    expectedSourceURL: $0,
                    expectedTOCTitle: ref.title
                )
            }) {
                cached.insert(index)
            }
        }
        return cached
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        do { try clearChapterCache(bookId: bookId, chapterIndex: chapterIndex, respectingCancellation: false) }
        catch { AppLogger.cache("Chapter cache removal failed", error: error, context: ["index": chapterIndex]) }
    }

    func clearAllChapterCache(bookId: UUID) {
        do { try clearAllChapterCache(bookId: bookId, respectingCancellation: false) }
        catch { AppLogger.cache("Book cache removal failed", error: error, context: ["bookId": bookId.uuidString]) }
    }

    @concurrent
    func clearChapterCacheAsync(bookId: UUID, chapterIndex: Int) async throws {
        try SourcePerfTrace.span("chapterCache.clear", "chapters=1 main=\(Thread.isMainThread)") {
            try clearChapterCache(bookId: bookId, chapterIndex: chapterIndex, respectingCancellation: true)
        }
    }

    @concurrent
    func clearAllChapterCacheAsync(bookId: UUID) async throws {
        try SourcePerfTrace.span("chapterCache.clearBook", "books=1 main=\(Thread.isMainThread)") {
            try clearAllChapterCache(bookId: bookId, respectingCancellation: true)
        }
    }

    private func clearChapterCache(bookId: UUID, chapterIndex: Int, respectingCancellation: Bool) throws {
        try Self.withBookMutation(cacheDir(for: bookId).path) { tickets in
            // 等本书上一次写入释放后再检查，取消的刷新不能清掉新一轮正文。
            if respectingCancellation { try Task.checkCancellation() }
            tickets[chapterIndex] = nil
            try removeChapterFiles(bookId: bookId, chapterIndex: chapterIndex)
        }
    }

    private func clearAllChapterCache(bookId: UUID, respectingCancellation: Bool) throws {
        let dir = cacheDir(for: bookId)
        try Self.withBookMutation(dir.path) { tickets in
            if respectingCancellation { try Task.checkCancellation() }
            tickets.removeAll()
            try removeIfPresent(dir)
        }
    }

    private func removeChapterFiles(bookId: UUID, chapterIndex: Int) throws {
        try removeIfPresent(cachePath(bookId: bookId, chapterIndex: chapterIndex))
        try removeIfPresent(cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex))
        try removeIfPresent(chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex))
        try removeIfPresent(chapterRawHTMLPath(bookId: bookId, chapterIndex: chapterIndex))
        try removeIfPresent(chapterNormalizedHTMLPath(bookId: bookId, chapterIndex: chapterIndex))
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try removeItem(url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }

    @discardableResult
    func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil,
        storeNormalizedHTML: Bool = true,
        subContent: ChapterSubContent? = nil,
        writeTicket: WriteTicket? = nil
    ) throws -> String {
        let canonicalTitle = extractedTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let displayTOCTitle = tocTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let effectiveTitle = canonicalTitle?.isEmpty == false ? canonicalTitle! : (displayTOCTitle ?? "")
        let hasRawHTML = rawHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        // A plain-text rebuild is only persisted alongside its raw HTML — see
        // `saveChapterArtifact`, which enforces the same rule for every writer.
        let persistsNormalizedHTML = storeNormalizedHTML && hasRawHTML
        let normalizedHTML = persistsNormalizedHTML
            ? ChapterFetcher.shared.buildNormalizedHTML(title: effectiveTitle, content: content)
            : nil
        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: displayTOCTitle?.isEmpty == false ? displayTOCTitle : nil,
            canonicalTitle: canonicalTitle?.isEmpty == false ? canonicalTitle : nil,
            content: content,
            contentChecksum: cacheChecksum(for: content),
            rawHTMLFilename: hasRawHTML ? "\(chapterIndex).raw.html" : nil,
            normalizedHTMLFilename: persistsNormalizedHTML ? "\(chapterIndex).normalized.xhtml" : nil,
            subContent: subContent,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        return try saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML,
            writeTicket: writeTicket
        )
    }

    @discardableResult
    func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String?,
        writeTicket: WriteTicket? = nil
    ) throws -> String {
        let dir = cacheDir(for: package.bookId)
        let index = package.chapterIndex
        return try Self.withBookMutation(dir.path) { tickets in
            if let writeTicket {
                guard writeTicket.folder == dir.path, writeTicket.chapterIndex == index, tickets[index] == writeTicket.id else {
                    throw ChapterCacheWriteError.staleWrite
                }
                // 新副文属于同一内容修订，正文相同也不能保留旧歌词／弹幕。
                if let current = readChapterPackage(bookId: package.bookId, chapterIndex: index,
                        expectedSourceURL: package.sourceURL, expectedTOCTitle: package.tocTitle),
                   current.content == package.content, current.canonicalTitle == package.canonicalTitle,
                   current.sourceURL == package.sourceURL, current.tocTitle == package.tocTitle,
                   current.subContent == package.subContent,
                   try artifactMatches(rawHTML, at: chapterRawHTMLPath(bookId: package.bookId, chapterIndex: index)),
                   try artifactMatches(normalizedHTML, at: chapterNormalizedHTMLPath(bookId: package.bookId, chapterIndex: index)) {
                    return "\(index).txt"
                }
            }
            guard !package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChapterCacheWriteError.emptyContent
            }
            tickets[index] = writeTicket?.id
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw ChapterCacheWriteError.createDirectory(error.localizedDescription)
            }
            do {
                return try persistChapterPackage(package, rawHTML: rawHTML, normalizedHTML: normalizedHTML)
            } catch {
                tickets[index] = nil
                do { try removeChapterFiles(bookId: package.bookId, chapterIndex: index) }
                catch { AppLogger.cache("Failed chapter write cleanup failed", error: error, context: ["index": index]) }
                throw error
            }
        }
    }

    // 只在持有对应书锁时调用；读回校验不进入会写入的旧缓存升级路径。
    private func persistChapterPackage(_ package: ChapterPackage, rawHTML: String?, normalizedHTML: String?) throws -> String {
        let filename = "\(package.chapterIndex).txt"
        let contentPath = cachePath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let checksum = cacheChecksum(for: package.content)

        do {
            try package.content.write(to: contentPath, atomically: true, encoding: .utf8)
        } catch {
            throw ChapterCacheWriteError.writeBody(error.localizedDescription)
        }

        let metadata = CachedChapterMetadata(
            sourceURL: package.sourceURL,
            tocTitle: package.tocTitle,
            extractedTitle: package.canonicalTitle,
            contentChecksum: checksum,
            savedAt: package.savedAt,
            state: .cached,
            failureReason: nil
        )
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(
                to: cacheMetadataPath(bookId: package.bookId, chapterIndex: package.chapterIndex),
                options: .atomic
            )
        } catch {
            throw ChapterCacheWriteError.writeMetadata(error.localizedDescription)
        }

        do {
            try saveChapterArtifact(
                package: package,
                contentChecksum: checksum,
                rawHTML: rawHTML,
                normalizedHTML: normalizedHTML
            )
        } catch let error as ChapterCacheWriteError {
            throw error
        } catch {
            throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
        }

        guard
            let verified = readChapterPackage(
                bookId: package.bookId,
                chapterIndex: package.chapterIndex,
                expectedSourceURL: package.sourceURL,
                expectedTOCTitle: package.tocTitle
            ),
            verified.state == .cached,
            verified.content == package.content,
            verified.contentChecksum == checksum
        else {
            throw ChapterCacheWriteError.verificationFailed
        }
        // The body and the HTML beside it; the metadata and package files are a few hundred bytes.
        CacheAutoCleaner.shared.noteWrite(
            bytes: package.content.utf8.count + (rawHTML?.utf8.count ?? 0) + (normalizedHTML?.utf8.count ?? 0)
        )
        return filename
    }

    func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        let url = cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedChapterMetadata.self, from: data)
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        // The package loader is the reading pipeline's source of truth. Upgrade
        // old offline downloads here (not only from `isChapterCached`) so opening
        // an already-downloaded chapter can never miss its valid `.txt` body.
        upgradeLegacyChapterCacheIfNeeded(bookId: bookId, chapterIndex: chapterIndex)
        return readChapterPackage(bookId: bookId, chapterIndex: chapterIndex,
                                  expectedSourceURL: expectedSourceURL, expectedTOCTitle: expectedTOCTitle)
    }

    private func readChapterPackage(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> ChapterPackage? {
        // "No metadata at all" is the ordinary not-cached-yet path and is checked
        // once per chapter by the offline validator — logging it would drown the
        // rejections below, which are the ones that mean a cache went bad.
        guard let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            return nil
        }
        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            AppLogger.cache("⟐ chapterPackage miss", context: [
                "index": chapterIndex,
                "reason": "urlMismatch",
                "saved": String((metadata.sourceURL ?? "nil").prefix(120)),
                "expected": String(expectedSourceURL.prefix(120)),
            ])
            return nil
        }
        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "titleMismatch",
                    "saved": String(normalizedCached.prefix(60)),
                    "expected": String(normalizedExpected.prefix(60)),
                ])
                return nil
            }
        }

        let packageURL = chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex)
        let bodyURL = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        let artifactData = try? Data(contentsOf: packageURL)
        let artifact = artifactData.flatMap { try? JSONDecoder().decode(ChapterPackageArtifact.self, from: $0) }
        let body = (try? cachedText(at: bodyURL)) ?? ""
        let cachedTitle = metadata.extractedTitle ?? metadata.tocTitle ?? ""

        if metadata.state == .cached {
            guard let artifact, !body.isEmpty, artifact.contentChecksum == cacheChecksum(for: body) else {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "artifact",
                    "hasArtifact": artifact != nil,
                    "bodyLen": body.count,
                    "checksumMatch": artifact.map { $0.contentChecksum == cacheChecksum(for: body) } ?? false,
                ])
                return nil
            }
            if ChapterFetcher.shared.isRejectedChapterContent(body) {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "contentRejected",
                    "bodyLen": body.count,
                    "title": String(cachedTitle.prefix(60)),
                ])
                return nil
            }
            return ChapterPackage(
                bookId: bookId,
                chapterIndex: chapterIndex,
                sourceURL: artifact.sourceURL ?? metadata.sourceURL,
                tocTitle: artifact.tocTitle ?? metadata.tocTitle,
                canonicalTitle: artifact.canonicalTitle ?? metadata.extractedTitle,
                content: body,
                contentChecksum: artifact.contentChecksum,
                rawHTMLFilename: artifact.rawHTMLFilename,
                normalizedHTMLFilename: artifact.normalizedHTMLFilename,
                renderArtifactVersion: artifact.renderArtifactVersion,
                subContent: artifact.subContent,
                savedAt: artifact.savedAt,
                state: .cached,
                failureReason: nil
            )
        }

        return ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: metadata.sourceURL,
            tocTitle: metadata.tocTitle,
            canonicalTitle: metadata.extractedTitle,
            content: "",
            contentChecksum: metadata.contentChecksum,
            rawHTMLFilename: artifact?.rawHTMLFilename,
            normalizedHTMLFilename: artifact?.normalizedHTMLFilename,
            renderArtifactVersion: artifact?.renderArtifactVersion,
            savedAt: metadata.savedAt,
            state: .failed,
            failureReason: metadata.failureReason
        )
    }

    private func isCachedChapterMetadataValid(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        let textPath = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: textPath.path) else { return false }
        guard let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            return expectedSourceURL == nil && expectedTOCTitle == nil
        }

        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            return false
        }

        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                return false
            }
        }

        return true
    }

    private func cacheDir(for bookId: UUID) -> URL {
        rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    private func cachePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).txt")
    }

    private func cacheMetadataPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).meta.json")
    }

    private func chapterPackagePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).package.json")
    }

    private func chapterRawHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).raw.html")
    }

    private func chapterNormalizedHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).normalized.xhtml")
    }

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }

    private func normalizeCacheTitle(_ title: String) -> String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    /// A cache file's text exactly as it was written. `String(contentsOf:encoding: .utf8)`
    /// drops a leading U+FEFF, so a chapter whose text starts with one never matched its own
    /// checksum and failed verification on every save: 笔趣阁 (apibi.cc, YCK1329／1330)
    /// decrypts to "\u{FEFF}<br><br>第1章…", saved at 1817 characters and read back at 1816.
    private func artifactMatches(_ expected: String?, at url: URL) throws -> Bool {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let expected else { return !exists }
        return try exists && cachedText(at: url) == expected
    }

    private func cachedText(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func cacheChecksum(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Synthesises a missing `.package.json` artifact from the existing `.txt` and
    /// `.meta.json` files.  Chapters cached by older app versions lack the artifact,
    /// which makes `loadChapterPackageSync` (and therefore `isChapterContentAvailable`)
    /// always return `nil` even though the content is valid — causing a permanent
    /// "loading" state in the reader.
    private func upgradeLegacyChapterCacheIfNeeded(bookId: UUID, chapterIndex: Int) {
        let packageURL = chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex)
        let bodyURL = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard !FileManager.default.fileExists(atPath: packageURL.path),
              FileManager.default.fileExists(atPath: bodyURL.path) else { return }
        Self.withBookMutation(cacheDir(for: bookId).path) { _ in
            guard !FileManager.default.fileExists(atPath: packageURL.path) else { return }
            upgradeLegacyChapterCache(bookId: bookId, chapterIndex: chapterIndex, bodyURL: bodyURL, packageURL: packageURL)
        }
    }

    private func upgradeLegacyChapterCache(bookId: UUID, chapterIndex: Int, bodyURL: URL, packageURL: URL) {
        guard
            let body = try? cachedText(at: bodyURL),
            !body.isEmpty,
            let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex),
            metadata.state == .cached || metadata.state == nil
        else { return }

        let checksum = cacheChecksum(for: body)

        // Write upgraded .package.json using the existing body checksum.
        let artifact = ChapterPackageArtifact(
            sourceURL: metadata.sourceURL,
            tocTitle: metadata.tocTitle,
            canonicalTitle: metadata.extractedTitle,
            contentChecksum: checksum,
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: metadata.savedAt
        )
        if let data = try? JSONEncoder().encode(artifact) {
            try? data.write(to: packageURL, options: .atomic)
        }

        // Backfill both fields used by the current package loader. Some legacy
        // metadata already has a checksum but predates the explicit state field.
        if metadata.contentChecksum != checksum || metadata.state != .cached {
            let updated = CachedChapterMetadata(
                sourceURL: metadata.sourceURL,
                tocTitle: metadata.tocTitle,
                extractedTitle: metadata.extractedTitle,
                contentChecksum: checksum,
                savedAt: metadata.savedAt,
                state: .cached,
                failureReason: nil
            )
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(
                    to: cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex),
                    options: .atomic
                )
            }
        }
    }

    private func saveChapterArtifact(
        package: ChapterPackage,
        contentChecksum: String,
        rawHTML: String?,
        normalizedHTML: String?
    ) throws {
        let rawPath = chapterRawHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let normalizedPath = chapterNormalizedHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let packagePath = chapterPackagePath(bookId: package.bookId, chapterIndex: package.chapterIndex)

        let rawFilename: String?
        if let rawHTML, !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try rawHTML.write(to: rawPath, atomically: true, encoding: .utf8)
                rawFilename = rawPath.lastPathComponent
            } catch {
                throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
            }
        } else {
            if FileManager.default.fileExists(atPath: rawPath.path) {
                try FileManager.default.removeItem(at: rawPath)
            }
            rawFilename = nil
        }

        // A normalized copy without its raw HTML is exactly the legacy shape
        // `shouldRefetchStrippedRenderArtifacts` purges and refetches. Writing one
        // here made the read path delete and refetch the chapter on *every* open,
        // and re-queued it for any offline download that had counted it complete —
        // the refetch reproduced the same shape, so the loop never terminated.
        // Without raw HTML the normalized copy is always the plain-text rebuild the
        // reader falls back to on its own, so dropping it changes no rendering.
        let normalizedFilename: String?
        if let normalizedHTML, rawFilename != nil {
            do {
                try normalizedHTML.write(to: normalizedPath, atomically: true, encoding: .utf8)
            } catch {
                throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
            }
            normalizedFilename = normalizedPath.lastPathComponent
        } else {
            if FileManager.default.fileExists(atPath: normalizedPath.path) {
                try FileManager.default.removeItem(at: normalizedPath)
            }
            normalizedFilename = nil
        }

        let artifact = ChapterPackageArtifact(
            sourceURL: package.sourceURL,
            tocTitle: package.tocTitle,
            canonicalTitle: package.canonicalTitle,
            contentChecksum: contentChecksum,
            rawHTMLFilename: rawFilename,
            normalizedHTMLFilename: normalizedFilename,
            renderArtifactVersion: OnlineChapterRenderArtifact.currentVersion,
            subContent: package.subContent,
            savedAt: package.savedAt
        )
        let data = try JSONEncoder().encode(artifact)
        try data.write(to: packagePath, options: .atomic)
    }
}
