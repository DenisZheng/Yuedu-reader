# S8：分层实源与规模验收（自动回归通过，人工待验）

## 结论

目前完成原始包离线复核、307 RSS两页刷新规模测量、受控RSS列表/正文/状态流程，以及R014/R217各一张真实公开图片经生产`RSSImageService`下载、原生解码和状态重载。R217其余16个唯一图片目标未加载；R128受限首列表20条无图片目标后按边界停止。CookieJar开关、路径作用域的列表→图片条目→资源合成闭环已补齐。**S8整体尚未通过；已通过的自动回归不阻塞后续开发**。用户确认保留iframe/JS支持，将R265/R267真实播放转入#58人工验收；受限登录及设备/发布门槛同样未闭合，见[人工／发布清单](s8-release-checklist.md)。R146图片为外部证书链前置条件（未验收），audio-only间歇风险根因未定位、已转监控，二者不再阻塞阶段推进，见下节。

完整聚焦批次iPhone/iPad曾各37项/9 suites通过，增加R141真实MP3资源层播放/进度重载并修复RSS快速退出进度；后来媒体复验失败，失败证据仍保留。最新[同文件App/XCTest双设备对照](s8-audio-clock-diagnostics.md)均在0.5秒内推进，原本地音频、PCM和R141真实MP3随后两端各项通过；但旧间歇现象根因未定，不能认定永久修复或放行整个网页播放器。当前nonmedia manifest双设备各22项/5 suites通过，包含R128无图受控页；full现47项/12 suites且双端已整套通过；R141 MP3与R217图片列入full、nonmedia显式排除，R146图片单列外部前置条件、不属于任何模式的通过集。新[R217单张图片闭环](s8-r217-image.md)只证明固定网页的一张WebP；其余目标、R265/R267第三方iframe仍未验证。R146独立复验确认系统SSL -9814证书链时效失败，未修改TLS。B122新增实源对照：原词0个匹配节点/0条、源内检查词12节点/12条，见[B122记录](s8-b122-search.md)，仅算搜索页局部；B122旧fixture和动态参数边界仍为离线用例。S8不推广为整包或原规则网页完整播放通过。S8相关主工作区不安装手机；#58、书源漫画翻页#64与视频反复弹出#65继续单列，#73按用户复测正常关闭。

## 人工分流与Release准备（2026-11-14）

已本地提交`fdd60bd4`，未推送。用户确认R265/R267按“保留能力，转人工”处理：**生产iframe／JS和源配置不变，不新增禁用开关或全站代理，不自动放宽公网准入**；实源播放状态仍为未验证，归#58，不继续卡住无依赖开发。操作卡与剩余设备／签名／发布条件见[收口清单](s8-release-checklist.md)。这不是S8整体或发布通过。

当前提交的正常`Reader-Fork-Dev` **Release模拟器构建通过**，没有DEBUG条件；App与两个扩展平台／Fork身份／最低声明17.0核验通过，主二进制未发现调试音频宿主符号。证据`/tmp/readerfork-s8-release-preflight.gAUsSt/`。本机无iOS17 runtime，未安装手机、未归档或发布；Release编译不能替代这些门槛。

## #77/#78 生命周期调整与full门槛实跑（2026-11-14）

**按用户决定，两项不再作为S8的持续阻塞。** 根因调查、缺陷状态与阶段门槛分开处理：

