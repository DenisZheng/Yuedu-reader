# Yuedu 与本地 Legado 的功能对齐审计

## 结论与范围

**Yuedu 可以作为 iOS 功能对齐的基础，但目前不是 Legado 的等价实现。** 搜书、发现、书架、换源、阅读、缓存、朗读、漫画、视频、RSS 等主干已存在；主要差距在书源执行契约、规则数据完整性、迁移互通和高级工具，而不是缺少一个阅读器界面。

本次比较固定在本地代码，不代表两个项目的最新线上版本：

| 项目 | 本地位置 | 仓库 | HEAD |
| --- | --- | --- | --- |
| Yuedu | 当前仓库 | `DenisZheng/Yuedu-reader`，上游 `CHANG-JUI-LIN/Yuedu-reader` | `f821dc9a` |
| Android 基准 | `../legado` | `LegadoTeam/legado` | `330e606c4` |

**基准是同级目录的 LegadoTeam 版本，不是凭印象中的旧版 Legado。** 这个基准已包含纯 JS 单文件书源、批量正文、扩展段评、自动任务、MCP 等能力，必须纳入对齐范围。

方法：核查两端 UI 入口、模型、导入导出、服务调用与测试源码。除下文的 macOS Foundation 正则小实验外，没有运行 App、Android 测试、iOS 测试或真实书源批量校验。本文的“已有”指发现实现与入口，不等于端到端验收通过；“未发现”指已检查相关模型、入口及全局引用，但不是穷举所有动态脚本的证明。

不提供“已对齐百分之多少”：功能权重未定义，字段存在不等于语义一致，已有测试文件也不等于本次测试通过。

**真实样本补充：** 后续对用户提供的 253 个书源和 307 个 RSS 源做了离线导入与调用链审计，见 [真实源包审计](LegadoRealSourceAudit.md)。这批 RSS 的 `type` 全为 0，媒体主要依赖网页/HTML；实际优先项是源会话、规则回调、HTML 媒体、脚本注入和列表翻页，而不是只增加 type=1/2 的分流。下文仍保留整个 Android 基准的通用差异，不能把其中每一项都当作这两个样本包已触发的问题。

下文 `Y:` 为当前仓库根目录，`A:` 为 `../legado` 根目录；Android 源码简称 `A/java/` 对应 `app/src/main/java/io/legado/app/`。

## 一、功能总览

