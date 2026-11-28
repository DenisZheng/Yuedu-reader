import Foundation
import Testing
@testable import yuedu_app

/// Covers the 換源 reading-position mapping (Legado getDurChapter-style):
/// title-similarity first, chapter-number match second, clamped fallback last.
struct ChapterAlignmentTests {

    // MARK: - Chinese numeral parsing

    @Test("arabic and chinese chapter numbers parse")
    func chapterNumbers() {
        #expect(ChapterAlignment.chapterNumber(in: "第103章 夜襲") == 103)
        #expect(ChapterAlignment.chapterNumber(in: "第一百零三章 夜襲") == 103)
        #expect(ChapterAlignment.chapterNumber(in: "第二十章 出發") == 20)
        #expect(ChapterAlignment.chapterNumber(in: "第十章") == 10)
        #expect(ChapterAlignment.chapterNumber(in: "第一千零一回") == 1001)
        #expect(ChapterAlignment.chapterNumber(in: "第兩百章") == 200)
        #expect(ChapterAlignment.chapterNumber(in: "12、風雪夜") == 12)
        #expect(ChapterAlignment.chapterNumber(in: "序章") == nil)
    }

    @Test("digit-run chinese numerals parse digit-wise")
    func digitRunNumerals() {
        #expect(ChapterAlignment.numericValue(of: "一二三") == 123)
        #expect(ChapterAlignment.numericValue(of: "一零三") == 103)
        #expect(ChapterAlignment.numericValue(of: "十五") == 15)
        #expect(ChapterAlignment.numericValue(of: "二十萬") == 200_000)
    }

    // MARK: - Purification & similarity

    @Test("purification strips chapter markers and noise")
    func purification() {
        #expect(ChapterAlignment.purifiedTitle("第103章 夜襲")
            == ChapterAlignment.purifiedTitle("第一百零三章　夜襲"))
        #expect(ChapterAlignment.jaccardSimilarity(
            ChapterAlignment.purifiedTitle("第10章 風起隴西"),
            ChapterAlignment.purifiedTitle("第十章 風起隴西（修改版）")
        ) > 0.96)
    }

    // MARK: - Index mapping

    @Test("identical TOC maps to the same index")
    func identicalTOC() {
        let titles = (1...50).map { "第\($0)章 標題\($0)" }
        let mapped = ChapterAlignment.mappedChapterIndex(
            oldIndex: 20, oldTitle: titles[20], oldCount: titles.count, newTitles: titles
        )
        #expect(mapped == 20)
    }

    @Test("new TOC with an extra leading chapter shifts the index")
    func shiftedTOC() {
        let old = (1...50).map { "第\($0)章 標題\($0)" }
        let new = ["序章 引子"] + old
        let mapped = ChapterAlignment.mappedChapterIndex(
            oldIndex: 20, oldTitle: old[20], oldCount: old.count, newTitles: new
        )
        // old[20] is 第21章 → new index 21.
        #expect(mapped == 21)
        #expect(new[mapped] == old[20])
    }

    @Test("chapter-number match wins when titles differ")
    func numberMatch() {
        let old = (1...60).map { "第\($0)章 舊站標題\($0)" }
        // New source names chapters differently but numbers align, minus a volume header.
        var new = ["【第一卷】"]
        new += (1...60).map { "第\($0)章" }
        let mapped = ChapterAlignment.mappedChapterIndex(
            oldIndex: 30, oldTitle: old[30], oldCount: old.count, newTitles: new
        )
        // old[30] is 第31章 → new[31] == "第31章".
        #expect(mapped == 31)
    }

    @Test("同名标题优先选最近；唯一匹配和原位置兜底不变")
    func repeatedTitle() {
        var titles = (0..<20).map { "目次\($0)" }
        titles[4] = "番外"
        titles[13] = "番外"
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: "番外", oldCount: 20, newTitles: titles) == 13)
        titles[4] = "后记"
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: "番外", oldCount: 20, newTitles: titles) == 13)
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: "尾声", oldCount: 20, newTitles: titles) == 12)
    }

    @Test("同距选择较小下标，但更高标题分优先")
    func repeatedTitleTieAndScore() {
        var titles = (0..<20).map { "目次\($0)" }
        let title = "abcdefghijklmnopqrstuvwxyz0123456789甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉春夏秋冬東南西北江河湖海天地玄黃宇宙洪荒日月盈昃辰宿列張"
        #expect(ChapterAlignment.jaccardSimilarity(title, title + "章") > 0.96)
        titles[11] = title
        titles[13] = title
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: title, oldCount: 20, newTitles: titles) == 11)
        titles[11] = "序"
        titles[12] = title + "章"
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: title, oldCount: 20, newTitles: titles) == 13)
    }

    @Test("标题不同但章号重复，优先离旧位置最近，同距取较小下标")
    func repeatedChapterNumber() {
        var titles = (0..<20).map { "目次\($0)" }
        titles[4] = "第一百零三章 新站上卷"
        titles[13] = "第103章 新站下卷"
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: "第一百零三章 舊站", oldCount: 20, newTitles: titles) == 13)
        titles[11] = "第一百零三章 新站番外"
        #expect(ChapterAlignment.alignedIndex(oldIndex: 12, oldTitle: "第一百零三章 舊站", oldCount: 20, newTitles: titles) == 11)
    }

    @Test("no signal falls back to the clamped old index")
    func fallback() {
        let new = ["甲", "乙", "丙"]
        let mapped = ChapterAlignment.mappedChapterIndex(
            oldIndex: 10, oldTitle: "某章", oldCount: 40, newTitles: new
        )
        #expect(mapped == 2)
    }

    @Test("chapter zero stays at zero")
    func chapterZero() {
        let mapped = ChapterAlignment.mappedChapterIndex(
            oldIndex: 0, oldTitle: "序章", oldCount: 10,
            newTitles: (1...10).map { "第\($0)章" }
        )
        #expect(mapped == 0)
    }
}
