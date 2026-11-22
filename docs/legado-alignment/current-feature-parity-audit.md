# 当前 Fork 与固定 Android 基准的功能差距复核

> 本报告保留 `c3eec5e1` 加当时工作区的历史判断；下文的“未实现”不是当前缺失清单。正则／配置保真、文件型书源、RuleSub、mainJs、批量正文，以及 2026-11-22 的副文、原生只读段评、LoginUiV2 与 Review 修复已先后进入主线。当前结论、剩余边界和证据见 [项目状态页](STATUS.md)；完整段评写动作、完整替换语义和其他后置项并未因此全部完成。

## 结论

**RSS 已从“入口、字段和运行时缺少接线”推进到“主流程已实现、部分实源和平台验收未完成”；整个 App 仍不是 Android 基准的等价实现。** 下一轮不能只继续补 RSS 字段，也不能照抄起点审计的缺失清单。更大的剩余差距在书源协议、规则语义、配置订阅、文件型内容、数据互通和高级工具。

建议顺序：按代表输入修复共享规则语义，补文件型书源、规则包订阅和书源配置保真；再按需要推进 mainJs、批量正文、段评、迁移和高级工具，并单独补 RSS 人工验收记录。**用户已确认真实视频能够播放，偶发快进异常作为小 Bug 单独维护，不列为功能缺失，也不作为优先补功能的依据。** 本报告只盘点，不批准扩大实现范围。

## 1. 本次比较对象与证据边界

| 对象 | 本次实查 |
| --- | --- |
| Android | 同级 `../legado`，HEAD `330e606c4d57e08adc056ff8ab7a4132c784da9a`，与项目固定基准相同 |
| iOS 已提交基线 | HEAD `c3eec5e15297f28649ec70fdee2da1a1ceaf6358`，3.0.1 Debug IPA 交付记录提交 |
| iOS 实际阅读的代码 | 上述 HEAD 加本次开始时已有的未提交改动；涉及 BookSourceStore、ModernParserBridge、JSCoreEngine、LegadoJSBridge 的导入不变不写和日志清理。不把工作区等同已交付 IPA |
| 书源样本 | `docs/Booksource.json`，253 项：文本 208、音频 3、图片 32、文件 3、视频 7 |
| RSS 样本 | `docs/rssSources-valid.json`，307 项，type 全为 0；没有 type=1/2 实源样本 |

本次重新执行了两包的 JSON 解析、计数及 SHA-256。两包分别为 `3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc` 和 `0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45`，与固定记录一致。未执行包内脚本、未打印源名、规则、请求地址或凭据。

核查方式：读取最终方案、执行计划、旧审计和最新专项记录；对照两端模型、消费者、导入、状态、服务和 UI 路径；对缺失候选搜索生产 Swift 源码，并检查相关入口。**“未发现实现”是已核查范围内的静态判断，不是对所有动态脚本的穷举证明。**

状态用语：

- **未实现**：相关生产模型/路由/服务没有接通 Android 合同。
- **部分对齐**：有对应功能，但字段、结果、状态或操作集合不等价。
- **已实现、有已知 Bug**：功能已可用，但部分操作偶发异常；与功能缺失分开统计和维护。
- **已实现、待验收**：发现完整接线或历史局部行为证据，但没有当前目标的实际验收。
- **明确受限/产品差异**：平台、安全边界或已经确认的产品决定；不自动作为必须修复的 bug。
- **外部失败待分因**：站点/源配置失败与客户端缺陷尚不能统一归因。

本次没有运行 Android/iOS App 测试、没有构建或安装 App、没有公网播放/登录/WebDAV 测试，也没有启动全包联网校验。下文历史测试只标为“既有记录”，不写成本次通过；不给出全项目对齐百分比或源可用率。

## 2. 旧缺口中，哪些已经不能继续报“没有”

