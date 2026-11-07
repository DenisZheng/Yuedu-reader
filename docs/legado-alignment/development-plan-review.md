# 开发方案 v1.0 审查与补充建议

> 本页保留对 v1.0 的审查记录。后续 Q1–Q9 已确认首期独立本地 Fork、无需原版历史/云端迁移，实施以 [最终方案 v2.0](development-plan.md) 和 [执行计划](implementation-plan.md) 为准；下文迁移等建议不能覆盖后续已确认的范围选择。

## 结论

**总体方向可行，RSS 基础差异分析大部分有代码依据，但 v1.0 还不能直接作为完整实施合同。** 建议保留其“RSS 优先、复用原生阅读/播放能力、分阶段验证”的主线，先修订入口/网页行为、复用边界、身份迁移和媒体验证关卡，再逐 PR 开工。

- **覆盖范围：** 已覆盖 RSS 导入、请求、变量、分页、附件、媒体、编辑和诊断；对规则网页的执行合同仍有关键遗漏。全项目部分是方向清单，不是完成了逐项对齐的开发方案。
- **可行性：** 导入、规则上下文、分类分页与状态修复可沿现有结构实施；WebKit 资源处理、复杂 HTML 播放器、媒体认证必须先做技术验证，不能提前承诺全兼容。
- **排期：** 第一 PR 内容过多；独立 RSS 请求/会话/缓存体系的描述容易造成重复实现。
- **事实修正：** “没有真实源包”的前提已过时；Exhibit B 的许可判断存在明确误读。

本审查按原方案的范围约束讨论：Dict 与 AutoTask/Cron 暂不纳入，不把它们列作本轮漏项。是否永久排除仍属于产品决策；在排除它们的前提下，交付目标应叫“约定范围内的功能对齐”，而不是完整复制 Android 全部功能。

## 归档与审查依据

原方案先从根目录归档；修订 v2.0 后，v1.0 保留于 [development-plan-v1.0.md](development-plan-v1.0.md)，**正文和格式保持原样**。原文 SHA-256：

```text
335fb104c7df3acfe7b0e45d7d26567fe47e5467965917afef75193b7f328cc3
```

因此下面的章节/行号仍可用于定位 v1.0；本文件是审查意见，不应被误认为原作者已接受修订。

代码固定为 Yuedu `f821dc9a`、LegadoTeam `330e606c4`。同时参照：

- [架构与状态地图](architecture.md)
- [共享规则运行时](book-source.md)
- [RSS 执行契约](rss-source.md)
- [真实源包审计](../../Technotes/LegadoRealSourceAudit.md)

下面 `Y/` 指 iOS 仓库根目录，`A/` 指 Android 的 `app/src/main/java/io/legado/app/`。

## 一、应保留的正确判断

| 原方案判断 | 复核结果与依据 |
| --- | --- |
| 本地 JSON 与远程 URL 导入后刷新不一致 | 成立。`Y/Modules/Features/RSS/RSSListView.swift:676` 与 `:1496` 路径不同 |
| 导入器不支持 sourceUrls、强制名称非空 | 成立。`LegadoSourceJSONParser` 与 `A/ui/association/RssSourceImport.kt` 对照可确认 |
| 重复源仅跳过，无法完整更新 | 成立。`RSSStore.addSourcesReturningAdded` 按已有 URL 跳过 |
| 标准 Feed/全文抓取没有同等源请求上下文 | 成立。`RSSUtilities.swift` 中 `RSSRequestFactory.feedRequest`、`RSSArticleContentLoader` 只用默认头部 |
| 附件在中间模型转文章时丢失 | 成立。`RSSItem.init(from:)` 未复制 `ParsedFeedItem.attachments`，Record 也没有对应字段 |
| articleID 作为全局状态 key 存在串源风险 | 成立。`RSSStore.articleStatuses` 和 `article(id:)` 不以 source 为查询条件 |
| 列表分页、文章变量、HTML 媒体未完整接通 | 成立；与真实源包审计相符 |
| 复用现有播放器而非重写、明确 DASH/DRM 边界、先做媒体 PoC | 方向正确，但需要下面的具体前置条件 |

