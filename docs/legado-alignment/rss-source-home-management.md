# 订阅首页、源维护与活性验证（2026-11-17）

## 交付范围与入口

按用户确认完成四项增量需求，不扩大RSS实源／发布阶段门槛：

1. **资源库移除RSS副入口**：删除`LibraryTabRoot`订阅卡片及其RSSStore观察；默认五Tab仍是探索｜书架｜订阅｜资源库｜设置，RSS通过独立订阅Tab进入。其他内部RSS目的地保留，不删除订阅数据。
2. **树型／方格切换**：订阅页“更多”中切换并保存选择；方格按用户选择平铺，顶部原生Picker筛选全部／未分类／某分类。保留现有源图标、未读数、源打开和长按操作，不复制Android样式或固定4列；列数随容器宽度和Dynamic Type变化。
3. **源级批量维护**：“更多 → 管理订阅源”进入原生List多选页；搜索名称／分类、全选当前列表、跨分类保留选择、取消全选、确认删除。无筛选时全选就是全库源，包含停用源；删除只作用于确认时的稳定源id，不删除分类，不自动清除用户实际数据。
4. **主动活性验证**：管理页可检查所选源；未选源时检查当前列表。先展示副作用／范围确认，允许取消。不同主机的普通 Feed 最多两条并行，规则、登录等来源仍串行。验证后按结果类型切页，HTTP 404、423、503 等状态码各自成页。切换结果页清空旧勾选，结果页的全选／反选受当前源分组和搜索范围限制。普通「全部」仍保留跨分组勾选。结果仅在本次管理页保留，不自动启用／停用／删除源。

`RSSStore`仍是源、文章和状态的唯一owner。批量删除直接复用`removeSources(ids:)`，清理文章／状态／源变量并撤销旧请求。没有新持久化格式、数据迁移、播放器或权限。

## 组件调研与决策

用户要求优先检索有星且仍维护的现成第三方组件，不能重复造轮子。实际检索了：

