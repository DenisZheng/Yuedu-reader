# 小浣熊阅读（legado-ios）与 LegadoPro：全项目功能对比与取舍

**优先借鉴换源时的两个判断：目标章可不可以读，同名章选哪一个。** 前者可以避免目录正常、正文失败后才发现已经切错源；后者已在相同输入下测出差异。搜索方面值得借的是“不让慢源占满名额”的试验，而不是再做并发和缓存。若选一个面向普通读者的新功能，建议先做**把已下载的文字章节导出为 TXT**：收益清楚，不需要联网、改书架格式或换阅读器。

**落地方案：** [双端代码索引、吸收顺序、Swift 函数草案与验收条件](../docs/legado-alignment/legado-ios-adoption-plan.md)。

**后续复核：** [净化规则、WebDAV 备份模型、RSS 实际入口与媒体书源](LegadoIOSRulesBackupMedia.md)。净化方面，比新增试跑页更优先的是手动导入不能丢失排除范围；RSS 的演示入口不能算普通用户可达。

## 对比口径

| 对象 | 本次基线 | 如何解读 |
| --- | --- | --- |
| 小浣熊阅读，简称 L | 同级 `../legado-ios`，`2ea381463ed2230decdf2f7d3b4ef533636e05c6` | 指定的 iOS 同行项目，不是 Android Legado，也不是本 Fork 的上游。下文的 L 源码链接均固定到该提交。 |
| LegadoPro，简称 Y | 当前仓库 `5f2bea2d5f4d7775dc7b25dd2c79450e93ae42d1` | 以当前源码而非 Fork 起点或旧审计判缺口；原工作区的版本配置改动、私有源包均不作为证据。 |
| 证据 | 2026-11-28；两边入口、实际调用方、持久化路径；另有一组主机离线对照 | **实测**在本文指下文换源匹配函数；另有专题记录净化范围、备份退避和朗读中断的小型实验；**源码**指追到了实现、未在设备操作；**建议**不是现有行为或已批准排期。“未见”限定于所列入口。 |

