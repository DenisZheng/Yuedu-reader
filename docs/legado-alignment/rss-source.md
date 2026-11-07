# RSS 与规则网页执行契约

返回 [总入口](README.md) · [共享规则运行时](book-source.md)。这篇是现有真实源包优先使用的对齐参考。

**Legado 的 RssSource 是一个内容应用入口，不仅是 Feed URL。** 同一个 type=0 源可以展示文章、图片、网页播放器和脚本交互；type=1/2 又有独立媒体路由。不能只在 iOS RSS 列表后加一个播放器就算完成。

## 1. 从哪里进入

| 关注点 | Android 源码入口 |
| --- | --- |
| 源列表、点击源、登录 | [RssFragment][rss-home]、[RssViewModel][rss-home-model] |
| 源字段 | [RssSource][rss-source] |
| 导入、合并、保留配置 | `A/ui/association/ImportRssSourceViewModel.kt` |
| 分类解析 | [RssSourceExtensions][rss-ext] 的 `sortUrls()` |
| 分类/搜索 UI | `A/ui/rss/article/RssSortActivity.kt` |
| 列表加载与分页 | [RssArticlesViewModel][articles-model]、[RssPaginationState][pagination] |
| 请求和内容拼接 | [Rss][rss-model] |
| 默认/规则解析 | [RssParserByRule][rss-parser]、`A/model/rss/RssParserDefault.kt` |
| 点击条目后的类型分流 | [ReadRss][read-router] |
| 网页内容选择、模板、启动页 | [ReadRssViewModel][read-model] |
| WebView、注入、拦截、请求上下文 | [ReadRssActivity][read-activity] |
| 页面与导航桥接 | `A/help/webView/WebJsExtensions.kt`、`A/ui/rss/read/RssJsExtensions.kt` |
| 视频型订阅 | [VideoPlay][video]、`A/ui/video/VideoPlayerViewModel.kt` |

## 2. 第一层路由：点击源，不是点击文章

```text
RssFragment.openRss(source)
  ├─ singleUrl=true
  │    → RssViewModel.getSingleUrl
  │       ├─ sortUrl 非空：可先求值 JS，再取 URL
  │       └─ 否则 sourceUrl
  │    → http(s)：ReadRssActivity
  │    → 其他 scheme：对应外部打开路径
  │
  └─ singleUrl=false
       → launchRssWithHtml
          ├─ startHtml（可求值 JS）有结果：ReadRssActivity 启动页
          └─ 否则：RssSortActivity 分类/条目列表
```

### 不能改变的优先级

基准先判断 `singleUrl`，**不会因为存在 `ruleArticles` 或 `sortUrl` 而自动改成列表源**。`sortUrl` 在单页源里还可以用于计算启动 URL，而不一定表示分类。

#### 现有样本中的已确认差异

307 个 RSS 中有 155 个 `singleUrl=true`。iOS `opensAsWebPage` 额外要求没有文章规则、没有分类，因而只有 149 个走直接网页。

数组序号 **R002、R012、R079、R081、R110、R167** 在这两个入口契约下选择了不同分支：前五个被 iOS 当作规则列表，最后一个进入普通 Feed 路径。这里比较的是入口分支，不是声称 Android 最终地址一定有效，也不是实机成功率。

这是比“加独立 RSS Tab”更优先的行为差异。补 `singleUrl` 时必须连 `getSingleUrl` 的 URL 求值一起对齐，不能只删一个布尔条件。

## 3. 第二层：列表请求、变量与文章实体

```text
RssArticlesViewModel.loadArticles / loadMore
  → Rss.getArticlesAwait(sortName, sortUrl, source, page, key)
      → 新的 RuleData
      → AnalyzeUrl(... source, ruleData, page, key)
      → HTTP/WebView 响应
      → loginCheckJs（也考虑错误响应）
      → RssParserByRule.parseXML
          ├─ ruleArticles 空：RssParserDefault
          └─ AnalyzeRule(ruleData, source)
              → 列表 + 下一页
              → 每项 RssArticle，继承流程变量后解析各字段
  → Room RssArticleDao
```

