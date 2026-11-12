import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("S8 synthetic 307-source scale", .serialized)
@MainActor
struct S8ScaleAcceptanceTests {
    @Test("307 synthetic RSS configs import, persist once, reload and remain idempotent")
    func importPersistReloadAndMeasure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S8ScaleAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("无法清理隔离S8测试目录") }
        }

        let baselineMemory = Self.processMemory()
        let payload = try await Task.detached(priority: .utility) {
            let entries: [[String: Any]] = (0..<307).map { index in
                let group = "Synthetic group \(index % 7)"
                var entry: [String: Any] = [
                    "sourceUrl": "https://synthetic-\(index).fixture.invalid/feed",
                    "sourceName": "Synthetic source \(index)",
                    "sourceGroup": group,
                    "singleUrl": false,
                    "enabled": true,
                    "ruleArticles": "article.entry",
                    "ruleTitle": "h2.title@text",
                    "ruleLink": "a@href",
                    "ruleDescription": "div.summary@html",
                ]
                if index.isMultiple(of: 3) { entry["ruleNextPage"] = "PAGE" }
                if index.isMultiple(of: 5) { entry["ruleImage"] = "img@src" }
                if index.isMultiple(of: 11) { entry["rulePubDate"] = "time@datetime" }
                return entry
            }
            return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        }.value

        let loadStart = ContinuousClock.now
        let loaded = try await RSSImportService.load(.data(payload))
        let loadDuration = Self.milliseconds(since: loadStart)
        var memorySamples = [Self.processMemory()].compactMap { $0 }
        let afterLoadMemory = Self.processMemory()
        if let afterLoadMemory { memorySamples.append(afterLoadMemory) }
        #expect(loaded.candidates.count == 307)
        #expect(loaded.candidates.allSatisfy { $0.source != nil && $0.issue == nil })
        #expect(loaded.requests == 0, "synthetic configuration import must not make network requests")

        let store = RSSStore(storageDirectory: directory)
        let compareStart = ContinuousClock.now
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        let compareDuration = Self.milliseconds(since: compareStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(plan.additions == 307 && plan.errors == 0 && plan.skips == 0)

        let mergeStart = ContinuousClock.now
        let changes = try await RSSImportService.changes(for: plan, selected: plan.initialSelection)
        let mergeDuration = Self.milliseconds(since: mergeStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(changes.added == 307 && changes.changedIDs.count == 307)

        let persistStart = ContinuousClock.now
        try await store.commitImport(changes)
        let persistDuration = Self.milliseconds(since: persistStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        let firstWrites = store.writeCounts
        #expect(store.sources.count == 307)
        #expect(firstWrites["rss_sources.json"] == 1)
        #expect(firstWrites["rss_folders.json"] == 1)

        let reloadStart = ContinuousClock.now
        let reopened = RSSStore(storageDirectory: directory)
        let reloadDuration = Self.milliseconds(since: reloadStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(reopened.sources.count == 307)
        #expect(Set(reopened.sources.map(\.sourceKey)).count == 307)

        let repeatPlan = try await RSSImportService.compare(loaded, with: reopened.importSnapshot())
        #expect(repeatPlan.skips == 307 && repeatPlan.updates == 0 && repeatPlan.errors == 0)
        let noChanges = try await RSSImportService.changes(for: repeatPlan, selected: repeatPlan.initialSelection)
        try await reopened.commitImport(noChanges)
        #expect(reopened.writeCounts.isEmpty, "unchanged import must not rewrite any file")
        if let sample = Self.processMemory() { memorySamples.append(sample) }

        let baselineResident = baselineMemory?.resident ?? memorySamples.first?.resident ?? 0
        let observedResidentDelta = memorySamples.map(\.resident).filter { $0 >= baselineResident }
            .map { $0 - baselineResident }.max() ?? 0
        let processPeakRSS = memorySamples.map(\.peak).max() ?? 0
        let reportMainThread = { Thread.isMainThread }()
        print("S8_SCALE scenario=synthetic-rss-307 bytes=\(payload.count) requests=\(loaded.requests) sourceWrites=\(firstWrites["rss_sources.json", default: 0]) folderWrites=\(firstWrites["rss_folders.json", default: 0]) unchangedWrites=\(reopened.writeCounts.values.reduce(0, +)) loadMs=\(loadDuration) compareMs=\(compareDuration) mergeMs=\(mergeDuration) persistMs=\(persistDuration) reloadMs=\(reloadDuration) sampledResidentDeltaBytes=\(observedResidentDelta) processPeakRSSBytes=\(processPeakRSS) mainThreadAtReport=\(reportMainThread)")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private struct MemorySample {
        let resident: UInt64
        let peak: UInt64
    }

    private static func processMemory() -> MemorySample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemorySample(resident: UInt64(info.resident_size), peak: UInt64(info.resident_size_peak))
    }
}