| 起点审计的判断 | 当前复核 | 当前入口/依据 |
| --- | --- | --- |
| RSS 缺 type、启动页、搜索、正文分页等扩展字段 | 已承载，导入未知字段保留；相关执行路径已接入 | [RSSModels.swift](../../Modules/Services/RSS/RSSModels.swift)、[LegadoSourceJSONParser.swift](../../Modules/Services/RSS/LegadoSourceJSONParser.swift) |
| singleUrl 因分类/列表规则被误分流 | 已改为 singleUrl 优先，计算动态启动地址；不再报告旧 6 项分支缺口未修复 | [RSSOpenTarget.swift](../../Modules/Services/RSS/RSSOpenTarget.swift):214 起，`resolve` |
| RSS 每次新建空 JS 引擎、没有源变量/规则回调 | 已复用 BookSourceSession/共享宿主，源/流程/文章状态及撤销接入 | [RSSRuntime.swift](../../Modules/Services/RSS/RSSRuntime.swift):15–127、LegadoRSSScraper |
| 列表只能加载首页，正文没有分页 | 分类、远程搜索、下一页/重试/取消/循环控制和正文分页已有实现 | [RSSFeedSession.swift](../../Modules/Services/RSS/RSSFeedSession.swift):59–168、[LegadoRSSScraper.swift](../../Modules/Services/RSS/LegadoRSSScraper.swift) |
| 规则 HTML 全走净化器，网页只是 Safari URL 交接 | 普通 Feed 与规则网页已分开；源样式/启动脚本/预注入/完成注入/导航和图片资源路径已接入 | [RSSSourcePageSheet.swift](../../Modules/Features/RSS/RSSSourcePageSheet.swift)、[RSSRuleWebDocument.swift](../../Modules/Services/RSS/RSSRuleWebDocument.swift) |
| RSS 图片只有 URL，不执行 coverDecodeJs | 列表缩略图、正文图片和 type=1 已有上下文/字节解码服务 | [RSSImageService.swift](../../Modules/Services/RSS/RSSImageService.swift)、[RSSWebImages.swift](../../Modules/Services/RSS/RSSWebImages.swift) |
| 没有独立订阅 Tab、源批量维护、活性检查 | 已有独立 Tab、记忆树型/方格、筛选、多选/确认删除、主动检查 | [订阅首页与维护记录](rss-source-home-management.md)；活性检查明确不等于全文章/播放验证 |
| 没有 RSS 状态备份和中断恢复 | WebDAV 已加入版本化 RSS 配置/状态及恢复 journal | [WebDAVVersionedBackup.swift](../../Modules/Services/WebDAV/WebDAVVersionedBackup.swift)、[S7 中断恢复](s7-restore-interruption.md) |
| java.downloadFile/readTxtFile 不存在 | 两者已有真实读写/下载实现；但这不等于文件型书源工作流已完成 | [LegadoJSBridge.swift](../../Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift):1552、1602 |
| enabledCookieJar 完全不生效 | 旧模型注释过期；WebFetcher、JS 请求/重试及 RSS 请求执行器已有消费者和回归源码 | [WebFetcher.swift](../../Modules/Services/Network/WebFetcher.swift):66、95–112；[SourceRequestExecutor.swift](../../Modules/Core/BookSource/SourceRequestExecutor.swift):64–119；SourceCookieJarTests |
| 漫画图片还原/长图没有对应能力 | 已补有限 Bitmap/Canvas 横条还原和长图布局；有原规则像素/少量实图的既有证据 | [漫画解码记录](manga-image-decode.md)、[长图与媒体记录](book-source-media-fixes.md)；不是完整 Android Graphics |
| 换源高级功能/自动换源都没有 | 作者校验、分组、详情/目录/字数探测、单章换源和源删除后的自动换源已有 | [ChangeSourceSearch.swift](../../Modules/Features/ChangeSource/ChangeSourceSearch.swift)、[ReaderView+SourceChange.swift](../../Modules/Features/Reader/ReaderView+SourceChange.swift):444–514；仍有结果筛选差距，见下文 |
| RSS java.addBook 完全没有 | RSS 页面/动作桥已有该动作，并经确认交给书源匹配；通用解析 java 对象与网页 java 不是同一个协议 | [RSSWebPageBridge.swift](../../Modules/Services/RSS/RSSWebPageBridge.swift):65、[RSSWebActionRouter.swift](../../Modules/Services/RSS/RSSWebActionRouter.swift):195 |

以上说明旧差距被实现或局部补齐，不代表这些能力在所有源、设备和系统上全部验收通过。

## 3. RSS：已知 Bug、兼容差距与验收边界

### R1：真实视频已可播放，偶发快进异常属于小 Bug

**状态：视频播放功能已实现、用户确认可用；偶发 seek/快进异常是小 Bug，不是功能缺失。**