- **#77 → 未定位的间歇风险，转监控。** 解除条件是原始音频合同在受支持环境实跑一次：`RSSMediaPoCTests/testLocalAudioActuallyAdvances`在iPhone/iPad模拟器各1项通过、零失败零跳过（`/tmp/readerfork-s8-audio-contract-174833-{iPhone,iPad}.xcresult`），单次执行、未循环、断言未改。这不是修复结论：根因仍未定位，历史失败证据保留。**重开条件**：该断言再次失败，或出现`unknown`停滞、`timebaseRate=0`、时钟不推进、`-66681`，或真机/网页播放器出现同类用户可见症状；重开时保存拆除前AVPlayer/AVAudioSession状态，围绕该次失败做最小实验，无新失败不再循环重跑。
- **#78 → 客户端缺陷调查关闭，R146图片标为外部证书链前置条件。** `testReviewedR146ImageRequiresSystemTrustAndNativeDecode`保留在源码中可单独运行，但从full/nonmedia两种模式的通过集中剔除，verifier以`externalPreconditionsNotRun=1`单列；混入结果树会按多出项目被拒绝。**R146图片仍是未验收，不是通过。** 图片代表链由R014、R217各一张实图承担。证书链恢复可信后，用同一请求与解码断言重验即可移回门槛。
- **full门槛首次实跑通过。** `bash scripts/validate_reader_fork_s8.sh full`在iPhone/iPad各47项/12 suites、零失败/跳过/预期失败，精确集合与模板探针通过（`/tmp/readerfork-s8-full-iPhone.skTNEI/`、`/tmp/readerfork-s8-full-iPad.44CJ0U/`）。其中R141真实MP3各3事务200/200/206、推进500/502ms且进度重载；R217 WebP 12,838 B解码480×300；R014 JPEG 640×440；R146列表/正文4事务、987字符、状态重载，R146图片只读取元数据未请求。verifier仍输出`stageAccepted=false`。

full通过只覆盖所列自动回归。S8未完成的真实iframe播放（R265/R267）已由用户确认转#58人工验收，现有支持不变；真实受限登录、iOS17、当前物理设备与签名／发布仍在[收口清单](s8-release-checklist.md)逐项待验。

以下两段为调整前的诊断依据。

#77：用户转交的交错A/B工具交替 XCTest/Standalone 先行，3轮加2对补全共5对、10次探针均ready并推进，`timebaseRate/effectiveRate=1`。这提高了排除固定宿主顺序和单次预热混杂的置信度，但同日同模拟器未复现不等于修复；历史`unknown`、约15秒延迟、`-66681`与停钟证据保留，CoreAudio间歇服务卡死仍只是待验证假设。交错结果未由当前会话重跑，其证据目录在本会话不可见；原始音频合同已另行实跑（见上）。不写成永久修复、真机可听声音或网页播放器通过。

#78：`RSSImageService` → `SourceRequestExecutor` → 系统URLSession路径没有server trust放行或自定义TLS绕过；`S8RequestBoundary`只限制测试目标/预算。R146的`-1202/-9814`发生在HTTP响应之前，现有列表/正文同源事务通过，当前证据不支持修改图片解码器。代码与记录支持将其标记为外部证书/信任链前置条件；安全后续只能是用户决定的同一目标受控对照或换代表源，不安装CA、不改时间/网络、不关闭TLS、不重复公网重试。

## 首轮范围与安全限制（历史）

以下为最初一轮只读抽查范围；后续经单独预审的正文/单张图片与发出前请求边界见[资源与Cookie补充](s8-resources-cookies.md)。历史Session delegate的“拒绝跳转”不能当作实际拦截保证，最新用精确URL/哈希准入约束。

- 原始输入仍只读：`docs/Booksource.json` 253项、`docs/rssSources-valid.json` 307项。两个文件SHA-256仍分别为 `3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc` 和 `0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45`。
- 联网前从对应原始包中只取单个源配置到测试解析器，未把整包交给源执行器；手工 GET 请求无Cookie/凭据/Cache，禁用跳转，超时15/25秒、最多一页、每项一次请求。
- 活动真实源只读 GET；不触发登录、验证码、支付、写入/上传、源脚本注入，也不抓文章、目录、封面或iframe媒体资源。BookSource用例额外预检 CookieStore、URLSession和WebKit主机Cookie为空后才请求。
- 任何真实站点可能因策略、反爬、响应变化或地区条件而不同；不将一次成功推广成整包可用。

## 原始包/合成规模实测

### 离线完整RSS包

既有生产导入往返测试在两个模拟器均通过：从原始路径加载307条，0网络请求、0脚本执行，导入隔离RSSStore，重建并导出后逐字段差异0，重导入跳过307且没有冗余写入。证据 `/tmp/readerfork-s8-raw-pack-audit.B6osvz/`，iPhone/iPad各1项/1 suite通过。

### 307个合成RSS源性能快照

新增 `Tests/iOS/yuedu appTests/S8ScaleAcceptanceTests.swift`，生成独立synthetic URLs/rules，不访问网络或使用用户Cookie；实测加载→比较→合并→持久化→重建→幂等导入，并采样进程resident变化和writer计数。