两者的分工不同：L 把规则、网络书、SQLite 仓库拆在 [LegadoCore 包](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Package.swift)，App 层编排搜索和阅读；Y 已用[按源复用的会话](../Modules/Core/BookSource/BookSourceSession.swift#L4-L34)、[在线阅读管线](../Modules/Services/Online/OnlineReadingPipeline.swift)和各自的数据管理模块服务书源、书架与 RSS。**以下比较用户能完成什么，不按页面数、代码量或数据库选型打分。**

## 一、原有书源：从导入到读完一章

| 环节 | L 的实际做法 | Y 已有什么；值得借哪一部分 |
| --- | --- | --- |
| 导入、编辑与管理 | [导入器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Import/BookSourceImporter.swift)区分替换、跳过、拒绝；[字段校验](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Import/BookSourceValidator.swift)给出问题代码和字段名。[书源管理](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Sources/SourceManagementView.swift#L270-L285)还可从二维码进入预览。 | [书源导入确认](../Modules/Core/BookSource/BookSourceImportCoordinator.swift#L6-L47)已统一文件、网址、粘贴、网页、分享和深链，可保留本地名称、分组和启用状态。增量是**从一张图片读出规则或链接**，不是新导入器。 |
| 配置订阅、发现与登录 | [规则包订阅](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Rules/RuleSubscriptionModel.swift)、[动态发现分类](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Explore/BookExploreService.swift#L24-L47)、[登录表单](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Sources/SourceCredentialsForm.swift)各有独立调用方。 | [规则包更新](../Modules/Services/RuleSubscriptions/RuleSubscriptionUpdateService.swift#L29-L58)已分书源、RSS 源、替换规则；[发现](../Modules/Core/BookSource/BookSourceFetcher+Discover.swift)和 [LoginUiV2](../docs/legado-alignment/login-ui-v2-source-batch.md)也有路径。不能把“对方有订阅和登录”列成缺项，也不能把旧表单等同于 V2 协议。 |
| 规则执行、详情、目录 | L 的 [RuleEngine](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/RuleEngine/RuleEngine.swift#L3-L43)组合 HTML、JSONPath、正则和 JS；[网络书服务](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/NetworkBookService.swift)取详情、目录并传递规则上下文。 | Y 的 [BookSourceSession](../Modules/Core/BookSource/BookSourceSession.swift)、[mainJs 分流](../Modules/Core/BookSource/MainJsSource.swift)和[目录抓取](../Modules/Core/BookSource/BookSourceFetcher+TOC.swift)已有实现。两边都有 JS 不能推断同一书源两边都通。按具体规则制作合成输入，不引入第二个解析器或 JS 宿主。 |
| 多源搜书 | L [先展示有效缓存，再跟在线结果合并](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Search/SearchViewModel.swift#L99-L149)，[调度器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Search/BookSearchService.swift#L174-L240)按历史排序，另限制疑似 JS／WebView 源同时运行的数量。 | Y 已有[按查询和书源读取的非空缓存](../Modules/Services/Online/SearchResultCache.swift#L87-L120)、[流式汇总、暂停和恢复](../Modules/Services/Online/SearchAggregator.swift)和[随电量、温度调整后续页](../Modules/Services/Online/SearchDevicePacing.swift#L3-L25)。差异在**队首都是慢源时，普通源能否及时开始**；不是 Y 没有并发，也没有证据说 L 整体更快。 |
| 换源与进度 | L [选中候选后取详情、目录、定位后的可读正文](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/BookSourceSwitchService.swift#L285-L329)，没有可读结果不交给调用方切换；[重复章名取距离原位置最近者](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/BookSourceSwitchService.swift#L103-L145)。 | Y [可只替换一章](../Modules/Features/ChangeSource/ChangeChapterSourcePage.swift#L12-L25)，整书换源则[等待目录、提交、再打开正文](../Modules/Features/Reader/ReaderView+SourceChange.swift#L374-L435)，[统一提交](../Modules/Services/LibraryStore/OnlineBookSourceSwitch.swift#L48-L109)还迁移图像和音频位置。已有能力保留；**点选后验证、同名就近**是可分开交付的两项增量。 |
| 正文、评论与媒体 | L [正文](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/NetworkBookService.swift#L559-L689)追下一页、去重，并处理图片与副文；[章评](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/NetworkBookService.swift#L698-L731)有独立读取路径。一个明确边界：音频型书源直接返回章节地址、没有正文规则时，该分支报告不支持，不能把朗读当作网络音频书播放。 | Y 已有[批量正文与单章回退](../Modules/Core/BookSource/BookSourceFetcher+ContentBatch.swift)、[歌词／弹幕等副文](../docs/legado-alignment/sub-content-source-batch.md)、[原生只读段评及回复](../docs/legado-alignment/readonly-review-source-batch.md)、[漫画及视频路径](../docs/legado-alignment/book-source-media-fixes.md)。不为照齐 L 退化成单章文本管线；两边的评论粒度、登录要求、媒体可播性须分开验证。 |
| 调试与活性检查 | L 的[书源调试报告](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Debugging/BookSourceDebugger.swift#L3-L65)明确区分阶段、耗时、警告、失败、跳过；无样本时不把后续步骤算通过。 | Y 不是缺少调试：[逐规则调试](../Modules/Core/BookSource/BookSourceDebugEngine.swift#L4-L55)和[书源验证](../Modules/Core/BookSource/BookSourceHealthChecker.swift)已有。可借一个**不含正文的结果摘要**：“目录成功，正文未执行（需登录）”，供普通用户反馈；不能用一个红绿灯替代各内容类型的判断。 |

## 二、书架、离线、本地阅读及其他功能

| 用户任务 | 两端源码对照 | 判断 |
| --- | --- | --- |
| 一本书同时归入“在读”和“科幻” | L [独立增减所属分组](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Books/BookLibraryModel.swift#L588-L625)，还可按组决定是否查更新；Y 当前[书架分组写入口](../Modules/Services/LibraryStore/BookStore.swift#L1502-L1539)给每本书指定一个组名，批量操作也是“书 → 一个组名”。 | **真差异，但暂缓。** 需先定删除组、旧数据升级、备份恢复的含义；不把 L 的整数位掩码当作产品需求，也不把书架分组和书源分组混为一谈。 |
| 搜一段记得的原文，不记得出自哪本书 | L 的[书架正文搜索](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Settings/LibraryTransferViews.swift#L185-L291)搜本地书和有缓存的网络章节，返回摘录并定位；[临时索引](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Search/LibraryPassageSearch.swift)按会话建，短词或无 trigram 支持时走扫描。Y 的[书架搜索](../Modules/Services/Works/Providers/ShelfProvider.swift#L72-L88)按书名／作者找书，[阅读器内搜索](../Modules/Features/Reader/ReaderBookSearchSession.swift#L4-L37)则在**当前一本**离线找正文，已有正则和替换前后选项。 | 新的是**跨书找句子**。建议先限定用户选定的一组已下载书，沿用现有定位语义；不在启动时给整个书架建永久索引。 |
| 离线读、把缓存留成 TXT | L 的[离线任务](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/OfflineEditions.swift#L185-L231)保存游标与失败章节；[导出器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/LocalBook/LocalFileService.swift#L147-L178)按目录逐章写 TXT，缺章留标记，[分享前提示已缓存几章](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Activity/FileManagementView.swift#L209-L225)。Y 有[离线下载](../Modules/Services/Offline/OfflineDownloadManager.swift)、[章节缓存](../Modules/Services/Online/ChapterCacheRepository.swift)和漫画清单；这些不等于把一本网络文字书导出为可读文件。 | **优先做导出，不重做下载。** 无网也能导出已经下载的部分；区分“未缓存”和“缓存损坏”，不要像 L 的 `try?` 读取分支那样一律标成缺章。 |
| 修改净化规则后先看效果 | L 的[规则试跑](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ReplaceRuleTester.swift)接受示例书名、标题、正文、来源，走实际净化管线，返回处理结果与耗时。Y 的[替换规则编辑页](../Modules/Features/Settings/ReplaceRuleListView.swift#L358-L426)可编辑保存，但未见样本试跑；[TXT 目录规则编辑器](../Modules/Features/Settings/TXTTocRuleEditView.swift)已有预览，是另一种规则。 | **小而独立的增量。** 用 Y 的[替换引擎](../Modules/Core/Replace/ReplaceRuleEngine.swift#L14-L58)，不要另写一套正则或假装支持尚未实现的作用域。 |
| 本地书、排版及远程书库 | L 的 [EPUB 阅读器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/EPUBReaderView.swift#L1-L23)区分 Readium 原排版和文字朗读；Y 有[本地格式与远端来源合同](../Modules/Services/LibraryStore/BookFileFormat.swift#L3-L41)，除 EPUB/TXT 还有 MOBI/AZW3、PDF、Markdown 等，沿用 [EPUB 会话](../Modules/Core/EPUB/PublicationSession.swift)、CoreText 和既有 OPDS／Calibre 路径。 | 可借 L 的**复杂 EPUB 测试场景**（插图、原排版目录、切换后续读），不借另一阅读内核。看同一本自建书开到哪一章、能否找回原位置，不比较截图好不好看。 |
| 朗读、来电、耳机断开 | L 除系统、在线语音外还有[可下载并校验的 MeloTTS](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/OfflineSpeechSynthesizer.swift)；[中断处理](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/TTS/SpeechInterruptionCoordinator.swift#L57-L99)在耳机断开时撤销待恢复意图。Y 已有[系统离线朗读](../Modules/Core/TTS/SystemTTSEngine.swift#L6-L18)、HTTP／Edge 等引擎和[中断、路由切换处理](../Modules/Core/TTS/TTSCoordinator.swift#L1245-L1294)。 | **借测试，不急着借模型。** 覆盖“来电暂停 → 拔耳机 → 来电结束”和“中途手动停止”，不能突然外放。MeloTTS 是新增本地音色而非补“无离线朗读”；引入推理库、模型下载、存储和真机耗电要另评估。 |
| 恢复书库、保住本地原书 | L 的[本机包](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibraryBackupArchive.swift#L30-L76)可带文件、流式写入并逐项校验；[WebDAV 策略](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Sync/WebDAVBackupPolicy.swift)有间隔、失败退避和保留数。[Android 导入](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Import/AndroidLibraryImport.swift#L37-L86)仅识别部分数据，跳过缺原文件的本地书。Y 已有[分类与版本选择](../Modules/Features/Settings/WebDAVSyncView.swift#L69-L101)、[最后上传 manifest、校验和回滚](../Modules/Services/WebDAV/WebDAVVersionedBackup.swift)。 | 后续可借**备份前说明哪些本地文件不会随包走、恢复前显示数量**。本机包、WebDAV 版本、Android 导入是三件事；不要替换 Y 格式、恢复 iCloud 或照搬上传后自动删旧版本。 |
| 阅读记录、统计与导航 | L 的[统计页](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Activity/ReadingStatisticsView.swift#L16-L37)在[四个根 Tab](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/RootTabView.swift#L10-L16)之一，展示今日、周趋势和历史。Y 的[统计页](../Modules/Features/Stats/ReadingStatsView.swift#L12-L60)已有日／周／月／全部、排行；[五个默认 Tab](../Targets/Yuedu/SharedApp/RootTabCustomization.swift#L16-L23)有明确产品约定。 | 不是缺少统计。无证据支持为曝光度挪走资源库或订阅，不建议模仿导航。 |
| RSS 订阅与规则网页 | L 有模块，但本提交 RSS 首页仅找到演示参数入口，未找到普通导航入口。模块内有[网页／图片／视频内容分流](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/RSS/RSSReadingPolicy.swift#L11-L28)和[分阶段调试](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Debugging/RSSSourceDebugger.swift)。Y 有[启动页路由](../Modules/Services/RSS/RSSOpenTarget.swift)、[首列表活性检查](../Modules/Services/RSS/RSSSourceHealthChecker.swift#L4-L42)、[含正文分页的调试](../Modules/Services/RSS/RSSSourceDebugger.swift#L69-L115)，且区分合法空列表和失败。 | 只借“失败后哪些阶段没测”的表现；不把 L 的“没有文章即列表失败”、原始响应展示或首项成功即全源可用带过来。不改变普通 Feed 与规则网页的安全边界。 |

## 三、哪些值得先做，怎样验收

以下是**候选顺序**，不是给现有 [S8 验收](../docs/legado-alignment/s8-release-checklist.md)加门槛。“小／中／大”指影响范围，不是工期。

| 建议顺序 | 最小行动与接入点 | 验收／停止条件 |
| --- | --- | --- |
| **1 · 小：换源同名章就近**（已复现） | 只在 [ChapterAlignment](../Modules/Services/Online/ChapterAlignment.swift#L38-L92)解决多个等质量结果怎么选；保留现有中文数字、标题顺序辨别和无匹配回退。不直接移植 L 的算法或它的字符偏移策略。 | 下节三组输入分别得到 13、13、12；再覆盖同距、卷头、目录变长和中文章号。离线函数相同仍要测真实应用从阅读器／详情换源后重开的位置。 |
| **2 · 中：选中的文字书源先试读当前章**（源码差异） | 仅试用户点选的候选，不扫所有搜索结果。复用现有取章和唯一换源提交；在确认前隔离结果，成功后复用章包。单章换源、音频、漫画、需交互分开设计。 | 目录成功但正文为空／需登录／被取消时，旧书源、进度及旧缓存不变；成功时相同正文只请求一次。若做不到不提前覆盖旧缓存或明显拖慢已缓存的换源，先不推全量。 |
| **3 · 小实验：混合书源的首条结果**（未测速度） | 在 [BookSourceSearchFanOut](../Modules/Services/Online/BookSourceSearchFanOut.swift#L59-L105)用可控慢源堵住队首；参考 L 的[混合搜索用例](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Tests/LegadoCoreTests/SearchPerformanceTests.swift#L28-L44)。复用已有 `search.firstResult` 埋点；不加并发，不照搬 L 的固定 4 个名额（总宽度 ≤4 时它也不能保证留位）。 | 同一设备、相同源顺序和总宽度，冷／热缓存分开。记录首结果 p50/p95、总耗时、请求数；普通源能在慢源释放前被调度，暂停／恢复不重发已完成源。若没有可重复收益，保留原调度。 |
| **4 · 中：已缓存的文字章节导出 TXT** | 从现有目录及离线内容逐章读，限用户有权导出的文本；不补下载、不导出登录数据、媒体或受限内容，不把临时文件当备份。 | 飞行模式下用 5 章中已有 3 章的书，先显示 3/5，文件顺序正确并列出缺章；0 章、读盘失败、取消、空间不足不报成功，大书不整本装入内存。 |
| **5 · 小：替换规则保存前试跑** | 先只支持 Y 已实现的正文范围，给一段示例文字，显示改动前后。 | 分清未命中、非法表达式、超限；结果与真正阅读相同，取消不改规则和书。 |
| **6 · 小：从图片二维码导入书源** | 先支持**选图片**，不申请相机权限；L 的[识别器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Import/QRCodeDecoder.swift)只产出字符串，[书源入口](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Sources/SourceManagementView.swift#L270-L285)再预览。Y 先接书源导入确认；以后也可接 [RSS 确认流程](../Modules/Services/RSS/RSSImportSession.swift#L23-L70)，不代表 L 已有 RSS 扫码入口。 | 覆盖无码、多码、非法链接、合法 JSON 和深链。远端链接先让用户确认目标再下载，预览后才写入；不能扫码即执行或用固定延时等弹层。 |
| **7 · 中到大：跨书架搜正文** | 从小范围、按需、可取消的离线搜索起步。先验证单书文本、替换规则修订、阅读定位能复用，再决定是否需要临时索引。 | 两本书同句、短中文词、标点和 emoji 都能跳到原文；未下载章不发请求。记录首批结果时间、峰值内存、临时磁盘和取消后的资源回收；达不到预算不扩大到全书架。 |

**保留到单独决策：** 多分组会改变持久化与备份；随备份携带原书会改变空间和隐私成本；MeloTTS 会引入模型和二进制依赖。反过来，朗读中断顺序、备份缺件、合法空列表这些**验收样本**可以先借，不必等新功能立项。

## 四、实测证据：为什么先做同名章

两份生产匹配逻辑使用同一组合成标题。旧目录 20 章，原阅读下标 **12**、标题“番外”；新目录也有 20 章，除指定的“番外”外均为不同的普通标题，下标从 0 开始。适配结构只提供匹配器读取的书与章节字段，不启动 App、不读用户书。

| 新目录中“番外”的下标 | Y | L | 读者看到的差别 |
| --- | ---: | ---: | --- |
| 只有 13 | 13 | 13 | 唯一近邻，两边一致 |
| 4 和 13 | **4** | **13** | Y 在窗口内先遇到下标 4，L 取离 12 最近的一章 |
| 没有 | 12 | 12 | 两边均回退原位置 |

这是**匹配行为**，不是对两本真实书内容相同的保证。下标近只是同等匹配时更好的默认值。L 对所有可读章找精确同名，Y 在窗口内比较标题相似度；不建议为这个例子把 Y 的有界搜索改成每次全目录扫描。

<details>
<summary>复现命令（在 Y 仓库根执行，需本机 Swift 和同级 legado-ios）</summary>

```bash
python3 - <<'PY'
import subprocess as sp
def source(repo, rev, path):
    return sp.check_output(["git", "-C", repo, "show", rev + ":" + path], text=True)
ours = source(".", "5f2bea2d", "Modules/Services/Online/ChapterAlignment.swift")
peer = source("../legado-ios", "2ea3814", "Sources/LegadoCore/Book/BookSourceSwitchService.swift")
start = peer.index("private enum ChapterProgressMatcher {")
end = peer.index("public actor BookSourceSwitchService {", start)
fixture = """
struct Book { let durChapterIndex: Int; let durChapterTitle: String?; let totalChapterNum: Int }
struct BookChapter { let title: String; let isVolume: Bool }
"""
cases = """
for (label, duplicates) in [("unique", [13]), ("repeated", [4,13]), ("absent", [])] {
    let names = (0..<20).map { duplicates.contains($0) ? "番外" : "正文" + String($0) }
    let old = Book(durChapterIndex: 12, durChapterTitle: "番外", totalChapterNum: 20)
    let a = ChapterAlignment.mappedChapterIndex(oldIndex: 12, oldTitle: "番外", oldCount: 20, newTitles: names)
    let b = ChapterProgressMatcher.match(current: old, chapters: names.map { BookChapter(title: $0, isVolume: false) }).index
    print(label, "Y=\\(a)", "L=\\(b)")
}
"""
sp.run(["swift", "-"], input="\n".join([ours, fixture, peer[start:end], cases]), text=True, check=True)
PY
```

本次环境：Darwin arm64，Apple Swift 6.4.2。实际输出：

```text
unique Y=13 L=13
repeated Y=4 L=13
absent Y=12 L=12
```

</details>

**证据边界与许可。** 本轮没有运行两个 App 的测试套件、联网书源、导入真实备份、下载模型或做真机速度评测；没有两端同批书源的成功率，也不能把对方仓库的测试文件算成通过。RSS 的 Android 基准、Fork 的发布门槛均不因此改变。L 是 [GPLv3，含另有许可的第三方材料](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/THIRD_PARTY_NOTICES.md)，Y 以 [MPL-2.0 及逐文件例外](../LICENSING.md)发布。建议只吸收交互、约束、指标，用自建数据独立实现；不把对方源码、规则包、测试资源、模型或品牌素材搬进产品。