### 列表字段的职责

| 字段 | 消费方式 |
| --- | --- |
| `ruleArticles` | 提取集合；开头 `-` 表示反转 |
| `ruleTitle` | 条目标题；空白标题不形成有效条目 |
| `rulePubDate` | 发布日期文本 |
| `ruleDescription` | 已可显示的内容 HTML；不必只是短摘要 |
| `ruleImage` | 条目图片地址，后续还可能需要图片解码 |
| `ruleLink` | 条目链接与后续内容基址 |
| `ruleNextPage` | 列表下一页；`PAGE` 为特殊值，否则执行规则并解析绝对 URL |
| `type` | 复制到 `RssArticle.type`，供条目打开使用 |
| `sourceGroup` / `articleStyle` | 源分组/列表样式；不应误作媒体类型 |

每项先创建 `RssArticle(variable=列表阶段变量)`，再把 AnalyzeRule 的 ruleData 切到该条目，依次解析字段。因此前一字段的变量写入可能被后一字段、正文或网页动作读取。

实体主键是 `origin + link + sort`。保留分类、原始 HTML、变量和类型，不要仅保存 `title/link/image` 三个展示字段。

## 4. 分页是状态机，不只是 page++

[RssPaginationState][pagination] 负责：

- `startRefresh`、`startNextPage` 期间拒绝重复并发操作。
- next-page 请求使用“当前成功页 + 1”，但只有成功提交才推进 page。
- requestId 区分过期响应；失败保留 Refresh/NextPage 的重试目标。
- 仅非空下一页 URL 表示还有候选页。

`RssArticlesViewModel` 负责把结果写入 Room、设置顺序及去重；加载更多发现首末条目都已存在时，可以判定没有新增内容。UI 的 hasMore 还考虑本页是否实际新增。

对齐必须覆盖：下一页失败后重试、刷新与旧响应相遇、空页、循环/重复页、分类切换、搜索 key 持续传递。不能把失败当作最后一页，也不能失败一次就跳过一个页码。

## 5. 第三层：条目打开与内容选择

[ReadRss][read-router] 根据 **条目类型** 选择：

| `RssArticle.type` | 路径 | 内容合同 |
| --- | --- | --- |
| 0 网页 | ReadRssActivity | 页面 URL 或源生成的 HTML，可含多媒体和脚本 |
| 1 图片 | PhotoDialog | 无 ruleContent 用条目链接；有规则则提取图片地址并解析相对 URL |
| 2 视频 | VideoPlayerActivity → VideoPlay | 携带 sourceKey、SourceType.rss、条目记录，不是裸 URL 打开 |

### 网页条目的优先级

`ReadRssViewModel.resolveRssReadLoadTarget`：

1. 找不到文章：按历史链接加载网页。
2. `description` 非空：直接使用已保存内容。
3. 否则有 `ruleContent`：运行正文规则。
4. 否则：加载文章原始 URL。

因此 `ruleDescription` 返回一段交互 HTML 时，它就是可显示内容；不能因为文字少就判定成劣质摘要，再抓另一页覆盖它。

### 正文分页与列表分页不同

`Rss.getContentAwait` 使用 `ruleContent` 提取内容，另外读取 `nextContentUrl`：单下一页顺序追踪并防重复，多链接可并发获取后合并。

这个合并只用于源和条目均为 type=0 的网页正文。type=1/2 保持单个媒体结果合同，不能把多个视频链接用换行拼接后交给播放器。

## 6. WebView 是运行环境，不是 HTML 展示框