证据 `/tmp/readerfork-s8-final-local-real-both.g1uf7t/`，iPhone/iPad各1项规模测试通过（结果包中与RSS全包及代表源合计6项）；

| 设备 | payload | 加载 | 比较 | 合并 | 落盘 | 重建 | 阶段采样resident增量* | 首次写入 | 不变重导入写入 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| iPhone模拟器 | 90,518 B | 6 ms | 4 ms | 0 ms | 5 ms | 4 ms | 507,904 B* | sources 1、folders 1 | 0 |
| iPad模拟器 | 90,518 B | 6 ms | 4 ms | 0 ms | 5 ms | 4 ms | 540,672 B* | sources 1、folders 1 | 0 |

`*` 是测试内各阶段采样的进程resident增长，不是峰值内存严格上界；同一测试进程的process peak分别约767 MB/771 MB，主要含App及测试宿主常驻映射，不可归因给307条源。

### 刷新合并与两页订阅规模

新增同文件的loopback合成验收：307个源各读首页一次、相同响应重复刷新一次、每源再翻到第二页，总计1228次本地GET；每页返回5条，最终重建3070条。验证首次全源变更合并一次文章写入、不变响应零新增文章写入，所有源第二页追加再合并一次文章写入。队列等待、RSS与时延是单次环境观察，不作为相对性能SLA。

| 设备 | 首页全量刷新 | 不变响应刷新 | 两页翻页 | 请求 | 合并文章写入 | 主队列采样 |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| iPhone模拟器 | 9853 ms | 7793 ms | 8544 ms | 1228 | 2次；不变响应0次 | 最长等待58.73 ms / 1321个样本 |
| iPad模拟器 | 13149 ms | 8993 ms | 12923 ms | 1228 | 2次；不变响应0次 | 最长等待25.69 ms / 1557个样本 |

测试进程resident阶段采样增量约38,289,408 B/37,552,128 B；进程峰值约1.01/1.02 GB，包含App和测试框架映射，不能归因307源。无旧版本对照、无SLA结论；该规模下的刷新/浏览耗时与队列采样仍须谨慎评估，不能单凭一次模拟器采样宣称流畅度。

后续主工作区整合集重复测量了一次：iPhone 307源首页刷新4732 ms、不变刷新4254 ms、两页翻页7401 ms，主队列最长采样1.78 ms/979次；iPad分别4680/4286/7308 ms，主队列最长采样27.37 ms/958次。耗时相对首次运行（约8.5–13.1秒）明显较短，说明模拟器运行状态/预热会影响结果；因此两组都只作为观察，不构成回归阈值或优化结论。最新主回归路径见下文。

最近一次完整主工作区回归iPhone与iPad各47项/11 suites通过、0失败/跳过，结果 `/var/folders/r_/9t3glr2x0_xc15drxxf3035w0000gp/T/readerfork-s8-delivery.wyxigg26/{iPhone,iPad}/tests.xcresult`。包含浏览器会话/默认UA一致性、请求、缓存、Cookie、撤销、WebKit、S8规模与代表源：R181 XML 10条、R265 HTML媒体列表100条、R014两页20→40条、B002文本搜索3项、B122离线匹配DOM1项、R146两页/正文重载20条/987字符。R146 metrics共4个transaction，包含一个301和三个200；所有请求origin匹配预审源站，无凭据、无跨origin transaction。301并未被写作成功的最终HTTP状态；实际正文/列表由应用取回并通过下一页、状态重载等断言。外部图片CDN不计入通过。

## 低并发代表源联网

测试新增强制固定包哈希、检查无账号/认证头/源JS/非GET操作、检查URL无内嵌凭据、使用隔离URLSession禁Cookie和凭据存储，并在metrics上断言恰好一个GET/HTTP200、无Cookie/Authorization、无重定向。源通过原序号记录，日志不打印源名、URL、查询、正文或响应内容。

最终聚焦复跑 `/tmp/readerfork-s8-final-local-real-both.g1uf7t/`：iPhone/iPad的6项聚焦集合均通过，其中4项受控真实源测试、1项规模测试、1项全包离线导入；B122图片源是另一个额外探测，单独保留失败证据，不包含在这6项通过集合中。

