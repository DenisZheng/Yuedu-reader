# 用户真实源包的 iOS 兼容性审计

## 结论

**两个包都能被当前数据模型/导入器读入，但不能据此认定可正常使用。对这批 RSS，首要缺口不是 type=1/2 的图片/视频分流，而是 type=0 网页源依赖的执行环境、HTML 媒体、注入与翻页。**

用户说明两包在 Android 上正常使用；本次没有重做 Android 联网验证。代码基线沿用 [功能对齐审计](LegadoFeatureParityAudit.md)：Yuedu `f821dc9a`，本地 LegadoTeam `330e606c4`。

## 1. 样本基线

| 文件 | 条目 | 类型分布 | SHA-256 |
| --- | ---: | --- | --- |
| `docs/Booksource.json` | 253 | 文本 208、漫画/图片 32、视频 7、音频 3、文件 3 | `3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc` |
| `docs/rssSources-valid.json` | 307 | `type=0` 网页 307；没有 `type=1/2` 条目 | `0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45` |

两包全部条目的 `enabled` 都为 true。文中 B/R 编号分别是 JSON 数组的 **1 起始序号**，例如 B130 为书源数组第 130 项，不是持久化 ID。

### 不应从类型字段得出的结论

RSS 的 `type=0` 不表示内容只有文字。源可以返回带图片、`<video>`、`<iframe>` 和 JS 播放器的 HTML，也可以直接打开媒体网站。

这批 RSS 的正文/描述规则中：

- 36 个源出现 `<video>` / `<source>` 标签特征。
- 20 个源出现 `<iframe>` 标签特征。
- 两组去重后为 55 个源。
- `ruleContent` 有 7 个以完整 HTML 文档开头，`ruleDescription` 有 2 个。

这些是**静态规则特征**，已排除只在 `sourceComment` 出现的标签；不是联网失败数，也不保证每个分支都会执行。

书源包未出现 `mainJs`、`contentBatch/maxBatchSize/subContent`；`ruleReview` 未包含非空业务规则。因此总审计中的这些协议缺口仍成立，但不是这批样本优先验证的对象。

## 2. 已执行的离线导入实验

将当前生产源码中的以下部分提取到临时 macOS Swift 程序：

- `BookSource.swift` 的模型与 `Codable` 解码/编码实现。
- `RSSSource` 的存储字段，以及 `isLegadoRuleBased`、`hasSortCategories`、`opensAsWebPage` 等纯判断属性。
- 完整 `LegadoSourceJSONParser`。

未提取 UI、存储服务和 JS 运行时；`localized` 仅用返回 key 的替身满足错误文案依赖，不改变导入判断。程序读取两个原文件，执行导入与导出，再比较原始键及共同键的值。**不运行源脚本、不联网、不写用户数据库。**

| 检查 | 结果 |
| --- | --- |
| 书源模型解码 | 253 / 253 |
| 书源原有字段丢失 | 0 |
| 书源原有共同字段值变化 | 0 |
| RSS 导入器解析 | 307 / 307 |
| RSS 原有共同字段值变化 | 0 |
| RSS 导出字段丢失 | `type`、`preload`、`cacheFirst`、`showWebLog` 各 307 项；`preloadJs` 1 项 |

“原有字段没有变化”不表示字节完全相同，也不涵盖未纳入本程序的 App 导入界面、持久化、网站响应和阅读过程。

其中丢失字段的实际值是：`type` 全为 0；`preload` 全为 false；`cacheFirst`、`showWebLog` 各有 1 项 true；`preloadJs` 有 1 项非空。因此不要把 307 次默认值字段丢失误报为 307 个功能故障。

### 当前 RSS 分流结果

依据生产模型的判断属性，307 个导入源分为：

| 当前 iOS 路径 | 数量 | 实际含义 |
| --- | ---: | --- |
| 直接网页 | 149 | 显示网页入口，经 `SafariView` 打开 URL |
| Legado 规则列表 | 154 | 抓列表、解析条目，再进入文章阅读页 |
| 普通 Feed | 4 | 尝试标准 RSS/Atom/JSON Feed 流程 |

这也解释了为何不能把整个包看作普通 RSS 新闻订阅。

后续基准结构分析还确认了打开优先级差异：Android `RssFragment.openRss` 先判断 `singleUrl`，不因列表/分类规则存在而改走列表。样本中 155 个 `singleUrl=true`，其中 R002、R012、R079、R081、R110、R167 在 iOS 被分到规则列表或普通 Feed；还需对齐 Android `getSingleUrl` 的动态启动 URL。详见 [RSS 基准执行契约](../docs/legado-alignment/rss-source.md)。此为源码分支对照，不是联网成功率。

