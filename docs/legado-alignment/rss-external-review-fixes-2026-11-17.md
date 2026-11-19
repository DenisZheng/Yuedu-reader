# RSS 外部 Review 修复与双设备门槛复验（2026-11-17～18）

## 结论与范围

在 `fix/rss-review-20261117`、`9ee66fb5` 之上修复普通 Feed 全文请求上下文、未知附件保留、静态懒加载图片、受限媒体诊断和列表预取；完整门槛进一步暴露音频端点扩展名／有限 Range 截断及扩大分块后的极端 Range 溢出，均已补测试并修正。

**当前双设备 full 自动门槛通过：每端 68 项／16 suites，零失败、跳过及预期失败，最终 `** TEST SUCCEEDED **`，脚本退出 0。** iPhone 证据为 `full-maintained-iphone/`，iPad 为 `full-maintained-ipad-final/`；均位于本地 `.artifacts/rss-review-20261117/`。`stageAccepted=false` 保持不变：自动回归不代表 S8 人工、最低 iOS 17、真机、签名或发布验收。

R217 是网站改版，不是共享解析器缺陷。用户要求继续维护后，独立预审新版测试配置与当前精确图片目标，经源更新、真实下载／解码／状态重载验证；**原始源包不变，原包中的 R217 仍失效**，不把维护后的测试配置通过冒充原包兼容。旧规则的空结果由新增合成生产路径回归固定，旧失败和超时证据保留。

用户最新要求：完成记录后提交并 Push 当前修复分支，随后本机生成 IPA，**不关机**。不合并 main、移动 tag、发布或更改正式签名。既有 `9ee66fb5` 首批六项上游适配与 [40065b99 订阅入口记录](rss-source-home-management.md) 是不同批次；本次 Push 包含本地首批提交，不把其测试与本次 full 混算。

## Review 采纳矩阵

| 意见 | 核对与处置 |
| --- | --- |
| 去掉 `preloadJs` 门槛即可解锁其余源的 `window.java` | 不采纳。固定 Android `ReadRssActivity.kt` 也仅在存在 `preloadJs` 时安装 RSS JavaScript bridge；源数量不能证明缺陷，更不能据此扩大所有网页的桥权限。 |
| `singleUrl` 只解析而未自动打开 | 不成立。`RSSFeedView` 已以 `autoOpenedWebPage` 自动打开解析结果，启动 URL 优先级不改。 |
| 普通 Feed 全文遗漏源 header 与调用方 session | 采纳。`RSSArticleContentService` → `RSSArticleContentLoader` → `RSSOpenTarget` 传递 owner、session 和文章上下文，复用共享原生请求准备／执行；普通文章链接中的模板仍是外部数据，不作为源脚本执行。 |
| 重定向后的相对正文资源使用旧地址 | 采纳。提取和落盘清洗使用最终响应 URL 固定相对链接／图片，跨 origin 私有头过滤不变。 |
| 缺 MIME／非媒体 MIME 附件被丢弃 | 采纳。保留 `.other`、MIME、标题、大小和时长元数据；旧 JSON 可读。未知附件是显式链接，不猜作音视频、不交给播放器。 |
| 关闭 JavaScript 后常见懒加载图片为空 | 采纳。在安全文章及静态图片改写路径规范化 `data-src`／`data-original`／`data-srcset`；正常 `src` 优先，危险协议仍过滤。开启脚本的规则网页不强行静态替换。 |
| 列表无近尾预取 | 采纳。List／网格／瀑布流行使用同一 `RSSFeedSession.preloadIfNeeded()`，只检查末尾少量稳定 ID；失败保留手动重试，不因行再出现而反复请求。 |
| DASH／DRM／受限 HLS 仅报普通网络错误 | 采纳诊断部分。新增明确受限错误，不重抓、不增加播放器依赖；SAMPLE-AES／DRM、受限清单功能与响应限额独立于暂时网络失败。 |
| 普通网页媒体／M7 尚未全闭环 | 保留限制，不把原生 type=2／附件播放通过外推到网页 `<video>`／iframe。WebKit 原生资源不盲继承源私有头；认证网页媒体和第三方 iframe 真播仍按 [S8 人工门槛](s8-release-checklist.md) 验收。 |
| Cookie 同域共享就是身份缺陷 | 不采纳这种概括。Android Cookie 行为也按域／路径共享；不新增按源隔离 CookieJar，不改变 CookieJar 关闭的合同。 |
| `stageAccepted=false`、M7 按需范围应改为通过 | 不采纳。它们是已披露的验收保护／范围，不是待删除的失败；真实 VoiceOver、最低系统、真机和签名／发布不由自动测试替代。 |
| 81 提交／源百分比代表完成度 | 不采用为验收证据。`fdd60bd4..40065b99` 的 81 含 merge，first-parent 为 12；字段、源数、页面存在和估算百分比都不证明行为通过。 |