| 功能域 | Yuedu 当前状态 | 与基准的主要差别 |
| --- | --- | --- |
| 书架、分组、排序、批量操作 | 已有 | 分组模型、批量操作集合和备份格式仍需逐项验收，不能因都有书架就认定数据可互换 |
| 多源搜索、发现、详情、目录、正文 | 已有 | 传统声明式书源主流程存在；纯 JS 单文件源与部分规则字段未对齐 |
| 书源管理、编辑、导入导出、调试、校验 | 已有 | 有五阶段校验，但缺规则订阅更新机制；导入导出不能完整保存基准的所有字段 |
| 换源 | 已有 | Yuedu 还可切书库、模块和保留版本；基准的按作者、字数、响应时间过滤及自动处理等高级控制未见同等入口 |
| TXT / EPUB / PDF / MOBI / AZW3 | 两端均有实现 | 不能把 PDF、Kindle 文件当作 Yuedu 独占优势；解析和渲染质量需另测 |
| Markdown、CBZ、本地音频 | Yuedu 有明确导入路径 | 属于可保留的产品能力；不以格式数量代替在线书源兼容性 |
| UMD | 未发现支持 | Android 有 `UmdFile`；Yuedu 格式表与导入服务没有 UMD |
| 排版、主题、翻页、自动阅读 | 已有 | SwiftUI/CoreText 与 Android 原生实现不同；设置包仅部分兼容，不应要求 UI 像素复刻 |
| TXT 分章规则 | 部分对齐 | 可导入规则，但忽略 Android 的 `replacement` |
| 正文替换/净化 | 部分对齐 | 标题作用域、书名/书源范围、排除范围、分组语义不完整 |
| 书签、高亮、笔记、正则高亮 | 已有 | 不等于兼容 Android 的备份与全部规则语义；部分入口有 Pro 门槛 |
| 段评 | 有另一套实现，协议不齐 | Yuedu 识别正文标记并运行相关动作，不等于支持基准完整 `ruleReview` / JS 段评协议 |
| 系统 TTS、HTTP TTS | 已有 | Yuedu 能导入 Legado HTTP TTS 配置，还有 Edge TTS；复杂 JS 引擎仍受公共运行时差异影响 |
| 有声书 | 已有 | 包含睡眠定时、片头片尾跳过等，不应误报为缺失；缓存范围及中断恢复需单独验收 |
| 漫画、视频 | 已有 | 已有原生视频播放；不是旧文档写的“只开浏览器”。浮窗等细节不等价 |
| RSS / Legado 订阅源 | 部分对齐 | 基础列表、分类与正文路径已有；搜索、正文翻页、启动页、预注入等扩展字段缺失 |
| 离线下载 | 已有，后台行为不同 | 当前 iOS 实现后台额度到期暂停并落盘，不是 Android 式持续运行的缓存服务 |
| 在线书导出 TXT / EPUB / PDF | 未发现同等实现 | Yuedu 能分享本地原文件；没有把在线章节缓存组装为书籍文件的同等路径 |
| 正文手工编辑 | 未发现同等入口 | 替换规则、笔记不是修改该章正文的替代功能 |
| iCloud / WebDAV | 已有，但不互通 | Yuedu 自有同步协议；不能直接当作 Legado 整包备份恢复或跨端进度同步 |
| 字典规则 | 未发现同等实现 | AI 查词不是 `DictRule(urlRule, showRule)` |
| 自动任务 | 未发现同等实现 | 阅读自动翻页、RSS 刷新、下载任务不是可导入的 cron + JS 自动任务 |
| Web 管理、远程调试、MCP | 明显不足 | Yuedu 局域网服务仅少量只读 JSON 接口；不是基准的网页阅读/编辑/调试平台 |
| OPDS / Calibre / 公有领域书库 / 模块 / AI | Yuedu 有独立实现 | 本次基准未见同类原生模块；属于可保留的差异化方向，不应挤占书源对齐的优先级 |

主干入口证据：

- Y: `Modules/Features/Bookshelf/HomeView.swift`、`Modules/Features/Settings/ProfileView.swift`、`Modules/Features/BookSource/BookSourceListView.swift`。
- Y: `Modules/Core/BookSource/BookSourceFetcher+Search.swift`、`BookSourceFetcher+Discover.swift`、`BookSourceHealthChecker.swift`（`ValidationStage`）。
- Y: `Modules/Features/Reader/ReaderView+SourceChange.swift`、`ReaderView+AutoRead.swift`、`ReaderDownloadOptionsView.swift`。
- Y: `Modules/Core/TTS/TTSSourceImport.swift`、`TTSCoordinator.swift`、`AudiobookPlayer.swift`；`Modules/Features/Reader/TTS/AudiobookView.swift`。
- Y: `Modules/Services/LibraryStore/BookFileFormat.swift`、`LocalBookImportService.swift`；`Modules/Features/FixedPageReader/`、`Modules/Features/Reader/Video/`。
- A: `app/src/main/res/xml/pref_main.xml`、`app/src/main/res/menu/book_read.xml`、`book_info.xml`、`book_source.xml`、`main_bookshelf.xml`、`change_source.xml`、`book_manga.xml`、`audio_play.xml`。
- A/java: `model/localBook/LocalBook.kt`、`TextFile.kt`、`EpubFile.kt`、`PdfFile.kt`、`MobiFile.kt`、`UmdFile.kt`。

## 二、优先处理的兼容缺口

### G01：纯 JS 单文件书源 `mainJs` 缺失

Android 的 `BookSource.mainJs` 不是 `jsLib` 的别名。非空时，搜索、发现、详情、目录、正文走独立的 JS 函数契约；编辑器还能新建 JS 书源。

