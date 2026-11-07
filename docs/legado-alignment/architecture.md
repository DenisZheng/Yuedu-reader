# 架构与状态地图

返回 [总入口](README.md)。`A/` 表示 Android `app/src/main/java/io/legado/app/`；以下均为固定基准的源码事实。

## 1. 构建模块，不是按功能划分的多模块架构

| 模块/目录 | 实际职责 | 入口证据 |
| --- | --- | --- |
| `:app` | UI、业务模型、规则抓取、数据库、播放、后台服务与 HTTP/MCP 都在这里 | [settings.gradle][settings]、[app/build.gradle][app-build] |
| `:modules:book` | 内置 EPUB/UMD 等格式库，包名包括 `me.ag2s.epublib`、`umdlib` | [modules/book][book-module] |
| `:modules:rhino` | Rhino 包装、脚本绑定、求值/编译、Java 互操作与执行控制 | [RhinoScriptEngine][rhino] |
| `modules/web` | Vue + Vite + Pinia 网页前端，调用 App 的 HTTP/WebSocket 接口；不是第四个 Gradle Android 模块 | [package.json][web-package] |
| `app/src/main/res` | XML 布局、菜单、Preference 页面与资源 | `layout/`、`menu/`、`xml/pref_main.xml` |
| `app/src/main/assets` | 默认数据、JS 脚本、作者模板、内置 Web 资源 | `js_source_template.js`、`web/` |
| `app/schemas` | Room 导出的数据库 schema | [AppDatabase][database] |

当前配置声明：minSdk 23、targetSdk 36、Java toolchain 21、XML/ViewBinding UI。这里只记录配置，不证明本机已具备或验证过构建环境。

主要技术边界：Room 持久化；Kotlin 协程异步任务；Rhino 脚本；jsoup/Jayway JSONPath/JsoupXpath 提取；OkHttp 与可选 Cronet 网络；Android WebView 页面；Media3/GSYVideoPlayer 音视频。

**版本事实必须看配置。** 当前 `gradle/libs.versions.toml` 的 jsoup 固定为 `1.23.2`；不能直接复用 iOS 旧注释中“Legado 固定 jsoup 1.16.2”的假设。这不是对任何版本的线上兼容性结论。

## 2. 应用入口与分层

```text
App.onCreate
  ├─ 初始化 Rhino、应用配置、生命周期与日志
  ├─ 初始化默认数据、清理过期状态
  └─ 自动任务调度 / 可选进度同步

MainActivity
  ├─ 书架 Fragment
  ├─ 发现 Fragment
  ├─ RSS Fragment
  └─ 我的 / 配置 Fragment
       ↓ Activity / ViewModel / model 单例
  WebBook / Rss / ReadBook / AudioPlay / VideoPlay …
       ↓
  AnalyzeUrl / AnalyzeRule / BaseSource
       ↓
  HTTP / Rhino / HTML 解析 / WebView
       ↔ Room、文件缓存、源变量与配置
```

[App][app] 负责基础设施初始化；[MainActivity][main] 的主导航明确含独立 RSS 页面。搜索、详情、阅读、源编辑等再进入各自 Activity。

这不是严格的 Clean Architecture：ViewModel、model、help 中都有编排；`ReadBook` 等是持有运行状态的全局对象，部分调用直接访问 `appDb`。iOS 应对齐可观察行为，不复制其依赖方式。

| Android 区域 | 用途 | iOS 对应归属 |
| --- | --- | --- |
| `A/ui/` | Activity、Fragment、ViewModel、自定义视图 | `Y/Modules/Features/` |
| `A/model/webBook/` | 在线书抓取流程 | `Y/Modules/Core/BookSource/`、`Modules/Services/Online/` |
| `A/model/analyzeRule/` | 规则/URL解释器、流程变量 | `Y/Modules/Core/RuleEngine/ModernParser/` |
| `A/model/rss/` | RSS 请求、列表/正文解析 | `Y/Modules/Services/RSS/` |
| `A/data/entities/`、`dao/` | 持久模型、查询与观察 | `BookStore`、`BookChapterStore`、`RSSStore` 等服务 |
| `A/help/source/`、`BaseSource` | 源身份、JS 库、配置与状态 | `BookSourceSession`、`SourceScriptHost`、运行状态 store；RSS 不能只创建空 JS 引擎 |
| `A/service/` | 缓存、音频/TTS、Web/MCP、自动任务的运行载体 | iOS 对应服务及系统生命周期管理，不能直接等同后台能力 |
| `A/api/`、`A/web/` | 对外控制器、HTTP/WebSocket/MCP | `LanWebServer` 目前只有少量只读能力，非等价实现 |

## 3. 先分清四套“类型”

