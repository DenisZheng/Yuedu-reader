# S6：规则网页与资源/媒体闭环

当前结论：本地门槛通过，提交 `9e9c9837`、`5e6e06e2`。用户随后确认真机视频画面和声音正常，并要求暂停真机测试、继续 S7–S8；以下各批次按当时状态保留，当前未验证项以“第六批与阶段结论”为准，不把模拟器证据外推为发布通过。

前置已完成并归档Push：S5 `a60f9d45`；手动IPA修复与云端成功证据 `129f3dea`；当前27.2媒体环境复验 `5453b7b7`。按用户要求自动进入S6，不把下面的局部通过记为阶段完成。

## 首批实现：规则文档展示

目的为原生导航中的订阅阅读：点击文章后保留源定义的交互内容，用户主要操作仍是阅读、滚动、查找、收藏/分享与返回。保持现有NavigationStack/inline标题和原生WebKit，不增加另一套浏览器界面或播放器。

- `RSSOpenTarget.articleHTML` 与启动页HTML明确区分；只有显式规则文章走受控规则文档，普通Feed（包括只做Legado导入的标准Feed）继续既有净化文章路径。
- `RSSRuleWebDocument` 在共享脚本执行器中准备大HTML，不在View.body解析DOM。保留脚本、事件属性、iframe和相对地址，按基准合同插入style/default CSS；启动页独立使用startStyle/startJs，不把startJs执行到文章里。
- `RSSSourcePageWebView` 复用首文档、启动页和规则正文的生命周期。preloadJs在主frame documentStart执行；页面脚本随后执行；injectJs等主导航完成后执行。enableJs=false同时禁止内容脚本和源注入，不需要为了保存滚动进度重新开启JS。
- loadWithBaseUrl开关实际决定HTML文档基址；每个页面实例使用nonPersistent WebKit数据空间，完整Cookie同步/认证策略留下一节，不能把隔离当作登录已可用。
- 页面使用WKWebView原生查找；滚动恢复由原生UIScrollView实现，等待真实contentSize信号而不是sleep。手势结束/离开时提交RSSStore，滚动中不向大View发布每帧状态；恢复尚未完成时不将0覆盖原进度。
- 导航对象与generation拒收旧完成回调；关闭时取消准备/注入任务、停止加载、移除脚本及尺寸观察。脚本异常显示脱敏的“来源网页脚本执行失败”，不把源异常文本写入UI/日志；现有原生页面加入重试动作，保留44pt最小点击区。
- 新规则文档与启动页有Preview；五语新增异常文案各4014键通过。普通文章的主题/安全渲染器未放宽。

基准入口：固定Legado `ReadRssViewModel.clHtml/loadStartHtml`、`ReadRssActivity` 的content/html observer和onPageFinished；按合同独立实现，不复制Android运行时或新增Java系统接口。

## RED → GREEN与实际页面证据

`RSSRuleWebTests` 走真实RSSArticleReaderView/生产WebKit及临时RSSStore，不只测HTML字符串：

1. 规则description保留可点击按钮、实际iframe请求；preload→页面→finished顺序；子frame没有preload；不会额外抓原文章。
2. enableJs=false仍显示HTML/源CSS，页面脚本、onclick与源注入均不执行。
3. 普通Feed即使标记Legado导入也不执行原始脚本/iframe。
4. 规则文章禁用JS时恢复300px、原生滚到600px后写回，重建Store仍为600px。
5. 启动页的startStyle优先及startJs阶段、baseURL开关。
6. injectJs失败明确报错且不泄露合成异常文本；配置切到enableJs=false重新加载时不残留旧preload/页面脚本。