| 候选 | 检索证据 | 本次是否适用 |
| --- | --- | --- |
| [exyte/Grid](https://github.com/exyte/Grid) | 搜索结果约2.1k星，核心是CSS式跨格／密集布局；索引显示2026年仍有活动，但最后稳定tag较旧 | 本次只是等宽源图标方格，不需要跨行列功能 |
| [WaterfallGrid](https://github.com/paololeonardi/WaterfallGrid) | 搜索结果约2.6k星，核心是高度不等的瀑布流 | 不符合本次图标＋名称的规则方格 |
| [FeedKit](https://github.com/nmdias/FeedKit) | 搜索结果约1.35k星；[Swift Package Index](https://swiftpackageindex.com/nmdias/FeedKit)显示近期版本／活动 | 能解析标准Feed，不能执行Legado的singleUrl、startHtml、分类脚本、URL options和认证合同；本仓库已经有Feed解析和共享请求路径 |

Stars／维护时间是检索时的搜索／索引证据，不是假称实时GitHub元数据。尝试官方`api.github.com/repos/...`被工具的fake-IP／SSRF策略阻断，未换工具绕过、放宽内部地址或修改工具配置，因此没有独立确认精确当前Stars／最近提交。

通过Context7核查Apple官方[LazyVGrid](https://developer.apple.com/documentation/swiftui/lazyvgrid)、[GridItem.adaptive](https://developer.apple.com/documentation/swiftui/griditem/size-swift.enum)、[List多选](https://developer.apple.com/documentation/swiftui/list)：系统已提供懒网格、自适应列和Set(id)多选。本轮直接复用这些现成组件，不自写布局／选择引擎，也不为已经具备的能力增加第三方依赖。项目既有Nuke／SwiftSoup等依赖保持不动。新增代码仅是RSS显示投影和活性检查用例，不是通用解析器或第二套缓存。

## 活性验证合同

Android固定基准仍为`330e606c4d57e08adc056ff8ab7a4132c784da9a`，没有修改Android仓库。其RSS首页为GridLayoutManager／4列，管理页含选择／全选／删除；本轮RSS活性检查是Fork新增功能，不声称Android已有。

验证遵从真实RSS入口而非假设存在搜索：

| 类型 | 执行路径 | 结果含义 |
| --- | --- | --- |
| singleUrl | `RSSOpenTarget.resolve`计算动态URL → 共享首文档请求 | HTTP首文档可达；不是视频播放通过 |
| startHtml | 同一运行时计算HTML | 仅“启动页已生成（未验证网络）”，不冒充网络可达 |
| 列表规则 | 解析分类 → 首分类第1页 → 共享规则提取 | 有条目与合法空列表分开；不请求文章正文或下一页 |
| 标准Feed | 共享源请求 → 既有RSSFeedParser | 实际解析成功／空Feed，HTTP和解析失败分开 |
| 已知直接媒体URL | 不请求文件 | “媒体入口（需人工播放验证）” |
| 外部打开／认证／人工要求 | 不打开系统页面、不交互登录 | 需登录或人工验证，不标记失效或可用 |

未知类型只请求入口首文档，不加载网页子资源；若响应为audio／video／image则标为媒体入口。不能宣称对所有未知URL都零字节媒体传输，也不能把原生首文档成功外推为WebKit脚本／iframe或播放器成功。

- 单源整体截止30秒，临时session请求／资源超时12／20秒，无URLCache，沿原限流／共享JS执行器。仅明确静态 HTTP(S)、无规则或登录配置的标准 Feed 可用两个检查槽；按原队列启动，规则、登录、CookieJar 或不能确认的来源独占。一次检查批次内，主机名归一大小写和尾点、不按端口拆开；重定向等实际目标主机空出再继续，不重发入口、不改认证或目标校验。排队未启动不计入单源截止。截止sleep有明确超时目的，不是等UI稳定。
- 活性检查绕过RSS `cacheFirst`首文档缓存且不写该缓存：旧200不能掩盖当前503。
- 不调用搜索、发现用户操作、正文分页、媒体子资源加载或自动删除；不创建新的无状态JSContext。
- 源脚本的变量／认证副作用仍遵从正常运行时，确认文案明确告知；结果不写入文章、已读或播放器状态。
- 诊断票据可检查停用源，但保留`enabled=false`；普通读取票据仍拒绝停用源。诊断标记只由TaskLocal检查上下文设置，不暴露给源脚本；原配置修订、认证变化、删除和取消约束不变。
- 结果按源 ID 及配置、登录修订校验。改配置、改登录或删除后，旧结果不显示，也不能用于批选；重新检查时撤回本批旧结果，未检查或尚未轮到的源不进结果页。HTTP 401／403 仍是需登录或人工验证；其他 HTTP 失败按实际状态码筛选，无状态码的连接、超时和解析错误留在「验证失败」。在「HTTP 404」全选只取当前分组和搜索内的有效 404。失败只代表这次检查没通过，不等同永久失效；删除仍须确认，确认期间结果范围变化则要求重新选取。错误文案仅固定类别和状态码，不复制私有 URL、脚本、headers 或服务器正文。

## 实际验收

下方为原管理页验收；2026-11-28 的并行验活和按 HTTP 状态码批选见 [新增回归证据](validation.md#rss-验活提速与-http-状态码筛选2026-11-28)。

环境：本机动态解析的Xcode／iOS Simulator SDK27.2，iPhone 18 Pro Max和iPad Pro 13-inch (M5)，均iOS27.2；Swift language mode从本次编译日志实查为6。测试串行，复用`scripts/xctest.sh`与现有DerivedData；没有另做build／clean，没有以新缓存目录绕过错误。

### 合同测试：两端各28项

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-RSS-PoC bash scripts/xctest.sh \
  -l .artifacts/rss-source-home/iphone-contracts-accepted.log -- \
  -only-testing:'yuedu appTests/RSSSourceBrowseTests' \
  -only-testing:'yuedu appTests/RSSSourceHealthCheckerTests' \
  -only-testing:'yuedu appTests/RSSIdentityStateTests' \
  -only-testing:'yuedu appTests/DismissalSequencedPresentationTests'
```

iPad只改destination为`$(bash scripts/sim.sh dest iPad)`和日志名`ipad-contracts-accepted.log`。两端输出均为`Test run with 28 tests in 4 suites passed`及`** TEST SUCCEEDED **`。

覆盖：分类／搜索／未读筛选与身份、跨分类选择、只删所选源／保留分类、票据失效及重载；无搜索源首分类首列表／合法空、普通Feed、401／503、动态singleUrl优先、静态startHtml非网络结论、已知媒体不请求、cacheFirst不掩盖新失败、取消不继续下一源、删除后旧响应不留结果、整体截止，以及普通读取仍拒绝停用源。没有用真实用户源包作fixture。

### 原生UI：两端各4项

```bash
YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh \
  -l .artifacts/rss-source-home/iphone-ui-accepted.log -- \
  -only-testing:'yuedu appUITests/RSSSourceHomeUITests'
```

该次运行当时的3项UI：资源库无RSS副入口、树型／实际并列方格／分类筛选／重启记住布局；多选→取消→删2源→未选源仍在→全选删剩余→重启空库；活性确认／取消／生成结果、停用源未改动且没有文章落盘。iPhone／iPad各`Executed 3 tests, with 0 failures`和`** TEST SUCCEEDED **`。

随后增加黑暗模式＋AX5＋18个长名称源的最后一行测试，两端分别执行：

```bash
YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh \
  -l .artifacts/rss-source-home/iphone-accessible-grid.log -- \
  -only-testing:'yuedu appUITests/RSSSourceHomeUITests/testAccessibleGridReachesLastSource'
```

两端各1项通过／`** TEST SUCCEEDED **`：原生懒网格最后一行存在且可点击，VoiceOver元素保留完整名称，大字不靠缩小字体截断，截图保留。UI4项是两次命令覆盖的4个不同用例，不冒称最后一次整套4项执行。补充说明文案／store传递后，`management-copy-final.log`另跑iPhone活性确认1项通过，作为当前View编译与实际交互证据。

收尾发现新增回归文件名与既有`RSSSourceManagementTests.swift`相同，立即将新用例移动到独立`RSSSourceBrowseTests.swift`，原135行测试按HEAD逐字恢复，`git diff`退出0。补跑原5项JSON编辑／变量／调试与隐私／损坏变量保护，加新10项：两端各15项／3 suites通过，iPad最终日志`ipad-existing-management-retry.log`。集合与前述28项重叠，不相加为独立总数。iPhone命令外层曾超时，但日志实际已有最终`TEST SUCCEEDED`；iPad首轮worker准备超时、0测试，不记通过，同条件重跑才通过，未清模拟器或修改测试断言。

所有UI仅使用`-rss-store-dir`传入测试创建的临时库、停用源和本机地址；Debug路径开关不进入Release逻辑。没有删除或替换用户库、源包或模拟器数据。原入口相关UI测试已同步改走订阅Tab，不保留依赖旧资源库卡片坐标的入口。

### 过程失败与修正

- 首轮UI fixture缺少RSSSource合成Codable必需字段，源未加载、分类仍显示；补齐fixture，不降低生产解码合同。
- 布局切换测试把`-rss_source_home_grid NO`作为启动参数，该参数域压过AppStorage写入，导致菜单切换仍为树型。改为通过真实菜单设定初始布局，再验证切换／重启；没有在生产加入测试用延时或重置逻辑。
- 停用源活性UI无结果，收敛到正常`RSSStore.accepts`拒绝停用源。新增行为回归先失败（`disabled-probe-red.log`），再加入明确诊断票据和TaskLocal上下文；当前正常读取仍拒绝停用源，诊断不自动启用它，回归通过。
- 诊断票据修改后3次验证调用在module／SwiftCompile阶段超时，没有测试结果，不记通过。保持同一scheme／DerivedData继续完整编译，一次后台保留的同一wrapper最终`compiler-profile-run.log`实际1项通过，再完成上述双端28项。没有改Swift版本／并发设置／签名；CPU采样时目标frontend已结束，没有声称定位了编译器根因。
- 新增cacheFirst和直接媒体行为门槛，不把缓存命中／空结果／可达网页当作所有源或影片可用。

## 检查、未验证和回滚

本轮同步五种语言、DS布局tokens、根入口指南、两份设计skill和源／阶段证据。实际运行本地化、UTF-8／LF、相对链接、skill一致性、原始源包哈希／提交范围和`git diff --check`检查；`ruby scripts/check_localizations.rb`最终输出`Localization OK: Resources/*.lproj/Localizable.strings (5 files, 4285 keys)`，`git diff --check`退出0、无输出，两份设计skill逐字一致。31个提交候选的格式／相对链接、原始253/307源包哈希、既有测试保留和最终行为日志核查输出`RSS_SOURCE_DELIVERY_CHECK_OK files=31 sourcePackHashesUnchanged=true existingTestsPreserved=true finalEvidenceVerified=true`；真实源包与`.artifacts`不入提交。

未验证：真实307源批量活性、个人登录／验证码／购买、文章全文／音视频／DRM、iOS17 runtime、真机、人工VoiceOver、Release／IPA和正式签名。界面与固定行为验收通过不等于S8全部发布验收。API元数据被安全边界阻断，没有为此扩大权限。

回滚仅由操作员对本次提交`git revert`，撤回入口／布局／管理／诊断改动；无数据迁移，不清缓存、不删除数据、不回滚先前漫画或视频修复。用户明确授权自动提交Push及完成后关机；不触发或监控新的Actions、不发布。关机若被系统权限阻断，不更换通道绕过，不把未成功的关机写作完成。
