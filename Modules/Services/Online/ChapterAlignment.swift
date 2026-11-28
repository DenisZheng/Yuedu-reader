import Foundation

/// Maps the reading position across a 換源 (source switch): different sources
/// disagree about chapter numbering (extra 卷 headers, merged 序章, missing
/// extras), so keeping the raw chapter index lands the reader in the wrong
/// chapter. Algorithm modeled on Legado's `BookHelp.getDurChapter`:
///
/// 1. Search a window around both the old index and the proportionally scaled
///    index (±10) in the new TOC.
/// 2. First pass: purified-title Jaccard similarity — > 0.96 wins outright.
///    Unlike Legado, over character bigrams, so titles that differ only in
///    character order ("標題12" / "標題21") do not count as the same.
/// 3. Second pass: extract the chapter number ("第一百零三章" → 103, Chinese
///    numerals included) and take an exact number match.
/// 4. For equal scores or repeated chapter numbers, prefer the chapter
///    nearest to the clamped old index. With no match, use that index itself.
///
/// As in Legado, the first chapter maps to the first chapter without a search
/// (`alignedIndex` searches for it too).
enum ChapterAlignment {

    static func mappedChapterIndex(
        oldIndex: Int,
        oldTitle: String?,
        oldCount: Int,
        newTitles: [String]
    ) -> Int {
        guard oldIndex > 0 else { return 0 }
        return alignedIndex(oldIndex: oldIndex, oldTitle: oldTitle, oldCount: oldCount, newTitles: newTitles)
    }

    /// `mappedChapterIndex`, the first chapter included: versions of a work
    /// (`VersionPlaceMapping`) open on different front matter — an EPUB's cover
    /// and title page, a TXT's preface, none for a 來源配置 — so the first entry
    /// of one is often the second of another.
    static func alignedIndex(
        oldIndex: Int,
        oldTitle: String?,
        oldCount: Int,
        newTitles: [String]
    ) -> Int {
        guard !newTitles.isEmpty else { return max(0, oldIndex) }

        let newCount = newTitles.count
        let clampedFallback = min(max(0, oldIndex), newCount - 1)
        func isNearer(_ candidate: Int, than current: Int) -> Bool {
            let candidateDistance = abs(candidate - clampedFallback)
            let currentDistance = abs(current - clampedFallback)
            return candidateDistance == currentDistance ? candidate < current : candidateDistance < currentDistance
        }

        let scaledIndex = oldCount > 0
            ? Int(Double(oldIndex) * Double(newCount) / Double(oldCount))
            : oldIndex
        let windowLow = max(0, min(oldIndex, scaledIndex) - 10)
        let windowHigh = min(newCount - 1, max(oldIndex, scaledIndex) + 10)
        guard windowLow <= windowHigh else { return clampedFallback }

        let oldPure = purifiedTitle(oldTitle)
        let oldNumber = chapterNumber(in: oldTitle)

        // Pass 1: purified-title similarity.
        var bestSimilarity = 0.0
        var bestSimilarityIndex = clampedFallback
        if !oldPure.isEmpty {
            for i in windowLow...windowHigh {
                let sim = jaccardSimilarity(oldPure, purifiedTitle(newTitles[i]))
                if sim > bestSimilarity || (sim == bestSimilarity && isNearer(i, than: bestSimilarityIndex)) {
                    bestSimilarity = sim
                    bestSimilarityIndex = i
                }
            }
            if bestSimilarity > 0.96 {
                return bestSimilarityIndex
            }
        }

        // 章号只比较相等。由近到远查找，同距先查较小下标，命中后无需继续扫描。
        if let oldNumber, oldNumber > 0 {
            let center = min(max(clampedFallback, windowLow), windowHigh)
            let left = center - windowLow
            let right = windowHigh - center
            for distance in 0...max(left, right) {
                if distance <= left, chapterNumber(in: newTitles[center - distance]) == oldNumber {
                    return center - distance
                }
                if distance > 0, distance <= right, chapterNumber(in: newTitles[center + distance]) == oldNumber {
                    return center + distance
                }
            }
        }

        return clampedFallback
    }

    // MARK: - Title purification & similarity