- 原净化路径RED：`/tmp/readerfork-s6-rule-doc-red.xcresult`，3项测试、5个issues。
- 滚动首次RED：`/tmp/readerfork-s6-scroll-red.xcresult`，3个issues。仅在didFinish恢复仍失败1项（contentSize尚未到达）；改为观察尺寸实际信号后通过，没有增加固定延迟。
- 首版新增测试曾把WebView实例出现误当文档/完成注入已就绪；改为等待真实readyState/本用例finished结果。另一次测试编译因private嵌套@Observable类型的宏扩展不可见而失败，只修正测试类型访问级别。

最终局部回归（正常Reader-Fork-Dev、Xcode27.2 / SDK27.2、iOS27.2(24B8117)）：

| 设备 | S6规则文档 + 既有页面 + AX | S5完整回归 |
| --- | --- | --- |
| iPhone18 Pro Max | 22项/3 suites/0失败跳过，`/tmp/readerfork-s6-first-rule-iPhone.xcresult` | 268项/38 suites/0失败跳过，`/tmp/readerfork-s6-first-s5-iPhone/tests.xcresult` |
| iPad Pro13-inch(M5) | 22项/3 suites/0失败跳过，`/tmp/readerfork-s6-first-rule-iPad.xcresult` | 268项/38 suites/0失败跳过，`/tmp/readerfork-s6-first-s5-iPad/tests.xcresult` |

命令：`scripts/validate_reader_fork_s5.sh`；专项通过 `scripts/xctest.sh` 选择 `RSSRuleWebTests`、`RSSOpeningViewTests`、`RSSToolbarVoiceOverTests`，使用上表resultBundlePath。未重复独立build/clean，也未改DerivedData。

## 第二批实现：首文档响应合同与网页撤销

### 请求与状态边界

- `ModernParserBridge.prepareRuleWebRequest` 返回跨执行器的值快照：准备好的URLRequest、charset/bodyJs和流程变量，不携带JS对象。网络之后复用同一`finishFetch`响应半段，不再求值动态URL或重复POST。
- `RSSOpenTarget.RequestContext` 额外保留原文章title/link/category、变量、owner/请求票据与凭据修订。响应阶段重新建立该文章的RuleData/rssArticle；loginCheckJs/bodyJs使用当前流程bindings，同源两篇文章并发也不互串或把文章变量塞入源变量。
- 错误HTTP响应先进入loginCheckJs，再判断检查后的状态；未处理的403仍报错。文本按共享解码器处理后以UTF-8交给WebKit；Big5源声明优先于错误的HTTP charset。没有对二进制主文档重新做UTF-8编码。
- 准备目标在加载前和取得同源turn后都校验owner票据/凭据修订。实际复现：只在排队前检查时，同源其他流程通过CAS刷新凭据会让旧请求继续发出；发送边界重验后不产生HTTP请求。旧凭据目标不能被当作可安全重放的请求。

### 已加载文档的撤销

- 页面复用RSSStore登记的RSSRuntimeState撤销回调；登录、配置、外部变量和删除使已加载文档停止并换成无脚本空文档，而不只是stopLoading。直接LoginManager凭据修改也通过现有通知检查当前授权；不监听全库发布、不轮询Store、不另建持久状态。
- 分离页面权限的accessGeneration与每次导航的generation。普通网页自身导航后，撤销登记仍覆盖新文档；旧导航/注入完成不能恢复页面或写滚动进度。
- owner身份是文档生命周期的一部分，相同source/HTML切换owner也重建文档和登记。这只验证文档/状态owner，不宣称Cookie完整隔离/同步已完成。
- 注入前后、导航与进度提交检查有效性。生产dismantle移除观察/回调/脚本后主动替换旧JS realm，避免WKWebView仍被持有时继续运行旧文档。文档级释放不替代AVPlayer、实际音视频和后台竞争验收。
- 新撤销提示走五语localized；各Localizable.strings现4015键。认证变化要求重新打开，完整重新授权/重试流程仍在下方门槛内。

### 可失败反馈

全部固定响应和脚本为自建合成数据，未执行私人源包脚本：

