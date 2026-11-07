# 书源与共享规则运行时

返回 [总入口](README.md) · [RSS 专属流程](rss-source.md)。`A/` 为 Android 应用代码根，基准版本见总入口。

## 1. 第一条调用链：源导入到在线书内容

```text
导入文本 / 文件 / URL
  → ImportBookSourceViewModel
      ├─ JSON → BookSource
      └─ 单文件 JS → JsSourceConfig.extract → BookSource.mainJs
  → 比较已有源、选择、保留用户配置
  → SourceHelp.insertBookSource → BookSourceDao

搜索/发现/详情/目录/正文调用方
  → WebBook.*Await
      ├─ isJsSource() → JsSourceBook → JsSourceEngine → JsSourceMarshaller
      └─ 声明式源 → AnalyzeUrl → 网络 → loginCheckJs → 对应解析器
                                           ↓
                    BookList / BookInfo / BookChapterList / BookContent
                                           ↓
                    SearchBook / Book / BookChapter / 内容字符串
                                           ↓
                    调用方提交模型、BookHelp 写内容、阅读器/播放器消费
```

[WebBook][webbook] 是在线书用例入口；[BookSource][book-source] 的 `isJsSource()` 只看 `mainJs` 是否非空。不要把带 `jsLib` 的声明式源误判成纯 JS 源。

| 用例 | 声明式主路径 | 重要结果 |
| --- | --- | --- |
| `searchBookAwait` | `searchUrl` → AnalyzeUrl → BookList | SearchBook 列表，含源和流程变量；空 searchUrl 明确报错 |
| `exploreBookAwait` | 发现分类 URL → AnalyzeUrl → BookList | 同搜索的列表形态，不是新的书籍实体协议 |
| `getBookInfoAwait` | 详情 URL → BookInfo | 名称、作者、目录地址等；文件源提取下载链接 |
| `getChapterListAwait` | 可选 `preUpdateJs` → 已有 tocHtml 或目录请求 → BookChapterList | 章节列表、卷/VIP/购买标记、目录分页与书籍目录摘要 |
| `getContentAwait` | 内容写回 token → 复用/请求 → BookContent → BookHelp | 正文或媒体地址；含失效保护，不只是返回一个 String |
| `getContentBatchAwait` | BookContent 或 JsSourceBook | 通过 `java.cacheContent` 写回，返回尚未回存的章节 |

目录/正文并非永远重新请求：详情和目录相同地址时可能复用 HTML；正文可复用已取得内容。对齐时至少覆盖缓存/复用和网络两条路径。

## 2. `BaseSource` 是公共能力，不只是字段接口

[BaseSource][base-source] 由 `BookSource`、`RssSource`、`HttpTTS` 等实现，承载：

- 源 key、名称、`header`、`jsLib`、`concurrentRate`、`enabledCookieJar`。
- `loginUrl/loginUi`、登录状态、登录请求头、自定义变量。
- `evalJS`，以及继承的 `JsExtensions` 能力。

当前基准还包含 `LoginUiV2` 相关调用。iOS 只有旧式表单或能打开登录网址时，不能据此认定所有登录协议已对齐；这个扩展不在现有样本审计的完整验证范围内。

### `java` 绑定取决于调用上下文

| 脚本位置 | `java` 实际对象 | 典型变量 |
| --- | --- | --- |
| URL 构建 | [AnalyzeUrl][analyze-url] | `key`、`page`、`speakText/speakSpeed`、`source`、`book`、`result`、`infoMap` |
| 内容提取规则 | [AnalyzeRule][analyze-rule] | `result`、`src`、`baseUrl`、`source`、`book`、`chapter`、`rssArticle`、`nextChapterUrl` |
| 源级脚本 | BaseSource | `source/sourceApi`、`baseUrl`、`cookie`、`cache`，以及调用方额外绑定 |
| 纯 JS 书源主函数 | JsSourceEngine | `source/sourceApi` 与当前函数实参，批量内容时还有批量上下文 |
| RSS 页面及导航动作 | WebJsExtensions / RssJsExtensions | 页面、源、文章、导航等特定桥接，详见 RSS 文档 |

因此，“统一注册一个含同名函数的 java 对象”不足以对齐。要检验参数、多载、返回类型、当前内容及副作用归属。

## 3. 请求合同：`AnalyzeUrl` 不只是 URL 模板替换

关键输入：规则 URL、baseUrl、key/page、source、ruleData、chapter、额外参数和调用上下文。

当前初始化顺序：

1. 获取源请求头；按调用选项与同站判断决定是否加入登录头。
2. 执行 URL 的 `@js:` / `<js>` 片段。
3. 处理 `{{…}}` 表达式及页码选择模板。
4. 解析相对 URL 和尾部 URL options。
5. 应用 method、headers、body、charset、retry、WebView、webJs/bodyJs、timeout、redirect、proxy 等配置。
6. 获取响应时经过每源限流和 Cookie 处理，选择 HTTP 或 BackstageWebView。
7. 返回 [StrResponse][response]，保留 URL、body、状态和请求/响应信息；不是只传一段网页文本。