| 类型域 | 值 | 不能混淆的原因 |
| --- | --- | --- |
| [BookSourceType][book-source-type] | 0 文本、1 音频、2 图片、3 文件、4 视频 | 源的内容类型，不是 HTTP/WebView 传输开关 |
| [BookType][book-type] | 位标记：4 视频、8 文本、32 音频、64 图片、128 Web 文件；另有本地、压缩包、临时书等位 | 一本书的类型/状态，不能直接赋值自 `bookSourceType` |
| [SourceType][source-type] | 0 书源、1 RSS 源 | 在数据库和媒体入口中选择源家族，不表示音频或图片 |
| `RssSource.type` / `RssArticle.type` | 0 网页、1 图片、2 视频 | 条目播放路由；0 网页照样可以内嵌图像和视频 |

新 iOS 路由应使用有名称的类型映射，不把上述 Int 原样透传到同一个 switch。

## 4. 持久化：身份比字段数量更重要

[AppDatabase][database] 当前 schema 版本为 113，使用 `legado.db`。已启用 `allowMainThreadQueries()` 是基准事实，不是应复制到 iOS 的做法。

| 对象 | Android 身份/关系 | 对齐注意点 |
| --- | --- | --- |
| `BookSource` | 主键 `bookSourceUrl` | 也是源运行状态的重要定位值；不要因导入而改变源身份 |
| `RssSource` | 主键 `sourceUrl` | 要与同 URL 的书源区分源家族 |
| [Book][book] | 主键 `bookUrl`；`name + author` 有唯一索引；`origin` 指向源 | 换源/去重不能只看 iOS 新 UUID |
| [BookChapter][chapter] | 主键 `url + bookUrl`；`bookUrl + index` 唯一；随书籍级联删除 | 目录索引、URL、卷标记及变量都影响后续读取 |
| [RssArticle][article] | 主键 `origin + link + sort` | 同一链接在不同分类可以是不同条目，不能仅按 URL 去重 |
| `RssStar` / `RssReadRecord` | 收藏和历史各有模型，保留源、类型、进度等 | 不能只迁移一个“收藏=true”字段而丢失可重新打开的数据 |
| `BookGroup` / `Book.group` | 分组 ID 与书籍分组位掩码配合 | Android 可按位添加分组；iOS 的单个 `group: String` 不天然等价 |
| [BookProgress][progress] | 书名、作者、章节索引、章内位置、时间、章节标题 | 不要用全书百分比或屏幕页号替代 |

Android `durChapterPos` 注释定义为首行字符位置；具体还受标题、净化和格式影响。迁移到 iOS `(spineIndex, charOffset)` 时必须用内容/章节锚点验证，不能直接复制数值。

## 5. 状态生命周期

| 状态 | 归属/入口 | 生命周期要点 |
| --- | --- | --- |
| 阅读中的当前书、目录与排版页 | `A/model/ReadBook.kt` | 当前阅读会话，不是全部持久书库 |
| 源变量、源自定义变量、登录数据 | [BaseSource][base-source] → [CacheManager][cache] | 源 key 命名空间；有持久化，不应在每次请求后重置 |
| URL/规则流程变量 | `RuleData`、书籍/章节/文章的 `RuleDataInterface` | 随流程上下文传递；详见书源文档 |
| 共享 JS 库与脚本全局状态 | `SharedJsScope`、`BaseSourceExtensions` | JS 库复用与源级可变状态隔离是两件事 |
| Cookie | `A/help/http/CookieStore.kt`、`CookieManager.kt` | 手动 Cookie、自动捕获、WebView Cookie 都要考虑 |
| 章节内容 | [BookHelp][book-help]、`book_cache` 文件 | 与 Room 目录信息分开；删缓存不能等同删目录 |
| 内容写回世代 | `BookHelp` 的 `ContentSaveToken` / 写入校验 | 防止旧网络结果覆盖更新/手工编辑后的正文 |
| RSS 翻页请求 | `RssPaginationState` | requestId 区分当前与过期结果，失败不能提前推进页码 |
| 源删除 | `SourceHelp.delete*` | 不止删源行：清源变量、共享状态；删 RSS 源还清其条目 |

迁移/对齐时必须注明状态 owner 和生存期，而不是统一塞进一份全局字典或缓存。

## 6. 阅读、缓存与媒体的边界

```text
在线书正文：WebBook → BookContent → BookHelp（内容缓存）
文本阅读：ReadBook → ChapterProvider / TextChapterLayout → TextPage → ReadView / PageView
漫画：ReadManga → WebBook / BookHelp → 图片列表与图片加载
音频：AudioPlay → WebBook 正文结果 → 播放 URL → AudioPlayService
视频：VideoPlay → 书源或 RSS 的内容流程 → 带请求上下文的媒体地址 → 视频播放器
TTS：BaseReadAloudService → 系统 TTS 或 HttpReadAloudService
```