| RED证据 | 实际失败及修正 |
| --- | --- |
| /tmp/readerfork-s6-web-request-red.xcresult | 2项/4 issues；charset/bodyJs与200/403登录检查未贯穿生产首文档，改为共享响应半段 |
| /tmp/readerfork-s6-web-revocation-red2.xcresult | 1项/12 issues；Store的四种撤销后旧DOM/JS仍存在，接运行时撤销 |
| /tmp/readerfork-s6-web-login-revision-red.xcresult | 1项/3 issues；直接凭据修订未撤销页面，接现有登录通知 |
| /tmp/readerfork-s6-web-boundary.xcresult | 原文章bodyJs缺rssArticle绑定而scriptFailure；同时测试失败清理额外报513。补共享响应bindings，异常退出先flushPersistence；未修改生产权限 |
| /tmp/readerfork-s6-web-navigation-revocation-red.xcresult | 2项/2 issues；导航generation改变后撤销回调失效，分离权限生命周期 |
| /tmp/readerfork-s6-web-owner-red.xcresult | 3项/2 issues；owner切换未重载/登记，加入owner身份判断 |
| /tmp/readerfork-s6-web-teardown-red.xcresult | 4项/2 issues；stopLoading保留已完成的JS realm，拆除时清空文档 |
| /tmp/readerfork-s6-web-queued-credentials-red.xcresult | 5项/2 issues；排队期间CAS刷新凭据后旧请求仍发送，取得turn后再次校验 |

首次撤销测试曾用错removeSource接口而编译失败；这不是行为RED，改为实际removeSources接口后才复现。早期专项写过不存在的AnalyzeUrlResponseBodyTests筛选器，不能计为该suite通过；最终改选AnalyzeUrlTests，并从xcresult树确认32项真实执行。

### 最终双设备专项与回归

正常Reader-Fork-Dev宿主、动态解析Xcode27.2/SDK27.2，官方iOS27.2(24B8117)；没有独立build/clean、修改DerivedData或清理用户数据。

| 设备 | 本批专项与共享响应回归 | S5完整回归 |
| --- | --- | --- |
| iPhone18 Pro Max | 63项/6 suites/0失败跳过，/tmp/readerfork-s6-request-lifetime-final-iPhone.xcresult | 268项/38 suites/0失败跳过，/tmp/readerfork-s6-request-s5-final-iPhone/tests.xcresult |
| iPad Pro13-inch(M5) | 63项/6 suites/0失败跳过，/tmp/readerfork-s6-request-lifetime-final-iPad.xcresult | 268项/38 suites/0失败跳过，/tmp/readerfork-s6-request-s5-final-iPad/tests.xcresult |

专项实际执行：RSSRuleWebTests(6)、RSSWebRequestTests(5)、RSSWebInvalidationTests(4)、RSSOpeningViewTests(6)、RSSToolbarVoiceOverTests(10)、AnalyzeUrlTests(32)。各suite的用例节点与零失败/跳过均经xcresulttool核验。63与268存在既有用例重叠，不相加宣称独立覆盖数量。