## 实现与资源边界

- 不建立新的 JSContext、请求解析器、持久 store 或媒体缓存；请求沿 `RSSRuntime`／`SourceScriptHost`／`SourceRequestExecutor`，内容和进度仍由 `RSSStore` 持有。
- 原生播放器本地端点保留受支持的音频／视频扩展名，不把 MP3 暗示为 MP4；端点仍是当前媒体会话的 capability URL，不是任意网页代理。
- 有限 Range 在单响应 16 MiB 上限内不再被固定 2 MiB 块截断；32 MiB 工作集、6 个在途请求、关闭撤销和认证作用域均保留。极端起点在加法前拒绝，避免整数溢出。
- 大 MP3 回归使用仓库既有 TTS fixture 拼接，读取／构造离开主线程，不依赖外部捕获。源修订回归使用自建 DOM，经真实 loopback 请求、生产规则与 store 更新／重载，旧规则不自动猜成新类名。
- R128 测试刷新后等待 `store.flushPersistence()` 再结束，避免隔离目录删除与异步写盘竞争；不改生产落盘机制，不吞清理错误。
- 临时页面／音频捕获及详细请求诊断已移出代码；私有产物留在本地 `.artifacts/`，不删除、不提交。R141 失败诊断只保留请求数、状态码、边界拒绝数和页码，不输出 URL／响应。

## R217 独立维护与原失效证据

原包 `ruleArticles=.item`（SHA-256 `eae38cbf1dc54f4646bc7390b8a7125737f233f47578e24f8f873956a96fb673`），标题／链接 `tag.a.2@text`／`tag.a.2@href`，图片 `tag.img@data-original`。捕获页离线审计 `.item=0`、`.article-item=18`，图片不再使用 `data-original`；生产原规则也实际返回 0 条。固定 Android `330e606c4d57e08adc056ff8ab7a4132c784da9a` 的 `AnalyzeByJSoup.kt` 同样使用 CSS `select`，无类名猜测。缺基准 jsoup 1.23.2／oracle pinned jars，**未实际运行 Android oracle**，源码核对不称双平台实跑。

新版配置只在 `Tests/iOS/yuedu appTests/Support/S8R217ReviewedRevision.swift` 定义：

| 字段 | 独立预审修订 |
| --- | --- |
| `ruleArticles` | `.article-item` |
| `ruleTitle` | `.article-item__title a@text` |
| `ruleLink` | `.article-item__title a@href` |
| `ruleImage` | `tag.img@src` |

不加源脚本、header 或登录，不改 `sourceKey`、原包、共享解析器和分类请求范围。隔离 store 先添加原配置，再走 `updateSource`，断言旧 ticket 失效、source ID 不变，最终配置落盘重载。用户自己的源库未被改写；该辅助配置不作为 App 内自动修正或源包更新分发。

首轮新版 DOM 捕获的精确图片随后已不在新列表中，目标断言实际失败，未请求替代图。重新进行独立 **1 GET／200、0 图片请求** 预审后，冻结当前精确 WebP URL SHA-256 `8535542ba811779b05908f43a7e61a7cd59dbd9d311144cd355b18306dfa0538`；host SHA-256 保持 `0336c9b73661988775e65e74fb5b8a891afe86e13bbf4b226c25b51e440860b1`，HTTPS、无 query／fragment／内嵌凭据。不是准入整站，也不在测试中自动挑新图替换固定目标。