补充：方案所称“Swift 6”不能用旧 skill 注释反驳。当前 `project.pbxproj` 的 App Debug/Release 确实声明 `SWIFT_VERSION=6.0`、strict concurrency complete。本轮未执行 `xcodebuild -showBuildSettings`，有效构建配置应在 Phase 0 再确认。

## 二、开工前必须修订的内容

### R01：真实源基线与优先级脱节

**定位：** §1.3（原文 88 行起）、Phase 0、§10。

方案称未拿到真实源包，但仓库已经有 253 个书源、307 个 RSS；离线导入实验已完成。307 个 RSS 全为 type=0 网页，其中正文/描述有视频标签特征的源为 36 个，iframe 特征 20 个，两组去重 55 个。原包均为数组且名称非空，所以缺名/sourceUrls 是应补的通用格式能力，却不是目前样本的首要故障解释。

**补充要求：** 把样本哈希、已有离线结果、代表源编号和未验证分支写入 Phase 0。固定 commit 后不要直接要求“编码前拉最新 main/master”；更新基准必须形成新差异和新验证记录。参考链接应固定 commit，避免正文声称固定而链接继续指向 main/master。

### R02：缺少 singleUrl、动态启动 URL 和正文选择优先级

**定位：** §3、Phase 2/3/4；原文没有 singleUrl 的执行合同。

Android `RssFragment.openRss` 优先判断 singleUrl；`RssViewModel.getSingleUrl` 可先执行 sortUrl 脚本并选择启动 URL。iOS 多了“没有列表/分类规则”的条件。现有样本 **R002、R012、R079、R081、R110、R167** 已能静态确认进入不同分支。

Android `resolveRssReadLoadTarget` 还会优先显示已有 description，再按 ruleContent 或原网页加载。description 可以是交互 HTML，不只是供全文抓取替换的短摘要。

**补充要求：** 用单独的打开意图/结果明确“单页 URL、启动 HTML、分类列表、已有文章 HTML、正文规则、媒体地址”的优先级；同时覆盖从源列表、历史、收藏、搜索和探索页进入的行为。不要只修一个 if 或播放器路由。

**依据：** `A/ui/main/rss/RssFragment.kt:182`、`RssViewModel.kt`；`A/ui/rss/read/ReadRssViewModel.kt:46`；`Y/Modules/Services/RSS/RSSModels.swift:173`、`RSSArticleReaderView.swift`。

### R03：放宽 sanitizer 不能完成规则网页兼容

**定位：** §4.1、Phase 4.3、附录 B。

新增 video/audio/source 标签可以改善静态 HTML5 媒体，但不能恢复被删的脚本、页面状态、注入时机、iframe 交互。方案在字段和编辑器中提到了 injectJs/preloadJs/startHtml，却没有把其执行列成完整交付任务；`coverDecodeJs` 也未进入开发清单。

**必须区分两种合同：**

1. 普通 RSS 文章：继续清理不可信内容，安全显示文字/图片/允许的媒体。
2. 用户授权的 Legado 规则网页：按明确权限支持源生成 HTML、style、loadWithBaseUrl、enableJs、startHtml/startStyle/startJs、preloadJs、injectJs、导航拦截和资源过滤。

“受控网页”是产品/安全要求，不是建议马上增加某个全新大型框架。现有 `ReaderWebEmbed` / `ReaderWebEmbedManager` 已提供部分嵌入网页与生命周期经验，应先评估复用点，但它们也不是现成的 RSS 完整运行时。

**验收补充：** type=0 的脚本播放器/iframe、文章图片解码、注入仅在正确时机执行、离开页面释放/暂停、网页不得跨源访问状态。默认不开放 iframe 可以是安全策略，但受影响源必须明确列为受限，不能仍宣称已对齐。