命令（重放需使用尚不存在的resultBundlePath）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)" # iPad用dest iPad
bash scripts/xctest.sh -l /tmp/readerfork-s6-request-lifetime-final-iPhone.log -- \
  -resultBundlePath /tmp/readerfork-s6-request-lifetime-final-iPhone.xcresult \
  -only-testing:'yuedu appTests/RSSRuleWebTests' \
  -only-testing:'yuedu appTests/RSSWebRequestTests' \
  -only-testing:'yuedu appTests/RSSWebInvalidationTests' \
  -only-testing:'yuedu appTests/RSSOpeningViewTests' \
  -only-testing:'yuedu appTests/RSSToolbarVoiceOverTests' \
  -only-testing:'yuedu appTests/AnalyzeUrlTests'
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s6-request-s5-final-iPhone bash scripts/validate_reader_fork_s5.sh
```

补充检查：五语本地化、git diff --check、原包SHA-256与基准一致。测试提供了编译证据，不触发云构建。当前两批均未提交/Push，S6仍不放行。

回滚本批时同步撤回共享bridge的准备/响应值快照、RSS请求context、WebKit权限生命周期及对应测试/五语文案；不改持久格式、不删除凭据/RSS状态，不撤回S5和前置归档。

## 第三批：有限网页动作、Cookie生命周期与生产图片资源

此批仍是S6局部实现，**不是S6阶段放行**。未执行原始源包脚本，所有HTTP/WebKit输入均为本地合成fixture。

- 导航拦截按固定Legado的shouldOverrideUrlLoading执行一次；未拦截的同源主导航复用共享请求/响应及文章上下文。页面仅有有限source值操作及原生动作意图，校验随机协议名、严格JSON、主frame、精确origin、可见/前台状态与请求票据；不提供解析器java的任意执行/文件/请求能力。动作路由模型已开始实现，搜索/分类/登录/照片/加书等真实原生目的页尚未全部接线验收。
- 每个非持久WebKit空间使用RSSWebCookies同步，保留domain/path/Secure/HttpOnly/过期信息；同源导航保留当前会话，不同owner/源/origin/凭据修订重置。网页改Cookie与注销回写共享CookieStore，原生图片响应Cookie也传回WebKit，实际后续fetch携带HttpOnly Cookie但document.cookie不可见。
- 先复现旧凭据响应绕过授权写Cookie，再关闭RSS请求的系统自动接收，由共享SourceRequestExecutor在源有效性及凭据修订的短临界区内提交。源凭据CAS与active检查也在同一临界区，文件落盘不在Cookie授权锁内。
- 进一步复现过期/会话Cookie通过旧扁平快照复活，以及响应为无关域种Cookie。现将有属性的根Cookie退休同名扁平值，系统jar保留真实属性；响应Cookie通过系统临时jar的setCookies(for:mainDocumentURL:)校验域/公共后缀，不把HTTPCookie构造成功当作响应域通过。
- RSSImageService复用SourceScriptHost/ModernParserBridge的coverDecodeJs与AnalyzeUrl请求，不把RSS写入书源store，不建立第二份图片缓存。实际合成密文经源jsLib解码、UIImage离主线程准备，并到达生产WKWebView图片。
- 只有需要私有头/解码的图片换成已登记的reader-rss-image能力URL；没有接管http(s)，没有URLProtocol子资源拦截或无限制代理。私有头和Cookie只在批准的origin内使用；外站仅公开HTTPS图片，拒绝未批准的IP/本机地址，不带其他站点Cookie。初始img/picture srcset、JS懒加载src与动态innerHTML经同一注册管道；页面读取到的逻辑src/currentSrc仍是原URL。
- 图片请求最多4个在途、2048登记项，响应流式上限16MiB，位图最多3200万像素；关闭、导航或撤销取消scheme任务。源黑名单优先于白名单，支持前缀/全串、区分大小写；WebKit不能表达的Java正则明确报受限，原生匹配有ICU进度预算。合法过滤返回空子资源，不误报整页失败。
- 网页图片的Cookie遵循浏览器生命周期；type=1原生请求仍保留源的Jar开关。Jar关闭不禁止浏览器Cookie或显式认证。当前图片管道只验证位图；SVG、CSS背景/复杂框架资源、生产type=1查看器/附件和音视频仍不能据此宣称完成。

### 新的可失败证据与限制

| 证据 | 结论 |
| --- | --- |
| /tmp/readerfork-s6-cookie-authorization-red2.xcresult → /tmp/readerfork-s6-cookie-authorization-green2.xcresult | 真实HTTP响应到达前改变凭据，旧响应不得写Cookie；302的path/开关合同一并验证 |
| /tmp/readerfork-s6-cookie-expiry-red.xcresult | 2 issues：过期及会话Cookie的扁平回退复活；退休旧值后原用例通过 |
| /tmp/readerfork-s6-cookie-response-domain-red.xcresult | 无关域Cookie被接收；改用系统响应域校验后原用例通过 |
| /tmp/readerfork-s6-web-images-red4.xcresult、/tmp/readerfork-s6-web-images-srcset-probe.xcresult | 1px测试图在2x候选的naturalWidth按密度修正为0，属fixture断言错误，不是资源方案失败；改为4px图并断言4/2，未改生产逻辑或放宽断言 |
| /tmp/readerfork-s6-cookie-image-flow-green.xcresult → /tmp/readerfork-s6-cookie-image-flow-green2.xcresult | 图片响应Cookie没有到达WebKit，分开浏览器与原生Jar生命周期并做增量同步后，后续真实fetch带HttpOnly Cookie通过 |

编译期还修正测试private嵌套Observable宏及await/throw在expect宏内的推断问题；这些编译失败不算行为RED。图片HTML/检查/展示准备、消息JSON均有main=false的SourcePerfTrace，未进行全库规模性能/内存阶段验收。

### 双设备局部回归

正常Reader-Fork-Dev、动态解析Xcode27.2/SDK27.2、iOS27.2(24B8117)，串行执行，无新增DerivedData/build/clean：

| 设备 | Cookie/导航/网页图片/原网页合同 | S5共享回归 |
| --- | --- | --- |
| iPhone18 Pro Max | 32项/7 suites，/tmp/readerfork-s6-image-cookie-iPhone.xcresult | 268项/38 suites，/tmp/readerfork-s6-image-cookie-s5-iPhone/tests.xcresult |
| iPad Pro13-inch(M5) | 32项/7 suites，/tmp/readerfork-s6-image-cookie-final-iPad.xcresult | 268项/38 suites，/tmp/readerfork-s6-image-cookie-s5-final-iPad/tests.xcresult |

均零失败、零跳过。32项实际选择RSSWebImageTests(4)、RSSImageServiceTests(3)、RSSWebNavigationTests(5)、RSSWebRequestTests(5)、RSSWebInvalidationTests(4)、RSSRuleWebTests(6)、RSSCookieAuthorizationTests(5)。命令沿用scripts/xctest.sh及scripts/validate_reader_fork_s5.sh，iPad使用scripts/sim.sh dest iPad；不把与268项重叠的用例相加。五语4020键通过，原包哈希/Android基准未变，git diff --check通过。

回滚本批需一起撤回有限动作桥、Cookie适配/共享执行边界、图片能力scheme和对应合成测试；保留既有Cookie/RSS数据，不恢复已证实不安全的自动Cookie接收或扁平回放作为成功方案。当前S6仍不提交为完成，不Push、不触发云归档。

## 第四批：原生动作、附件/type=1/2媒体与showWebLog（局部通过，S6未放行）

- 媒体改走 `RSSMediaResourceSession`：只绑定127.0.0.1的单次播放端点，随机capability只索引根资源和HLS清单列出的资源；私有头/Cookie按目标origin与path在原生侧附加，AVPlayer收到的headers为空，修复S1记录的asset级私有头跨host传播问题。这是新增的有界本地端点，不是通用代理：拒绝Origin头、未知路径和未批准origin，停止后端口关闭。
- 进度由RSSStore按文章+附件key持有，签名URL变化不改变身份；未开始播放就关闭不再把已有进度写成0（RED：/tmp/readerfork-s6-media-owner-red.xcresult）。
- 普通Feed带附件不再被改成type=1/2入口（同一RED）；附件从文章菜单主动打开。type=1/2按Legado ReadRss/VideoPlay：ruleContent为空用文章链接，否则取正文结果并补全相对地址。
- Range边界：416原先被报成502（RED：/tmp/readerfork-s6-media-resource-contract-red.xcresult），现透传总长。
- showWebLog按源开关安装console记录，脱敏、限200条；登录页不安装。
- 登录完成读取DOM时遇到POST后的文档切换窗口，documentElement为空会抛JS异常；现明确报未就绪。测试侧将这一种错误视为继续等待，其余错误仍失败；连续5轮通过（/tmp/readerfork-s6-login-repeat.xcresult）。

### 门槛结果

`scripts/validate_reader_fork_s6.sh`，正常Reader-Fork-Dev，Xcode/SDK 27.2，iOS 27.2(24B8117)模拟器：

| 设备 | S5回归 | S6专项+媒体PoC |
| --- | --- | --- |
| iPhone 18 Pro Max | 268项/38 suites | 73项/14 suites，/tmp/readerfork-s6-gate-iPhone |
| iPad Pro 13-inch(M5) | 268项/38 suites | 73项/14 suites，/tmp/readerfork-s6-gate-iPad |

均零失败零跳过；两组用例有重叠，不相加。

### 仍未完成

- 未实现：cacheFirst（当前为nonPersistent数据空间，字段未生效）。
- 未自动验证：播放页/type=1/2页面的SwiftUI真实点击路径（媒体测试直接驱动controller）；播放竞争、前后台、重启后实际续播、签名过期重新解析；SVG/CSS等复杂资源；新页面的深色、最大Dynamic Type、VoiceOver走查。
- 已知限制：单个上游响应上限16MiB，不支持Range的大MP4会失败；HLS外站资源仅允许公开HTTPS；loopback端点在后台/画中画及真机ATS下的行为未验证。
- 硬件阻塞：真机显示available (paired)，但本机codesigning身份为0，无法签名安装；iOS 17、DRM、真人登录、正式签名同样未验证。

## 第六批与阶段结论：S6本地阶段通过

- 签名地址过期：type=1/2文章的播放器持有ruleContent重算回调；AVPlayerItem失败时重新求值一次，取得新签名和新资源会话，从当前进度继续（先解除旧会话的撤销回调再停止）；再次失败只报错。手动重试本身算一次重算，不叠加自动重算。普通Feed附件和脚本链接没有可重算的来源，保持原地址并报告失败（与Legado每次打开重新getContent的语义一致；Legado本身没有播放中自动重算）。测试：`RSSMediaPlaybackTests/expiredSignedURLReResolves`。
- SVG/CSS：资源管道识别根元素为svg的XML，以image/svg+xml交给`<img>`；图片上下文中的SVG脚本不执行（测试断言）。原生图片查看器对SVG明确报“受限”，不当成解码失败。外部CSS由WebKit原生加载，不继承源私有头（测试断言）。管道模式下CSS中的背景图不经过私有头/coverDecode，这是已披露的限制。
- explore动作：确认→原生发现页→按目标书源的规则和请求头实际取书并显示；取消不发请求；待确认期间重复触发被拒绝。
- 视觉/AX：新增`RSSS6VisualAccessibilityTests`，类型化文章、图片和动作错误三个状态在深色/浅色+AX5下断言VoiceOver可读出标题/说明/操作按钮，且按钮在屏幕内。走查发现动作错误浮层在AX5下截断，已修复为全宽、可换行。截图位于/tmp/readerfork-s6-visual。
- 门槛：iPhone/iPad各S5回归268项 + S6专项97项（19 suites），零失败零跳过（/tmp/readerfork-s6-gate4-*）。真机iPhone 17 Pro已跑92项通过，用户也手动确认了视频画面和声音。
- 仍未验证（移交S8发布门槛）：iOS 17（本机没有该runtime，安装需另行批准）、DRM、真人登录、真实网站源、iCloud/App Group签名构建、真人VoiceOver实际使用。

## 第五批：cacheFirst、页面级媒体与真机（局部，S6仍未放行）

- `cacheFirst`：`RSSWebDocumentCache` 只覆盖首文档，对应Legado的 LOAD_CACHE_ELSE_NETWORK。key包含源、URL、认证头和Cookie；命中时不发网络请求，也不重放Set-Cookie。no-store、非200和登录检查失败的响应不写入缓存。缓存位于Caches目录，上限32MiB，按修改时间淘汰。WebKit子资源仍由系统处理。测试fixture原本对所有响应强制no-store，已改为路由可以覆盖。
- 页面级媒体：type=2文章经真实 `RSSArticleReaderView` 进入播放器，实际推进、离开后写入进度、重开继续播放；凭据撤销后播放器停止。
- 前台限定：切后台时暂停并保存进度，锁屏命令不会重新开始，回前台不自动续播，RSS媒体不开画中画。Legado的后台播放依赖用户主动开启的悬浮窗服务，按产品决定不移植。
- 真机启动崩溃：无iCloud能力的签名下，`CKContainer(identifier:)` 在启动阶段触发陷阱（5份设备崩溃日志栈一致）。新增编译条件 `READER_FORK_NO_ICLOUD`：该条件下不创建容器，账号状态视为restricted，所有CloudKit调用抛出账号不可用，状态文案为“此版本未啟用 iCloud”；本地阅读不受影响。正常构建行为不变。
- 测试fixture在真机上改为从测试bundle读取（`VideoStillFixtures`）；原先使用的 `#filePath` 在真机上指向不存在的Mac路径，导致首轮真机失败14项。