用户在本次审计后明确纠正：真实视频能够播放，只是偶尔快进有问题。因此撤回此前“真实视频不能播放／播放功能仍未完成”的当前判断，不将该问题计入功能缺失清单，也不以它作为必须先补视频功能的依据。

[验证记录](validation.md)中的旧“不能播放”和少量候选 404 是当时的历史观察，不能覆盖用户最新实际使用反馈。后续如处理快进问题，应按具体播放操作单独复现和修 Bug，不扩大为缺少播放器或整条播放链。本次确认来自用户反馈，助手没有重新运行播放／快进测试，根因未定位。

### R2：规则网页桥不是 Android WebJsExtensions 的完整实现

**状态：部分对齐，兼容差距与安全边界并存。**

- Android `help/webView/WebJsExtensions.kt:49–165` 处理 `ajaxAwait/connectAwait/getAwait/postAwait/headAwait`、`getStringAwait`、加解密、脚本导入等请求桥，并在 `:183–214` 提供同步网络/解析入口。
- Fork [RSSWebPageBridge.swift](../../Modules/Services/RSS/RSSWebPageBridge.swift):23–71、75–92 只准入有限 source 变量与 open/search/showPhoto/addBook/openVideoPlayer 等动作及图片消息。当前页面 `java.get` 是源变量读取，不是 Android HTTP get 的全套重载；没有上述 awaited 网络/解析接口的解码/执行分支。
- [RSSSourcePageSheet.swift](../../Modules/Features/RSS/RSSSourcePageSheet.swift):539–565 只在相应 preload/图片需求下安装桥，且限制 main frame、来源和活跃页面；iframe 不获得同等原生权限。

影响：页面普通 fetch、HTML5 视频或源注入能工作，不代表依赖 Android 网页 java/awaited API 的交互源能原样工作。解析宿主里的 java.ajax 已存在，不能代替网页桥。若以后扩展，必须按真实用例做有限权限适配；**不能为了对齐开放 Android 的任意 run、文件或无界代理**。

### R3：新版 LoginUiV2 未接通，影响 RSS 与书源

**状态：未实现新版协议；旧式登录不是完全缺失。**

Android `model/login/LoginUiV2.kt:11–114` 用 `{"version":2}` 判定，渲染结果为 `rows` 对象，动作返回 `state/error/login/close`；`data/entities/BaseSource.kt:116–163` 调用 `loginUi(state)` 和 `loginAction`。

Fork [RSSLoginService.swift](../../Modules/Services/RSS/RSSLoginService.swift):24–54 期待旧式字段数组，`:84–98` 执行旧式按钮/login 函数；LoginManager 的解析入口也要求数组。书源表单虽支持动态 loginUi 和按钮重载，生产源码未发现 V2 的标记、render/action 协议消费者。

影响：依赖新版动态登录 UI/多步状态/逐字段错误的源不能据旧表单或“可打开登录网页”判作已对齐。真实私人账号/验证码仍属于未验证前置条件，不擅自登录。

### R4：WebKit 子资源与媒体覆盖存在明确上限

**状态：受限或待验，不是缺少所有资源支持。**

- [RSSResourceRules.swift](../../Modules/Services/RSS/RSSResourceRules.swift):18–38 使用 WKContentRuleList；原生匹配与 WebKit URL filter 的表达能力不同，不能编译的 Java 正则明确报受限；还有规则数、大小与执行预算。不是 Android `shouldInterceptRequest` 的完全等价实现。
- WebKit 边界 PoC 已记录无法获得通用逐子资源事件/逐请求预算；R265/R267 的真实 iframe/HLS 在既有专项记录中仍按用户决定列为人工门槛。**这属于具体场景的验收记录边界，不是缺少 iframe/JS 或视频播放功能；用户本次已确认真实视频可播放，但未单列这些源编号的新记录。** 见[WebKit 边界](s8-webkit-boundaries.md)、[收口清单](s8-release-checklist.md)。
- [RSSMediaRequestService.swift](../../Modules/Services/RSS/RSSMediaRequestService.swift):3–11 和 RSSMediaResourceSession 对 DASH、SAMPLE-AES/DRM、部分 HLS 特征和响应预算明确拒绝；这是 Q6 确认的受限范围，不自动引入第二套播放器。
- 原包 type=1/2 为零，因此这两类有合成/本地媒体合同，不等于具有该包的真实源播放证明。HTML video、原生 type=2、附件、iframe/JS 四种路径也不能互相替代验收。