Yuedu 的 `BookSource`、`CodingKeys`、导入器及抓取路径未发现 `mainJs`。现有 `jsLib` 和规则里的 `@js:` 不能替代它。

影响：基准中正常工作的 JS 书源无法原样迁移；包含该字段的 JSON 经现有模型解码/重编码也不能完整保留脚本。单文件 JS 文本不会按该协议导入。

证据：

- A/java: `data/entities/BookSource.kt:108` 附近；`model/jsSource/JsSourceEngine.kt`；`model/webBook/WebBook.kt:60` 起的多个 `isJsSource()` 分支；`ui/book/source/edit/JsSourceEditActivity.kt`。
- Y: `Modules/Core/BookSource/BookSource.swift:246`、`:337`；`BookSourceStore.swift:717`；`BookSourceFetcher+Search.swift`。

### G02：批量正文与副文缺失

Android `ContentRule` 具有 `subContent`、`contentBatch`、`maxBatchSize`，批量正文还涉及 `java.cacheContent`；纯 JS 源有 `getContentBatch`。

Yuedu 的 `ContentRule` 没有以上三个字段，JS 桥未发现 `cacheContent`。普通章节预取和并发下载不是该协议的等价实现。

影响：副文/歌词等可能丢失；依赖批量协议的源不能获得同等行为。不能仅据此断言所有此类源完全不可读——Android 本身允许未回存章节回到单章路径。

证据：A/java `data/entities/rule/ContentRule.kt`、`model/webBook/WebBook.kt:510` 附近、`help/JsExtensions.kt:149`；Y `Modules/Core/BookSource/BookSource.swift:166`。

### G03：段评“有界面”但协议未对齐

Android 的 `ReviewRule` 包含摘要接口、段落索引/计数、详情与翻页、回复、头像/名称/徽章、发布/删除/赞踩等字段；JS 源另有段评函数入口。

Yuedu `ReviewRule` 只有 `review: String`，模型注释明确表示不执行通用 `ruleReview`，而从正文中提取段评标记。已有 `LegadoReviewActionRunner`，所以不能说 Yuedu 完全没有段评，也不能说已有功能等价于基准协议。

影响：部分站点段评可用，其他遵循基准规则的源仍无法直接工作；导入导出会丢掉未承载字段。

证据：A/java `data/entities/rule/ReviewRule.kt`、`ui/book/read/ReviewDetailDialog.kt`、`model/jsSource/JsSourceReview.kt`；Y `Modules/Core/BookSource/BookSource.swift:234`、`:270`，`Modules/Services/Online/LegadoReviewActionRunner.swift`。

### G04：JS / Java / HTML / 正则运行语义并不等价

这是整个书源生态的公共风险，而非一个 UI 功能：

1. Android 使用 Rhino/Java 互操作；Yuedu 使用 JavaScriptCore 和有限兼容层。`Packages.*` 是白名单，不是 JVM。
2. 本地基准存在的 `queryTTF`、`queryBase64TTF`、`downloadFile`、`readTxtFile`、`getZipStringContent`、`getZipByteArrayContent` 等，在 Yuedu 运行时未发现对应实现。字体反混淆、源内文件处理等不能仅靠成功导入 JSON 保证可用。
3. jsoup 兼容层已有真实 SwiftSoup 查询、`selectFirst`、Elements 索引/迭代，但仍有修改 DOM 的 no-op、返回固定值的接口；不能视为完整 jsoup。
4. `enabledCookieJar` 被保存但不控制自动 Cookie 管理。对依赖关闭自动 Cookie 的源，行为与基准不同。
5. `refreshContent()` 当前只输出 DEBUG 日志；`refreshExplore()` 已接到发现页动作，`refreshBookInfo/Toc()` 在段评动作流程有 handler，不能一概列为 no-op。

正则尤其值得先验证，而不是继续加“兼容转换”：

`RegexSanitizer.sanitize` 会把 `a++a` 改为 `a+a`，把 `(?>a+)a` 改为 `(?:a+)a`。本次在本机 macOS 的 `NSRegularExpression` 做了最小实验：