最终每端列表 18 条／18 个唯一图目标，扩展名 AVIF／PNG／WebP；仅请求指纹固定的一张 WebP，未加载 AVIF 或其他 17 张图。每端恰好 2 GET／200，0 凭据和重定向，13,674 B 原生解码 480×300，已读／收藏／图片 URL 与配置重载通过。条目顺序可能按日期重排，选图按固定指纹而非“当前第一行”，请求边界不变。**不宣称原包 R217、全部新版图、其他分类或正文已经可用。**

## 实际命令与结果

工具链与目标由 `scripts/sim.sh` 解析：Xcode 27.2（27B52），iOS 27.2 Simulator；iPhone UDID `1190ADDC-01AC-4B6C-B5B2-B6AB1E38F19A`，iPad UDID `CD03D0D9-4F96-4855-9C8A-F63A1C3B26B1`，scheme `Reader-Fork-RSS-PoC`。未换 DerivedData、clean、清用户数据、安装真机、重启服务或改变网络／CA。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_EVIDENCE_DIR=.artifacts/rss-review-20261117/full-maintained-iphone
bash scripts/validate_reader_fork_s8.sh full
# iPad串行执行，YUEDU_DEST使用dest iPad，证据目录full-maintained-ipad-final
```

最终两端 verifier 均输出：`passed=68`、`suites=16`、`explicitExclusions=0`、`notSelectedFromFull=0`、`externalPreconditionsNotRun=1`、`stageAccepted=false`。R146 原有外部图片前置条件保持未执行／未验收，没有新增排除 R217。两端 `s8-summary.json` 均 `Passed`、68 passed、0 failed／skipped／expectedFailures，最终日志均 `** TEST SUCCEEDED **`。iPhone full 早于仅测试收尾的 R128 flush 修正；iPad 最终 full 覆盖该修正，不把其写成生产代码变更。

| 本地证据（均在 `.artifacts/rss-review-20261117/`） | 实际结果／历史失败 |
| --- | --- |
| `fulltext-green-final.log` | 25 项／3 suites 通过；非 final 同名 run 失败，不计通过。 |
| `attachments-lazy-green-final.log` | 13 项／3 suites 通过；动态图首轮超时保留，隔离通过后未改时限，整套重验通过。 |
| `preload-green-final.log` | 26 项／3 suites 通过；18 项 fixture 不足滚动，改固定 60 项后原基线确无下一页请求，再修复。 |
| `media-resource-final{,-ipad}` | 每端资源层 8 项 + R141 实源 1 项、各 9 项通过，最终 `TEST SUCCEEDED`。 |
| `range-overflow-red-identifier.xcresult` | 新极端 Range 实际 1 项失败、`Crash: YueduReader`，修正后纳入 full；首次遗漏标识括号选到 0 项，被 wrapper 拒绝。 |
| `full-{iphone,ipad}` | 初轮每端 63 项：61 passed／2 failed／0 skipped，`Failed`；R217 空列表、R141 未推进，不用框架中途结论覆盖。 |
| `full-final-{iphone,ipad}` | 当时 67 项集合的外层 600／1200 秒超时、无最终结论；xcresulttool 返回 64，不计通过。 |
| `full-resume-iphone` | 实际最终 67 项：65 通过／2 失败；R217 空列表与 R141 目录失败。后续独立音频复验和最终两端 full 实跑通过，不加自动重试来掩盖。 |
| `r217-offline-revision-verified` | 私有捕获离线生产规则回放旧0／新18；不是图片／网络验收，捕获依赖已被自建回归替代。临时语法／Sendable／漏import编译失败保留。 |
| `r217-current-preflight` | 1 GET／200、145,664 B、0 图片请求，独立预审当前精确目标；私有页面未提交。 |
| `r217-maintained-final` | 新版配置真实闭环1项通过；旧图缺失、按首行选图错误等之前失败保留。 |
| `revision-synthetic-final` | 自建旧规则空结果→更新失效票据→新规则2条→配置／条目重载1项通过，无源包或私有文件依赖。 |
| `full-maintained-ipad` | 68 项：67通过／1失败，仅R128测试清理目录与异步写盘竞争；未吞清理错误，补flush后整套重验通过。 |
| `full-maintained-iphone`、`full-maintained-ipad-final` | 当前最终每端68项／16 suites完整通过；精确集合、最终结论、设备和模板探针均校验。 |
| `verdict-maintained-final.log` | `python3 -B -m unittest discover -s scripts/tests -p 'test_s8_regression_verdict.py' -v`：`Ran 11 tests`／`OK`，要求full 68项／16 suites，缺源修订回归仍拒绝。 |
| `localizations-final.log` | `ruby scripts/check_localizations.rb`退出0，五语4288键，Modules／Targets2975 literal keys齐全。 |

既有同 App／同路径／字节音频宿主对照见 `audio-host-current-iphone/`：comparisonValid=true、双方 ready／advanced；这是定位证据，不称永久间歇问题根因修复。

## 剩余范围与交付

本轮自动门槛通过，人工／发布仍待验：最低 iOS 17、真机声音／画面、实际 VoiceOver、受限登录、原网页媒体／第三方 iframe、签名／发布；R146 新证书政策下的图片未复验。本机生成未签名 Release 真机 IPA 只证明编译／包装，不替代用户自签启动或这些门槛。

收尾实际执行`python3 -B .artifacts/rss-review-20261117/check-current-delivery.py`，输出`RSS_REVIEW_DELIVERY_CHECK_OK docs=8 localLinks=151 swiftFiles=22 sourceHashesUnchanged=2 stagedFiles=0 UTF8_LF=true diagnosticsRemoved=true fullPassed=68 suites=16 devices=2 stageAccepted=false`；核对8文档／151本地链接、原包哈希、临时诊断移除和两个最终结果精确门槛。`ruby scripts/check_localizations.rb`退出0（五语4288键／2975调用键），`bash -n scripts/validate_reader_fork_s8.sh`、`git diff --check`均退出0。静态检查不代替行为验收；产物、脚本、日志、xcresult、原包和Review原稿不提交。

## 提交、推送与本机IPA（2026-11-18）

本轮37文件精确提交为`890285fac47bb39cacb7d9ee78756000941b5308`，`git push -u origin fix/rss-review-20261117`实际退出0；`git ls-remote`核对远端分支一致，main仍`40065b99a212a64da2dd4a5af6b9fbc319211a21`，没有合并／改tag／发布。原包、Review原稿、日志及诊断未暂存／提交。

按用户最新授权本机生成IPA，不关机；复用已有Actions的归档参数和打包器，不更改签名／工程配置／依赖。Xcode27.2（27B52）、iPhoneOS27.2，`Reader-Fork-Dev` Release／arm64、最低声明iOS17.0：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
work=.artifacts/rss-review-20261117/local-ipa-890285fa
xcodebuild archive -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$work/ReaderFork.xcarchive" \
  -resultBundlePath "$work/ReaderForkArchive.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  > "$work/archive.log" 2>&1
python3 -B scripts/package_unsigned_ipa.py --archive "$work/ReaderFork.xcarchive" --output "$work/output"
```