### R04：RSSSourceSession 可以独立编排，不能再复制一套基础实现

**定位：** §4.1 第 3 条、§4.2、§4.3、Phase 2。

独立的 RSS 用例/生命周期合理，但“独立 Session + 新请求构建器 + 新缓存 + RSSSourceStore”的描述没有定义复用边界：

- 已有 `SourceScriptHost`、`BookSourceSession`、`ModernParserBridge`、AnalyzeUrl、CookieStore、SourceRateLimiter。
- 已有 `RSSStore` 和 `RSSFeedRefreshService`；没有证据需要另一份拥有同样数据的 RSSSourceStore。
- 当前缺口是 RSS 没有完整接入上述能力，不是没有任何 JS/网络基础设施。

**建议：** RSS 层只拥有 RSS 数据、流程和上下文适配；URL options、JS 求值、通用 bridge、请求/错误处理、限流在明确的共享位置维护。允许提取真正共用的实现，但先用书源+RSS 两个真实调用方证明需要，避免大规模泛型化或第二条解析通道。

必须写清：源家族 + 原始 key + 配置修订的会话身份；源级持久状态与每次请求/每篇文章状态的隔离；分类/列表/正文的状态连续性；改源/删源/登录变化的失效；任务取消及晚到结果处理。仅“每源一个 JSContext”并不能保证同源并发的文章上下文不互相覆盖。

### R05：源身份不能直接用请求 URL 规范化，Cookie 也不能仅按源 UUID 切开

**定位：** Phase 1“按规范化 URL 比较”、Phase 2、第 6 章。

Android `sourceUrl` 是源身份；它可能包含片段、模板、JS 或非标准地址。`requireSourceUrl` 只要求非空，不强制其本身就是最终 HTTP URL。本次计数：307 个 RSS 的 sourceUrl 中 27 个有 `#`，6 个有模板/JS 特征。不能在去重时简单去片段、改 HTTP 为 HTTPS、删除查询/options。

应分开：原始 sourceKey、导入包地址、求值后的请求 URL、页面基址。缺名称时可用派生显示名，但不必把显示名写回改动原始配置。

CookieStore 在两端都涉及域语义。`enabledCookieJar=false` 不是清空全部 Cookie；跨源状态隔离也不是让同站登录永远不能共享。需要定义域/path、安全属性、手动与自动 Cookie、WebView 同步、登录/退出的边界。

“标准 Feed/全文使用源 header”也不是将所有认证头加到任意外链、CDN 或重定向目标。需要按目标来源决定传播，覆盖原网页、图像、子资源、媒体分片/密钥。条件请求 metadata 也应随实际 URL、分类/搜索、方法及认证上下文正确失效。

**依据：** `A/help/source/RssSourceExtensions.kt:14`；`A/model/analyzeRule/AnalyzeUrl.kt` 的 `setCookie/isLoginHeaderSite`；`Y/Modules/Services/RSS/RSSUtilities.swift:153`、CookieStore。

### R06：身份迁移还涉及 Firestore、通知和现有播放器

**定位：** §3.8、§4.4、Phase 1、Phase 4.2。

方案识别了 ID 冲突，但只强调本地 JSON 与缓存，遗漏已消费该身份的链路：

- `FirestoreSyncManager.pullRSS/pushRSS` 按 `articleId` 同步状态及 tombstone。
- RSS 通知的 userInfo、通知标识和动作按 articleID 工作。
- Explore 的文章路由和 `SubscriptionArticlesProvider` 使用同一 ID。
- `VideoPlaybackController` 的 link 模式按播放 URL 保存位置，不是按 RSS 文章保存。签名 URL 换了，简单传 VideoStream 无法保证继续播放。