| 表达式 | 编译 | 匹配 `aa` |
| --- | --- | --- |
| `a++a` | 成功 | 否 |
| `a+a` | 成功 | 是 |
| `(?>a+)a` | 成功 | 否 |
| `(?:a+)a` | 成功 | 是 |

这说明当前“ICU 不支持，所以必须降级”的笼统前提至少不适用于本机 Foundation；这种改写确实改变匹配语义。**这不是 iOS 17 真机结果，也未运行整个书源引擎**，下一步应在最低支持版本上添加原表达式/改写表达式的回归，再决定去掉哪些转换。

证据：

- Y: `Modules/Core/RuleEngine/ModernParser/JS/LegadoRuntimeCapabilityRegistry.swift`、`LegadoJSBridge.swift:1891`、`JSCoreEngine.swift:1450`；`Modules/Core/RuleEngine/ModernParser/Cache/RegexSanitizer.swift:34`。
- Y: `Modules/Services/Online/DiscoverQuickActions.swift:110`、`LegadoReviewActionRunner.swift:368`；`Modules/Core/BookSource/BookSource.swift:263`。
- A/java: `help/JsExtensions.kt`；`help/http/`；`model/analyzeRule/`。

### G05：文件型书源 `bookSourceType = 3` 缺少完整链路

Yuedu 有类型显示，也能编辑/保存 `ruleBookInfo.downloadUrls`，但当前内容路由只有 text/audio/manga/video，type 3 落入默认 text。全局引用中，`downloadUrls` 仅见模型、编辑器与 JS 暴露，未发现 Android 那样的提取下载链接并导入文件的服务流程。

Android 会根据 `isWebFile` 走 `downloadUrls`，而不是强行提取章节目录。

影响：能导入 EPUB 不代表能使用“提供 EPUB 下载链接的书源”。这是入口可见、执行未接通的典型缺口。

证据：A/java `model/webBook/BookInfo.kt:154`、`ui/book/info/BookInfoViewModel.kt:360`；Y `Modules/Core/BookSource/BookSource.swift:105`、`:420`、`OnlineBookContentInference.kind(fromSourceType:)`；`Modules/Features/BookSource/BookSourceEditView.swift:515`。

### G06：替换规则和 TXT 分章是有损兼容

**替换规则：**

- Android 有 `group`、`scopeTitle`、`scopeSource`、`scopeContent`、`excludeScope`、`timeoutMillisecond` 等。
- Yuedu 的持久模型只保留较小字段集合；导入器直接跳过 `scopeContent=false` 的规则，分组拼入名称。
- Yuedu 执行范围按源 URL 匹配，缺少同等的标题/正文分离和排除规则。Android 按书名限定的规则不能直接解释成源 URL。

**TXT 分章：**

- Android `TxtTocRule.replacement` 用于处理匹配到的标题。
- Yuedu 明确忽略该字段；虽然能导入 `rule`/`chapterRule`，生成的目录标题仍可能不同。

这类差异比一个完全缺失的按钮更隐蔽：导入显示成功，但结果发生变化。

证据：A/java `data/entities/ReplaceRule.kt`、`data/entities/TxtTocRule.kt`、`model/localBook/TextFile.kt:516`；Y `Modules/Core/Replace/ReplaceRule.swift`、`ReplaceRuleStore.swift:107`、`:326`；`Modules/Core/TXT/TXTTocRule.swift`。

### G07：RSS 扩展字段未承载

Android `RssSource` 具有 `nextContentUrl`、`searchUrl`、`preloadJs`、`startHtml/startStyle/startJs`、`enableReadRecord`、`showWebLog`、`type`、`preload`、`cacheFirst` 等字段。

Yuedu 的 `RSSSource` 和 Legado 导入导出器未承载这些字段。列表翻页的 `ruleNextPage` 不能替代正文翻页的 `nextContentUrl`；已有 `injectJs` 也不等于预注入和启动页协议。

影响：基础 RSS 和部分 Legado 网页订阅能工作，但复杂订阅源不可宣称完整兼容，也不能无损往返导出。

证据：A/java `data/entities/RssSource.kt`；Y `Modules/Services/RSS/RSSModels.swift:100`、`LegadoSourceJSONParser.swift`。