### 真机证据（iPhone 17 Pro，iOS 27.2，免费个人团队签名，无iCloud和App Group权限）

- 命令：`READER_FORK_TEAM=<team> READER_FORK_DEVICE=<udid> bash scripts/device_dev_test.sh <suites>`
- S6专项与媒体/资源PoC共18个suite：**92项全部通过，零失败零跳过**，证据 /tmp/readerfork-device-s6.xcresult。覆盖真实AVPlayer的MP4/HLS/音频seek与推进、loopback资源会话的Range/HEAD/凭据作用域、WebKit资源与CORS、页面级播放与撤销、cacheFirst。
- 未覆盖：真人操作的观感和声音、真实网站源、iCloud/App Group、iOS 17、DRM。

### 模拟器门槛

`scripts/validate_reader_fork_s6.sh` 已扩展到18个S6 suite。iPhone和iPad各通过S5回归268项和S6专项92项，证据 /tmp/readerfork-s6-gate3-*。iCloud相关回归另跑24项，全部通过。

## 早期未完成清单（历史，已由第五/第六批部分补齐）

- 有限动作桥已接生产WebKit并有组件行为证据，仍需逐个接通原生目的页、跨源确认和动作恰好一次的生产UI路径；组件通过不等于用户流程通过。
- 已撤销页面重新打开及完整原生重试（包括重新解析动态URL）；后续导航继续共享响应处理。已验证首文档charset/bodyJs/loginCheck，不等于后续导航全部完成。
- Cookie/域/path/注销与位图认证/解码已有生产资源证据，仍需扩展SVG、CSS/复杂框架资源、跨域/重定向与取消压力场景，并将受限情形接可视诊断；不把局部位图通过当成全部资源通过。
- type=1/2及附件接生产图片/视频/音频路径，稳定进度、重启、签名过期、Range/HLS、播放竞争、取消/前后台与释放。现有S1 PoC不替代这些项目。
- cacheFirst、showWebLog及源样式/网页错误的可视化诊断边界；不得泄露脚本正文/凭据。
- 新错误重试入口的实际点击、完整三态/深色/最大Dynamic Type截图和新网页VoiceOver内容走查；当前10项AX只证明既有工具栏，不冒充以上新场景。
- 最低iOS17、真机端到端媒体、DRM和登录/正式签名验收。当前只有模拟器证据，不能据此完成S6或推进S7。

本阶段尚未完成、尚未阶段提交/Push；不触发新的云IPA归档。回滚当前局部改动时撤回articleHTML路由、规则文档准备器与WebKit适配，保留S5和已归档的前置，不删除RSS状态/源文件。