### R5：S8 与发布门槛仍未完成

**状态：已实现部分能力，但验收缺口保留。**

- 本次 `bash scripts/sim.sh doctor` 实查仅有 iOS 26.2/27.2 runtime，没有 iOS 17。最低声明 17.0 不等于最低系统实际运行通过。
- 并非没有做过真机测试：旧稳定提交有 S6 自动回归和用户音画反馈，JSON 复制导入有自签真机反馈。但它们不覆盖当前代码所有实源、iframe、快进、VoiceOver 和 iPad 人工交互。
- 真实受限登录、真实 WebDAV 备份/恢复、VoiceOver/Dynamic Type、当前发布产物的签名/App Group/扩展共享和升级抽查仍须按目标提交单列证据。
- RSS enableReadRecord 的模型保留没有单独消费者，但固定 Android 的原生 RSS 路径也未发现消费该源字段；Android 全局阅读记录开关是另一件事。**不以字段注释推定这是明确的 RSS 故障，也不擅自关闭进度保存。**

[实施计划](implementation-plan.md)仍将 S8 标为进行中；[收口清单](s8-release-checklist.md)保留 `stageAccepted=false`。一些方案/清单顶部仍是旧提交快照，必须与最新 validation 和专项记录一起读。

## 4. 非 RSS：确认仍存在的功能差距

表中 `A/` 为 `../legado/app/src/main/java/io/legado/app/`，`Y/` 为本仓库。行号对应本次工作区，只作定位，不是版本永久链接。