另外 §4.4 同时把 mediaProgress 放到 Record 和 Status；RSSPageResult 又携带 currentPage/hasMore/nextPageURL。若没有唯一事实来源，容易引入双写和矛盾状态。

**补充要求：**

- 明确原始 GUID/link、sourceKey、分类 key、搜索作用域、持久 articleID 和媒体附件 ID 各自角色。
- 保留 source.id，更新源不另分配身份；分页页码不能成为文章身份。
- 进度只由一个状态 owner 写入，播放器通过现有或最小新增接口读写该状态；无需造假书籍来保存 RSS。
- 迁移必须有 schema version、备份、幂等、分阶段提交及中断恢复；多个文件各自 atomic 不等于整体事务。
- 旧状态若早已因相同 ID 串源，无法凭空推断用户原意。需定义保守继承/冲突报告，不能承诺所有状态无损还原。
- 新旧 App 同步往返、旧通知点击、删除/重导、改分类名、过期媒体 URL 更新都应测试；不能把同步兼容推迟到 Phase 6 才处理。

### R07：媒体代理必须是前置验证关卡，不是已经选定的通用方案

**定位：** §3.7、Phase 4、第 6 章。

方案提出 PoC 是正确的，但还需要明确以下约束：

- Apple 文档明确：`setURLSchemeHandler` 不能注册 WebKit 已处理的 scheme，例如 https，会抛异常。[官方 API 文档][webkit] 已经通过 Context7 核对。因此自定义 scheme 是另一种资源路径，不能描述成透明接管所有 HTTP 请求。
- 动态脚本请求、相对 URL、iframe、CORS/CSP、页面 origin、Cookie、流媒体嵌套资源在改写 URL 或本地代理后是否仍成立，必须实际验证，而不是默认能解决。
- Android `RssWebResourceProxy` 是有条件的子资源路径；当前调用还受 `AppConfig.isCronet` 等条件控制，不是整个 WebView 的万能代理。不同平台不能机械映射。
- `HeaderedMediaAsset` 使用字符串 `AVURLAssetHTTPHeaderFieldsKey`，源码注释明确它不是公开的 AVFoundation 常量。现有可用经验不等于完整 HLS 请求链、重定向及所有支持版本的保证；不能把它当成无需验证的基础合同。本审查不据此断言 App Store 审核结果。

PoC 应拆成静态 img/HTML5 媒体、原生 AVPlayer、受控规则网页三个场景；涵盖 HEAD、200/206/416、Range、媒体 seek、playlist/segment/key、重定向、签名过期、Cookie 更新、取消与资源释放。若考虑 loopback，补监听范围、不可猜测的访问凭据、转发目标限制、防任意代理及日志脱敏；不修改环境安全限制来绕过失败。

PoC 的失败应导致明确缩小支持范围或选择其他实现，不是静默退回浏览器并宣布兼容。

### R08：分页与导入错误合同还不够具体，第一 PR 过大

**定位：** Phase 1/3、§10。

- Phase 3 写“相对下一页以最终响应 URL 为基准”，但 Android `RssParserByRule` 给 AnalyzeRule 同时设置 sortUrl 和 redirectUrl，最后显式用 sortUrl 解析 nextUrl。需用重定向 fixture 对照，不宜制定与基准不同的一刀切规则。
- 需补 requestId/generation、成功后推进页码、失败保持重试目标、重复页停止及旧请求不得覆盖新分类/搜索。
- `sourceUrls` 集合导入需有深度/数量/响应大小限制、循环去重、HTTP 状态检查及每层错误报告；不能无限展开。
- Import→Validate→Save→Refresh 的 Validate 应先是结构/能力校验。暂时断网、需要登录、站点不可达不应使源无法保存。
- 保存成功和首次刷新失败是两个结果；更新后还要取消/拒绝旧配置的响应。直接网页和需要 UI 的源不能批量导入时自动打开一串验证页面。
- 应扩展现有 `RSSFeedRefreshService` 的必要用例来复用合并/取消/通知规则，不再复制一份刷新循环。

