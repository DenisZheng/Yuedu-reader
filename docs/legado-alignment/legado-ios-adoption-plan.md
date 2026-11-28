# 从小浣熊阅读吸收什么：LegadoPro 实施建议与函数草案

**建议先交付两个独立修正：净化规则不能因导入而扩大作用范围；换书源遇到同名章节时不要无故跳远。** 下一批改善 WebDAV 恢复前预览，补有声书中断回归。保留现有书源运行时、阅读器、播放器、RSS 独立入口和备份格式。本文是可评审方案，不是已实现清单，也不修改 [S0–S8 排期](implementation-plan.md)。

| 证据 | 固定版本／用法 |
| --- | --- |
| L：同级 `../legado-ios` | `2ea381463ed2230decdf2f7d3b4ef533636e05c6`。下文 L 链接固定到具体代码，不把 iOS 同行当成 Android 兼容标准。 |
| Y：本 Fork | `5f2bea2d5f4d7775dc7b25dd2c79450e93ae42d1`。Y 链接指向本仓文件，行号按此版本；函数名用于后续版本定位。 |
| 比较依据 | [全项目功能对比与同名章离线对照](../../Technotes/LegadoIOSFeatureComparison.md)；[净化、备份、RSS、音视频专题与复现命令](../../Technotes/LegadoIOSRulesBackupMedia.md)。只有下文标为“可独立运行”的草案是本文的主机样例；其余建议接口不是现有 API。 |

## 1. 净化：先阻止误导入，再做试跑和完整作用域