当前主工作区追加的两项受控闭环复测：R014在iPhone/iPad各读取两页，第一页20条、合并后40条；每页fetcher结果均为HTTP200、无凭据。ordinal146在iPhone/iPad各完成两页列表、正文提取、阅读状态与正文重载恢复，正文987字符。每次有4个URLSession metrics transaction，状态为301、200、200、200；全部交易origin匹配预审源站、无凭据。`redirectsBlocked`为0；metrics含301这一点本身不足以断言特定重定向delegate分支是否执行，所以只报告事务状态与最终应用行为，不将301解释成200。外部图片资源不在此闭环中：此前受控请求遇`NSURLErrorDomain -1202`，保留TLS失败证据。

资源补充前的代表源集合由6项构成，在iPhone/iPad各6/6通过：受控XML、HTML媒体列表、R014两页、B002文本搜索、B122离线匹配DOM fixture、ordinal146两页正文/状态重载。最新代表源xcresult路径见`/tmp/readerfork-s8-representative-final-{iPhone,iPad}-path.txt`所指目录，测试结果各6项/0失败/跳过。B122 fixture无任何网络请求，不纳入真实源通过数。

| 原包位置/类别 | 实际范围 | iPhone / iPad |
| --- | --- | --- |
| RSS R181：标准XML Feed | 1个GET；HTTP200；解析10条；无源规则，不加载其余资源 | 各通过 |
| RSS R014：规则列表/翻页 | 2个GET；每个生产fetcher返回HTTP200；解析第一页20条，第二页追加至40条；无凭据、无跨origin metrics transaction | iPhone/iPad各通过 |
| RSS R265：HTML媒体规则列表 | 1个GET；HTTP200；解析100条；100条保留了配置中的video/source/iframe标记；未打开文章/播放器 | 各通过 |
| BookSource B002：文本书源搜索 | Cookie预检空；1个GET；HTTP200；解析3项；未请求详情、目录、封面 | 各通过 |

结果包中iPhone/iPad各有1个S8合成规模用例，执行值如上；4个代表公网用例和307全包离线导入另在同次定向回归中通过。

媒体列表用例只证明响应携带标记，不证明第三方iframe可加载、播放器可播放或认证能够安全传播。R014与R146的第二页已实际执行；其他仅产生分页候选的源不能据此判为第二页成功。

## 图片型书源首次失败（历史）

以下为最初失败；后续已用双设备实源搜索输入/响应DOM对照收敛，见[B122搜索记录](s8-b122-search.md)。不删除旧失败，也不把后续局部搜索通过写成整个图片源通过。

静态审核找到无显式Cookie、登录字段、header、JS规则或写操作标记的图片型BookSource B122，且配置URL为HTTPS；在iPhone模拟器以无Cookie、无凭据、阻断跳转的隔离session实际请求一次搜索，收到**HTTP200，但结果0项**，用例以预期正结果断言失败。证据 `/tmp/readerfork-s8-image-source.yKTiwc/`，一次只读GET、HTTP200、cookie/凭据为0、跳转0，但B122本次查询解析结果为0项，未满足预期非空断言。**这是本轮S8未闭合项**。

目前证据只说明传输拿到200、用户查询未得到解析结果；尚未判明查询不匹配、站点响应/规则变化或客户端解析差异。为拆开“源响应/查询不匹配”和“iOS规则解析”两类可能，本轮新增完全离线的B122规则fixture：使用固定源包第122项的规则，对自建匹配DOM解析出1条条目、相对链接和封面规则均生效、0网络请求。这个fixture只证明规则在匹配DOM上可运行，不证明真实站点查询应返回结果，也不改变生产解析或真实查询。

其它优先候选中，文本B002不含执行标记并已测；静态检查发现B018漫画、B065音频、B130视频等候选包含JS/源运行标记，本轮没有执行。未尝试任何真人账号/真实登录。

## 真实图片与受限Cookie补充（2026-11-13）

新增结果与命令见[详细记录](s8-resources-cookies.md)。iPhone/iPad各23项/6 suites、零失败零跳过；只改测试和文档，没有生产修复或真机安装。