## 3. 这批 RSS 实际暴露的缺口

### S01：视频 HTML 会在文章阅读路径中被裁掉

当前流程：

```text
LegadoRSSScraper.fetchArticleContent
  → RSSArticleReaderView
  → RSSArticleHTMLRenderer
  → RSSArticleHTMLSanitizer
  → WKWebView
```

`RSSArticleHTMLSanitizer` 的清理器删除 `script/style/iframe/object/embed` 等节点；允许列表保留 `img`，但没有 `video/audio/source`。因此即使规则正确返回播放器 HTML，进入文章阅读模式后也无法原样保留。

对这批样本，36 个源在正文/描述规则中有视频标签特征，20 个有 iframe 特征。**不能通过只增加 RSS 的 type=2 分支解决这些 type=0 HTML 播放器。**

代表：R006、R041、R086 等规则包含媒体/播放器 HTML。无需访问其网站，源码已能说明当前文章渲染契约与 Android 不同。

依据：

- Yuedu `Modules/Services/RSS/RSSUtilities.swift:494`，尤其 `sanitizedHTML` 白名单。
- Yuedu `Modules/Features/RSS/RSSArticleReaderView.swift`。
- Android `ui/rss/read/ReadRssActivity.kt:404` 起，将规则内容交给带源配置的 WebView，并初始化 JS 接口。

### S02：多项字段保存了，但没有执行

| 配置 | 样本中非空条目 | 当前 iOS 的差距 |
| --- | ---: | --- |
| `injectJs` | 43 | 导入/导出保留，但 RSS 页面未消费 |
| `style` | 43 | 保存源样式，但文章页面采用自己的模板，不应用同等源样式 |
| `shouldOverrideUrlLoading` | 15 | 保存，但没有执行源的跳转拦截脚本 |
| `coverDecodeJs` | 6 | 保存，但未发现 RSS 图片加载接入该解码规则 |
| `preloadJs` | 1 | 模型/导入器未承载 |
| `loginUrl` | 14 | 保存，但当前 RSS UI 未提供 Android 同等源登录入口 |

43 个 `injectJs` 源中，27 个进入规则列表路径，16 个进入直接网页路径。不能认为“直接开网页”就自动恢复注入逻辑。

例如 R026 的源名表达了网页去广告用途，但它的网页注入在当前 Safari 路径中不会随源配置执行。R031/R032 等同时含登录、变量或跳转规则，需要验证整个源会话，而不只是 HTML 能不能显示。

依据：`RSSModels.swift`、`LegadoSourceJSONParser.swift` 的字段声明/读写；对这些字段的全局引用检查；`RSSFeedView.swift`、`RSSArticleReaderView.swift` 的实际显示路径。Android 对应消费点见 `ReadRssActivity.kt` 的 `upWebviewSettings`、预注入、`injectJs`、`shouldOverrideUrlLoading`。

### S03：RSS 脚本环境只接了网络，没有接完整源会话和规则回调

`LegadoRSSScraper.scriptHost(for:)` 创建新的 `JSCoreEngine`，仅设置网络 handler。分类解析又使用另一个新引擎。

未见该路径：

- 绑定当前 RSS 源身份、配置和持久变量。
- 装载该源 `jsLib`。
- 为 `java.getString/getElements/setContent` 等连接当前规则引擎。
- 为 `java.put/get` 连接流程内变量状态。
- 执行 `loginCheckJs`。

注意：默认 `source` 对象存在，但它是空身份桥，不等于当前 RSS 源。

样本中 7 个源含 `jsLib`；45 个源在 `sortUrl` 使用 `source.*`。在列表/正文/描述等规则与分类配置中，29 个源引用 `java.getString`，19 个引用 `java.put`，13 个引用 `java.getElements`。这些是引用计数，不能直接相加或当成失败数。

生产桥在缺少对应 handler 时会返回空字符串/空列表，或者变量写入不发生。因此会出现“导入成功，但分类、列表、图片或正文为空”的风险，而且无需缺少播放器就能发生。

依据：

- `Modules/Services/RSS/LegadoRSSScraper.swift:14`、`:218`、`:343`。
- `Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:189`、`:304`。
- `Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:1004`、`:1041`、`:1082`。
- Android `model/rss/Rss.kt` 将 `rssSource`、`ruleData` 传入 AnalyzeUrl/AnalyzeRule，并执行登录检查。

### S04：106 个源的列表翻页没有完整接线

106 个 RSS 源设置了 `ruleNextPage`，全部位于规则列表路径。