**差异与代码索引。** L 的 [`ContentSanitizer.ruleApplies`、`apply`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ContentSanitizer.swift#L238-L265)在正文处理前检查书名／书源和排除条件；[`ReplaceRuleTester.test`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ReplaceRuleTester.swift)让用户拿草稿试一段文字。Y 的手动路径是 [`ReplaceRuleListView` 文件导入](../../Modules/Features/Settings/ReplaceRuleListView.swift#L249-L275) → [`importFromLegadoData`](../../Modules/Core/Replace/ReplaceRuleStore.swift#L138-L154) → [`ReplaceRuleImportParser.makeRule`](../../Modules/Core/Replace/ReplaceRuleStore.swift#L379-L425)；订阅却在 [`compareReplacements`](../../Modules/Services/RuleSubscriptions/RuleSubscriptionUpdateService.swift#L139-L163)先拒绝不支持的包。对同一输入，手动路径会漏掉仅标题规则，还会把“除《保留本》外”导成全局。**先修这个差异，不要先上一个会预览错误结果的编辑器。**

**第一批，不改存储格式。** 在 `ReplaceRuleImportParser` 把“读出原字段 → 判断是否支持 → 构造本地规则”分开。建议 `review(data:)` 按原顺序返回可导入规则，或“第几条、哪些字段、受限还是无效”；不能先 `compactMap` 丢掉行。手动页有受限行时，用户只能明确确认导入其余可支持项，或取消；订阅仍按整包原子处理，不部分更新。两个入口用同一判断，但保留各自的保存方式、ID 与订阅修订检查。

以下是**对已解码语义**的建议函数。字段缺失才使用合同默认值；显式值类型错误、未知布尔文本等由原字段读取层报“无效”，不能把解码失败送成 `false`。原有全局／源地址列表沿用 [`ReplaceRuleStore.rules(for:)`](../../Modules/Core/Replace/ReplaceRuleStore.swift#L105-L124)；不能解释的限定方式须提示受限，不自行改成全局。

```swift
// 可独立运行：只判断是否能忠实执行，不执行表达式、不写规则。
struct ImportedRuleUse {
    var title = false, body = true, sourceFlag = false
    var exclusion = "", unsupportedInclusion = false
    var timeoutMS: Int? = nil
    var regex = true, replacement = ""
}

func unsupportedRuleFields(_ use: ImportedRuleUse) -> [String] {
    var fields: [String] = []
    if use.title { fields.append("scopeTitle") }
    if !use.body { fields.append("scopeContent") }
    if use.sourceFlag { fields.append("scopeSource") }
    if !use.exclusion.isEmpty { fields.append("excludeScope") }
    if use.unsupportedInclusion { fields.append("scope") }
    if let ms = use.timeoutMS, ms != 3_000 { fields.append("timeoutMillisecond") }
    if use.regex && use.replacement.hasPrefix("@js:") { fields.append("replacement") }
    return fields
}

precondition(unsupportedRuleFields(.init(title: true, body: false)) == ["scopeTitle", "scopeContent"])
precondition(unsupportedRuleFields(.init(exclusion: "保留本")) == ["excludeScope"])
precondition(unsupportedRuleFields(.init(timeoutMS: 3_000)).isEmpty)
precondition(unsupportedRuleFields(.init(regex: false, replacement: "@js:原样文字")).isEmpty)
print("rules: title-only and exclusion blocked; supported body rules retained")
```

**第二批，草稿试跑。** 建议 `preview(rule:sample:sourceKey:)` 放在 [`ReplaceRuleEngine.edits`](../../Modules/Core/Replace/ReplaceRuleEngine.swift#L197-L224)旁，用同一匹配结果和输出上限，区分停用／不在范围、没匹配、匹配但文本未变、替换成功、语法错误、超时和超限。样本文字不进日志、不落书库；不为预览另写正则。随后若支持章标题、排除范围与独立分组，再为 [`ReplaceRule`](../../Modules/Core/Replace/ReplaceRule.swift)设计兼容解码、导出回读和去重合同；先对 Android 固定基准确定书名／来源匹配语义，不直接照搬 L 的子串匹配。标题只改显示，不改章节键或书签。旧版本已丢失的字段不能靠猜测修复，只能从原包重新比较。

**验收：** 混合包放入普通正文、仅标题、带排除、非法字段四条；手动预览四行、只允许第一条提交，取消零写入；订阅拒绝整包且本地规则不变。分别从 [`RuleSubscriptionTests`](../../Tests/iOS/yuedu%20appTests/RuleSubscriptionTests.swift) 和 [`ReplaceRuleDisplayTimeTests`](../../Tests/iOS/yuedu%20appTests/ReplaceRuleDisplayTimeTests.swift)扩充，补手动入口行为，不以一个解析器测试代替两条路径。

## 2. 书源与换源：先解决重名，再验证候选正文

**差异与代码索引。** L 的 [`ChapterProgressMatcher.match`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/BookSourceSwitchService.swift#L103-L145)取最近的同名可读章，[`prepareSwitch`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/BookSourceSwitchService.swift#L285-L329)还先试读目标章。Y 的 [`ChapterAlignment.alignedIndex`](../../Modules/Services/Online/ChapterAlignment.swift#L35-L94)已识别中文章号和相似标题，但同分保留先遇到的一章；[`ReaderView.switchToOrigin`](../../Modules/Features/Reader/ReaderView+SourceChange.swift#L374-L435)先拿目录，再走[唯一的 `OnlineBookSourceSwitch.commit`](../../Modules/Services/LibraryStore/OnlineBookSourceSwitch.swift#L48-L109)。

**同名章草案。** 只改变同等质量候选的胜出条件，不改变现有窗口、相似度门槛和“没有匹配就沿用原位置”。在标题分支调用下列比较；章号分支有多个相同章号时也用“最近、同距取较小下标”，不在首个相等章号处提前结束。参数都是目录内的非负下标，旧位置先约束到新目录范围。

```swift
// 可独立运行：分数优先，只有同分才考虑离原位置多远。
func prefersChapter(_ i: Int, score: Double, to j: Int, bestScore: Double, near old: Int) -> Bool {
    if score != bestScore { return score > bestScore }
    let a = abs(i - old), b = abs(j - old)
    return a == b ? i < j : a < b
}

precondition(prefersChapter(13, score: 1, to: 4, bestScore: 1, near: 12))
precondition(prefersChapter(11, score: 1, to: 13, bestScore: 1, near: 12))
precondition(!prefersChapter(12, score: 0.97, to: 4, bestScore: 1, near: 12))
print("chapters: 13 beats 4 near 12; equal distance stable; higher score preserved")
```

**正文预检独立交付。** 建议 `prepareReadableSwitch` 仅对用户选中的**文字书**复用 `prepareTOCPackage(for:)` 和 [`OtherSourceChapter.package(of:toc:source:)`](../../Modules/Features/ChangeSource/ChangeSourceSearch.swift#L183-L199)。后者已用临时书 ID 取章，别再建缓存。跳过卷头，取得可读 `ChapterPackage`，在提交前复核原书、候选源修订和取消状态；成功后把**同一章包**交给现有提交／重开路径，不能再请求一次。目标章为空、需登录或候选已变时不改旧源、进度和正式缓存。试读不意味着脚本无副作用，仍沿用原请求预算，不为所有候选试读。

**验收：** 在 [`ChapterAlignmentTests`](../../Tests/iOS/yuedu%20appTests/ChapterAlignmentTests.swift)验证旧下标 12、新同名位置 4/13 选 13，唯一匹配和无匹配仍得 13/12；保留卷头、繁简章号和书签用例。预检单独用“目录成功／正文失败、成功、取消、取章时切换配置”四组；失败不换源、成功目标章仅请求一次。从详情和阅读器换源后重新打开验证位置，不把纯函数结果当整书换源已修复。

## 3. WebDAV：恢复前看清内容，不把恢复改成云同步

**差异与代码索引。** L 的 [`LibrarySnapshot.merging`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibrarySnapshot.swift#L123-L206)以整包合并，取较新的阅读进度、保留已有规则；[`exportDetailed(includeLocalBooks:)`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibraryBackupArchive.swift#L232-L281)可选携带本地原书。Y 的 [`WebDAVRestoreVersionView`](../../Modules/Features/Settings/WebDAVSyncView.swift#L289-L349)已经显示类别、字节数、覆盖警告并二次确认；[`restoreVersion`](../../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L478-L505)是校验后**替换所选类别**。值得新增的是所选快照里到底有几本书、几条规则，不是再加一层确认，也不是把旧备份写成新格式。

**建议接口：** 将 `restoreVersion` 下载／校验部分提为 `prepareRestore(name:categories:local:)`，只返回绑定版本、服务端连接和选择集的一次性 `PreparedRestore`（已验证内容及计数）；`applyPreparedRestore` 在用户确认后才进入现有空间检查、事务、回滚与发布路径。保持旧入口为两步的组合，避免第二条恢复实现。切换账户、版本或所选类别立即使预览失效；关闭页面释放数据。历史列表仍只读清单；点“预览所选类别”才下载，确认时用**同一批已校验字节**，不做第二轮 GET。设单类及合计内存预算，超出则提示缩小选择，不把原书或正文缓存装入内存。

下面是**依赖 Y 类型的接口草案，不能直接单文件运行**。把[原 `WebDAVProductionLocalData.validate`](../../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L213-L224)改为可返回摘要的同一校验逻辑，不在 View 重解 JSON。外层保留现有错误分类、大小和摘要校验；取消不是“备份损坏”。

```swift
enum RestoreContents {
    case books(Int), bookSources(Int), rules(Int), rss(sources: Int, states: Int)
}

func validatedContents(_ category: WebDAVBackupCategory, data: Data) async throws -> RestoreContents {
    try Task.checkCancellation()
    let decoder = JSONDecoder()
    switch category {
    case .bookshelf:
        let books = try decoder.decode([ReadingBook].self, from: data)
        guard Set(books.map(\.id)).count == books.count else { throw WebDAVBackupError.corrupt(category) }
        return .books(books.count)
    case .bookSources: return .bookSources(try decoder.decode([BookSource].self, from: data).count)
    case .replaceRules: return .rules(try decoder.decode([ReplaceRule].self, from: data).count)
    case .rss:
        let snapshot = try await RSSBackupCodec.decode(data)
        return .rss(sources: snapshot.sources.count, states: snapshot.statuses.count)
    }
}
```

**数量的含义和验收：** [书架导出](../../Modules/Services/WebDAV/WebDAVManager.swift#L190-L195)只含上架元数据，不等于原文件；[RSS 快照](../../Modules/Services/RSS/RSSBackupCodec.swift#L16-L25)的状态记录不等于可离线阅读的文章。旧 format 1 用合成备份“2 本书／3 条规则”预览，断言预览和取消均为零本地写入；篡改一类时不得应用其余类，确认成功只修改勾选类别。用 [`WebDAVVersionedBackupTests`](../../Tests/iOS/yuedu%20appTests/WebDAVVersionedBackupTests.swift)、[`RSSWebDAVBackupTests`](../../Tests/iOS/yuedu%20appTests/RSSWebDAVBackupTests.swift)覆盖预览、请求数、损坏、磁盘不足及中断。自动上传、自动删旧版、整包合并、携带原书和恢复 iCloud **都不在这批**。

## 4. 媒体和 RSS：借中断处理与诊断，不搬播放器或入口

**音频。** L 的 [`handleRouteDisconnected`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/TTS/SpeechInterruptionCoordinator.swift#L74-L99)和[系统通知接入](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/ReaderSpeechController.swift#L438-L460)属于 **TTS**；音频书直接给章节地址而无正文规则时，[`loadContent`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/NetworkBookService.swift#L565-L576)明确报受限。Y 则有专属有声书播放器；[`handleAudioInterruption`／`handleRouteChange`](../../Modules/Core/TTS/AudiobookPlayer.swift#L1584-L1631)中，中断后可能已暂停，拔耳机这一步不能只看 `isPlaying`。先用合成事件复现，再决定是否修改。下面是在“确实为旧输出设备断开”分支内的最小草案，直接更新播放器已有的恢复标记，不另建一份播放状态。

```swift
// 可独立运行：返回是否需要现在暂停；清除待恢复意图与当前是否播放无关。
func outputWasRemoved(playing: Bool, resumePending: inout Bool) -> Bool {
    resumePending = false
    return playing
}

var pending = true
let pauseAgain = outputWasRemoved(playing: false, resumePending: &pending)
precondition(!pauseAgain && !pending)
var playingIntent = false
precondition(outputWasRemoved(playing: true, resumePending: &playingIntent))
print("audio: disconnected while interrupted clears resume; active playback pauses")
```

**设备门槛：** 来电中拔耳机、未拔且系统允许续播、用户主动暂停／停止、蓝牙切换，在真实有声书路由分别验证；不把一次 TTS 状态机测试当作这些用例通过。L 的 [RSS 视频分支](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/RSS/RSSWebReaderView.swift#L144-L162)是网页 `video`，不是网络书剧集播放。Y 保留 [`VideoPlaybackController.load`](../../Modules/Features/Reader/Video/VideoPlaybackController.swift#L283-L329) → [`saveProgress`](../../Modules/Features/Reader/Video/VideoPlaybackController.swift#L548-L586)；不换播放器、不为受限格式作兼容承诺。

**RSS 与书源诊断。** L 有 RSS 模块，但[首页只从演示分支打开](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/RootTabView.swift#L53-L66)，不能作为默认入口参照。可借 [`RSSSourceDebugger.appendSkipped`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Debugging/RSSSourceDebugger.swift#L74-L86)的解释方式。Y 的[书源检查已有 `StageStatus.skipped`](../../Modules/Core/BookSource/BookSourceHealthChecker.swift#L322-L329)；RSS 只需在现有 [`RSSSourceDebugger.run/list/content`](../../Modules/Services/RSS/RSSSourceDebugger.swift#L45-L106)输出“第一处失败／需交互、后续哪些未测”。建议 `skippedStages(after:reason:)` 只整理本次记录，不发第二轮请求。用合法空列表、需登录、正文分页循环和媒体仅入口四例验收；不输出原网页、正文、带参数 URL 或私有配置。保留 Y 的五个 Tab。

## 5. 其他值得吸收的功能：先验证，再排期

| 项目 | L 对照 → Y 代码接入点 | 初步函数／放行标准 |
| --- | --- | --- |
| 已缓存文字书导出 TXT（优先的新功能） | [`cachedBook`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/LocalBook/LocalFileService.swift#L147-L178)顺序写章、缺章留标记 → Y [`ChapterCacheRepository.loadChapterPackageSync`](../../Modules/Services/Online/ChapterCacheRepository.swift#L400-L433)。 | 建议 `exportCachedText(bookID:refs:to:) async throws`，返回已写／缺章数。先让同一缓存读取路径能区分“确实没有”和“读取失败”，不能把现有可空结果一概当缺章。限有权导出的文字书；逐章写临时文件，完成再分享。5 章缺 2 章提示 3/5，0 章、取消或磁盘错误不发布文件，网络请求为 0。 |
| 多源搜索首条结果（先实验） | [`BookSearchService.searchOutcomes`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Search/BookSearchService.swift#L174-L240)限制重任务同时运行 → Y [`BookSourceSearchFanOut.run`](../../Modules/Services/Online/BookSourceSearchFanOut.swift#L57-L105)已有并发上限、暂停取消。 | 在既有入队函数试验 `nextSourceIndex`，仅普通源和重源同时待跑时留位，所有源都重时不饿死；宽度 1 不承诺并行。用 [`BookSourceSearchFanOutTests`](../../Tests/iOS/yuedu%20appTests/BookSourceSearchFanOutTests.swift) 加可控响应，固定总宽度、顺序与冷／热缓存，测 `search.firstResult` p50/p95、总耗时与请求数；无稳定改善不合入。 |
| 从图片二维码导入 | [`QRCodeDecoder.detect`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Import/QRCodeDecoder.swift)只输出字符串 → Y [`BookSourceImportCoordinator.present`](../../Modules/Core/BookSource/BookSourceImportCoordinator.swift#L70-L85)；RSS 若获批准再接 [`RSSImportSession.load/confirm`](../../Modules/Services/RSS/RSSImportSession.swift#L22-L70)。 | 建议 `decodeSourceQR(imageData:) throws -> [String]`，限制图片体积／像素、后台解码，不申请相机权限。无码有反馈、多码供选择；远端地址先确认下载，预览后另行确认写入，取消零写入、不自动执行脚本。 |
| 跨书架找原文（按需试点） | [`LibraryPassageSearch.collect/matches`](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Search/LibraryPassageSearch.swift#L53-L132)搜本地和已缓存章 → Y [`ReaderBookSearchSession.search`](../../Modules/Features/Reader/ReaderBookSearchSession.swift#L98-L132)、[`ReaderBookSearchMatcher.ranges`](../../Modules/Features/Reader/ReaderBookSearchMatcher.swift#L53-L86)目前服务单书。 | 建议 `searchDownloadedPassages(bookIDs:query:limit:)`：先限手选书、分批且可取消，不在启动时建永久索引。两书同句、短中文、emoji 均能跳到正确文字；缺章不联网。大书架测首批结果时间、峰值内存与临时磁盘再决定扩展。 |

**暂缓的产品变化：** 多书架分组会改变持久化与恢复规则；Android 备份包导入和跨设备合并不是“恢复 Fork 自己的版本”；MeloTTS 是新增本地音色，不是解决原声播放。以上均须另立决策。统计、EPUB 排版、规则登录、批量正文等已有能力的双端索引见[全项目对比](../../Technotes/LegadoIOSFeatureComparison.md)，不重复立项。

## 6. 交付顺序、验证与回退

1. **先做第 1 节第一批**，再独立做第 2 节同名章。前者防误改书，后者证据明确；都不要求改磁盘格式。第 1 节草稿试跑、第 3 节预览可单独评审，不必等待完整新规则协议。
2. **先复现再动媒体／性能。** 第 4 节先投事件顺序测试；第 5 节搜索先投测量。新功能一次做一项，不与 Android RSS 阶段验收捆绑。涉及 View 时沿用原生组件、五语言、VoiceOver、Dynamic Type 与 iOS 17 的真实弹层关闭顺序。
3. **回退边界：** 净化限制若需撤回，可暂时拒绝整包，不可恢复静默扩大范围；换源只撤回选章策略，不批量改用户进度；备份可撤下预览并沿用原恢复入口，不删本地数据、远端版本或恢复日志。未来若改持久化，须先单列前后版本读写与回滚方案。只独立实现行为和自建用例，[许可说明](../../LICENSING.md)不授权搬用 L 的 GPL 源码与素材。

**复验本文三个纯函数**（从 Y 仓库根执行；不运行 App，不读用户数据）。WebDAV 草案依赖 App 类型，不计入此命令；其验收必须走现有恢复管线与隔离存储。

```bash
python3 - <<'PY'
from pathlib import Path
import re, subprocess
doc = Path("docs/legado-alignment/legado-ios-adoption-plan.md").read_text()
blocks = [b for b in re.findall(r"^```swift\n(.*?)\n```$", doc, re.M | re.S)
          if b.startswith("// 可独立运行：")]
assert len(blocks) == 3
for block in blocks:
    subprocess.run(["swift", "-"], input=block, text=True, check=True)
PY
```

本次按上述命令实际运行了三个 `swift -` 样例，输出依次为 `rules: title-only and exclusion blocked; supported body rules retained`、`chapters: 13 beats 4 near 12; equal distance stable; higher score preserved`、`audio: disconnected while interrupted clears resume; active playback pauses`。这些结果只覆盖规范化输入的范围判断、候选比较和拔耳机时的恢复意图，不代表 JSON 导入、整书换源或设备播放已修改。

后续实际接入时，再用 `scripts/sim.sh` 解析环境、`scripts/xctest.sh` 串行运行相应测试类。未跑 App 回归、真机媒体及真实 WebDAV 前，不能宣称功能已交付或 S8 已通过。