第一 PR 同时处理集合导入、重复合并、刷新、报告、媒体字段、ID/旧数据兼容，实际涉及独立故障域。建议拆分：导入/配置保真是一件事，文章身份迁移与附件状态是另外的可独立回滚变更。

### R09：许可证结论必须纠正，但独立实现建议可以保留

**定位：** §8（原文 747 行起）。

原文据根 LICENSE 的 Exhibit B 推断项目已经标记 Incompatible With Secondary Licenses，这个推断不成立。

Mozilla 官方 [MPL FAQ Q25][mpl-faq] 明确说明：完整 MPL 2.0 文本本身包含 Exhibit B，**不等于**该 notice 已附加到代码；选择不兼容需要许可人的主动标记。当前本地搜索没有在业务代码/LICENSING 等所检查范围发现另附 notice，但这不代替完整历史和逐文件许可审查。

建议改为：“根许可证是 MPL-2.0；不能仅因标准文本含 Exhibit B 判断二级许可证不兼容。继续采取行为研究与独立实现策略，任何复制/改写/分发前另做逐文件合规审查。”

这既不等于 GPL 可以无条件复制，也不等于 Swift 翻译可以绕过原许可证。应保留源脚本/素材来源登记和公开 Fork 品牌区分的要求。

## 三、全项目覆盖还需补哪些范围

在保留 Dict/AutoTask 排除的前提下，Phase 6 至少应将下列事项列为“本期/后续/明确不做”，否则不能称全项目主要功能已对齐：

| 能力 | 原方案缺口 | 建议处理 |
| --- | --- | --- |
| 纯 JS 单文件源 mainJs | 仅笼统写 JS API | 单列导入、函数契约、返回值归一化与测试 |
| 批量正文/subContent | 未进入任务清单 | 单列 cacheContent、部分回存、副文歌词/弹幕 |
| ruleReview / JS 段评、事件/自定义按钮 | 未具体列出 | 区分已有 HTML 标记段评和完整规则协议 |
| 文件型书源 type=3 / downloadUrls | 缺明确任务 | 现有包含 3 项，不能被“文本阅读已支持”覆盖 |
| RuleSub 规则包订阅更新 | 未列出 | 与 RSS 文章刷新区分；不是排除 AutoTask 后自动排除 |
| TXT 分章 replacement、替换规则完整作用域 | 替换部分过于笼统 | 写出标题/正文/源/排除和目录标题转换合同 |
| 在线缓存导出 TXT/EPUB/PDF、正文编辑 | 未列出 | 与本地原文件分享区分 |
| Android 备份单向导入、跨端持续进度同步 | “完整恢复”含义不清 | 分成两项；分别定义对象身份、冲突与支持集合 |
| Web 管理/远程调试/MCP | 未列出 | 根据维护大量源的需求决定优先级 |
| UMD、换源高级筛选等 | 未列出 | 建立后续清单，不默认已覆盖 |
| OPDS/Calibre | 作为基准对齐项目缺依据 | 目前是 Yuedu 现有能力的专项回归/完善，不宜占用 Legado 缺口的优先级 |

这不要求首期全部实现，而是要求范围可追踪，避免“暂时没排”最终变成“默认已完成”。

## 四、建议的修订后实施顺序