## 三、需要补齐的用户工作流

### G08：规则订阅更新，而非一次性 URL 导入

Android `RuleSub` 管理书源、订阅源、替换规则的订阅地址，含自动更新、更新间隔、静默更新、预执行 JS 和绑定源。

Yuedu 有 URL 导入与合并更新，但在书源模型、管理 UI 和服务中未发现同等订阅实体及更新链路。`Modules/Services/Subscription` 是付费会员，不是规则订阅；模块仓库也不是该数据协议的替代。

证据：A/java `data/entities/RuleSub.kt`、`ui/rss/subscription/RuleSubActivity.kt`；Y `Modules/Core/BookSource/BookSourceStore.swift`、`Modules/Features/BookSource/BookSourceListView.swift`。

### G09：Android 整包迁移与跨端进度未对齐

Android 备份可选择书架/分组/备忘录、书签/高亮、书源/RSS/规则订阅、规则/TTS/字典/自动任务、阅读记录、设置等；部分敏感状态有单独保护逻辑。

Yuedu WebDAV 当前备份到 `/yuedu/`，主要是 `book_sources.json`、`books.json`、`replace_rules.json` 和 manifest。iCloud 同步覆盖更多自有数据，但仍是 Yuedu 协议。

未发现读取 Android 整套备份并迁移对象关系、阅读位置、书签和规则的导入器。**同用 WebDAV ≠ 同一备份协议，更不等于自动双向同步进度。** 已暴露给源脚本的 `book.durChapterIndex` 也不是迁移器。

推荐先做单向迁移：预览→选择→映射→导入→摘要→可回滚；跨端持续同步单独立项，先定义身份和冲突规则。不要直接覆盖本地存储，更不要把 Android 的页码当成 CoreText 分页位置。

证据：A/java `help/storage/Backup.kt:54`、`Restore.kt`；Y `Modules/Services/WebDAV/WebDAVManager.swift:175`、`Modules/Services/iCloud/ICloudSyncManager.swift`、`Modules/Services/Migration/StorageMigration.swift`。

### G10：在线书导出和正文编辑

Android `ExportBookService` 有 TXT/EPUB/PDF 导出分支；`ContentEditDialog` 提供正文编辑。

Yuedu `BookStore.shareableFileURL` 明确对在线书返回 nil，仅提供已有本地文件的分享；没有发现对应的章节组装导出服务或正文编辑入口。

推荐分开交付：先导出已经完整缓存的 TXT，再做 EPUB（目录、图片、编码、元数据），最后视需求做 PDF。缺失章节必须披露，不能导出不完整文件却提示成功。正文编辑需明确原始缓存与用户修改的关系，并校验书签、选择区、TTS 位置不会错移。

证据：A/java `service/ExportBookService.kt:313`、`ui/book/read/ContentEditDialog.kt`；Y `Modules/Services/LibraryStore/BookStore.swift:2791`。

### G11：自定义字典规则

Android `DictRule` 通过 `urlRule` 请求、`showRule` 解析，且支持规则驱动的动作。Yuedu 有 AI 查词，但未发现相同规则模型、导入和执行入口。

应复用现有网络/规则引擎建立字典用例，而不是把“查字典”强行依赖 LLM、账号或会员。

证据：A/java `data/entities/DictRule.kt`、`ui/dict/`；Y `Modules/Core/AI/AIWordLookup.swift`、`AIReadingAction.swift`。

### G12：cron + JS 自动任务

Android 有 `AutoTaskRule`、编辑/导入/调试入口、执行记录与调度器。Yuedu 未发现同等系统。

建议先对齐任务格式、手动执行、前台到期执行、日志与失败状态；后台准点执行需要另做平台验证，不能从 Android 调度器直接类推。不要把自动翻页或普通刷新计时器当作交付。

证据：A/java `data/entities/AutoTaskRule.kt`、`model/AutoTaskRunner.kt`、`service/AutoTaskScheduler.kt`、`ui/autoTask/`。

### G13：Web 管理与 MCP