### 三个容易实现错的边界

- **URL options 的 `type` 不是媒体类型。** `getStrResponseAwait` 在 `type != null` 时走字节→hex 的响应路径；不要混入书源/订阅类型枚举。
- **关闭 `enabledCookieJar` 不等于禁止所有 Cookie。** `setCookie()` 仍会合并持久 Cookie 与临时 Cookie；开关控制自动 CookieJar 标记及后续保存。不能把开关实现成无条件清空请求 Cookie。
- **认证请求头有作用域。** 登录头同站判断发生在初始 URL；当前代码也注明 JS 重写后跨域不在该保护范围内。对齐 iOS 时要单独检查跨域/重定向的安全边界，不复制已知保护空隙。

`loginCheckJs` 由 WebBook/Rss 等流程在响应后执行，而不是每个普通网络工具调用自动拥有同一语义。WebBook 对请求异常还可构造错误响应交给登录检查；不能只测试 HTTP 200。

## 4. 提取合同：`AnalyzeRule` 及上下文回调

`AnalyzeRule` 保存当前内容、baseUrl、redirectUrl、ruleData、source、chapter 等状态，拆分规则后分派给：

| 解析器 | 用途 |
| --- | --- |
| `AnalyzeByJSoup` | 默认/CSS/属性与文本提取 |
| `AnalyzeByXPath` | XPath |
| `AnalyzeByJSonPath` | JSONPath |
| Rhino eval | JS 链与嵌入表达式 |
| `RuleAnalyzer` / SourceRule | 链拆分、模板、变量与替换规则 |

`getString`、`getStringList`、`getElement/getElements` 不是可互换的包装：返回字符串、集合、Java/JS 对象时存在不同的转换和遍历语义。

尤其需要测试：

- 同一规则对 HTML、JSON、jsoup Element/Elements 的行为。
- `java.getString(rule, mContent)` 使用传入内容，而不是上一段页面。
- `setContent` 后的 `getString/getElements` 是否读到了更新内容。
- 相对链接使用 base/redirect URL 的区别。
- `getString(..., isUrl=true)` 遇空结果会返回 baseUrl；可选图片字段不应盲目继承这一行为。
- 正则替换、捕获组和模板必须按语义比较，不以“两端都能编译”作为标准。

## 5. 状态合同：四种变量不能合并

| 状态 | 写入/读取语义 | 生存期 |
| --- | --- | --- |
| AnalyzeUrl 的 `put/get` | 章节优先，其次 ruleData；不是通用源持久变量 | 当前请求关联对象 |
| AnalyzeRule 的 `put/get` | 写：chapter → book → ruleData → source；读另含 localBindings、bookName/title 等特殊值 | 当前操作及关联实体 |
| `source.put/get` | BaseSource 按 `v_<sourceKey>_<key>` 使用 CacheManager | 源级持久状态 |
| `source.setVariable/getVariable()` | `sourceVariable_<sourceKey>` | 用户/规则设置的源自定义变量，与任意键值变量分开 |
| 全局 `cache` | 显式 key、可选过期时间；不是自动源隔离的 dictionary | CacheManager 定义的内存/磁盘生命周期 |

[RuleDataInterface][rule-data] 为 Book/Chapter/RSS 文章等提供变量接口，还区分普通与大变量。RSS 列表阶段的变量会继续带入条目；只保留标题和链接会破坏后续正文。

[SharedJsScope][shared-js] 缓存共享库求值结果；[BaseSourceExtensions][source-extensions] 用库标识、源类与源 key 区分可变共享状态。每次执行的 bindings 和可复用脚本库不是同一个东西。Rhino 的执行还有取消与运行闸门，不应绕开统一引擎入口。

## 6. 内容分页、批量、媒体与写回

### 目录与正文分页

- `BookChapterList` 处理 `nextTocUrl`、目录顺序、卷标记及 `formatJs`，再更新书籍目录摘要。
- [BookContent][content] 处理 `nextContentUrl`：单链接顺序追页并防重复/跨到下一章；多链接按并发流程取得内容并合并。
- 章节边界、URL、返回顺序是合同；不能把重复第一页当作“没有下一页”。

### 副文

`subContent` 对文本可追加正文，对音频可写歌词，对视频可写弹幕。它不是通用广告清理字段；必要时还会请求副文 URL。

### 批量正文

声明式源使用 `contentBatch`，纯 JS 源使用 `getContentBatch`。两者经 `BatchContentContext` / `java.cacheContent` 回存，未回存部分再交给单章流程。它不是单纯把多个普通请求放进并发队列。

### 类型结果

- 文件型源：`BookInfo` 提取 `downloadUrls`，交给文件下载/本地导入，不是正文分页。
- 漫画：ReadManga 消费图片内容；图片还可能需要 [ImageUtils][image-utils] 的 bytes 解码。
- 音频/视频：内容结果往往是媒体 URL，继续经请求解释和源请求头进入播放器。
- 书籍封面用 `coverDecodeJs`，书中图片用 `ruleContent.imageDecode`；RSS 图片使用自己的 `coverDecodeJs`。