| 阶段 | 建议交付 | 依赖与退出条件 |
| --- | --- | --- |
| 0：证据与风险 | 固定 commit/源包哈希；重用离线实验；最小相关构建/测试；媒体候选方案 PoC | PoC 不承诺架构，记录成功/失败；不擅自升级依赖或切最新基准 |
| 1：导入与配置保真 | sourceUrls、缺名显示、逐项结果、更新保留 source.id、已知字段往返 | 结构校验与联网检查分开，不改文章主键、不引入媒体代理 |
| 2：公共运行能力接入 | 共享请求/JS桥复用、RSS上下文/变量、jsLib/loginCheck、singleUrl/启动 URL | 普通列表、带状态的分类和单页入口均用 fixture 验证；源修订与取消可控 |
| 3：状态与分页 | 独立的身份迁移；随后分类/搜索分页与正文分页 | 同步、通知、旧数据、晚到响应合同先确定；进度 owner 唯一 |
| 4：媒体和规则网页 | 复用播放/嵌入基础；图片解码；受控 HTML/注入/拦截；附件与继续播放 | 采用 Phase 0 验证过的资源路径，真机逐类型验收，不只测裸 MP4 |
| 5：维护界面 | 高级编辑、可视化调试、可选入口布局调整 | 基础日志与错误报告从阶段 1/2 就有，不能一直等到阶段 5 |
| 后续 | 按上表逐个决策的书源/数据/工具能力 | 每项独立范围和验收，不一次性重写 |

这是依赖顺序，不是工期估算，也不表示本轮已获准编写业务代码。若有低成本独立导入修复，可先交付，不必等待全部媒体研究完成。

## 五、验收还应补充

1. **源包不是黄金输出。** Android 当前能用是用户观察；应补去敏的固定响应、预期条目/变量/下一页，以及相同网络条件下的最小对照。样本中没有 RSS type=1/2、mainJs，需要补小 fixture。
2. **普通 Feed 回归：** 304、ETag/Last-Modified、重新登录/改URL后的条件缓存失效；保留原生 RSS/Atom/JSON Feed 行为。
3. **安全：** 请求 URL 的 query、正文、规则结果和异常也可能含凭据，不能只脱敏请求头；网页消息桥需校验来源/frame/动作权限。
4. **身份生命周期：** 更新/删除源、跨分类同链接、不同源同 GUID、搜索查询切换、签名地址变化、旧通知和旧设备同步。
5. **后台与前台：** 现有后台能力不扩展，但新增 JS/登录/WebView 工作不可在后台无限等待 UI；应能取消并记录需前台继续。
6. **性能：** 用 307 个源和多页文章 fixture 测请求数、峰值内存、落盘次数、主线程耗时；保留 `performRefreshBatch` 合并写入和“不变不写”。目标数字先测基线再确定，不给臆测承诺。
7. **iOS 工程约束：** iOS 17 与当前支持版本、iPhone/iPad、VoiceOver、Dynamic Type、权限拒绝、五种语言文案、可关闭/取消的页面与 `#Preview`。iOS 17 菜单→导入器继续遵循真实 dismiss 顺序，不加延时补丁。
8. **失败不是成功：** 结构失败、请求失败、登录等待、规则错误、合法空列表、最后一页、媒体格式不支持和用户取消应是可区分的结果。

## 六、本轮验证与保留事项

- 已阅读完整 v1.0（886 行），并核查其主要新增判断的生产代码。
- 已复核导入/刷新差异、附件丢失、状态 key、Firestore/通知消费者、视频进度实现、现有源会话与媒体嵌入能力。
- 通过 Context7 核对 Apple WKURLSchemeHandler 官方限制；通过网页检索及存储内容核对 Mozilla FAQ Q25。直接抓取 Mozilla 页面曾被本地网络地址安全检查阻止，未修改任何安全配置。
- 没有构建或运行 App，没有执行原始源脚本、真实网络媒体测试或 PoC；可行性中标记需要验证的部分仍未验证。
- 原方案文件原样移动，31 行原有尾随空白和原有表格格式也保留；不能把原文格式问题报告为本轮新增实现故障。本审查文件及索引按 UTF-8/LF 和链接规则检查。
- 原方案目前是宽表格/多行表格样式。若后续要在 GitHub/Obsidian 长期维护，可另做一次只改格式的 Markdown 表格整理；本轮不混入内容审查。

[webkit]: https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:)
[mpl-faq]: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