`A/service/CacheBookService.kt` 是缓存任务运行载体，会补书籍信息/目录；内容写入和读缓存要继续追到 `BookHelp`。`ExportBookService` 另负责 TXT/EPUB/PDF 组装，下载完成不等于已有导出功能。

iOS 不必替换 CoreText：应在内容供给、身份和状态边界接入。Android 的后台 Service 运行语义不能直接作为 iOS 的验收承诺。

## 7. 周边系统：从哪里继续追

| 系统 | 基准入口 | 后续检查重点 |
| --- | --- | --- |
| 声明式/JS 源导入 | `A/ui/association/ImportBookSourceViewModel.kt`、`ImportRssSourceViewModel.kt` | JSON/URL/脚本分流、去重、保留用户字段、确认后提交 |
| 源调试与校验 | `A/model/Debug.kt`、`CheckSource.kt` | 调试上下文、失败阶段；不要把“抓到列表”当作正文通过 |
| 规则订阅更新 | `A/model/RuleUpdate.kt`、`A/ui/main/MainViewModel.kt` | 到期检查、版本比较、静默合并或待确认；不是 RSS 内容刷新 |
| 全量备份恢复 | `A/help/storage/Backup.kt`、`Restore.kt` | 分类数据、配置、媒体、敏感状态保护与恢复前处理 |
| WebDAV 进度 | `A/help/AppWebDav.kt` | `BookProgress` 协议；进度文件按规范化书名/作者命名，不等于整包备份 |
| 自动任务 | `A/model/AutoTaskRunner.kt`、`A/service/AutoTaskScheduler.kt` | 任务持久化、执行日志、到期调度与中断 |
| 字典 | `A/data/entities/DictRule.kt`、`A/ui/dict/` | URL 规则 + 显示规则，不是 AI 查词 |
| 替换/高亮 | `A/help/book/ContentProcessor.kt`、`A/data/dao/ReplaceRuleDao.kt`、`A/ui/highlight/` | 标题/正文/源作用域，排除范围与应用时机 |
| HTTP/WebSocket | `A/web/HttpServer.kt`、`WebSocketServer.kt`、`A/api/controller/` | 与 App 共用真实模型/调试引擎，包含写操作 |
| MCP | `A/web/mcp/McpToolServer.kt`、`A/service/McpService.kt` | 保存/调试/校验源，执行 JS，读写 Cookie；必须分别审查授权 |

### 发现的两个文档陷阱

- `RuleSub` 的旧字段注释把替换规则类型写为 3，而当前 `RuleUpdate.cacheSource` 的执行分支为 **2**。协议对齐必须核对实际消费者和导出样本。
- `RuleSub` 虽有 `js/showRule/sourceUrl` 字段，当前自动更新路径 `RuleUpdate.cacheSource` 是直接 HTTP 获取并解析；不能仅凭字段存在声称自动更新执行了这些脚本。其他入口需要另追。

## 8. 建议的 iOS 接入原则

1. 在线内容仍进入 `BookSourceFetcher` / `OnlineReadingPipeline`，阅读位置与文件缓存继续由现有 store 管理。
2. 规则引擎复用 `ModernRuleEngine`；源脚本沿 `BookSourceSession` / `SourceScriptHost` 串行执行，不另起临时上下文体系。
3. RSS 复用公共能力但保留 RSS 自己的实体和工作流，不能简单把所有 RSS 转成 `BookSource` 后丢掉分类、网页配置和条目变量。
4. 加入类型/备份支持时先定义身份、导入幂等性和冲突处理；单独验证非当前阅读书、缓存命中和重新启动。
5. 把“正确实现”和“Android 历史兼容行为”分开；任何安全例外、退化或替代行为要明确记录。

[settings]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/settings.gradle
[app-build]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/build.gradle
[book-module]: https://github.com/LegadoTeam/legado/tree/330e606c4d57e08adc056ff8ab7a4132c784da9a/modules/book
[web-package]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/modules/web/package.json
[rhino]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt
[app]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/App.kt
[main]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/ui/main/MainActivity.kt
[database]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/AppDatabase.kt
[book-source-type]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/constant/BookSourceType.kt
[book-type]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/constant/BookType.kt
[source-type]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/constant/SourceType.kt
[book]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/Book.kt
[chapter]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/BookChapter.kt
[article]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/RssArticle.kt
[progress]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/BookProgress.kt
[base-source]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/data/entities/BaseSource.kt
[cache]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/help/CacheManager.kt
[book-help]: https://github.com/LegadoTeam/legado/blob/330e606c4d57e08adc056ff8ab7a4132c784da9a/app/src/main/java/io/legado/app/help/book/BookHelp.kt