当前 `RSSFetcher.fetchWithLegadoRules` 只调用一次 `scrape`，使用默认 `page=1`；`ruleNextPage` 未被执行，也未从 scraper 返回下一页状态。RSS UI 未见相应的继续加载流程。

Android 的 `RssParserByRule` 会读取 `ruleNextPage`（含 `PAGE` 特殊值），同时返回条目和下一页。

所以“首页有结果”不是对齐完成：继续滚动或切下一页才会暴露差异。

依据：Yuedu `RSSFetcher.swift:1289`、`LegadoRSSScraper.swift:38`；Android `model/rss/RssParserByRule.kt:56`。

### S05：直接网页只是 URL 交接，不是同一个源运行环境

149 个源按当前属性进入直接网页路径。`SafariView` 只接收 URL，通过 `SFSafariViewController(url:)` 打开；不传入或执行源的注入、变量、JS 库和拦截逻辑。

其中 16 个源设置了非空 `injectJs`，16 个设置了非空 `header`（两组可能重叠）。因此这种处理能覆盖普通网页，但不能代表完整的规则网页源。普通网页或其原生 HTML 视频仍可能正常打开，**不能说这 149 个源全部不可用**。

依据：`Modules/Features/RSS/RSSFeedView.swift:8`、`:334`；`RSSFetcher.swift:1115`。

## 4. 书源包的判断

- 文本、漫画、音频、视频：有对应原生路径；这批 250 项不能据静态分析一概宣称正常，需要真实响应和媒体播放验收。
- 文件型 3 项：B011、B056、B105。`downloadUrls` 虽然被保留，但当前 type=3 到下载/导入的链路缺失，仍是明确的功能对齐任务。
- B117 的脚本引用 `java.downloadFile/readTxtFile`，当前 JS 桥未见对应实现；是否命中该分支需单源测试。
- 111 个书源显式 `enabledCookieJar=false`，而当前自动 Cookie 管理不按该字段关闭。此为语义差异，不等于 111 个都失败。

适合优先选作对照的现有入口：B018（漫画）、B065（音频）、B130（视频），再加一个简单文本源。选择仅依据规则结构和类型，不代表联网推荐或已通过播放测试。

本书源包包含 `presentsAndroidIdentity` 等 Yuedu 扩展字段，且当前模型往返没有丢字段；不能用它证明“所有 Android 导出的书源都能无损往返”，也不能从包中没有 `mainJs` 推断无需支持该协议。

## 5. 针对这批样本调整实施顺序

1. **先修 RSS 公共运行环境。** 源身份/变量、`jsLib`、规则回调、请求配置与登录检查先形成可测试合同；沿已有源会话能力复用，不再增设另一套临时引擎或缓存。
2. **明确两种 RSS 内容合同。** 普通 RSS 文章继续安全清理；明确声明并经用户授权的规则网页源走受控网页运行环境，按需支持媒体与源脚本。不要为了视频而对所有文章取消清理，也不要把全局权限暴露给远程页面。
3. **接通列表分页、源图片解码、注入/拦截。** 分别用样本验证，不用“打开原文”隐藏主路径缺陷。
4. **补 type=1/2 类型分流。** 这是 Android 基准能力，但当前包没有此类条目，需要单独的小型合成 fixture 或用户另给样本。
5. **书源按类型逐个真实验收。** 文本/漫画/音频/视频的搜索→详情→目录→阅读/播放，再覆盖登录、缓存与恢复；同时补文件型书源链路。
6. **最后调整导航。** 独立订阅 Tab、列表/网格、文件夹显示属于可用性层面，不能替代上述兼容工作。

验收至少要分别回答：是否导入完整、能否得到正确列表、能否翻页、能否保留媒体、能否播放、是否沿用正确请求与登录上下文。不能只报告一个笼统的“源有效”。

## 6. 验证边界和数据处理

已完成：JSON 解析与类型统计、生产模型/导入器离线往返实验、生产 RSS 分流属性计算、脚本特征去敏统计、两端代码调用链检查。

未执行：源脚本、第三方联网请求、完整 App 构建、iOS/Android App 自动测试或真机播放。因此本文没有给出真实可用率；正文/标签特征计数不是失败数。

临时验证程序与去敏汇总保存在本机 `/tmp/yuedu-source-audit.I9XWxz/`，未将原始头部、Cookie、登录参数或完整源脚本复制进报告。原始两个 JSON 保持不动且未提交；存在登录/请求配置的源包应在公开提交前单独检查敏感数据。

本次只新增此报告并为总审计添加交叉引用，不修改业务代码。