### 写回保护

`WebBook.getContentAwait` 与 `BookHelp` 使用 `ContentSaveToken`。异步下载返回后，不得覆盖更新世代或手工编辑后的内容。iOS 要保留现有 generation/提交策略，而不是只实现“请求完成就存盘”。

## 7. 纯 JS 书源的函数合同

[JsSourceBook][js-book] 调用 [JsSourceEngine][js-engine]，结果交给 [JsSourceMarshaller][js-marshaller]：

| 函数 | 参数 | 结果/缺省 |
| --- | --- | --- |
| `search` | key, page | 搜索结果列表 |
| `explore` | url, page | 发现列表 |
| `getBookInfo` | book | 可选；缺失/无返回时保留已有字段，再做合并与文件源检查 |
| `getChapters` | book | 章节列表；空列表报目录错误 |
| `getContent` | chapter, book, nextChapterUrl | 内容；非卷节点的空正文报错 |
| `getContentBatch` | 批量调用所绑定的上下文和参数 | 可选，通过 cacheContent 回存 |

主脚本执行、返回值归一化、对象合并、章节写回是独立步骤。缺 `getBookInfo` 不应和缺必需函数一样处理；新增 `mainJs` 字段也不能替代这些行为。

段评另有 `JsSourceReview` 与 `ReviewRuleParser`；不要把现有 HTML 段评标记路径视为通用段评协议已经完成。

## 8. iOS 对应入口与验收点

| 对齐边界 | 当前 iOS 入口 | 验收重点 |
| --- | --- | --- |
| 源字段/导入 | `Modules/Core/BookSource/BookSource.swift`、`BookSourceStore.swift` | 原字段往返、错误不伪装成空源 |
| 用例抓取 | `BookSourceFetcher+Search/Discover/BookInfo/TOC/Chapter.swift` | 五阶段同一源身份；复用、网络、分页均覆盖 |
| 源脚本 | `BookSourceSession.swift`、`SourceScriptHost.swift`、`JSCoreEngine.swift` | 同源状态连续、不同源隔离、取消正确 |
| 请求 | `ModernParser/URL/AnalyzeUrl.swift`、`Modules/Services/Network/LegadoRequestParser.swift` | method/body/header/encoding/redirect/Cookie |
| 提取与桥接 | `ModernRuleEngine.swift`、`ModernParserBridge.swift`、`JS/LegadoJSBridge.swift` | 回调、返回类型、mContent、变量优先级 |
| 运行状态 | `ModernParser/BookSourceRuntimeStateStore.swift`、`CookieStore.swift` | 持久变量/登录状态，不能每次重建为空 |
| 阅读/缓存 | `Modules/Services/Online/OnlineReadingPipeline.swift`、`Modules/Services/Offline/` | 有效目录与内容分离、晚到结果拒绝、媒体请求上下文 |

路径简写中的 `ModernParser/` 均位于 `Modules/Core/RuleEngine/ModernParser/`；上述为入口，不是本轮修改清单。

## 9. 现成测试线索

Android `app/src/test/java/io/legado/app/`：

- `model/analyzeRule/AnalyzeUrlNetworkOptionsTest.kt`：URL options。
- `model/analyzeRule/AnalyzeRuleElementsNormalizationTest.kt`、`AnalyzeByJSoupDomTest.kt`：返回对象/DOM 行为。
- `model/jsSource/JsSourceBookTest.kt`、`JsSourceMarshallerTest.kt`、`JsSourceEngineTest.kt`：纯 JS 协议。
- `help/book/ContentSaveFenceTest.kt`：晚到结果与内容写回世代。
- `model/analyzeRule/ReviewRuleParserTest.kt`：段评解析。
- `model/analyzeRule/AnalyzeUrlLoginHeaderContractTest.kt` **检查源码字符串，不是实际网络安全测试**。

Android `app/src/androidTest/` 的 `BatchContentDownloadTest.kt` 是另一层设备/应用集成线索。iOS 可复用 `Tests/iOS/yuedu appTests/Legado*Tests.swift` 及相关 BookSource 测试，但先检查覆盖范围；本轮没有运行上述测试。

[webbook]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/webBook/WebBook.kt
[book-source]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/BookSource.kt
[base-source]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/BaseSource.kt
[analyze-url]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt
[analyze-rule]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt
[response]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/help/http/StrResponse.kt
[rule-data]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/analyzeRule/RuleDataInterface.kt
[shared-js]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/SharedJsScope.kt
[source-extensions]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/help/source/BaseSourceExtensions.kt
[content]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/webBook/BookContent.kt
[image-utils]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/utils/ImageUtils.kt
[js-book]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/jsSource/JsSourceBook.kt
[js-engine]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/jsSource/JsSourceEngine.kt
[js-marshaller]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/model/jsSource/JsSourceMarshaller.kt