| 功能 | 状态与具体差距 | 两端证据 | 最小完成标准 |
| --- | --- | --- | --- |
| **纯 JS 单文件书源 mainJs** | 未实现。BookSource 没有 mainJs 承载和函数分流；单文件 JS 被默认按 JSON 尝试解析。jsLib 不能替代主脚本 | A `data/entities/BookSource.kt:100`、`model/webBook/WebBook.kt:60/136/207/303/410`、`model/jsSource/`；Y `Modules/Core/BookSource/BookSource.swift:246`、`BookSourceStore.swift:752–777` | 同一 JS 文件能导入/导出，执行 search/explore/getBookInfo/getChapters/getContent；缺可选函数与缺必需函数分开，变量和正文写回正确 |
| **批量正文与副文** | 未实现。ContentRule 缺 contentBatch/maxBatchSize/subContent，桥无 java.cacheContent。普通并发下载不等价；歌词/视频弹幕副文没有该协议 | A `data/entities/rule/ContentRule.kt:14/25/26`、`model/webBook/WebBook.kt:518–526`、`BookContent.kt:131–161`；Y `BookSource.swift:166–192`，生产源码搜索没有消费者 | 批量回存章节与单章回退不重写/串章；文本副文、歌词/弹幕按类型保存，不全部拼作正文 |
| **完整段评协议** | 部分对齐。已有正文标记、点击执行和网页段评；ReviewRule 只有 review 字符串，没有原生摘要/详情/回复分页协议，enabledReview 也没有对应通用解析链 | A `data/entities/rule/ReviewRule.kt:10–51`、`model/analyzeRule/ReviewRuleParser.kt`、`model/jsSource/JsSourceReview.kt`；Y `BookSource.swift:234–241/270`、`Modules/Services/Online/LegadoReviewActionRunner.swift:5–18` | 用固定段评输入验摘要计数/段落锚点、详情/回复分页及动作；发帖/删除等写操作另需确认，不按字段存在假定 Android 所有动作已完成 |
| **文件型书源 type=3** | 未接通完整工作流。downloadUrls 能保存/编辑，但未被详情抓取、下载选择和文件导入服务消费；内容类型 switch 中 3 仍落默认文本 | A `model/webBook/BookInfo.kt:155–170`、`ui/book/info/BookInfoViewModel.kt`；Y `BookSource.swift:105/533–539`，downloadUrls 全局引用无下载链 | 搜索/详情提取下载列表→确认→带源请求上下文下载→既有本地导入→书架/失败/取消；样本 B011/B056/B105 可作后续分层输入 |
| **替换规则语义** | 部分对齐。scopeContent=false 直接跳过；分组拼入名称；scopeTitle/scopeSource/excludeScope/单规则 timeout 不承载；源 URL 范围不等于书名范围。超时跳过本章与 Android 禁用规则/显示错误不同 | A `data/entities/ReplaceRule.kt:25–62`；Y `Modules/Core/Replace/ReplaceRule.swift:6–31`、`ReplaceRuleStore.swift:334–376`、`ReplaceRuleEngine.swift:106–111` | 标题/正文/书名/源/排除范围固定输入对照；导入导出不丢语义；超时及错误结果明确 |
| **TXT 分章标题处理与正则** | 部分对齐。TXT replacement 被忽略；RegexSanitizer 把 possessive/atomic 改成不同语义。本次 macOS 已实际复现，最低 iOS 未验证 | A `data/entities/TxtTocRule.kt:13–15`、`model/localBook/TextFile.kt`；Y `Modules/Core/TXT/TXTTocRule.swift:4–6/33–66/85–87`、`ModernParser/Cache/RegexSanitizer.swift:26–33`、`RegexCache.swift:20` | 固定 TXT 得到相同章节标题；按原表达式比较匹配/替换输出，不能只测转换后能编译 |
| **规则包订阅更新 RuleSub** | 未实现同等实体/流程。手动 URL 导入和 RSS 内容刷新已有，但没有订阅地址、更新间隔、到期检查、版本比较、静默/待确认更新闭环 | A `data/entities/RuleSub.kt:11–29`、`model/RuleUpdate.kt:26–123`；Y BookSourceStore/RSSImportService 没有同等生产流程 | 书源/RSS/替换规则包到期更新，保留本地用户设置；不变不写、失败/取消可重试。实际 Android 更新分支的替换规则 type=2，不照抄旧注释的 3；不声称其自动路径执行 js/showRule |
| **全项目备份完整性/自动备份** | 部分对齐。已有四类版本化 WebDAV 和中断恢复；未覆盖 Android 的完整分类集合/自动备份。书架里的书签/笔记/标注随 ReadingBook 承载，不能误报全不备份；TXT/TTS、正则高亮规则、全局设置、独立历史等仍非同等覆盖 | A `help/storage/Backup.kt:54–84/131–158/273–306`；Y `Modules/Services/WebDAV/WebDAVVersionedBackup.swift:11–29/201–221`、`WebDAVManager.swift:192–195`，backupVersion 生产调用为设置页手动入口 | 各 owner 的可恢复数据逐项列清；损坏/空间不足/强杀不破坏旧数据；真实服务器验证。媒体缓存/凭据默认排除不能简单算故障 |
| **Android 整包迁移和跨端进度** | 未实现，已决定首期后置。Fork WebDAV 自有 manifest/身份，不读取 Android zip 与 BookProgress 协议；有书架位置备份不等于持续同步 | A `help/storage/Restore.kt`、`help/AppWebDav.kt:291–374`；Y WebDAVVersionedBackup/WebDAVManager、Services/Migration 无对应映射消费者 | 单向导入先预览/选择/关系映射/幂等/回滚；跨端进度用章节和字符锚点比较，不能拷贝 CoreText 页码 |
| **在线书导出、正文手工编辑** | 两个工作流未实现同等入口。在线章节缓存不能组装导出 TXT/EPUB/PDF；本地原文件分享、笔记或替换规则不是正文编辑 | A `service/ExportBookService.kt:313–325`、`ui/book/read/ContentEditDialog.kt:115`；Y `Modules/Services/LibraryStore/BookStore.swift:2819–2830` 明确在线书不能分享原文件 | 先完整缓存 TXT 导出，并标缺章；编辑正文有权威 owner/世代保护，刷新不能悄悄覆盖用户编辑，位置/书签/TTS可解释 |
| **书架多分组与换源结果选项** | 部分对齐。一本书只有一个 group String；Android group 位标记可多组。换源已有字数/响应测量和作者校验，但没有相同的绝对字数区间/相对百分比筛选及用户可选的当前章响应时间排序 | A `data/entities/Book.kt:78`、`data/dao/BookDao.kt:414–418`、`ui/book/changesource/ChangeSourceResultOptions.kt:9–76`；Y `LibraryStore/Models.swift:311`、`BookStore.swift:1507–1524`、`Features/ChangeSource/ChangeSourceSearch.swift:57–103/366–373` | 多组增删保持关系/备份；换源对同组固定候选验证未测量项、当前来源固定位置、绝对/相对范围和排序。不是重做已有自动/单章换源 |
| **共享 Java/API 兼容层** | 有限实现。queryTTF/queryBase64TTF、getZipStringContent/getZipByteArrayContent 未发现对应 API；refreshContent 仍只打印 DEBUG 日志。有限 Packages/Graphics 不是 JVM/Android 全量 | A `help/JsExtensions.kt:165/928–984/1052–1108`；Y `ModernParser/JS/LegadoRuntimeCapabilityRegistry.swift`、`LegadoJSBridge.swift:2897–2901`；全文引用排除注释后无上述字体/ZIP接口 | 以实际源分支为单位补有限能力、预算/取消/权限和固定输出；不按 API 数量开放任意系统访问，不重复添加已有文件读写/Bitmap |
| **Web 管理、远程调试、App 内 MCP** | 未实现等价平台。LAN 服务只有健康、书架摘要、单书摘要、源摘要四类 GET，不提供完整规则编辑/保存、目录/正文/调试/WebSocket/MCP | A `web/HttpServer.kt`、`web/WebSocketServer.kt`、`web/mcp/McpToolServer.kt:239/276/347/616/721`、`modules/web/`；Y `Modules/Services/LanServer/LanWebServer.swift:270–310` | 有认证的电脑端维护和调用真实手机引擎；写入/脚本/Cookie各自授权，不直接把只读服务器变成无界执行入口 |
| **UMD** | 未发现格式/导入/解析/阅读路径。已有 EPUB/TXT/PDF/MOBI/AZW3/Markdown/CBZ/音频不能替代 | A `model/localBook/UmdFile.kt`、`LocalBook.kt:171/224/333/366`；Y `Modules/Services/LibraryStore/BookFileFormat.swift:12–36` | 合法/损坏/编码/章节样本导入、阅读和恢复；分发前审查解析器/样本许可 |