Android HTTP/WebSocket 服务具备书源保存、读取、调试、书架、目录、正文等接口，还有网页前端。MCP 支持 `save_source`、`debug_source`、`list_sources`、`get_source`、`check_source`、`eval_js`、日志/Cookie 操作等。

Yuedu `LanWebServer.handleRequest` 实际只有四类只读路由：`/health`、`/`、`/book/:id`、`/api/sources`；书源接口返回名称、URL、启用状态的摘要，不返回完整规则。未发现网页管理、WebSocket 调试或 App 内 MCP 服务。

这影响在电脑上维护书源，以及让开发工具直接调用手机真实规则引擎。若补齐，写入/执行脚本/读取 Cookie 必须有明确授权边界，不能沿用只读服务思路直接开放。

证据：A/java `web/HttpServer.kt`、`web/WebSocketServer.kt`、`web/mcp/McpToolServer.kt`；A `modules/web/`、`api.md`；Y `Modules/Services/LanServer/LanWebServer.swift:270`。

### G14：UMD 与剩余高级控制

UMD 是明确的格式缺口。换源筛选、缓存/导出细项、阅读菜单自定义、漫画控制、硬件按键与墨水屏行为等，应列为第二轮逐操作验收，不能仅按类名或设置名称判断全部缺失。

尤其不要误报：Yuedu 已有自动阅读、漫画自动滚动、有声书片头片尾跳过、源变量/书籍变量编辑、源自定义按钮、主题/正则高亮导入。

## 四、保留的能力与 Fork 决策

1. **保留 SwiftUI/CoreText 和现有阅读位置模型。** 功能对齐不要求移植 Android UI、数据库或整套分页器。
2. **保留 OPDS、Calibre、青空文库/Gutenberg、模块、作品聚合、iCloud、AI 等现有方向。** 它们不是书源缺口的补偿，也没必要为了相似度删掉。
3. **单独决定账号/会员产品策略。** 当前 `PremiumFeature` 和 `SubscriptionStore.hasAccess` 将字体导入、触摸区编辑、主题/背景、部分笔记与高亮等绑定 Pro；存在实现不等于普通自构建用户能直接用。功能对齐前应明确 Fork 的访问策略，本次未修改任何授权逻辑。
4. **自行构建的服务配置要独立。** README 明确构建需要自己的 `GoogleService-Info.plist`；账号、StoreKit、Firebase、同步并非仅换 Bundle Identifier 就自然可用。应把最小可用阅读路径与可选云服务的依赖边界列清。
5. **发布前审查许可证和品牌。** 本地 Yuedu 根许可证为 MPL-2.0，Legado 为 GPL-3.0。不能把“功能仿照”与“复制代码”当作同一件事；需要移植源码时逐文件核查许可。Yuedu 的 `TRADEMARKS.md` 另要求公开 Fork 使用独立名称、图标和品牌。这里记录仓库条款，不作许可证兼容性的法律结论。

证据：Y `Modules/Services/Subscription/PremiumFeature.swift`、`SubscriptionStore.swift:261`、`README.zh-Hans.md`、`LICENSING.md`、`TRADEMARKS.md`；两仓库根 `LICENSE`。

### 当前后台行为应如何表述

`OfflineDownloadBackgroundTask` 使用有限后台任务断言，到期触发暂停；应验收“切后台→安全暂停→回前台续传”，不能宣传为与 Android 后台长期缓存等价。是否追加纯 HTTP 文件的后台传输，需要按源的请求/解析/WebView需求分别设计。

证据：Y `Modules/Services/Offline/OfflineDownloadBackgroundTask.swift`、`Technotes/OfflineDownloadContract.md`。这是对当前实现的判断，不是声称 iOS 永远不能增加后台下载能力。

## 五、建议实施顺序与验收

优先级以“未改写的基准书源与用户数据能否继续使用”为准，不以页面多少或代码量排序。

### P0：先建立可比较基线，再补书源核心