- R014：1页列表+1张公开HTTPS CDN图片，2个GET/200；JPEG 75,292 B，实际原生解码640×440；已读、收藏和图片地址重载通过。0凭据请求、0未准入目标，未加载整篇文章或视频。
- CookieJar=false/true合成流程各4个loopback请求，实际贯穿RSSFeedSession、type=1规则解析、原生图片解码与RSSStore重载；显式/已保存Cookie正常传播，private路径不泄漏到public对照，响应Cookie保存遵守Jar开关。此为合成合同，不是真实账号登录通过。
- 发现并复现Session重定向delegate会被生产task delegate覆盖；新增测试专用发出前精确URL/哈希与次数边界。R146只准入经无Cookie/禁跟随301预审的确切同源canonical目标，最终仍为301、200、200、200四个事务。不能将旧redirectsBlocked=0解释为没有跳转。
- 使用已有Reader-Fork-RSS-PoC隔离宿主，拒绝普通App主页后台请求干扰；B002只隔离测试缓存修订。旧47项回归与307规模测量保持历史证据，本轮未重测性能，也不据此声称S8完成。

## 真实音频资源与退出进度补充（2026-11-14）

详见[音频与进度记录](s8-audio-progress.md)。双设备最终各37项/9 suites、零失败零跳过。R141首分类20条，列表`@put`和正文`java.get`保留同一条目MP3；生产媒体资源层各3个事务200、200、206，实际推进500/503ms，关闭资源与进度重载通过。原sourceKey、query参数、type=0路由不改；目录只准入已审查的offset/Date.now表达式及全部固定参数，媒体才显式允许HEAD，HTTP总准入上限8。

本轮发现关闭时保存1秒UI采样旧值的实际RSS缺陷，已用本地0.25秒的关闭/暂停/切后台三种情况复现。RSS强制保存改取真实时钟，并保护未完成seek目标、加载修订和结束归零；书源/脚本路径不变。R141原规则网页WebKit/HTML audio、iframe和物理设备声音仍未验，不把这次原生资源层通过写成完整网页播放通过。R304/R187的403停止不绕过；R306响应形状不匹配预期，未继续执行媒体。

## 可重复自动回归脚本（2026-11-14）

新增[脚本与精确集合门槛](s8-regression-gate.md)：更新后的`bash scripts/validate_reader_fork_s8.sh nonmedia`双设备完整运行均零失败/跳过，当前各22项/5 suites（`stageAccepted=false`）；R128一页20条无图是明确no-image停止观察。R146图片改列外部前置条件后，full manifest为47项/12 suites，**已在双设备实际整套运行并通过**（证据见上文生命周期一节）；nonmedia仍为22项/5 suites，显式排除R141 MP3与R217实图。10项verdict/shell单测通过。以下nonmedia证据早于该调整：更新后的证据：`/tmp/readerfork-s8-current-nonmedia-iPhone.kDBTd1/`、`/tmp/readerfork-s8-current-nonmedia-iPad.42BVWD/`。

## S6/S7前置

按用户确认，两个真实音频输出时钟断言只从模拟器门槛排除，保留在XCTest源码及历史失败证据；其余S6媒体合同保留。更新后的完整S7脚本在双设备已完成：S5各270/38、S6各99/19 + Web UI 3、S7各93/20，均0失败/0跳过。该门槛范围变更与失败证据见本目录的 `s7-restore-interruption.md`。

## audio-only旧失败与当前宿主对照（2026-11-14，根因未定）

[精确诊断](s8-audio-clock-diagnostics.md)保留旧失败：两端m4a在ready截止时unknown，约+15.2秒后ready，但最终timebaseRate=0/clock0；当时PCM亦失败。用户纠偏后，同一已安装App/同一Caches文件/同一播放器代码在XCTest和独立隔离App双端均ready且推进，原音频断言双端复查通过；随后PCM和受控R141原生媒体双端也通过。它否定本轮“只有XCTest出错”的预测，却不解释旧间歇失败；既不改生产路由/clock也不放宽断言。原规则网页/iframe和真实登录仍未验，#77继续保留历史间歇风险。

## R265/R267 iframe只读边界（2026-11-14）