### 尚不能凭静态检查判断完全对齐的既有功能

文本搜索→详情→目录→正文、目录/正文多页、缓存命中、登录后读取、漫画/有声书/视频、系统/HTTP TTS、选区/书签/高亮、主题/触摸区/阅读菜单、后台暂停→前台续传等都有实现，不一概列为“没有”。但未做整个 Android 用户操作集合的逐项回放，本次不认证它们全部等价。

特别是 [BookSourceCompatibilityAuditTests.swift](../../Tests/iOS/yuedu%20appTests/BookSourceCompatibilityAuditTests.swift):36–75 已支持指定 sourceTypes（空数组可审计全类型），旧报告“工具只能测文本”应更正为“默认仍只文本”。该测试不对可用率做断言，抓到正文/媒体 URL 也不等于图片/音画验收。

## 5. 不应混成未完成 bug 的产品/平台差异

1. **Google/Firebase、账号后台、StoreKit/会员/Pro 限制**：按 ADR-0004 主动移除，不是待恢复功能。
2. **iCloud**：ADR-0006 暂停入口/自动调用/权限，保留实现和数据。本版不能称它可用，也不把重新开启列为默认补齐任务；保留 WebDAV。
3. **DictRule、AutoTask/Cron**：Android 有 `data/entities/DictRule.kt`、`AutoTaskRule.kt` 和 UI/执行器，Fork 未发现同等模型/导入/执行。它们是全项目差距，但已明确排除本轮；AI 查词、定时刷新、自动翻页不能当作替代。
4. **后台长期运行**：Fork [OfflineDownloadBackgroundTask.swift](../../Modules/Services/Offline/OfflineDownloadBackgroundTask.swift):4–17、35–44 采用有限后台额度，到期暂停落盘，不等于 Android CacheBookService 常驻缓存；正确目标是安全暂停/恢复，不未经验证承诺常驻或准点 Cron。
5. **DASH/DRM、Java/正则/WebKit预算、跨来源桥/认证限制**：明确受限或安全边界。用户已接受的 ADR-0005 无效服务器证书策略也不是“证书链修好了”，更不授权取消其他安全检查。
6. **原始源过期或站点失败**：R217 原包规则仍失效，独立维护配置的单图成功不能写成原包修复；R146 新证书策略后的真实图片仍需自己的复验。站点 404、登录、反爬与程序缺陷分开。
7. **iOS 原生 UI、CoreText、OPDS/Calibre/模块/AI 等**：保留架构/产品差异，不追求 Android 像素复制。Fork 按已确认的五 Tab 和独立 RSS 入口执行；默认停用部分内置模块也不等于删除其实现。