1. 固定本文两端 commit，建立对齐台账；每项记录输入、期望结果、两端证据、差异类别。
2. 选一组有代表性的真实源，同时保存去敏后的固定响应和期望值；涵盖普通 HTML/JSON、复杂 JS、登录、漫画、音频、视频、文件源、JS 单文件源、段评。
3. 给 `mainJs`、正文/段评/RSS 扩展字段增加承载与导入导出完整性检查。未实现字段要明确告知；保存字段不算完成执行。
4. 处理 G01/G04；按样本补 G02/G03/G05。正则与 Cookie 属于公共语义，应先有回归再改。

验收：同一固定输入得到相同书名、详情、目录顺序/URL、正文和媒体 URL；分页、登录状态和变量写回一致；声明支持的字段往返不丢失。真实网站不可达要与解析不一致分开统计。

实现边界：沿现有 `BookSourceSession` / `SourceScriptHost` / fetcher → `OnlineReadingPipeline` → store 流程接入；不要在 View 里增加抓取链，不再建平行的规则缓存或 JSContext 系统。

### P1：可迁移、可维护、可导出

1. G09 单向 Android 备份导入，先覆盖书源、书架/分组、进度/书签、替换/TXT/TTS。
2. G06 替换和 TXT 规则语义；G07 RSS 扩展。
3. G08 规则订阅更新。
4. G10 在线书 TXT/EPUB 导出；正文编辑可单独后置。

验收：拿一份完整 Android 样本备份导入，核对数量、关系、进度、规则与重复导入的幂等性；不可迁移项有摘要；失败不破坏原数据。导出的书能在独立阅读器打开，章节完整性可核对。

### P2：高级工具与平台体验

1. G11 字典规则、G12 自动任务。
2. G13 Web 调试/MCP、G14 UMD 和高级控制。
3. 按明确的平台合同验收后台、音频中断、锁屏、低内存恢复等行为。

如果维护大量书源，Web/MCP 可提前到 P1，原因是它能提高兼容性验证与调试效率，而不是普通用户阅读的硬前提。

### 可复用的测试资产

Yuedu 已有 `LegadoAlignmentTests`、`LegadoRuntimeContractTests`、`LegadoJsoupBridgeCompatibilityTests`、`LegadoJSONPathCompatibilityTests`、`LegadoRSSCompatTests` 等，不必从零另起一套测试框架。

`BookSourceCompatibilityAuditTests` 可驱动五阶段真实源校验，但有两个边界：

- 默认关闭，需要指定本地源包；本次未开启。
- 当前筛选 `bookSourceType == 0`，且不对通过率作断言，因此不能拿它单独证明音频/漫画/视频/文件源或整体功能对齐。

Android 的 `model/jsSource/`、批量正文、自动任务、ReviewRule 相关测试可作为契约线索；测试源码本身不等于生产行为已验证。

## 六、文档与验证记录

现有 `docs/book-source/legado-differences.zh-Hans.md` 可以作为线索，不能直接作为本次结论：

- 它把 `openVideoPlayer` 写成退化到浏览器；当前已调用原生视频 presenter。
- 它把多个 refresh API 统一写为 no-op；当前 `refreshExplore` 和部分段评动作已有接线，只有逐调用路径核对才准确。
- 它的正则“不支持”说明与本机 Foundation 最小实验不符，应复核支持版本后修订。
- 它围绕较早的 Legado 3.0 规则面描述，没有覆盖本次基准的 `mainJs`、批量正文及新版段评字段。

本次已执行：

- 固定并读取两端本地 commit、remote 与工作区状态。
- 对照模型字段、导入器、路由、关键 UI 菜单、服务及测试源码。
- 搜索缺失候选的全局引用，并追读相关实现；字段改名（如 `initScript` 对应 JSON `init`）不计作缺失。
- 执行上文 macOS Foundation 正则最小实验。

本次未执行：App 构建、模拟器/真机操作、Android/iOS 测试套件、真实源包联网校验、跨端迁移或完整性能测试。因此本文是**可用于拆任务的静态差异审计，不是兼容性认证**。

本次只新增本文，不修改业务代码、配置、现有差异文档，也不修改 Android 仓库。开始时已有的未跟踪 `.codegraph/` 保持不动。