    /// Normalizes a chapter title down to its "name" part for similarity:
    /// fullwidth→halfwidth, lowercased, whitespace dropped, a leading
    /// "第…章/节/回/卷…" marker removed, a trailing bracketed annotation removed,
    /// and only letters/numbers/CJK kept.
    static func purifiedTitle(_ raw: String?) -> String {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return "" }
        value = value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
        value = value.lowercased()
        value = value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: "^第[^章节節回卷集话話部篇]{0,10}[章节節回卷集话話部篇]",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "[(\\[][^()\\[\\]]{2,}[)\\]]$",
            with: "",
            options: .regularExpression
        )
        return String(value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
        }.map(Character.init))
    }

    /// Character-bigram Jaccard similarity of two already-purified titles.
    /// Legado compares plain character sets, which ignore order: "標題12" and
    /// "標題21" (or "chapter12" and "chapter21") score 1.0, so pass 1 took
    /// whichever came first in the window. Bigrams keep order, and the
    /// boundary marks give a one-character title a bigram of its own.
    static func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = bigrams(of: a)
        let setB = bigrams(of: b)
        return Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
    }

    private static func bigrams(of value: String) -> Set<String> {
        // Purified titles hold only letters, numbers and CJK, so ^ and $
        // cannot collide with title characters.
        let characters = Array("^" + value + "$")
        return Set(zip(characters, characters.dropFirst()).map { String([$0, $1]) })
    }

    // MARK: - Chapter number extraction

    private static let markedNumberRegex = try? NSRegularExpression(
        pattern: "第([0-9零〇一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+)[章节節篇回集话話卷部]"
    )

    // Matched against the normalized title (halfwidth, whitespace removed), so
    // the separators are written in their normalized form:
    // `.fullwidthToHalfwidth` turns 、 into ､ (U+FF64) and ，．： into ASCII.
    private static let leadingNumberRegex = try? NSRegularExpression(
        pattern: "^([0-9零〇一二两兩三四五六七八九十百千万萬]+)[､,.:]"
    )

    /// Extracts the chapter's ordinal from its title ("第一百零三章 …" → 103,
    /// "12、xxx" → 12). Returns nil when no number is recognizable.
    static func chapterNumber(in title: String?) -> Int? {
        guard var value = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value = value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
        value = value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        for regex in [markedNumberRegex, leadingNumberRegex] {
            guard let regex,
                  let match = regex.firstMatch(in: value, range: fullRange),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value)
            else { continue }
            if let number = numericValue(of: String(value[captureRange])) {
                return number
            }
        }
        return nil
    }

    private static let digitMap: [Character: Int] = [
        "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
        "零": 0, "〇": 0,
        "一": 1, "壹": 1,
        "二": 2, "两": 2, "兩": 2, "贰": 2, "貳": 2,
        "三": 3, "叁": 3, "參": 3,
        "四": 4, "肆": 4,
        "五": 5, "伍": 5,
        "六": 6, "陆": 6, "陸": 6,
        "七": 7, "柒": 7,
        "八": 8, "捌": 8,
        "九": 9, "玖": 9,
    ]

    private static let smallUnitMap: [Character: Int] = [
        "十": 10, "拾": 10,
        "百": 100, "佰": 100,
        "千": 1000, "仟": 1000,
    ]

    /// Converts an Arabic or Chinese numeral string to Int.
    /// Positional forms ("一百零三" → 103, "二十" → 20) and plain digit runs
    /// ("一二三" → 123, "103" → 103) are both handled.
    static func numericValue(of raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        if let direct = Int(raw) { return direct }

        let hasUnit = raw.contains { smallUnitMap[$0] != nil || $0 == "万" || $0 == "萬" }
        if !hasUnit {
            // Digit-wise concatenation: 一二三 → 123.
            var result = 0
            for ch in raw {
                guard let digit = digitMap[ch] else { return nil }
                result = result * 10 + digit
                if result > 99_999_999 { return nil }
            }
            return result
        }

        // Positional parse with 十/百/千 sections and 万 as a section break.
        var total = 0
        var current = 0
        for ch in raw {
            if let digit = digitMap[ch] {
                current = digit
            } else if let unit = smallUnitMap[ch] {
                // "十" with no leading digit means 1 (十五 → 15).
                total += (current == 0 ? 1 : current) * unit
                current = 0
            } else if ch == "万" || ch == "萬" {
                total = (total + current) * 10_000
                current = 0
            } else {
                return nil
            }
            if total > 99_999_999 { return nil }
        }
        return total + current
    }
}