| 配置/行为 | 基准执行点 | iOS 需要对齐的内容 |
| --- | --- | --- |
| URL、headers、UA、Cookie | AnalyzeUrl → ReadRssActivity 的 URL observer | 首次页面与资源请求的来源上下文 |
| `enableJs` | `upWebviewSettings` | 是否运行页面 JS；不能只有字段却永远开启 |
| `loadWithBaseUrl` | `loadDataWithBaseURL` | 决定 HTML 的 base URL；影响相对图片、脚本、链接 |
| `style` | `ReadRssViewModel.clHtml` | 保留源内容并合入样式；默认样式包含 video/img |
| `injectJs` | 页面完成回调 | 按时机执行，不是导入后立即执行一次 |
| `preloadJs` | 注入资源及接口安装路径 | 早期执行与桥接建立；不同于页面完成注入 |
| `shouldOverrideUrlLoading` | 导航拦截回调中 `source.evalJS`，绑定 url 与 RSS 动作桥 | 返回值决定是否拦截，动作和导航不能重复执行 |
| `startHtml/startStyle/startJs` | 启动页生成 + `loadStartHtml` | 启动页自身的 HTML/CSS/JS 合同 |
| `contentWhitelist/contentBlacklist` | `shouldInterceptRequest` 的资源过滤分支 | 逗号分隔；按 URL 前缀或完整正则匹配，黑名单非空时不再执行白名单 |
| `cacheFirst` | WebView cacheMode | 页面缓存策略，不是源规则缓存 |
| `showWebLog` | 网页日志配置相关路径 | 调试能力，不表示页面能否执行 |

资源过滤不能套到所有导航上：主文档与预注入资源在前面的专门分支处理；普通子资源才继续走上述黑/白名单。把它改成“同时执行两张名单”也会改变基准行为。

页面桥接有多条路径：`WebJsExtensions` 提供网页请求等能力，`RssJsExtensions` 提供 RSS 导航动作；接口安装还受预注入配置影响。**不要把解析脚本的 `java` 对象不加区分地暴露给所有远程页面。**

### 图像与视频并不是只有 URL

- [ImageUtils][image-utils] 对 RSS 使用 `coverDecodeJs`，输入可以是图片流/bytes，并带 `src`；拿到图片 URL 但跳过解码仍会显示失败。
- [VideoPlay][video] 对 type=2 的 RSS：无正文规则时解释条目链接；有规则先 `Rss.getContent`。返回值还可能被当作 MPD 文本生成临时文件，再使用 AnalyzeUrl 的请求头交给播放器。
- 上述原生视频路径与 type=0 的 HTML `<video>`/iframe/JS 播放器路径并存。
- iOS 具体媒体格式和播放器能力必须另验，不能因能播放一条 MP4 就承诺所有基准媒体格式可用。

## 7. 三种“订阅”不要混在一起

1. `RssSource`：内容来源及网页/文章规则。
2. `RuleSub`：更新书源/RSS/替换规则配置包；入口在 `ui/rss/subscription`，执行器是 `model/RuleUpdate`。
3. Yuedu `Modules/Services/Subscription`：付费会员，与前两者不是一个业务概念。

Android 规则包自动更新目前使用到期时间、源更新时间和静默/确认分支；它不是当前 RSS 列表的刷新或 loadMore。

## 8. iOS 当前路径与接入位置

| 职责 | iOS 当前文件 | 对齐重点 |
| --- | --- | --- |
| 类型/网页配置保存 | `Modules/Services/RSS/RSSModels.swift`、`LegadoSourceJSONParser.swift` | 未支持字段不得静默丢失；读入不等于执行 |
| 入口 | `Modules/Features/Library/LibraryTabRoot.swift`、`Modules/Features/RSS/RSSListView.swift` | 二级入口/树形分组是 UI 选择，不是协议本身 |
| 单页判断 | `RSSSource.opensAsWebPage`、`RSSFetcher.fetchItems` | singleUrl 优先级、动态启动 URL |
| 分类/列表/正文 | `Modules/Services/RSS/LegadoRSSScraper.swift` | 绑定源、jsLib、变量、规则回调、登录/请求上下文 |
| 分页与文章状态 | `RSSFetcher.swift`、`RSSStore.swift`、`RSSFeedView.swift` | 分类身份、nextPage 状态、失败重试、晚到响应 |
| 文章显示 | `RSSArticleReaderView.swift`、`Modules/Services/RSS/RSSUtilities.swift` | 普通安全文章与受控规则网页的合同分开 |
| 直接网页 | `RSSFeedView.swift` 的 SafariView | 仅交接 URL 不能执行源注入/拦截 |
| 媒体 | 现有 FixedPageReader / VideoPlayerView 及服务 | 复用播放器不等于丢弃 sourceKey、headers、Cookie 和播放位置 |

