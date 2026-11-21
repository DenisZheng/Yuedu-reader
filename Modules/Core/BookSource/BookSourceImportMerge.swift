import Foundation

/// 手动导入和规则包更新共用的纯合并；新异步流程在后台计算，主线程只校验版本并发布。
enum BookSourceImportMerge {
    struct Result: Sendable {
        let sources: [BookSource]
        let changed: Bool
    }

    static func apply(_ imported: [BookSource], existing: [BookSource], options: BookSourceImportOptions,
                      pins: [UUID: SourcePinRecord], now: Int64) -> Result {
        var changed = false
        var merged = existing
        var indexByURL: [String: Int] = .init(minimumCapacity: merged.count)
        for (index, source) in merged.enumerated() where !source.bookSourceUrl.isEmpty {
            if indexByURL[source.bookSourceUrl] == nil { indexByURL[source.bookSourceUrl] = index }
        }
        var additions: [BookSource] = []
        var additionIndexByURL: [String: Int] = [:]
        for src in imported {
            let localIndex = src.bookSourceUrl.isEmpty ? nil : indexByURL[src.bookSourceUrl]
            var candidate = options.merged(
                incoming: src,
                local: localIndex.map { merged[$0] }
            )
            if let idx = localIndex {
                candidate.id = merged[idx].id
                let same = candidate.hasSameContent(as: merged[idx])
                candidate.lastUpdateTime = same ? merged[idx].lastUpdateTime : now
                if !same { changed = true }
                merged[idx] = candidate
            } else if !candidate.bookSourceUrl.isEmpty,
                      let idx = additionIndexByURL[candidate.bookSourceUrl] {
                changed = true
                candidate.id = additions[idx].id
                candidate.lastUpdateTime = now
                additions[idx] = candidate
            } else {
                candidate.lastUpdateTime = now
                if !candidate.bookSourceUrl.isEmpty {
                    additionIndexByURL[candidate.bookSourceUrl] = additions.count
                }
                changed = true
                additions.append(candidate)
            }
        }
        if !additions.isEmpty {
            let insertionIndex = merged.firstIndex(
                where: { pins[$0.id]?.position == .bottom }) ?? merged.count
            merged.insert(contentsOf: additions, at: insertionIndex)
        }
        return Result(sources: merged, changed: changed)
    }

    @concurrent static func background(_ imported: [BookSource], existing: [BookSource], options: BookSourceImportOptions,
                                       pins: [UUID: SourcePinRecord], now: Int64) async -> Result {
        SourcePerfTrace.span("source.subscription.merge", "main=\(Thread.isMainThread) sources=\(existing.count) incoming=\(imported.count)") {
            apply(imported, existing: existing, options: options, pins: pins, now: now)
        }
    }
}
