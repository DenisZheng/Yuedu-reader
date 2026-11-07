# Yuedu-reader 对齐 Legado Android：功能差异分析与开发方案

> **目标项目：**
> [DenisZheng/Yuedu-reader](https://github.com/DenisZheng/Yuedu-reader)\
> **基准项目：**
> [LegadoTeam/legado](https://github.com/LegadoTeam/legado)\
> **审查日期：** 2026-11-07\
> **文档版本：** 1.0\
> **目标：** 在保留 Yuedu 原生 iOS 架构的前提下，对齐 Legado
> 的主要功能与核心运行行为；RSS 是第一优先级。

------------------------------------------------------------------------

## 文档摘要

Yuedu 已经具备较成熟的 iOS 阅读器、书源规则、漫画、音视频和 RSS
基础设施。正确方向不是重写项目，而是补齐 Legado
的数据格式、规则运行时、分页、媒体和业务行为兼容。

本方案基于两个公开仓库的代码结构、RSS
数据模型、导入路径、规则解析器、文章阅读器、媒体请求代理及相关测试进行静态代码审查。文档会区分"已经实现""部分实现""缺失或未接入"，避免把页面存在误判为功能兼容。

### 范围约束

-   **不开发 Dict（字典规则）**。
-   **不开发 AutoTask/Cron 用户可编程后台任务**。
-   Yuedu 现有 RSS
    刷新、通知及系统允许的后台刷新机制保持现状；只修复必要的刷新链路，不扩展成通用任务系统。
-   优先完成 RSS 的导入、解析、分页、图片、视频闭环。
-   RSS
    完成后，再对书源、漫画、视频书源、TTS、OPDS、备份同步等主要功能做专项对齐。

### 优先级总览

  -----------------------------------------------------------------------------------------------------
  优先级                  工作内容                         目标
  ----------------------- -------------------------------- --------------------------------------------
  P0                      RSS 导入、数据模型、请求链路     导入的源真正能够请求和解析，失败有明确报告

  P1                      RSS                              提高 Legado RSS 规则兼容率
                          规则运行时、登录、Cookie、变量   

  P1                      列表分页、正文分页、分类缓存     完成订阅文章的主要浏览流程

  P1                      图片、视频、音频及资源请求       实现 RSS 媒体内容可见、可播放

  P2                      RSS 高级编辑器、规则调试         便于维护复杂订阅源

  P2                      书源、漫画、TTS、OPDS 等专项对齐 逐模块提高整体功能覆盖率
  -----------------------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 1. 审查基线与范围

## 1.1 仓库与版本

  -----------------------------------------------------------------------------------------------------------------------------
  项目              仓库                                         分支              审查基线
  ----------------- -------------------------------------------- ----------------- --------------------------------------------
  Yuedu-reader      https://github.com/DenisZheng/Yuedu-reader   main              `f821dc9a7f35b375ea043c07fd1b95e15465e267`

  Legado            https://github.com/LegadoTeam/legado         master            `330e606c4d57e08adc056ff8ab7a4132c784da9a`
  -----------------------------------------------------------------------------------------------------------------------------

基线以 2026-11-07
可访问的仓库提交为准。两个项目仍可能继续更新；正式编码前应重新拉取
main/master，并确认关键文件是否发生变化。

## 1.2 本次检查的代码范围

  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  领域                    Yuedu 重点文件/目录                                                     Legado 重点文件/目录
  ----------------------- ----------------------------------------------------------------------- ---------------------------------------------------------------------------------
  RSS 数据模型            `Modules/Services/RSS/RSSModels.swift`                                  `data/entities/RssSource.kt`、`RssArticle.kt`、`RssStar.kt`、`RssReadRecord.kt`

  RSS 导入                `LegadoSourceJSONParser.swift`、`RSSListView.swift`、`RSSStore.swift`   `ui/association/RssSourceImport.kt`、`ImportRssSourceViewModel.kt`

  RSS 解析                `LegadoRSSScraper.swift`、`RSSFetcher.swift`、`RSSUtilities.swift`      `model/rss/Rss.kt`、`RssParserByRule.kt`、`RssParserDefault.kt`

  RSS 阅读                `RSSFeedView.swift`、`RSSArticleReaderView.swift`                       `ui/rss/read/ReadRss.kt`、`ReadRssActivity.kt`

  媒体资源                `Reader/Video`、`Core/Video`、`RSSUtilities.swift`                      `RssWebResourceProxy.kt`、`ReadRssActivity.kt`

  书源运行时              `Core/RuleEngine/ModernParser`、`Core/BookSource`                       `model/analyzeRule`、`help/http`
  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

## 1.3 审查限制

1.  本次是静态代码审查，没有在 iPhone/iPad 上执行完整端到端测试。
2.  没有拿到用户实际导入失败的 RSS JSON、订阅源 URL
    和网络日志，因此不能把某一个具体源的失败归因于单一原因。
3.  媒体代理、HLS、Range、Cookie
    等必须通过真实设备和本地测试服务器验证，不能只靠代码阅读确认。
4.  本方案不承诺 Legado 的所有 Android 专属能力都能在 iOS
    上一比一实现；会按主要功能、平台能力和协议限制分级。

------------------------------------------------------------------------

# 2. 两个项目的架构现状

## 2.1 Yuedu 已有基础

Yuedu 是 Swift 6 / SwiftUI 的 iOS 原生阅读器。项目 README 标明 iOS
17+，内容覆盖本地书库、在线来源、RSS、OPDS、WebDAV、Calibre、漫画、音频和视频。

  --------------------------------------------------------------------------------------------------------------------------------
  模块                    当前基础                                                本项目中的处理方式
  ----------------------- ------------------------------------------------------- ------------------------------------------------
  阅读器                  CoreText 原生阅读、EPUB/PDF/TXT/Markdown 等             保留，不重写

  书源                    Legado 格式导入、规则引擎、JavaScriptCore 兼容层        作为 RSS 运行时可复用的底层能力来源

  漫画                    CBZ/固定页面阅读及缩放能力                              核对在线漫画源规则和图片缓存，不另起一套阅读器

  视频                    AVPlayer、VideoPlaybackController、HeaderedMediaAsset   RSS 视频优先接入现有播放器

  TTS/音频                系统 TTS、HTTP TTS、音频播放基础设施                    核对 Legado 规则和音频附件接入

  RSS                     原生 Feed 解析、Legado 规则抓取、订阅管理和 WebKit      优先补齐
                          文章阅读                                                

  同步/远程               iCloud、WebDAV、OPDS、Calibre 等                        进行行为对齐，不整体重写
  --------------------------------------------------------------------------------------------------------------------------------

## 2.2 Legado RSS 的业务模型

Legado RSS 并不是只有"URL + XML 解析"。RssSource
包含源级规则、登录脚本、网络请求、分类、正文分页、页面展示、媒体类型和搜索等配置；RssArticle
又保存文章类型、阅读进度、变量等信息。

  ---------------------------------------------------------------------------------------------
  Legado 字段/机制        含义                           Yuedu 对齐要求
  ----------------------- ------------------------------ --------------------------------------
  `sourceUrl` /           源地址与名称                   已有对应字段；导入校验需放宽名称必填
  `sourceName`                                           

  `header` /              请求头及 Cookie 行为           统一请求层及源级会话
  `enabledCookieJar`                                     

  `loginCheckJs` /        登录检查和 JS 库               接入 RSSSourceSession
  `jsLib`                                                

  `sortUrl`               RSS 分类列表                   已有基础解析；补齐分类状态和缓存

  `ruleArticles`          文章列表规则                   已有基础实现

  `ruleNextPage`          文章列表下一页                 字段存在，完整分页链路未实现

  `ruleTitle` /           文章字段规则                   已有基础实现，需补齐文章上下文
  `ruleLink` /                                           
  `ruleDescription` /                                    
  `ruleImage` /                                          
  `rulePubDate`                                          

  `ruleContent`           文章正文规则                   已有基础实现

  `nextContentUrl`        文章正文下一页                 Yuedu 模型缺失，需新增

  `type`                  源及文章类型：网页/图片/视频   Yuedu RSSSource 缺少对应字段

  `preloadJs` /           阅读页脚本、样式及起始页面     部分字段存在，运行时未完整对齐
  `injectJs` / `style` /                                 
  `startHtml`                                            

  `searchUrl`             源内搜索                       模型和远程搜索链路需补齐
  ---------------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 3. RSS 代码级差异与已确认问题

## 3.1 导入链路：JSON 可读不代表订阅源可用

Yuedu 的 `LegadoSourceJSONParser` 当前支持 JSON 数组和单个 JSON
对象，并通过 `compactMap` 过滤不能解析的项目。单个订阅源解析时要求
`sourceUrl` 和 `sourceName` 都非空。

Legado 的 `RssSourceImport` 还支持包含 `sourceUrls` 的对象；Yuedu 当前
parser 没有对应分支。对这种对象，Yuedu 会尝试把它当作单个 source
解析，最终不能得到有效订阅源。

另一个已确认问题是导入路径不一致：本地 JSON 导入会调用
`refreshImportedSources`；远程 JSON URL 导入则调用 `store.addSources()`
后结束，没有触发相同的刷新流程。

  ----------------------------------------------------------------------------------------------------
  问题              当前代码行为             影响                       修复要求
  ----------------- ------------------------ -------------------------- ------------------------------
  `sourceName` 必填 缺少名称时 compactMap    有效源可能导入数量为 0     `sourceUrl`
                    丢弃                                                必填，名称允许为空并自动生成

  `sourceUrls` 缺失 未识别 sourceUrls        远程源集合无法完整导入     实现 Sources/SourceUrls
                    集合格式                                            两类导入结果

  远程导入不刷新    URL 导入只保存，不走     用户看到导入成功但无文章   统一 Import → Validate → Save
                    refreshImportedSources                              → Refresh

  重复源只跳过      RSSStore 按 URL 去重     无法选择更新旧配置         实现比较、更新、保留用户字段

  错误被静默跳过    批量刷新失败直接         用户无法定位坏源           生成逐源导入和刷新报告
                    continue                                            
  ----------------------------------------------------------------------------------------------------

## 3.2 请求链路：标准 Feed 和 Legado 规则请求不一致

Yuedu 标准 Feed 走 `RSSRequestFactory.feedRequest()`，当前会设置默认
User-Agent、Accept、Accept-Encoding、ETag 和 Last-Modified，但没有把
`RSSSource.header` 合并到请求中。

Legado 自定义规则请求走 `LegadoRSSScraper.fetchBody()`，这条路径会解析
`source.header` 并合并到 URLRequest。因此，两类 RSS
请求的请求头行为不一致。

`RSSArticleContentLoader` 抓取全文时也只使用默认请求头，没有获得订阅源
header/session。对要求 Referer、Authorization、Cookie 或特定 UA
的站点，可能出现列表能取到、全文却 403/空白的情况。

`LegadoRSSScraper.scriptHost(for:)` 当前只创建 JSCoreEngine 并连接
networkHandler，没有像书源 ModernParserBridge 那样把 BookSourceSession
的完整源对象、jsLib、登录状态及会话管理接进来。RSS 的 `loginCheckJs`
在已检查的抓取流程中没有被执行。

## 3.3 RSS 规则解析：列表规则有了，分页闭环没有

Yuedu `LegadoRSSScraper.scrape()` 接收 `page` 参数，但当前
`RSSFetcher.fetchWithLegadoRules()` 只请求一次 scrape，并将结果写入
items。解析结果没有返回 nextPageURL，也没有接入连续分页状态。

Legado `RssParserByRule.parseXML()` 会执行 `ruleNextPage`：

-   值为 `PAGE` 时继续使用当前 sortUrl 并递增 page。
-   其他规则则从页面提取下一页 URL。

正文分页是另一条链路。Legado `Rss.getContentAwait()` 会根据
`nextContentUrl` 循环获取下一页，使用 `visitedUrls` 防止循环；多个下一页
URL 还支持并发解析。Yuedu RSSSource 当前缺少
`nextContentUrl`，不能视为已支持正文分页。

此外，Legado 在每个文章元素解析前会设置
`ruleData(rssArticle)`，让规则可以读写文章级变量。Yuedu 当前的
`parseArticles()` 主要是对元素 setContent
后提取字段，没有完整等价的文章级 RuleData 持久化。

## 3.4 分类：入口存在，缓存模型不完整

Yuedu 已有 Legado `sortUrl` 解析和分类选择 UI，但 RSSStore
的文章缓存主要按 sourceId 存储，而不是 sourceId +
sortKey。切换分类时缺少独立、稳定的分类缓存和分页状态。

因此，分类入口存在不等于已经具备 Legado
的分类独立刷新、分页、缓存和阅读状态行为。建议在数据层增加 sortKey
维度。

## 3.5 图片：有 HTML 图片，但缺少完整媒体模型

Yuedu 已有 `ParsedAttachment`，解析器能识别 Feed 附件，但
`RSSItem.init(from:)` 没有把 `ParsedFeedItem.attachments` 写入
RSSItem；RSSItem 和 RSSArticleRecord
也没有附件字段。附件会在解析结果转换为持久化文章时丢失。

`RSSArticleHTMLSanitizer` 当前白名单保留 img 的
src、alt、title、width、height，没有保留 `data-src`、`data-original`
等常见懒加载属性。图片站点可能因此显示空白。

Legado 的 `source.type` / `article.type`
可以将文章路由到图片阅读界面。Yuedu 的 RSSSource 缺少 type
字段，也没有完整的 RSS 图片文章路由。

## 3.6 视频和音频：播放器基础存在，RSS 入口缺失

Yuedu 已有 `VideoPlayerView`、`VideoPlaybackController`、`VideoStream`
和 `HeaderedMediaAsset`，书源视频可复用这套播放基础设施。

但 `RSSArticleHTMLSanitizer` 的 noiseSelector 包含
iframe/object/embed，sanitizedHTML 的白名单也没有
video、audio、source、track。因此 HTML5 媒体在清理阶段就可能被移除。即使
renderer 的 CSS 已经包含 video 样式，也不能恢复已被 sanitizer
删除的节点。

Legado `ReadRss` 会根据 article.type
分别打开网页、图片或视频播放器。Yuedu 需要补齐 RSS
文章媒体类型、附件模型及媒体路由。

Yuedu 现有 `VideoChapterLink` 明确把 DASH `.mpd` 视为不支持；RSS
视频实现时需要把 HLS、MP4、DASH 和 DRM
作为独立兼容项，不能承诺所有视频源都可播放。

## 3.7 媒体资源请求代理

Legado `RssWebResourceProxy` 针对 WebView
子资源请求提供请求头合并、Range 请求、206 状态码、Content-Range、MIME
和响应头透传。Yuedu RSSArticleWebReaderView 当前使用
`WKWebView.loadHTMLString(document.html, baseURL:)` 展示文章，没有对应的
RSS 资源代理层。

这是图片/视频"解析到 URL"之后仍然失败的关键风险：服务器可能要求源
header、Cookie、Referer 或 Range。WKWebView
子资源请求不能简单假设会自动继承原始 Feed 的请求头。

**技术验证要求：** 先用 WKURLSchemeHandler / 本地 HTTP 代理做小型
PoC，验证普通图片、带 Header 图片、MP4、HLS
playlist/segment/key、Range/206。再选定架构。不要把 URLProtocol 当作
WKWebView 所有子资源的通用拦截方案。

## 3.8 文章 ID 和状态作用域

RSSStore 的 articleStatuses 以 articleID 为 key，当前文章 ID 可能来自
Feed GUID 或 URL。不同订阅源有可能复用同一个
GUID/URL，造成已读、收藏或阅读位置状态串源。

建议使用 `sourceId + sortKey + stableArticleKey` 生成稳定复合
ID，并设计旧数据迁移映射，保留已有收藏、已读、全文缓存和阅读位置。

## 3.9 当前 RSS 差异汇总

  --------------------------------------------------------------------------------
  功能                        Yuedu 当前状态               结论
  --------------------------- ---------------------------- -----------------------
  RSS/Atom/JSON Feed          有解析器及相关测试           已有，保留

  Legado JSON 数组/单对象     有基础导入导出               部分兼容

  sourceUrls 集合导入         缺少对应分支                 缺失

  Legado RSS                  有基础规则解析               部分兼容
  CSS/XPath/JSONPath/JS                                    

  source.header               规则抓取路径支持；标准       需统一
                              Feed/全文不统一              

  loginCheckJs/jsLib/Cookie   未接入完整 RSS 运行时        缺失或不完整
  会话                                                     

  ruleNextPage                字段存在，抓取链路不消费     缺失
                              next URL                     

  nextContentUrl              模型缺失                     缺失

  sortUrl 分类                有解析/UI，分类缓存不完整    部分兼容

  attachments                 中间模型有，RSSItem/Record   数据丢失
                              未保存                       

  source.type/article.type    RSSSource 未定义             缺失

  HTML5 video/audio           sanitizer 会移除相关元素     缺失

  媒体 Header/Range 代理      没有 RSS 等价代理            缺失

  RSS 规则调试器              缺少完整的源级调试工作流     需建设
  --------------------------------------------------------------------------------

------------------------------------------------------------------------

# 4. 目标架构设计

## 4.1 架构原则

1.  保留 Yuedu 原生 RSS Feed Parser；标准 RSS/Atom/JSON Feed 不迁移成
    Legado 规则解析。
2.  标准 Feed 和 Legado
    自定义规则共用网络请求、Cookie、日志、缓存和持久化基础设施。
3.  RSSSourceSession 独立于 BookSourceSession，但可以复用底层 JS、网络和
    Cookie 组件。
4.  RSS 文章缓存按 sourceId + sortKey 管理；文章状态按稳定复合 ID 管理。
5.  网页、图片、视频、音频使用独立展示路由；媒体播放器优先复用 Yuedu
    已有能力。
6.  每个阶段都需要可自动运行的测试，不以"页面能打开"作为完成标准。

## 4.2 建议新增/调整的组件

  ------------------------------------------------------------------------------------------------------
  组件                       职责                                              建议位置
  -------------------------- ------------------------------------------------- -------------------------
  RSSSourceImportService     本地/远程                                         `Modules/Services/RSS/`
                             JSON、sourceUrls、重复比较、更新、刷新报告        

  RSSRequestBuilder          URL 选项、GET/POST、Header、Cookie、超时、编码    `Modules/Services/RSS/`

  RSSSourceSession           源级                                              `Modules/Services/RSS/`
                             JS、jsLib、Cookie、loginCheckJs、文章变量、节流   

  RSSPageResult              文章列表、下一页 URL、分页状态、分类 key          `Modules/Services/RSS/`

  RSSArticleContentService   ruleContent、nextContentUrl、正文合并             `Modules/Services/RSS/`

  RSSMediaAttachment         图片/视频/音频附件及 MIME 元数据                  `Modules/Services/RSS/`

  RSSMediaResourceProxy      子资源 Header/Cookie/Range/MIME/206               `Modules/Services/RSS/`

  RSSImageViewer             图片文章全屏查看、缩放、翻页、保存                `Modules/Features/RSS/`

  RSSRuleDebugService        请求、规则步骤、解析结果、错误诊断                `Modules/Services/RSS/`
  ------------------------------------------------------------------------------------------------------

## 4.3 数据流

``` text
RSSSourceImportService
        |
        v
RSSSourceStore / RSSSource DTO
        |
        v
RSSSourceSession
  |       |       |
 JS     Cookie   Network
        |
        v
     RSSFetcher
       /     \
      /       \
Native Feed  Legado Rule
 Parser       Parser
      \       /
       \     /
       RSSPageResult
             |
             v
          RSSStore
             |
          RSSFeedView
             |
      +------+-------+------+
      |      |       |      |
    WebKit  Image  AVPlayer Audio
```

## 4.4 关键数据模型建议

  ----------------------------------------------------------------------------------------------------------------------------------
  模型                    建议字段                                                                      目的
  ----------------------- ----------------------------------------------------------------------------- ----------------------------
  RSSSource               type、nextContentUrl、searchUrl、preloadJs、startHtml/startStyle/startJs 等   覆盖 Legado RSS 源配置

  RSSItem                 attachments、sortKey、mediaType                                               解析输出不丢媒体及分类信息

  RSSArticleRecord        attachments、mediaType、sortKey、mediaProgress、mediaDuration、variableJSON   持久化完整文章状态

  RSSArticleStatus        read/favorite/lastOpenedAt/readerScrollY/mediaProgress                        状态与文章内容分离

  RSSPageResult           items/nextPageURL/currentPage/hasMore/sortKey                                 统一列表分页结果
  ----------------------------------------------------------------------------------------------------------------------------------

字段增加必须提供默认值和解码兼容。当前 RSSStore 使用本地 JSON 文件保存
sources、folders、articles、statuses、feed
metadata；改数据结构时必须验证旧文件仍可解码。若文章 ID
变更，必须迁移状态和全文缓存。

------------------------------------------------------------------------

# 5. 分阶段开发计划与 PR 拆分

## Phase 0：建立可重复的基线

**目标：** 先确定当前 main
分支可构建、测试可运行，避免后续把已有问题误判为新回归。

工作：

-   创建 `feature/rss-legado-parity` 分支。
-   记录当前 RSS 相关测试通过/失败基线。
-   准备测试用 Firebase 配置、签名和模拟器环境。
-   建立脱敏的 Legado RSS JSON fixtures；不要把真实
    Cookie、Token、账号写入仓库。
-   确认许可证边界和文件级第三方许可证。

**交付：** 基线测试报告、测试数据目录、PR 开发约定。

## Phase 1：导入和数据模型修复（第一优先）

**建议 PR：** `RSS Import and Data Compatibility`

  ------------------------------------------------------------------------------------------
  任务                    具体修改                        验收条件
  ----------------------- ------------------------------- ----------------------------------
  导入格式                数组、单对象、sourceUrls        所有有效 source
                          对象、远程集合 URL              都能识别；无效项有原因

  源名称                  sourceName 允许空，按           合法 URL 不因缺名称被丢弃
                          URL/域名生成显示名称            

  重复源                  按规范化 URL                    更新不丢用户名称、分组、启用状态
                          比较，提供新增/更新/跳过        

  导入流程                本地和远程统一                  导入后自动刷新且有逐源报告
                          Import→Validate→Save→Refresh    

  媒体字段                RSSItem/Record 增加             解析到的附件在 Store
                          attachments/mediaType           重新加载后仍存在

  ID 迁移                 sourceId + sortKey + stable key 相同 GUID 的不同源状态不串扰

  源模型                  增加                            旧 JSON 和新 JSON 都能读写
                          type/nextContentUrl/searchUrl   
                          等字段                          
  ------------------------------------------------------------------------------------------

## Phase 2：RSS 网络请求与运行时

**建议 PR：** `RSS Source Runtime`

1.  实现 RSSRequestBuilder，统一 URL 规范化、Legado URL+JSON
    选项、GET/POST、请求头、超时、字符集和重定向。
2.  标准 Feed 请求合并 RSSSource.header；全文抓取也使用相同源会话。
3.  实现 RSSSourceSession，建立每个源独立的 JS 和请求上下文。
4.  加载 jsLib，接入 loginCheckJs，并处理登录状态变化。
5.  建立 Cookie 容器策略，明确 enabledCookieJar
    的语义；不得无意中把不同源的 Cookie 混用。
6.  文章规则执行时设置 article RuleData，支持文章级变量读写和持久化。
7.  接入 concurrentRate，限制同源并发请求。

**验收：** 标准 Feed、自定义
Header、Referer、Cookie、登录检查、jsLib、文章变量均有 fixture 测试。

## Phase 3：分类、列表分页、正文分页

**建议 PR：** `RSS Pagination and Category Cache`

  ----------------------------------------------------------------------------------------
  能力                    实现细节                           防坑要求
  ----------------------- ---------------------------------- -----------------------------
  ruleNextPage=PAGE       页码递增并重新执行 URL 模板        页码只在该分类内递增

  ruleNextPage URL        从当前页面提取并解析绝对 URL       相对 URL 以最终响应 URL
                                                             为基准

  sortUrl                 每个分类独立加载、刷新和缓存       sortKey
                                                             进入文章主键和状态作用域

  nextContentUrl          正文页循环获取并合并               visited URL
                                                             防循环；限制最大页数/总大小

  多 URL 正文分页         可配置并发，结果按源定义顺序合并   取消任务和错误策略明确

  远程搜索                searchUrl、key、page 变量          搜索结果与普通列表缓存分开
  ----------------------------------------------------------------------------------------

**验收：** 分类 A/B
之间切换不会覆盖缓存；刷新不会清空其他分类；列表分页和正文分页各自独立通过测试。

## Phase 4：RSS 图片、视频、音频

**建议 PR：** `RSS Media Support`

### 4.1 图片

-   解析 RSS enclosure、Media RSS thumbnail/content、Atom
    enclosure、JSON Feed attachments 和 HTML img。
-   保留 src、srcset、data-src、data-original 等必要图片字段，并统一相对
    URL 解析。
-   实现
    RSSImageViewer：全屏、双指/双击缩放、上一张/下一张、保存、分享、重试。
-   图片请求使用源 Header/Cookie；支持缓存、取消和失败诊断。

### 4.2 视频

-   识别 source.type=2、article.type=2 及 Feed video enclosure。
-   将 RSS 视频转换成现有 VideoStream，复用
    VideoPlayerView/VideoPlaybackController。
-   保存播放进度、标题、时长和封面；支持继续播放。
-   单独验证 MP4、HLS、Range、Referer、Cookie、签名 URL。
-   DASH `.mpd` 当前播放器不支持，应显示明确错误，不要假装兼容。

### 4.3 HTML5 音视频

-   修订 sanitizer：安全保留 video/audio/source/track/picture
    及必要属性。
-   iframe 默认不开放，按可信域名或明确的嵌入策略处理。
-   配置 WKWebView 的内嵌媒体播放策略。
-   建立 RSSMediaResourceProxy，验证子资源
    Header、Cookie、Range、206、Content-Range、MIME。

### 4.4 媒体验收

  用例                         验收
  ---------------------------- --------------------------------
  普通图片、data-src 图片      首屏和正文图片都能加载
  需要 Referer/Cookie 的图片   请求携带正确源上下文
  MP4 附件                     可播放、暂停、拖动、恢复进度
  HLS m3u8 + segment/key       播放列表、分片和密钥请求均成功
  Range/206                    拖动进度条不损坏播放
  HTML5 video/audio            sanitizer 保留安全元素并可播放
  无效/过期媒体链接            显示可理解错误并允许重试

## Phase 5：RSS 高级编辑器与调试器

**建议 PR：** `RSS Source Editor and Debugger`

目标是让用户可以在 iOS 端维护复杂 Legado RSS，而不是每次都依赖 Android
编辑。

  -----------------------------------------------------------------------------------------------------
  页面分区                            主要字段/功能
  ----------------------------------- -----------------------------------------------------------------
  基本信息                            名称、URL、分组、启用状态、类型、排序

  请求设置                            Header、Cookie、超时、UA、请求方式、字符集

  分类与列表                          sortUrl、ruleArticles、ruleNextPage

  文章字段                            ruleTitle、ruleLink、ruleDescription、ruleImage、rulePubDate

  正文                                ruleContent、nextContentUrl、contentWhitelist、contentBlacklist

  页面与脚本                          jsLib、loginCheckJs、style、injectJs、preloadJs、startHtml

  媒体                                type、附件规则、图片/视频 URL 测试

  调试                                请求预览、响应状态、解析步骤、文章预览、分页轨迹
  -----------------------------------------------------------------------------------------------------

调试器至少应显示：

-   请求 URL、最终 URL。
-   请求头（敏感值脱敏）。
-   HTTP 状态、响应编码。
-   规则名称、匹配数量、字段结果。
-   下一页 URL。
-   错误堆栈。

## Phase 6：全项目主要功能专项对齐

RSS 闭环完成后，再逐模块审查主要功能。不是将每个 Android 页面照搬到
iOS，而是核对相同输入是否能完成相同业务结果。

  ---------------------------------------------------------------------------------------------------
  模块              Yuedu 已有基础          后续对齐重点                            优先级
  ----------------- ----------------------- --------------------------------------- -----------------
  书源/文本阅读     Legado 规则引擎和阅读器 JS                                      P1
                                            API、登录、Cookie、分页、规则语义差异   

  漫画/图片         CBZ/固定页阅读、缩放    在线漫画源、图片请求、章节、长图/分图   P1

  视频书源          AVPlayer 和视频章节解析 HLS、页面嗅探、Header、协议限制         P1

  TTS/音频          系统 TTS、HTTP          Legado TTS 配置、登录脚本、音频附件     P1
                    TTS、音频播放                                                   

  替换规则          已有 Replace 模块       导入、分组、适用范围、规则语义          P1

  OPDS/远程书库     已有                    分页、元数据、下载、错误恢复            P2
                    OPDS、WebDAV、Calibre                                           

  备份/同步         iCloud、WebDAV 等       书源/RSS/规则/阅读状态的完整恢复        P2

  浏览器/登录       WebBrowser、来源登录    站点登录状态、Cookie 与来源会话衔接     P2
                    WebView                                                         
  ---------------------------------------------------------------------------------------------------

**明确排除：** 不开发 Dict 字典规则模块；不开发 Legado AutoTask/Cron
用户可编程后台任务。现有 RSS
刷新和系统后台刷新仅保持现状，不作为本次新功能扩展。

------------------------------------------------------------------------

# 6. 主要风险和技术坑

  -----------------------------------------------------------------------------------------------------------
  风险                    可能表现                         应对措施
  ----------------------- -------------------------------- --------------------------------------------------
  Rhino 与 JavaScriptCore 相同 JS 规则结果不同或报错       建立 Legado 规则 fixture；逐项补齐 JS
  不同                                                     API，不承诺引擎完全等价

  Java/Android API        Packages、Android 类或 Java 特有 维护兼容清单；提供明确的 Unsupported API 诊断
                          API 不存在                       

  Cookie 混用             A 源登录态泄漏给 B 源            按源隔离 Cookie/session；定义过期与导入策略

  WebKit 子资源请求       HTML 正常但图片/视频 403         先完成资源代理 PoC，再定架构
                          或不能拖动                       

  HLS 资源链              m3u8 能取到但 segment/key 失败   代理完整 playlist/segment/key 请求并测试 Range

  分类缓存冲突            切分类后文章覆盖或分页错乱       sourceId + sortKey 独立缓存

  文章 ID 冲突            不同源的已读/收藏串源            复合稳定 ID + 旧数据迁移

  旧数据解码              升级后 RSSStore 无法读取旧 JSON  所有新字段提供默认值；迁移测试

  内存和并发              刷新大量源时内存增长或请求过多   同源并发限制、批量写入、取消传播、响应大小限制

  iOS 平台限制            Android 功能无法一比一复刻       对后台调度、文件权限、媒体解码等定义平台适配策略
  -----------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 7. 测试与验收标准

## 7.1 导入测试

-   [ ] JSON 数组包含多个 RSSSource。
-   [ ] 单个 RSSSource JSON 对象。
-   [ ] sourceUrls 远程订阅源集合。
-   [ ] sourceName 缺失但 sourceUrl 有效。
-   [ ] sourceUrl 缺失或 URL 无效。
-   [ ] 重复源选择新增、更新、跳过。
-   [ ] 本地导入和 URL 导入均自动刷新并生成结果报告。
-   [ ] 导入失败不影响同批次其他有效源。

## 7.2 规则和网络测试

-   [ ] CSS、XPath、JSONPath、Regex、JS 列表规则。
-   [ ] GET、POST、URL JSON options、相对 URL 和重定向。
-   [ ] 自定义 User-Agent、Referer、Authorization、Cookie。
-   [ ] loginCheckJs 成功、失败和需要更新登录头的场景。
-   [ ] jsLib 引用和文章级 @put/@get。
-   [ ] ruleNextPage=PAGE、规则提取下一页 URL。
-   [ ] nextContentUrl 单页、多页、重复 URL、多个并发 URL。
-   [ ] 同源 concurrentRate 生效，不同源互不阻塞。

## 7.3 媒体测试

-   [ ] RSS/Atom/JSON Feed 附件数据解析和持久化。
-   [ ] HTML img、data-src、相对图片 URL。
-   [ ] source.type 图片模式和图片翻页/缩放。
-   [ ] MP4、HLS、带 Referer/Cookie 的视频。
-   [ ] Range、206、Content-Range、MIME 透传。
-   [ ] HTML5 video/audio 的 sanitizer 安全策略。
-   [ ] DASH/DRM/不支持协议明确提示。

## 7.4 回归测试

-   [ ] 原生 RSS/Atom/JSON Feed 不回归。
-   [ ] RSS 文件夹、搜索、未读、收藏、通知不回归。
-   [ ] 文章刷新后已读、收藏、全文和阅读位置保留。
-   [ ] 旧版 RSS JSON 数据能够读取。
-   [ ] 现有书源、漫画、视频书源、TTS 不受 RSS 改动影响。
-   [ ] iPhone 与 iPad 的文章阅读和媒体布局均可用。

## 7.5 发布门槛

一个 PR 只有同时满足以下条件才能合并：

-   新增功能有单元测试或集成测试。
-   相关旧测试全部通过；若存在基线失败，必须记录并解释。
-   没有把真实账号、Cookie、Token 或个人订阅数据提交到仓库。
-   数据模型变化有旧数据兼容测试。
-   媒体功能至少在真机上完成一次端到端验证。
-   用户可见错误有可理解的提示，不以静默失败代替错误处理。

------------------------------------------------------------------------

# 8. 许可证与实现边界

Yuedu 当前仓库 LICENSE 为 MPL-2.0，并在 Exhibit B 标记为 Incompatible
With Secondary Licenses；仓库 LICENSING.md
也明确说明，不能接受来自不兼容来源的复制代码。Legado 仓库 LICENSE 为
GPL-3.0。

因此，本方案采用"行为兼容、独立实现"的工程策略：以 Legado
公开的数据结构、功能表现和测试输入输出作为兼容标准，用 Swift
重新实现。不要直接复制 Legado Kotlin/GPL 源文件或将其翻译成 Swift
后视为规避许可证。具体文件复用、代码来源和分发合规应由项目维护者/法律专业人士确认。

-   可以研究公开格式、协议、字段含义和可观察行为。
-   可以独立编写 Swift 实现，并用自建 fixtures 验证行为。
-   保留第三方依赖、字体、图标和资源各自的许可证声明。
-   对来源不明的代码片段、测试数据和规则脚本进行来源记录。

------------------------------------------------------------------------

# 9. 实施节奏与交付物

  ------------------------------------------------------------------------------------------------------
  阶段                    建议交付物                                 完成标志
  ----------------------- ------------------------------------------ -----------------------------------
  基线                    构建/测试基线报告、fixtures                开发分支可重复构建

  P0 数据基础             导入服务、模型迁移、导入报告               导入的源可正确保存和刷新

  P1 运行时               RSSSourceSession、请求构建器、日志         Header/Cookie/JS/登录行为通过测试

  P1 分页                 RSSPageResult、分类缓存、正文分页          分类和分页闭环

  P1 媒体                 附件模型、图片查看器、视频路由、资源代理   真机图片/视频测试通过

  P2 调试                 高级编辑器、规则调试器                     可独立诊断常见订阅源失败

  全项目                  书源/漫画/TTS/OPDS 对齐矩阵                逐模块验收，不一次性重写
  ------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 10. 第一轮实际开发建议

不要一开始同时修改 RSS 导入、JS 引擎、WebKit
代理和播放器。建议先做一个范围可控、能验证价值的第一 PR。

## PR-1：RSS Import and Data Compatibility

建议先处理以下文件：

-   `Modules/Services/RSS/LegadoSourceJSONParser.swift`
-   `Modules/Services/RSS/RSSModels.swift`
-   `Modules/Services/RSS/RSSStore.swift`
-   `Modules/Features/RSS/RSSListView.swift`
-   `Tests/iOS/yuedu appTests/LegadoRSSCompatTests.swift`
-   `Tests/iOS/yuedu appTests/RSSStoreTests.swift`

PR-1 范围：

1.  支持 sourceUrls 导入。
2.  sourceName 缺失容错。
3.  重复源比较。
4.  统一本地/远程导入刷新。
5.  导入结果报告。
6.  RSS 附件持久化。
7.  type/nextContentUrl/searchUrl 等模型字段。
8.  旧数据解码测试。

PR-1 不做：不在同一个 PR 内实现视频代理、重写 JS 引擎或大改
WebKit。先把数据正确保存下来，后续媒体和分页才有可靠基础。

**建议验收顺序：**

1.  先让一个普通 Legado RSS JSON 导入后自动刷新成功。
2.  再让一个规则型 RSS 源导入后执行 ruleArticles。
3.  最后验证重复导入能更新源配置且不丢用户字段。

------------------------------------------------------------------------

# 11. 参考代码与文件链接

## 11.1 Yuedu

-   [仓库主页](https://github.com/DenisZheng/Yuedu-reader)
-   [RSSModels.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/RSSModels.swift)
-   [RSSFetcher.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/RSSFetcher.swift)
-   [LegadoRSSScraper.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/LegadoRSSScraper.swift)
-   [LegadoSourceJSONParser.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/LegadoSourceJSONParser.swift)
-   [RSSStore.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/RSSStore.swift)
-   [RSSUtilities.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Services/RSS/RSSUtilities.swift)
-   [RSSFeedView.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Features/RSS/RSSFeedView.swift)
-   [RSSArticleReaderView.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Features/RSS/RSSArticleReaderView.swift)
-   [VideoPlaybackController.swift](https://github.com/DenisZheng/Yuedu-reader/blob/main/Modules/Features/Reader/Video/VideoPlaybackController.swift)
-   [Legado
    差异说明](https://github.com/DenisZheng/Yuedu-reader/blob/main/docs/book-source/legado-differences.zh-Hans.md)
-   [LICENSING.md](https://github.com/DenisZheng/Yuedu-reader/blob/main/LICENSING.md)

## 11.2 Legado

-   [仓库主页](https://github.com/LegadoTeam/legado)
-   [Rss.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/model/rss/Rss.kt)
-   [RssParserByRule.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/model/rss/RssParserByRule.kt)
-   [RssParserDefault.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/model/rss/RssParserDefault.kt)
-   [RssSource.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/data/entities/RssSource.kt)
-   [RssArticle.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/data/entities/RssArticle.kt)
-   [ReadRss.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/ui/rss/read/ReadRss.kt)
-   [RssWebResourceProxy.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/ui/rss/read/RssWebResourceProxy.kt)
-   [ReadRssActivity.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/ui/rss/read/ReadRssActivity.kt)
-   [RssSourceImport.kt](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/ui/association/RssSourceImport.kt)

------------------------------------------------------------------------

# 附录 A：本方案不纳入的功能

  ----------------------------------------------------------------------------------------------
  功能                    本轮决定                说明
  ----------------------- ----------------------- ----------------------------------------------
  Dict 字典规则           不开发                  用户明确不需要，不列入排期和验收范围

  AutoTask/Cron           不开发                  用户明确不需要，不移植 Android 定时任务系统
  用户可编程后台任务                              

  Yuedu 现有 RSS 刷新     保持现状                只修复必要的源刷新链路，不扩展为通用任务系统
  ----------------------------------------------------------------------------------------------

# 附录 B：核心完成定义

本项目的主要功能对齐不以"页面看起来相似"为标准，而以业务行为为标准：同一份合法
Legado 配置导入 Yuedu
后，用户可以完成相应的请求、解析、阅读、媒体展示、进度保存和收藏操作；遇到
iOS 平台或协议限制时，应用必须给出明确提示。

RSS 的最终验收样例至少包括：

-   一个普通 RSS 源。
-   一个带自定义 Header 的规则源。
-   一个带 Cookie/登录检查的规则源。
-   一个带列表分页的源。
-   一个带正文分页的源。
-   一个图片源。
-   一个视频附件源。
-   一个 HTML5 视频源。