## 6. 建议的后续拆分

| 顺序 | 工作包 | 为什么先做 |
| --- | --- | --- |
| 1 | 补适用 S8 人工/最低系统验收记录，与功能补齐分开 | 验收记录不足不等于功能缺失；视频已能播放，偶发快进问题单列为小 Bug |
| 2 | 代表书源分类型验收 + 配置未知字段/能力报告 + 正则语义修复 | 先建立可复现输入；避免成功导入却静默丢字段/改变内容 |
| 3 | 文件型书源、规则包订阅更新 | 当前样本有文件源；订阅能减少过期规则的维护成本，复用现有服务即可拆成独立工作包 |
| 4 | mainJs、批量正文/副文、完整段评和 LoginUiV2 | 这些是基准新增协议，不是 UI 装饰；分别建立合成合同，不先泛化整个运行时 |
| 5 | TXT/替换规则深化、全项目备份覆盖、在线书导出/正文编辑 | 导入看似成功却有损的语义和用户数据可恢复性，须明确数据 owner |
| 6 | 按用户需要选 Android 单向迁移/跨端进度、多分组、换源细项、Web/MCP、UMD | 涉及身份/安全/新依赖或产品选择，逐项确认；Dict/Cron 继续保留排除决定 |

“未实现”“已实现、待验”和“已实现、有已知 Bug”分开统计和排期。不要为了增加兼容函数数目，另建 JS 引擎、缓存、播放器或无界网页代理。

## 7. 本次实际验证与未验证

实际执行：

- `git rev-parse HEAD` 和 `git -C ../legado rev-parse HEAD`：得到第 1 节的固定 commit；读取工作区状态并保留所有既有改动。
- Python `json.loads`/`Counter`/`hashlib.sha256` 离线统计：得到第 1 节 253/307 数量、类型和匹配哈希；不是导入 UI/运行成功率。
- `python3 -I scripts/legado-compat/lc.py status`：1330/1331/1329 均 `MISSING`；历史 r20 的 fingerprint 与当前不同。未下载旧包/启动 audit，不重用历史 score 作为当前可用率。
- `bash scripts/sim.sh doctor`：选中 SDK 27.2，runtime 仅 26.2/27.2，没有 17.x；只检查环境，没有启动/安装 App。
- 当前生产 RegexSanitizer 的 macOS 合成行为探针：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
xcrun swiftc Modules/Core/RuleEngine/ModernParser/Cache/RegexSanitizer.swift \
  .git/parity-audit.zatJSUG3/Probe.swift -o .git/parity-audit.zatJSUG3/regex-probe
.git/parity-audit.zatJSUG3/regex-probe
```

决定性输出：

```text
REGEX_DIFFERENCE pattern=a++a rewritten=a+a originalMatch=false rewrittenMatch=true
REGEX_DIFFERENCE pattern=(?>a+)a rewritten=(?:a+)a originalMatch=false rewrittenMatch=true
MACOS_REGEX_DIFFERENCE_CONFIRMED cases=2
```

这证明当前生产转换有实际语义差异，**不是修复通过，也不是 iOS 17 或完整规则引擎验证**。探针/输出仅保存在本地 `.git/parity-audit.zatJSUG3/`，不进入 App/test target 或公共源包。

未执行：Android/iOS XCTest、App build/archive、模拟器/真机 UI 操作、全包源联网、播放器/seek、真实登录、WebDAV 服务、跨端迁移、性能与无障碍验收。既有成功记录只能支持它们各自的提交/输入/设备，不能覆盖本次工作区全部功能。

文档格式、相对链接及 `git diff --check` 的本次结果记录到 [validation.md](validation.md)。

本次只新增审计报告并补文档导航/验证索引，没有业务代码/配置修改，没有 commit/push/release。撤回本报告及本次新增导航/索引即可回滚，不删除用户数据、源包、旧产物或既有未提交工作。