归档实际退出0，`archive.log`最终`** ARCHIVE SUCCEEDED **`；包装退出0。`python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v`实际19项／OK。产物`.artifacts/rss-review-20261117/local-ipa-890285fa/output/LegadoPro-unsigned.ipa`，36,646,075 B（约34.95MiB），SHA-256 `edd56c09c6f68dd6c89b860196f4e2329acd9373ef89a96bd402671a950df9b2`，同目录`.sha256`一致。

实际打开ZIP校验无损；Info.plist确认LegadoPro／`dev.denis.readerfork.dev`／3.0（5）／iPhoneOS／最低17.0，Widget和ShareExtension两个独立ID正确；`xcrun lipo -archs`为arm64，`codesign -d --entitlements :-`返回未签名，包无embedded.mobileprovision。主App源entitlements没有CloudKit，App Group仍按既有配置保留；**安装前须自行签名，扩展／共享组权限取决于该签名授权**。未安装真机、验证实际启动／声音或上传Release；IPA与archive只留本机，未加入Git。

## 回滚

本轮未改变持久格式版本、Bundle ID、依赖、签名、原包或 App 数据；旧附件 JSON 继续可读。回滚仅撤销 `9ee66fb5` 后本轮 RSS／播放器／本地化／测试／verifier／文档改动，不撤回首批上游提交，不清用户库或诊断。独立 R217 测试配置随本轮撤销，不替用户改写原源；旧失败证据保留。