[预审记录](s8-iframe-preflight.md)：R265生产列表一页1 GET/200，双端均解析100条；静态HTML审计100个跨源、带query的iframe目标、0个直接媒体目标，未请求子frame或媒体。R267只检查原包配置、0网络，同一第三方iframe来源。两端复用已有生产规则网页6项+本地WebKit iframe/HLS播放1项合成合同通过，但不能将分别通过的两个fixture当作真实R265网页/第三方播放器验收。未审阅子frame脚本/请求图，WebKit子资源不受测试URLSession预分派边界统一控制，因此停止自动加载，而非放宽准入。R146首图-9814链过期仍为独立外部信任门槛，不修改TLS。下一步只选择可精确预审且能约束子资源的代表来源；否则明确标未验。

## WebKit iframe安全边界可行性（2026-11-14）

新增两个本地loopback合同，复用公开`WKNavigationDelegate`/`WKContentRuleList`而不访问R265/R267目标。双端各3项/0失败/0跳过：可在发请求前拒绝精确frame文档导航；静态内容规则阻止不准入的iframe/nested-frame图片、fetch和重定向目标，但只回调文档导航，没有子资源运行期事件/限次计数；相同精确白名单资源两次仍可访问。每端共6个本地HTTP事务，delegate只见3个文档导航。另一个scheme-only取消合同验证可控WKURLSchemeTask，不推广到HTTP(S)。结论是不可能由这些公开观察点建立每个WebKit子资源精确准入/请求预算，所以未加载公网iframe、未作生产权限更改。具体assert、命令与回滚见[WebKit边界PoC](s8-webkit-boundaries.md)。


## R217单张公开图片闭环（2026-11-14）

[R217记录](s8-r217-image.md)：双端首页1 GET/200后生产解析18条/17个唯一HTTPS图链，均无query/凭据；指纹固定的一张跨源WebP由真实`RSSImageService`请求，生产检查及原生480×300解码通过，标已读/收藏后`RSSStore`重载通过。每端恰有2个GET/200，无跳转/凭据；另一个候选R128首页20条无图片，因此0图片请求并按边界停止。R217其他16个图目标仍未读取；R146 TLS错误、#77历史音频间歇风险、真实iframe/登录、full整套验收不受本次结论覆盖。

## S8未验证/后续

- B122原词0条已收敛到输入响应DOM差异，检查词实际12条；详情/目录/封面/漫画图片与更多书源端到端仍未验。
- 本次新增浏览器会话和实际HTTP User-Agent一致性代码已并入主工作区：符合条件的简单singleUrl用同一WebKit会话加载；原规则、登录、响应处理和私有头留在共享执行器；fixture已在两台iOS27.2模拟器验证首请求与网页navigator.userAgent、后续表单一致。诊断只记录白名单元数据，不记录URL/头/Cookie/正文/任意错误文本。实源目标在用户换节点、该源仅把Android UA改为WebKit默认UA后重开两次成功；VPN/UA对照和外部策略边界详见[实源记录](rss-single-page-diagnostics.md)。
- RSS真实列表下一页与正文已有受控证据：R014两页和单张CDN图片解码、R146两页/正文/状态、R141提取出的MP3资源层曾通过、随后本地音频失败、最新双端重新推进且进度重载；#77的间歇根因仍未查明。R146自己的外部图片仍因`-1202`未通过；真实网页音频/iframe、视频/HLS、登录/受限站点与更多跨站资源链仍未验，Cookie合成合同不能替代真实登录。
- 本轮S7/S8代码未安装到物理设备；独立RSS实源实验以稳定提交15a29143为基线，不能把隔离实验候选或当前主工作区测试泛化成正式真机/发布验证。
- iOS17、真实WebDAV、正式签名/iCloud/App Group、真实账号登录、DRM和人工VoiceOver均未验。
- 性能没有旧版同口径基线；无发布SLA结论。

## 回滚

最初S8的合成规模/代表源与load span、后续浏览器会话，以及本轮资源/测试边界分别按各批次回滚；各批次分别按[资源记录](s8-resources-cookies.md)、[进度修复](s8-audio-progress.md)、[日志安全](s8-template-logs.md)和[自动回归](s8-regression-gate.md)撤回对应改动；不整体覆盖共享文件或恢复泄露原始表达式/结果的日志。不覆盖#74网页返回改动，不删除源包或用户数据；原始输入/本地审计目录不提交，推送不等于S8完成或发布。