具体样本计数和已确认断点见 [真实源包审计](../../Technotes/LegadoRealSourceAudit.md)，这里不维护第二份完整差异表。

## 9. 后续实现的最小验收矩阵

| Fixture | 必须观察到的结果 |
| --- | --- |
| singleUrl=true，同时存在规则/分类 | 仍按基准单页入口，使用正确计算出的 URL |
| 分类脚本读取 source.getVariable 与 jsLib | 当前源状态可读，其他源状态不串入 |
| 列表规则 java.put，条目规则 java.get | 状态沿同次抓取继续传递 |
| getString(rule, mContent) 与 setContent | 使用正确文档，不返回默认空值 |
| description 已含交互 HTML | 不因摘要长度启发式替换掉内容 |
| type=0，正文包含 img/video/iframe | 授权的规则网页保持所需媒体；普通 RSS 不因此获得无限脚本权限 |
| 页面完成 injectJs 与早期 preloadJs | 两种时机可区别验证，不重复注入 |
| 跳转拦截返回 true/false | 分别拦截/放行，外部动作恰好一次 |
| Header/Cookie、跨域资源 | 必需认证不丢；私有认证不误发到无关域 |
| ruleNextPage / PAGE | 下一页、空页、失败重试、重复页和分类切换正确 |
| nextContentUrl，网页/图片/视频三种类型 | 网页合并正文；图片/视频保持单媒体合同 |
| 图片解码 | 原始 bytes → decode JS → 可显示图像 |
| type=2 返回链接或 MPD 文本 | 按约定解析/播放，明确不支持格式的错误 |
| 重新启动与历史/收藏打开 | 源身份、文章类型、变量与进度仍可恢复 |

这些是建议的待实现/待运行合同，不是已经通过的测试。

## 10. 已有基准测试入口

Android `app/src/test/java/io/legado/app/`：

- `ui/rss/article/RssPaginationStateTest.kt`：实际分页状态转换。
- `model/rss/RssContentPaginationTest.kt`：固定响应的正文解析/下一页，含图片和视频保持单 URL 的案例。
- `help/source/RssSortUrlsTest.kt`：分类规则结果。
- `ui/rss/read/ReadRssTitleTest.kt`：标题与加载目标相关行为。
- `ui/rss/read/RssWebResourceProxyTest.kt`：网页资源代理辅助逻辑。
- `ui/association/RssSourceImportTest.kt`、`RssSourceImportComparisonTest.kt`：导入形态与比较。

iOS 现有 `LegadoRSSCompatTests.swift`、`RSSPageDecodingTests.swift`、`RSSArticleLinkResolutionTests.swift` 可作为入口，但还需覆盖上述源上下文、脚本网页和分页。当前真实包没有 RSS type=1/2，必须另补合成样本或专门源。

本轮没有执行这些测试；其中辅助逻辑测试、源码约束测试、真正 WebView/媒体测试的证明力度不同，交付时应分别报告。

[rss-home]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/main/rss/RssFragment.kt
[rss-home-model]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/main/rss/RssViewModel.kt
[rss-source]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/RssSource.kt
[rss-ext]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/help/source/RssSourceExtensions.kt
[articles-model]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/rss/article/RssArticlesViewModel.kt
[pagination]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/rss/article/RssPaginationState.kt
[rss-model]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/rss/Rss.kt
[rss-parser]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/rss/RssParserByRule.kt
[read-router]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/rss/read/ReadRss.kt
[read-model]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/rss/read/ReadRssViewModel.kt
[read-activity]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/rss/read/ReadRssActivity.kt
[video]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/VideoPlay.kt
[image-utils]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/utils/ImageUtils.kt
