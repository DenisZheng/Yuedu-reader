# RSS 对齐验证记录

本文件只记录实际执行证据和阻碍。计划见 [implementation-plan.md](implementation-plan.md)，不能把环境检查或文档完成当作 RSS 已实现。

## CF 验证页与普通 HTTP 403 分开显示（2026-11-20）

用户指出模拟器验证期间 App 的「HTTP 403／重试」条仍覆盖网页，Android 不显示这条。原因是原生网页响应代理把所有 4xx/5xx 都赋给普通错误状态；CF 本身会用 403 返回交互验证页，不能只按状态码判断加载失败。

按 [Cloudflare 的响应合同](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/)，只在已准入的原生主文档同时收到 `HTTP 403` 和 `cf-mitigated: challenge` 时，不生成普通失败重试条，让网页自身承载人工验证。只有 `Server: cloudflare` 或其他 `cf-mitigated` 值都不满足；普通 403、网络／脚本／安全检查失败仍保留原提示。不修改 UA、Cookie、导航限制或挑战内容，也不求解验证；诊断仍记录真实 403，不改成 200 或功能成功。

本地 HTTP 合成页面通过生产 WebView 复现原症状：修复前，明确 challenge 的一组断言失败，错误值是「无法完成 RSS 请求（HTTP 403）」；无标记和未知标记两组符合原错误合同。回归还覆盖后续普通页面导航清理旧错误、文档仅请求一次，不自动重试。输入完全自建，不向外站发送请求，也不运行 CF 验证脚本。

实际环境为 Xcode 27.2（27B52）、iOS 27.2 iPhone 模拟器；最终串行 20 项／4 suites 通过，0 失败／跳过，命令退出 0，`** TEST SUCCEEDED **`：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
result_dir="$(mktemp -d -t yuedu-rss-cf-display)"
bash scripts/xctest.sh -l "$result_dir/final.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$result_dir/final.xcresult" \
  -only-testing:'yuedu appTests/RSSBrowserSessionTests' \
  -only-testing:'yuedu appTests/RSSWebLoadDiagnosticsTests' \
  -only-testing:'yuedu appTests/RSSWebRequestTests' \
  -only-testing:'yuedu appTests/RSSNativeWebFlowTests/loginPageOwnsItsForm()'
```

`ruby scripts/check_localizations.rb` 检查通过（5 个语言、4288 个主文案键），本轮不新增文案。回滚只撤销 `decidePolicyFor navigationResponse` 中的 challenge 分类条件和本轮测试，保留先前 UA 修复；不改源包或用户数据。此次显示修复未重访实源、未重新打包／安装手机，不能说明循环已经永久解决。

## 原生订阅网页的系统 UA 与实源对照（2026-11-20）

用户指明项目根目录的 `rssSources 2.json`，实际 399 项，第 20 项精确匹配「禁漫天堂-漫画」；仓库既有 307 项包没有这条。新文件是待核对的输入，不修改、不导入真机或提交。导出中的该源显式声明 Android/Chrome UA；用户说明实际手机已经改成 `header: "{}"` 或删掉 `header`，两种都进入验证循环，Safari 不循环，不能把导出状态当作当前手机状态。

本机用 `python3 -B -` 检查第 20 项为简单 HTTPS 单网页、无登录／脚本／认证头后，按导出中唯一显式 UA 发出一次 GET，不跟随跳转或保存响应正文。返回 `HTTP 403, cf_challenge=True`（678 ms），在验证入口停止，不切换 UA 复探。“本机首响应被挑战”不等于重现用户在真机勾选后循环的过程。

在 `94401903`，留空和删除两种写法都在准备网页请求时补出项目拼接的手机 Safari UA，再赋给 `customUserAgent`，并非由 WebKit 自选。本地 HTTP 200 用例直接比对系统 WKWebView 和生产页面，修复前两种写法的首请求、首文档 DOM、后续请求与后续 DOM 共 8 条断言失败。现在在已准入的原生 WebKit 导航分支保持未声明值；显式 UA 仍保留。共享执行器及生成 HTML 的缺省、Cookie、认证和导航准入不变。不添加站点识别或挑战处理。回滚仅反向应用本次三处生产代码与回归差异，不涉及源配置或数据迁移。

Xcode 27.2（27B52）、iOS 27.2 iPhone 模拟器定向回归（修复前以 `-only-testing:'yuedu appTests/RSSBrowserSessionTests/nativeBrowserKeepsSystemUserAgent(header:)'` 单独复现）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
result_dir="$(mktemp -d -t yuedu-rss-system-ua)"
bash scripts/xctest.sh -l "$result_dir/final.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$result_dir/final.xcresult" \
  -only-testing:'yuedu appTests/RSSBrowserSessionTests' \
  -only-testing:'yuedu appTests/RSSWebRequestTests' \
  -only-testing:'yuedu appTests/RSSWebDocumentCacheTests' \
  -only-testing:'yuedu appTests/RSSNativeWebFlowTests/loginPageOwnsItsForm()'
```

最终 `Test run with 18 tests in 4 suites passed`，`** TEST SUCCEEDED **`，退出 0。覆盖空对象、缺字段、显式 UA、真实 HTTP 与 DOM、同源表单、历史导航、共享请求和缓存。中间一轮错误假设清除 `customUserAgent` 后 getter 必为 `nil`，模拟器实际返回空字符串；修正测试只比较可观察的 HTTP 与 DOM，未再改生产行为。未复探站点、未打 IPA，也未在真机、iPad 或 iOS 17 验证。

用户另要求用实源对照视频。旧包 R115「央视直播」、R154「科普中国」各一次只读 GET 返回 200，静态首文档各无可直接测的点播媒体；直播入口不能代替点播快进。R265/R267 保持既有逐条人工验收边界，未请求其 iframe。没有测出用户视频的跳转延迟，也没有更改播放器或缓冲。

### 真机对照准备与当前阻碍（2026-11-20）

用户确认 Android 同源正常，作为已知对照；本轮不改 Android。`xcrun devicectl device info apps` 按确切 Bundle ID 查询，发现 iPhone 上只有正式自签版 3.0 (5)，没有 Debug 版。沿已有开发签名用 `bash scripts/device_dev_test.sh` 尝试单独的 Debug 构建，`xcodebuild` 返回 `Timed out waiting for all destinations matching the provided destination specifier to become available`，并提示解锁、接线／局域网及无线调试需要 Developer Mode。未完成构建或安装，没动正式版、书库或签名。仅从第 20 项生成隔离测试用的单条无 UA JSON，未导入手机或发实源请求。

等设备可调试，用 Debug 版只导入同一条源；用户手动操作验证，是否进入正文并能重开是验收标准。若仍循环，现有 `[RSSWebLoad]` 只看该次加载阶段和状态，区分 App 重开页面与同一 WebKit 内反复收到拒绝；不采集 Cookie、认证或页面正文，不自动重试或更换网页身份。此段仅记录准备与失败证据，不改变上一节的模拟器结果。没有设备变更需要回滚。

### 模拟器实源首屏与人工操作边界（2026-11-20）

用户随后授权改用模拟器点开实源。使用第 20 项生成的单条测试输入，`RSSRealSourceOpeningUITests` 在单独的 RSS 目录经真实「Subscriptions → 源按钮 → 原生网页」进入；只为图标设置本机拒绝端口，避免首屏点击前额外抓取实站，网页地址和默认 WebKit 身份不变。正常回归不执行此用例，只有设置 `TEST_RUNNER_RSS_REAL_OPENING_INPUT` 与 `TEST_RUNNER_RSS_REAL_OPENING_STORE` 才会运行。未把原始包或 URL 写进测试源码。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export TEST_RUNNER_RSS_REAL_OPENING_INPUT="<私有单条测试输入路径>"
export TEST_RUNNER_RSS_REAL_OPENING_STORE="<新建的隔离 RSS 目录路径>"
result_dir="$(mktemp -d -t yuedu-rss-real-opening)"
bash scripts/xctest.sh -l "$result_dir/first-screen.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$result_dir/first-screen.xcresult" \
  -only-testing:'yuedu appUITests/RSSRealSourceOpeningUITests/testOpenSingleSourceWithoutChallengeInteraction'
```

实际 Xcode 27.2、iOS 27.2 iPhone 模拟器，1 项 UI 用例退出 0，`** TEST SUCCEEDED **`。输出 `containerOpened=true http403Overlay=true challengeVisible=false observationCompleted=true automatedChallengeClicks=0`。此通过只证明真实网页入口可达且首屏呈现 HTTP 403；不能说明真人验证成功，也未模拟勾选、重试或播放。测试结束后保持同一隔离目录启动 Debug App，待用户本人查看和操作。

当前 Xcode 的模拟器图形窗口由 Device Hub 提供，而非单独的 Simulator.app；已按安装位置打开 Device Hub，未安装工具或改系统设置。用户人工流程：选择该 iPhone 模拟器，在 App 中点 Subscriptions → RSS opening fixture，亲自完成验证。记录是否看到正式页面、是否再次出现验证，以及退出重开结果；只有完成这些才可判定本源的网页闭环是否修复。

用户两次确认，手动验证后已能看到漫画列表／分类，不仅是绿色勾选提示；这是本轮模拟器的人工可见结果。对应脱敏日志有 10 条事件，最后仍是 403 文档完成，没有正式页面的 200 记录，因此不把用户可见内容说成日志已证明的 403→200，也不外推真机或退出重开已修复。本次 CF 403 提示条调整是在这次人工观察之后实施，尚未重新访问实源。

## 合入 main（2026-11-19）

用户随后明确要求合入主分支并切换到 main。修复分支 `fix/rss-review-20261117` 的 `3cc914dc576d5af1b145738e896347baf11c361a` 已正常推送；本地 main 先用 `git merge --ff-only origin/main` 同步到远端 `9a88554c`，再以 `git merge --no-ff --no-commit fix/rss-review-20261117` 无冲突合入。补本条记录前，`git write-tree` 与 `3cc914dc^{tree}` 同为 `07d6a2844f52c3d2f3e87a840764a8092d557c0b`：源码、测试与配置未发生额外变化，复用本会话已执行的 25 项 RSS／47 项稳定性回归和 Release 归档证据，不重复 build／测试或声称新提交重新生成过 IPA。合并提交只追加此条交付记录，保留两个父级历史，不 force／rebase、不移动 tag 或发布，未跟踪的用户包／原稿和构建产物保持原样。

## 本轮提交与推送授权（2026-11-19）

用户在上游移植、回归和下载目录 IPA 交付完成后要求提交并推送当前修复分支。提交范围为本轮 RSS 网页 UA、Release 身份、上游首批三项、正式测试和记录；原始源包、用户审查原稿、IPA／归档／日志和其他未跟踪目录不纳入。下文“未提交／未推送”保留各阶段当时状态，不代表后续操作授权。当前 IPA 是提交前的已验证工作区产物，源码与待提交代码一致，但内嵌 GitCommitSHA 仍为构建时的 `8f699695`；不将其说成新提交重新归档的产物，不合并 main、改 tag 或发布。

## 下载目录新版 IPA（2026-11-19）

用户在本批上游移植过程中要求编译 IPA 到下载目录。47 项定向回归通过后，使用当前工作区归档，包含 `75381a89`、`2a66e1e2`、`82177e65` 的适配和此前 RSS 网页 UA 修复；不是之前已交付的旧 IPA。源码差异快照保存后，归档至完成未变化，不自动提交、推送或发布。

Xcode 27.2（27B52）、iPhoneOS SDK 27.2，`xcodebuild archive -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev -configuration Release -destination 'generic/platform=iOS'`，保留 `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`，签名参数为 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=`，未新建 DerivedData 或 clean。归档和 `python3 -B scripts/package_unsigned_ipa.py --archive … --output …` 均退出 0，最终 `** ARCHIVE SUCCEEDED **`。

实际成品位于系统 Downloads 下 `LegadoPro-20261119-211604-wjiAXy/LegadoPro-unsigned.ipa`，36,648,931 B，SHA-256 `86acaf5a41f15a4cde2be9e1798810cbfbf715e980b69c555c5ae3ed6aad6822`，同目录 `.sha256` 一致。真实 ZIP／主包及两个扩展／可执行文件与归档字节一致／arm64 iPhoneOS／3.0（5）／最低声明 17.0／无签名无 profile 均通过核验。主包 `com.deniszheng.legadopro`，扩展分别为 `.widget`、`.shareextension`。归档、源码差异和 `verification.log` 保留在未跟踪 `.artifacts/legadopro-upstream-20261119-HTAeXr/`，未覆盖旧包。

需要用户自签后安装；未做真机启动、Cloudflare 验证、页脚视觉或共享组权限验收。本次只生成新的本地安装文件，不改变既有用户数据；安装、数据恢复与签名授权不由归档成功证明。

## 上游第一批三项移植与回归（2026-11-19）

用户批准后，在 `8f699695` 当前工作区移植 `75381a89`、`2a66e1e2`、`82177e65`，保留 RSS 网页 UA 和 Release 包名修改，不整包 merge／切分支／提交／推送。RED 实际 5 项、1 通过／4 失败：三十章后保留 52 份完整排版、内存警告后仍有 4 份、两个封面空头期望过时。GREEN 的同一输入保留 8 份、警告后 0 份；iOS 27.2 iPhone 模拟器串行回归 47 项／9 suites 全通过，最终 `** TEST SUCCEEDED **`、退出 0。内存增长单次观察 40.8→9.1 MB，不外推实机。页脚原始视觉与真机／iPad／最低系统未验；用户样本没有 `c51b91a0` 接口引用，本批不扩大 Cookie 能力。命令、来源、样本统计与回滚见[本批记录](upstream-stability-batch-2026-11-19.md)。

## 上游 78199517 只读评估（2026-11-19）

上游 `main` 自上次评估的 `5671a240` 起新增 36 个提交。本轮只做补丁适用性检查和整包合并预演，没有合入、构建或运行上游测试；工作区、暂存区和引用前后一致。结论与逐项取舍见[评估记录](upstream-78199517-assessment.md)。

## 本机试用 IPA 与正式版 Bundle ID（2026-11-19）

应用户要求在 `8f699695` 的当前工作区本机归档，包含下节 RSS 网页 UA 修复。Release 主 App 为 `com.deniszheng.legadopro`，Widget 与分享扩展分别为 `.widget` 与 `.shareextension`；Debug、App Group、URL scheme、iCloud 停用与签名项目设置保持原样。[身份决定](../adr/0006-pause-icloud-for-current-release.md)不等于数据迁移；旧 App 的沙盒和凭据不会自动进入新安装。

环境：Xcode 27.2（27B52）、iPhoneOS SDK 27.2。从仓库根目录运行：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
work="$(mktemp -d -t legadopro-local)"
xcodebuild archive -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$work/LegadoPro.xcarchive" -resultBundlePath "$work/LegadoProArchive.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  > "$work/archive.log" 2>&1
python3 -B scripts/package_unsigned_ipa.py --archive "$work/LegadoPro.xcarchive" --output "$work/output"
```

实际目录 `.artifacts/legadopro-local-20261119-lg0A2f/`，归档与包装均退出 0，`** ARCHIVE SUCCEEDED **`。最终 `output/LegadoPro-unsigned.ipa` 36,648,128 B，SHA-256 `11f40b94b3e0f2f3152cf67e2e67dce16e0d6d6770ba053442d6d89f0d641bc6`。ZIP 内容、实际 Info.plist、两个扩展、Mach-O arm64/iPhoneOS（3.0／5，最低声明 iOS 17.0）、无签名／无 profile 已核对，见同目录 `verification.log`。`python3 -B -m unittest discover -s scripts/tests -p 'test_fork_configuration.py'` 9 项 OK、以 `test_*ipa*.py` 为筛选 20 项 OK。未使用证书、未安装、未运行云构建或发布；签名、共享组授权及实源验证由实际安装后确认。配置回滚用同目录 `before/` 对照，仅恢复本轮身份和打包合同差异，不撤销 RSS 补丁或改动用户数据。

## RSS 网页缺省 User-Agent（2026-11-19）

在 `8f699695` 复现（相关请求代码与报告基线 `9a88554c` 一致）：`header: {}` 并非不发送 UA。RSS 适配复用书源脚本运行时，`58ab9cb2` 加入的 `JSCoreEngine.resolvedSourceHeaders` 会先补桌面 Chrome UA，再由 `applySourceAuthentication` 合入请求。对照[先前的单网页诊断](rss-single-page-diagnostics.md)，`64149fd1` 修的是同一原生 WebKit 会话内的请求连续性；单个实源的恢复还伴有网络节点和源头变化，不能证明本次循环也是同一原因。

网页准备读取源实际声明的头（JSON 或脚本），在 URL options 与同源导航上下文合入后，只有缺少 UA 才补按系统主次版本生成的手机 Safari UA；不按字符串判定来源，显式配置相同的桌面 UA 仍保留。直接传入的网页请求也在发送前补默认值（文档缓存键随实际 UA 自然失效）；无请求上下文的 HTML 由 WebView 使用同一默认值。书源、标准 Feed 刷新、独立图片/媒体请求、Cookie 和导航准入不变。

本地合成 HTTP 页面复用了生产 WebView 和请求执行器。原版 RED 聚焦 3 个测试、12 条 UA 断言失败：请求快照与 `navigator.userAgent` 实际是桌面 UA；第一次只在缺头时补值，仍失败，并有一次既有 POST 返回测试在截止前未出现历史项；未放宽等待，最终该用例也通过。最终在 Xcode 27.2（27B52）、iOS 27.2 iPhone 模拟器运行：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
result_dir="$(mktemp -d -t yuedu-rss-web-ua)"
bash scripts/xctest.sh -l "$result_dir/final.log" -- -resultBundlePath "$result_dir/final.xcresult" \
  -only-testing:'yuedu appTests/RSSBrowserSessionTests' \
  -only-testing:'yuedu appTests/RSSWebRequestTests' \
  -only-testing:'yuedu appTests/RSSWebDocumentCacheTests' \
  -only-testing:'yuedu appTests/RSSArticleFullTextRequestTests' \
  -only-testing:'yuedu appTests/RSSNativeWebFlowTests/loginPageOwnsItsForm()' \
  -only-testing:'yuedu appTests/LegadoDefaultUserAgentTests' \
  -only-testing:'yuedu appTests/HeaderRulePerRequestTests/analyzeUrlRequestEvaluatesOnce()'
```

`Test run with 25 tests in 7 suites passed`、`** TEST SUCCEEDED **`、退出 0；xcresult 为 25/25 通过（含参数组合共 39 个通过项），0 失败/跳过。覆盖原生首请求和表单、文档首请求和后续导航、无上下文 HTML、显式 UA 和原缓存/登录边界。未访问实际受影响站点或进行真机验证，Cloudflare 是否仍循环需用户用原出问题源手动复测。回滚只需反向应用本次代码和测试差异，无源配置或持久数据迁移。

## 当前修复分支推送与本机IPA（2026-11-18）

已提交并Push `fix/rss-review-20261117@890285fa`（37文件793增／59删，包含本地首批`9ee66fb5`），远端核对一致，main仍40065b99；不合并main／改tag／发布。用户最新决定取消关机、推送后本机编译IPA。本机Xcode27.2（27B52）／iPhoneOS27.2，复用`Reader-Fork-Dev` Release和现有unsigned打包器，`xcodebuild archive`退出0／`** ARCHIVE SUCCEEDED **`，`python3 -B scripts/package_unsigned_ipa.py`退出0，IPA合同19项／OK。

产物`.artifacts/rss-review-20261117/local-ipa-890285fa/output/LegadoPro-unsigned.ipa`，36,646,075 B，SHA-256 `edd56c09c6f68dd6c89b860196f4e2329acd9373ef89a96bd402671a950df9b2`；真实ZIP、arm64、LegadoPro／dev.denis.readerfork.dev／3.0（5）／最低17.0、两个扩展及校验和核对通过，无签名和embedded profile。主App无CloudKit权限，既有App Group配置保留；需自行签名安装，未验证该包真机启动／扩展权限／声音，不冒充S8或发布通过。命令和限制见[本轮交付记录](rss-external-review-fixes-2026-11-17.md)；原包、用户数据、日志／IPA未提交，不关机。

## RSS 外部 Review 修复与双设备 full 通过（2026-11-17～18）

当前 `fix/rss-review-20261117` 在 `9ee66fb5` 上补普通 Feed 全文的 owner／session／动态源 header、重定向基址、未知附件与元数据、静态懒加载图片、近尾预取和受限媒体诊断。定向集合实际25／13／26项通过，范围有重叠不混算；音频端点格式、有限Range及极端起点溢出修正后，当前**full两设备各68项／16 suites、零失败／跳过／预期失败，最终`** TEST SUCCEEDED **`、脚本退出0**。证据`.artifacts/rss-review-20261117/full-maintained-iphone/`与`full-maintained-ipad-final/`，verifier精确集／设备／模板探针通过，`stageAccepted=false`不变。

R217网站改版导致原`.item`／第三a／data-original规则失效，不修共享解析器、不改原包。用户要求继续后独立预审新版测试配置和当前精确WebP，沿store更新验证旧票据失效／ID不变，2 GET／200／无凭据／禁重定向、13,674 B原生480×300解码与已读收藏／配置重载通过；**原包R217仍失效**，维护后配置不冒充原包可用。新增自建DOM生产请求回归固定旧0条→配置更新→新2条重载。iPad前一次full仅R128隔离目录清理竞争失败，补`flushPersistence`后完整通过。初轮63项双端61通过／2失败、67项65通过／2失败、外层超时和旧图片指纹缺失均保留为历史失败，不改断言刷过。

`python3 -B -m unittest discover -s scripts/tests -p 'test_s8_regression_verdict.py' -v`实际`Ran 11 tests`／`OK`，要求full68／16；Ruby五语4288键、2975调用键通过；交付检查实际输出`RSS_REVIEW_DELIVERY_CHECK_OK docs=8 localLinks=151 swiftFiles=22 sourceHashesUnchanged=2 stagedFiles=0 UTF8_LF=true diagnosticsRemoved=true fullPassed=68 suites=16 devices=2 stageAccepted=false`，`git diff --check`退出0。Review采纳矩阵、命令、过程失败／回滚见[本轮记录](rss-external-review-fixes-2026-11-17.md)。私有捕获依赖已移出代码，产物／原包／Review原稿不提交。用户最新授权收尾后Push当前修复分支并本机编译IPA，**不关机、不合并main／改tag／发布**；iOS17、真机、实际VoiceOver／媒体／登录及签名发布不因自动通过而完成。

## 用户授权的上游首批六项修复（2026-11-17）

以40065b99为起点，在`merge/upstream-small-fixes-20261117`适配66124f63、97b4f5b7、e8bc688b、68e2c544、a4df38b6、5905b06d；不整包merge，不升级依赖／版本、不恢复Pro、不引入新首页／模块JS。本次按后续授权提交已验收补丁与正式记录，不Push，main引用不变；来源、逐文件适配、命令及回滚见[首批记录](upstream-small-batch-2026-11-17.md)。保留已有媒体真正拆除／临时覆盖区分，搜索仍为Fork推入页，不加上游搜索Tab根标题锚点。

原始RED：7项单元行为失败、iPad静置最近记录2项UI失败。修复后xcresult为green-unit7通过、iPad搜索3通过、iPhone回归56通过／3跳过、iPad回归58通过／3跳过、iOS26.2无障碍3通过；所有run最终`** TEST SUCCEEDED **`。跳过均为私人EPUB缺失，不计通过；另用自建图片／Unicode／装饰块及既有合成图片用例补测，5通过／0跳过。集合含重复，不相加宣称独立总数。

同机固定HTML的857790字符分页由16372ms变1576ms，页数1362保持；4倍正文耗时比9.24→3.56，是本次单次模拟器证据，不外推真机。首次fixture编译错误与补图测试缺import均保留为失败记录，修正后才实际通过。最低iOS17、真机、实际VoiceOver／连续朗读、真实源及云产物／自签仍未验收；不宣布S8或发布完成。

`ruby scripts/check_localizations.rb`退出0，5语言4285键、Modules／Targets2972 literal key均齐全。交付检查`python3 .artifacts/upstream-small-batch-2026-11-17/check-delivery.py`输出`SMALL_BATCH_CHECK_OK docs=7 localLinks=108 swiftFiles=12 greenRuns=6 dependencyChanges=0 stagedFiles=0`，`git diff --check`退出0；仅本地留存脚本／日志，不提交源包或其他用户资料。

## 后续复审核对与发布表述修正（2026-11-17，先前只读快照）

核对固定`main@40065b99`：`git ls-remote origin refs/tags/reader-fork-v3.0-rc.1 refs/heads/main`实查main为`40065b99`、rc.1为`23b7d7de`；本地`upstream/main`快照`5671a240`相对`dbd25567`为36提交，没有fetch或实际merge。历史build 5的`cb28a56e…`产物对应`5ac9b1b9`，不是当前main；新RC必须以同一目标commit／同一产物建立云归档与自签启动验收，旧开发签名成功不替代年度自签或新代码。

更正历史修复记录中a0ff4497已提交／推送状态；复审表述明确活性检查不写文章／已读／进度但源脚本仍可能更新变量／Cookie／认证，不能写成“完全不写状态”。发布说明及S8清单标明rc.1的已知CloudKit启动风险、不推荐安装，保留历史tag而不强制移动／删除或自动创建Release。用户复审原稿先备份到本地`.artifacts/review-2026-11-17/`，仅按本次明确要求精准修正文义。

[固定上游评估](upstream-5671a240-assessment.md)实查36提交、289文件、两侧45重叠路径；`git merge-tree --write-tree --name-only 40065b99 5671a240`退出1，20冲突路径，仅生成Git对象，无MERGE_HEAD或实际合并。建议小批稳定性修复，不把新增Pro、模块JS、新首页与YueduCoreText0.19.0作为RSS发布必需项。`bash scripts/sim.sh doctor`退出0，仅26.2／27.2 runtime、无17.x。

文档检查命令`python3 .artifacts/review-2026-11-17/check-review-docs.py`实际输出`REVIEW_DOCS_CHECK_OK files=6 localLinks=100 upstreamCommits=36 conflicts=20 head=40065b99 UTF8_LF=true`；检查UTF-8／LF／代码围栏、本地链接、36提交覆盖、发布口径与未实际合并状态。本地脚本不纳入提交。

本轮只有文档修正、只读Git与环境核查，不重跑／宣称Swift、IPA或设备验收；原文档中的历史执行证据保持其对应提交。验收范围、原始失败及回滚记录不改为阶段通过。

## 订阅入口、方格与源维护／活性检查（2026-11-17）

按用户确认移除资源库RSS副入口，保留独立订阅Tab；新增记忆的树型／原生方格切换与平铺分类筛选、源级多选／全选当前列表／确认删除，复用唯一RSSStore。主动活性验证走动态启动页／首分类首列表／标准Feed，不要求搜索接口；合法空、网页可达、仅HTML生成、直接媒体需人工、交互、失败和取消分开，跳过cacheFirst且不写文章。停用源诊断票据与正常读取分离，正常读取仍拒绝停用源。

iPhone/iPad iOS27.2 Simulator各28项／4 suites合同通过，`** TEST SUCCEEDED **`；原生UI每端3项布局／选择删除重载／活性确认，加独立深色AX5长名称18源最后一行1项，合计4个不同UI用例通过，不冒称最后命令整套4项。iPhone文案/store收尾另跑活性UI1项通过；原135行源管理回归保留，新测试独立文件，两端补原5+新10项／3 suites15项通过，iPad首轮worker准备超时0测试不计通过。五语4285键检查、skill一致性和diff检查通过。没有改语言模式、清DerivedData、自动处理实际用户数据；fixture字段／参数域覆盖和停用诊断失败先收敛后修正，编译超时不计通过。组件检索后使用系统LazyVGrid／List和现有解析器，不新增重复组件；GitHub元数据API安全阻断未绕过。详情、命令、边界和回滚见[订阅首页与源维护记录](rss-source-home-management.md)。

本次仅增量功能与固定输入验收，真实源批量活性、iOS17／真机／发布项仍未验证，不宣布S8完成。用户授权所有本轮验收后自动提交Push、最后关机；不触发新Actions或发布。

## 书源网页竖屏视频返回（2026-11-16）

用户确认从书源网页播放、右划或导航返回后反复弹出。上一轮只用横向MP4验证ReaderView暂时覆盖，未覆盖竖向素材和JsBridgeBrowserView真正退出；本次修复该遗漏路径，不按画面方向猜测原因。

固定竖向媒体修复前实际出现旧网页`state=1 fullscreen=true`，关闭媒体/禁止恢复两断言失败；源浏览器拆除新增suspend、解绑/停止、隔离world清空旧DOM及事件，再关闭系统媒体展示和空文档。横竖均明确进入真实WebKit全屏、等待生产关闭完成后尝试晚到媒体恢复；最终旧视频节点已移除，状态none/suspended、fullscreen=false。iPhone/iPad iOS27.2 Simulator各10项通过（XCTest4+Swift Testing6），两份最终日志均`** TEST SUCCEEDED **`；同步JS和合成认证合同保留，Ruby五语4267键检查通过。iPad默认内联与异步关闭的失败记录没有当通过，完整命令/修正及范围见[源网页视频返回记录](source-browser-video-return.md)。

未运行具体源、实际右划XCUITest、type4全部路径、真机/iOS17/PiP/Release；不推送或触发Actions，不改源包/登录/方向策略，不宣布S8完成。

## 禁漫天堂API漫画图片还原（2026-11-16）

用户在上一轮单张长图回归后明确该源仍可复现。B013原始imageDecode的离线像素回放确认缺少Android BitmapFactory/Canvas，源内catch返回乱序原图；不是把整章多图合并成一页。现有共享JS运行时已补有限位图解码/Rect裁剪/编码，不改源包、默认阅读模式或网络权限。

游客实源一章13图，前三张960×1342分别按14/12/4条还原，独立Pillow逐像素最大差异均0；8个请求、零拒绝，不登录、不传签名到CDN。原源固定像素从`returnedOriginal=true restoredPixels=false graphicsMissing=true`变为`false/true/false`；iPhone/iPad iOS27.2 Simulator各48项通过（47项Swift Testing+1项原源XCTest），两个最终日志均为`** TEST SUCCEEDED **`。合成回归覆盖生产Nuke/翻页的三张独立页、40图连续解码及跨Context总预算。测试SDK锁编译阻碍最小修正后，移出临时网络探测并重编译，held响应释放回归1项通过。

实源同次误选后台刷新启动注册测试导致整套失败，该单源XCTest通过与整套失败分开记录；未改注册断言。临时源脚本/原图/签名诊断不进提交或默认测试。B104需登录、B135边界拒绝均未完成图片验证；用户具体章节、iOS17、真机和Release仍未验证，不宣布S8完成。完整命令、证据、范围及回滚见[漫画图片还原记录](manga-image-decode.md)。

## 书源视频退出循环与漫画长图（2026-11-16）

按用户本次授权独立修复书源媒体问题，不改变 S8 的实源／发布门槛。视频修复将内嵌媒体释放从暂时覆盖的 `onDisappear` 移到真实阅读器拆除；长图高宽比 ≥ 3:1 时按宽度布局并可滚动，普通页保持整页适配，阅读模式／存储格式不变。

修复前生产 `ReaderView` 全屏覆盖／退出回归出现 3 个失败，长图回归出现 6 个 issues；最终动态解析的 iPhone／iPad iOS27.2 Simulator 各 15 项通过（XCTest 1 + Swift Testing 14），两个日志均有 `** TEST SUCCEEDED **`。视频使用本机固定 MP4 验证真实播放时钟及实例复用，长图覆盖缓存／新图／底部到达／缩放与位置恢复，并补双页邻页加载／重试中心先失败后通过的回归。未验证用户具体源、实际右划手势、iOS17、真机或 Release；命令、超时与测试宿主修正、Android 参考及回滚见[书源媒体修复记录](book-source-media-fixes.md)。

## 状态

| 阶段 | 当前结果 |
| --- | --- |
| 最终方案/执行计划 | Q1–Q13 已确认；移除 Google/收费，保留 iCloud/WebDAV，备份先保证 Fork 自身恢复 |
| 项目代理指南 | 根目录 AGENTS.md 已生成，格式/相对链接已校验 |
| S0 独立构建与基线 | 本地阶段通过：独立 App/扩展构建、203项相关验收、2项阅读器导入UI及4项iPad UI通过；签名/真实iCloud和最低系统验收留发布门槛 |
| S1 | 本地阶段通过：iPhone/iPad最终各54项通过，固定流程、图片解码、资源约束见[媒体PoC](media-poc.md) |
| S2 | 本地阶段通过：iPhone/iPad各101项，307项离线导入/重载/导出0字段差异；[细节与限制](s2-import.md) |
| S3 | 本地阶段通过：iPhone/iPad120项，iPad导入UI2项；[S3身份与状态记录](s3-identity.md) |
| S4 | 本地补充验收通过：前台owner修正，官方27.2 runtime的正常Dev宿主两设备各238项/35 suites/0失败跳过；旧26.2系统JSC失败保留，[S4记录](s4-runtime.md) |
| S5 | 本地阶段通过并Push：两设备各268项/38 suites/0失败跳过，见[S5记录](s5-browsing.md) |
| IPA/#35 | 实际26.6云归档与产物校验通过，run42460767989，见[归档记录](ipa-first-run.md) |
| 媒体前置/#36 | 当前0f31f857基线加诊断后，正常Dev两设备最新各36/36；完整S6也实际执行音频通过。用户确认Mac音频正常，afplay不作门槛；旧间歇失败根因未唯一定位，见[音频记录](../../Technotes/RSSSimulatorAudioClock.md) |
| S6 | 当前模拟器门槛通过（按用户确认范围）：iPhone/iPad各S5 270/38、S6 99/19 + 网页UI 3项，零失败零跳过。2项真实音频输出时钟PoC移出模拟器集合但保留源码；稳定15a29143真机S6 101/101覆盖HTTP/本地音频时钟，详见[S7范围说明](s7-restore-interruption.md)和[真机记录](device-s6-15a29143.md) |
| S7 | 双设备自动门槛通过：各S5 270/38、S6 99/19 + UI 3、S7 93/20，零失败零跳过；推送前补齐Release构建及81项回归，见[S7记录](s7-restore-interruption.md)。本批未安装真机，发布项待验 |
| S8 | 进行中：当前修复分支full双设备各68项／16 suites通过，R217仅独立维护的测试配置通过、原包仍失效，见[本轮记录](rss-external-review-fixes-2026-11-17.md)；人工／发布未接受。以下为历史证据：307源配置/两页刷新规模、受控RSS分页/正文/状态已有证据；完整批次双设备曾各37项/9 suites补R014真实图片、R141真实MP3原生资源层/进度重载与RSS快速退出修复；随后媒体再次失败，本地音频对照两端ready/clock失败；用户纠偏后同一隔离App/同文件XCTest↔独立App双端均ready且时钟推进，原用例、PCM及R141受控真实MP3双端复查通过；转交的交错A/B又以3轮交替先行、5对采样/10次探针提高了对宿主顺序/单次预热混杂的排除置信度，但当天仍未复现停滞，#77根因未知、不能外推真机或永久修复。最新nonmedia子集两端22项/5 suites通过，新增未知私有头发出前阻断与R128一页无图停止，显式排除R141 MP3、R146 TLS图和R217实图；R217另有独立双设备单图真实解码通过，R146不覆盖。独立R146图片连接两端-1202/SSL -9814证书链时效错误，代码审阅未发现客户端TLS绕过或图片解析缺陷，#78仍是外部证书/信任链前置条件；B122原词无匹配DOM/0条、源检查词12节点/12条，搜索输入响应差异已收敛，不修解析器。按用户决定#77转监控、#78改列外部前置条件后，full门槛双设备各47项/12 suites首次整套实跑通过，原始本地音频合同各1项通过。当前提交Release模拟器编译通过；用户确认保留iframe／JS，R265/R267实播转#58人工、不阻塞其他开发。真实登录、B122后续图片、R146图片（未验收）及设备／发布仍待验，见[收口清单](s8-release-checklist.md)；书源漫画／视频问题独立 |

## 3.0首次Actions归档与SDK阻碍（2026-11-15）

用户授权后，3.0准备改动已提交Push为`ad96e15c`，通过现有手动工作流触发run43681572831。Xcode26.6／Swift6.3.3／iPhoneOS SDK26.5：17项合同与依赖解析通过，完整archive日志报`BookSourceCheckBackgroundTask.swift:126:67 extra trailing closure passed in call`，IPA打包上传跳过，没有IPA或Release。

原因是SDK26.5不能读取iOS27后台调度的新回调重载，仅运行时available不足；已为新回调增加编译器保护，旧工具链沿用原提交方法，不变更线程、Swift／优化／签名设置。新增静态回归先失败后通过，Python合同18项通过；仍须下一次真实Actions archive确认，不能把静态通过标成编译修复完成。后续不在本地编译，完整日志、命令与边界见[云归档记录](release-3.0-cloud.md)。

## 3.0图标与IPA前置准备（2026-11-15）

在`cd159098`之后的未提交工作区，按用户确认修正IPA守卫测试的过期类型名断言、使用最终提供的`閱讀 Pro Logo.png`替换系统及应用内7张图标，并将统一版本设为`3.0`、构建号保留`4`。工作流／打包合同17项实际通过；原生actool的iPhoneOS／iPhone／iPad图标编译退出0，PNG尺寸／无alpha／灰度／CRC及项目文件与候选文件一致性通过。Release build settings实查App、Widget、ShareExtension均为3.0（4）、最低声明17.0；新版本正常Dev宿主模块回归7项／2 suites通过。命令、环境、备份和回滚见[3.0准备记录](release-3.0-preparation.md)。

以上是准备时的历史证据，当时没有提交Push、完整Release真机archive／IPA、签名安装、正式身份或S8人工验收。用户随后要求后续编译全部使用Actions，并授权提交Push后交付GitHub预发布；不再本地构建，不把旧归档结果外推到新资源版本。云端结果须在实际执行后另行记录。

## 固定上游首批合入（2026-11-15）

按用户确认，只合入`cc566a84..dbd25567`的7个提交到本地`merge/upstream-dbd25567`，合入前Fork为`a0ff4497`；不自动Push，不扩大到模块3.0.2及首页／详情重设计。仅iCloud文本冲突，保留Fork的`SyncRecord`／`SyncMerge`、旧shadow key及移除Firestore的决定，补不同正文版本的首次同步隔离。书架UI种子改为测试临时目录，默认书架文件测试前后SHA-256一致，没有擦除模拟器或自动授予权限。

Xcode27.2、动态解析的iPhone／iPad iOS27.2 Simulator，`Reader-Fork-Dev`串行测试：核心40项／10 suites、版本隔离与同步／漫画18项／3 suites、书架UI9项零失败、清除诊断后的Fork边界42项／6 suites、iPad双页8项／2 suites、目录失败分支1项／1 suite均实际通过。集合重叠，不合计成独立测试总数。漫画落盘及不同正文版本同步均保留先失败后通过证据；RSS呈现曾因懒父容器遗漏就绪偏好而超时，四张图片已完成的诊断后改为条目观察，断言与超时不放宽，生产RSS代码不变。本地化主资源5文件4267键通过；详细命令、日志、未验证与回滚见[首批合入记录](upstream-dbd25567-integration.md)。

本批没有验证真实iCloud、R146新证书政策实图、真机、最低iOS17、人工VoiceOver或正式签名／发布；S8仍人工待验。真实源包、用户评审资料与本地工具／捕获保持不动，不加入提交。

## S1–S8 CodeReview交接（2026-11-14）

用户已授权将当前代码和随后确认的7份验收文档提交到`origin/main`供CodeReview；本节之后的“未push”均描述当时历史状态。代码／Release验证对象仍为`fdd60bd4`，本次后续提交只有文档；不自动重跑公网验收、手动触发云构建、安装手机或发布。审查建议以`bd6b0076`（S0完成后的独立Fork基线）到审查固定HEAD为S1–S8范围；包含S0时以`f821dc9a`为起点，详见[交接清单](s8-release-checklist.md)。原始源包、临时目录、xcresult和私有日志均不上传，S8整体仍人工待验。

## 本地提交后的人工分流与Release准备（2026-11-14）

当前代码已本地提交`fdd60bd48714c1d38f78013731f120748348c921`，保留`64149fd1`，未push。54个相关文件入库，原始源包与`.codegraph/`、`.workbuddy/`、`__pycache__/`仍未跟踪，未删除。用户结构化确认“保留能力，转人工”：R265/R267真实播放移入#58人工／发布验收，不关闭生产iframe／JS、不扩网络准入，实源仍未验证，不影响已通过的自动回归及后续独立开发。[验收矩阵与操作卡](s8-release-checklist.md)逐项区分通过、未验收、外部前置条件及另行授权动作。

实际Release准备：`DEVELOPER_DIR`／`YUEDU_DEST`由`scripts/sim.sh`解析，`xcodebuild -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev -configuration Release -destination "$YUEDU_DEST" -resultBundlePath <证据目录>/build.xcresult CODE_SIGNING_ALLOWED=NO build`退出0。证据`/tmp/readerfork-s8-release-preflight.gAUsSt/`，含原始构建日志、settings、xcresult、源commit及产物摘要。Xcode／SDK27.2、实际Swift语言模式6.0、无DEBUG；App及两个扩展为Fork开发身份、平台iphonesimulator、最低声明17.0；Mach-O为IOSSIMULATOR／minos17.0，主二进制未发现DEBUG-only音频宿主符号。复用既有DerivedData，没有clean或新建路径。doctor只发现26.2／27.2 runtime，无iOS17。

这只证明当前工具链Release编译与产物检查，不是Release运行／iPhoneOS归档／IPA／真机媒体／iOS17／云签名验收。未安装或启动手机App，未访问第三方iframe，未改生产代码、签名配置、权限或系统时间；未触发CI或发布。回滚仅撤回本次验收文档分流说明，不回滚代码提交、不删除数据或历史证据。

## 本地提交前核对（2026-11-14）

范围为`64149fd1`之后的#74网页返回、RSS快速退出进度、模板日志安全以及S8隔离测试/门槛/诊断记录；不宣布S8阶段完成。原始253/307条包、`.codegraph/`、`.workbuddy/`、`__pycache__/`不提交，不推送、不装手机。

#74正常`Reader-Fork-Dev`宿主复核：通过`scripts/sim.sh`解析Xcode与两台模拟器，串行运行`scripts/xctest.sh`，选择`RSSBrowserSessionTests`与`RSSWebDisplayUITests`。两端各12项（7项单元合同、5项UI），零失败/跳过；覆盖网页返回、刷新后返回、同文档history/hash、POST不重送、撤销、AX5/深色及旧缩放/退出。完整结果`/tmp/readerfork-local-commit-webback.ZBbVp8/{iPhone,iPad}.xcresult`；测试构建同时提供当前工程编译证据，不重复clean/build。S8代码未变，复用下文双端full47项/12 suites与WebKit边界3项实际通过结果，不重复公网验收。

音频交错脚本、比较器和新增探针一并保留；交错探针的运行结果为用户转交，本会话只复核脚本/离线单测，不把bundle identifier hash当作构建二进制身份，也不把少量同日通过视为排除所有冷启动/预热因素。#77仍按监控处理。提交前实际运行`python3 -B -m unittest discover -s scripts/tests -p 'test_s8_*.py' -v`共16项通过，5份相关shell语法检查、Python解析、本地化4114键、双份设计skill一致性、文档相对链接、原始包SHA-256和改动文件隐私扫描通过；暂存前后检查只包含审核过的54个相关文件。

## S8补充：#77/#78解除持续阻塞与full门槛首次实跑（2026-11-14）

按用户决定把根因调查、缺陷状态和阶段门槛分开。

- 原始音频合同`RSSMediaPoCTests/testLocalAudioActuallyAdvances`：iPhone/iPad模拟器各单次执行1项通过、零失败零跳过，`/tmp/readerfork-s8-audio-contract-174833-{iPhone,iPad}.xcresult`。未循环、未改断言。#77据此转为“未定位的间歇风险、监控中”，重开条件见[音频记录](s8-audio-clock-diagnostics.md)；不是修复结论。
- R146图片用例改列外部证书链前置条件：从两种模式的通过集中剔除，verifier单列`externalPreconditionsNotRun=1`，结果树出现该用例即拒绝。状态为未验收。verdict/shell单测10项通过，新增该拒绝对照。
- `bash scripts/validate_reader_fork_s8.sh full`：iPhone/iPad各47项/12 suites通过，零失败/跳过/预期失败，脚本退出0，`stageAccepted=false`。证据`/tmp/readerfork-s8-full-iPhone.skTNEI/`、`/tmp/readerfork-s8-full-iPad.44CJ0U/`。两端一致：R141 MP3 3事务200/200/206、推进500/502ms、进度重载；R217 WebP 12,838 B/480×300；R014 JPEG 75,292 B/640×440；R146列表/正文4事务、987字符、状态重载，图片未请求。

未验证：原规则网页/iframe真实播放、真实受限登录、iOS17、物理设备、人工VoiceOver与发布项；R146图片；#77根因。只改测试门槛脚本、单测与文档，无生产代码/TLS/播放器改动，未装手机、未commit/push、未清数据。回滚：把R146用例从`EXTERNAL_PRECONDITIONS`移回`EXCLUDED_NONMEDIA`并恢复shell中nonmedia专属skip与单测计数。

## #77/#78 转交诊断结果核对（2026-11-14）

#77的新增交错工具 `scripts/compare_reader_fork_s8_audio_interleaved.sh` 在实现上交替 XCTest/Standalone 先行，默认3轮、上限5轮，任一轮未ready或未推进即停止；`--allow-rotated-container` 只放宽容器路径和输入路径哈希，仍校验bundle哈希、输入内容SHA-256、字节数、宿主身份和AVPlayer状态。工作区离线比较器测试6项通过，shell语法通过。用户转交的结果称3轮交错、另2对补全，共5对/10次探针均ready、推进、`timebaseRate/effectiveRate=1`；本会话没有重跑这些模拟器探针，报告中的`/tmp/readerfork-audio-host-interleaved.*`目录当前也不可见，因此这里只记录为转交结果，不把它当作本会话独立复现。它提高了对“固定宿主顺序/单次预热”的排除置信度，仍不能定位CoreAudio服务间歇卡死，也不能外推真机、可听声音或网页播放器。`RSSMediaPoCTests/testLocalAudioActuallyAdvances`在转交会话中未完成独立复检；其后已在主会话双设备补跑，见上节。

#78的代码路径为 `RSSImageService` → `SourceRequestExecutor` → 系统URLSession；没有serverTrust/challenge放行、关闭ATS或自定义TLS校验，`S8RequestBoundary`只做测试请求准入。现有`-1202/-9814`发生在HTTP响应之前，R146列表/正文同源事务通过，当前证据不支持修图片解析器。保持系统证书校验；如要继续，只做用户另行决定的同一确切目标与Android基准/干净设备受控对照，并只读核查本机时钟。若证书链确实过期，应标记外部前置条件或换代表源；不装CA、不改时间/网络、不关闭校验、不重复公网重试。



用户明确解除真机暂停后，使用独立15a29143工作树及既有真机DerivedData/个人签名构建，安装到iPhone 17 Pro (iOS27.2)，安装包GitCommitSHA与提交一致。真机101项/20 suites、零失败零跳过，包括本地/HTTP音频、MP4/HLS真实时钟及新增网页显示测试；测试后已重新打开正常App。证据 `/tmp/readerfork-device-current.DekGzG/`，命令/范围/回滚见[真机记录](device-s6-15a29143.md)。本次不能验收iCloud/App Group；Simulator-only三项网页工具栏UI未在手机执行。用户在本次回归后已明确确认当前版本「画面声音正常」。不把尚未完整编译/验收的S7工作区混入手机安装物。

## 当前基线：网页显示闭环与完整S6复验

用户选择继续以 `0f31f857` 为基线；不恢复回退前整包提交。本轮独立新增网页缩放/原生退出及测试，接入既有首文档生命周期；缓存修复与音频诊断保持一条请求/播放器路径。最终iPhone `/tmp/readerfork-current-s6-viewport.SsfuYj/iPhone/`、iPad `/tmp/readerfork-current-s6-ipad-recheck.AU0Pd7/`，各S5 270项/38 suites、S6 101项/20 suites与3项UI零失败零跳过。首次iPad S5原生RSS搜索未在8秒截止内出现结果；原条件16项及完整重跑通过，未改等待或搜索实现，原失败保留。RED/GREEN、命令、截图、本地化4111键、未验证范围及回滚见[本轮记录](s6-web-display.md)。不把合成弹层通过写成真实站点已恢复或S7/S8已完成。

## 当前基线S7：WebDAV中断恢复与后台重载

当前工作区已补齐active journal、启动前恢复、跨分类owner回滚、后台解析/重载、revision拒绝过期快照和强杀UI。iPhone/iPad owner回归各76项/13 suites，入口聚焦UI各10项/7 suites，均零失败零跳过；完整阶段证据及模拟器音频范围调整见[中断恢复记录](s7-restore-interruption.md)。完整S7脚本双设备均通过：S5 270/38，S6 99/19 + UI 3，S7 93/20，零失败零跳过。

两条真实音频输出时钟用例仍在源码中，但按用户确认从模拟器S6门槛排除；稳定15a29143真机S6 101/101含HTTP与本地音频时钟。本批未在真机安装。用户已授权推送；推送前修正DEBUG钩子泄漏到Release的编译错误，Release build和81项/11 suites定向回归通过，证据 `/tmp/readerfork-prepush-verified.y7qNNr/`。

## 当前基线S8：分层实源与规模验收

iPhone/iPad最新主工作区整合集各47项/11 suites通过，含S8受控代表源复跑：R181 XML 10条，R265 HTML媒体列表100条，R014第二页追加至40条，B002文本搜索3项；B122规则fixture在匹配DOM上解析1条、0请求；ordinal146两页/正文/状态恢复各通过、正文987字符，首个同源301后200，所有transaction同源且无凭据。真实媒体只验证规则列表中的标记，不加载媒体内容。ordinal146外部图片`NSURLErrorDomain -1202`保留为未通过，禁止绕过TLS。B122真实搜索HTTP200仍0项，合成fixture不能推断真实查询结果。请求预算、性能观察与未验证范围见[S8验收记录](s8-acceptance.md)。

S8仍未闭合：B122真实图片搜索HTTP200返回0项，但使用它真实规则的合成匹配DOM成功，不能据此将真实源判为可用或归为生产解析缺陷；ordinal146的外部图片请求因TLS证书错误`-1202`未通过，保留证书校验。RSS深分页/正文代表流程已覆盖，但媒体图像/CDN尚未闭环；不能用合成fixture替代站点验收。用户报告的书源漫画翻页与视频弹出仍为独立问题#64/#65。阶段状态与剩余限制见[S8验收](s8-acceptance.md)。

## RSS 单网页实源：当前节点恢复，重开通过

用户补充的「1第一道路 / 禁漫天堂-漫画」来自另一个399项导出，不是本仓库307项包中的R062或书源。原生首文档47次HTTP403及HTML错误页实验的真人验证循环均保留为失败证据。第三版在获授权后以稳定15a29143基线无线安装：简单singleUrl从首请求起保持同一个WebKit会话。旧VPN节点下Safari和App都循环；用户换节点后Safari恢复、App仍失败；再仅将该源header改为字符串`{}`、使用真实WebKit默认User-Agent，网站正常，日志记录403后同会话200。用户划掉App后重开并两次进入均正常，最终4次响应200、3次完成200、0次新403。

隔离候选定向26项/6 suites、0失败/跳过及签名核验通过；主工作区已整理相同行为与类型化日志，并补默认UA回归，整合后验证单独记录。没有统一覆写所有源的UA、绕过TLS或自动操作验证；旧节点限制和长期稳定性不在通过范围。详细命令、前后证据及回滚见[单网页诊断记录](rss-single-page-diagnostics.md)。主S7/S8工作区仍未装到手机，S8、书源漫画和视频问题继续单列。

## S8补充：WebKit iframe公开边界可行性（2026-11-14）

仅用loopback HTML/嵌套iframe与WebKit本地规则完成双设备3项：精确iframe文档导航可由公开navigation delegate在HTTP前拒绝；`WKContentRuleList`阻断未知子资源/redirect目标，但没有子资源逐请求回调或累计预算，重复获准资源可多次请求。被测6个HTTP事务中只收到3次文档导航回调；另有已有scheme handler held-task取消合同各1项，范围不推广到HTTP(S)。因此不放宽R265/R267真实跨源iframe许可，明确仍未验证。证据/推理及回滚见[WebKit边界PoC](s8-webkit-boundaries.md)。

## S8补充：R217单张真实公开图片与R128无图停止（2026-11-14）

固定307条RSS包sha仍保持既定hash。按只读/无凭据方式预审后新增R217：每端列表1 GET/200，生产解析18条/17个唯一图片目标；所有目标HTTPS、query/fragment/嵌入凭据为0，唯一目标host hash固定，PNG/WebP两种扩展。首目标整URL只以SHA-256留痕。生产闭环重新读取一页，先验证固定shape与URL hash，再仅显式准入一张跨origin WebP：列表GET+图片GET=2个事务、均200；图片12,838 B，经`RSSImageService.inspect`及`displayImage`得到480×300，RSSStore已读/收藏/图片URL重载双端通过。0凭据、0跳转，唯一跨origin事务即所审图片，0额外图请求。R217其余16个独特目标没有访问。两个设备的最终1项精确用例结果在`/tmp/readerfork-s8-r217-image-cookie-audit-{iPhone,iPad}.xcresult`，启动日志同前缀`.log`；此前单页/指纹对照见`/tmp/readerfork-s8-r217-image-target-fingerprint-{iPhone,iPad}.xcresult`。

R128只做过首列表1 GET/200，解析20条、无任何图片引用、0媒体请求，之后冻结无图结果不尝试图片/翻页。R217与R128均进入固定manifest：R128在nonmedia，R217实图闭环在full；当前nonmedia双设备完整运行各22项/5 suites，零失败零跳过、`stageAccepted=false`，10项verdict/shell单测通过。full manifest为48项/12 suites、尚未整套运行。最终nonmedia证据 `/tmp/readerfork-s8-current-nonmedia-iPhone.kDBTd1/`、`/tmp/readerfork-s8-current-nonmedia-iPad.42BVWD/`。R014既有图片独立。#77间歇音频根因、R146 `-1202/-9814`及R265/R267真实iframe不受影响。

保留开发期失败结果：R128首测错把`ruleImage`配置等同于每条都有图片，页面GET后测试断言失败但没有图片请求；R217的错误分类项数/跨源假设在HTTP前即被拒绝。更正后双设备预审及精确闭环通过。无生产代码/TLS/认证改动，无真机安装、commit/push、设备清理；详细范围和回滚见[R217记录](s8-r217-image.md)。

## S8补充：R265/R267 iframe只读预审与TLS限制（2026-11-14）

R265仅用原预审首页1 GET/200获取100条，生产解析条目交离主线程SwiftSoup作静态审计，iPhone/iPad各1项通过：100个iframe、100个跨源、100个带query，0个直接media、0个条目内script/preload、0个内嵌凭据/格式错误，**0个iframe/媒体子请求**。冻结条目/目标host形状，发生变化必须重新审阅，不让新目标自动进入WebKit。R267仅原包静态审查、0网络：其iframe指向同一第三方host但源URL还有query。配置为type0规则网页、enableJs=true；不因父HTML无script认为子frame安全。自建生产规则网页6项和本地WebKit iframe HLS1项双设备各7/7通过，是分开的合成合同，不是R265第三方网页真实播放。证据 `/tmp/readerfork-s8-r265-guarded-{iPhone,iPad}.xcresult`、`/tmp/readerfork-s8-iframe-fixture-{iPhone,iPad}.xcresult`，命令、资源预算与回滚见[iframe预审](s8-iframe-preflight.md)。

R146首图当前仍为系统-1202/SSL -9814链时效失败、无HTTP状态/解码；本轮不重复请求、不改CA/VPN/时间/TLS。R014成功不覆盖它。WebKit第三方子资源不受S8测试专用URLSession精确准入全局约束，未自动加载整站iframe；没有安全可约束的真实目标时保持未验而非模拟器绿灯放行。无新依赖/权限、原包改动、手机安装、commit/push或设备数据清理。

## S8补充：同文件XCTest/独立App音频宿主对照（2026-11-14，根因未定）

此前的Apple API查询与窄搜索不足以判断系统原因。扩大检索后找到旧Simulator同15秒超时/-66681的一手复现、XCTest与App不同的案例，以及VM权限影响音频输出的案例，均不等于当前27.2根因。用新的DEBUG+Simulator-only隔离探针在同一已启动设备、同一App容器的同一个Caches m4a文件（SHA-256与路径哈希双方完全一致）、同一播放器代码与AVAudioSession、同一10秒ready/8秒时钟截止比较XCTest和独立App。没有触及RSSStore、用户源/网络，也没有改路由、时钟或系统设置。

iPhone XCTest 0.495秒、独立App 0.430秒；iPad 0.497/0.420秒，均ready、实际推进、item timebase/effectiveRate=1，XCTest探针各1项Passed。原`RSSMediaPoCTests/testLocalAudioActuallyAdvances`又在双端各1项通过。随后独立PCM及R141真实MP3生产资源链各2项双端通过；R141各3事务200/200/206、推进505/502ms、RSS进度重载与资源停止。证据`/tmp/readerfork-s8-host-ab-gate-{iPhone,iPad}/`、`/tmp/readerfork-s8-current-media-{iPhone,iPad}.xcresult`。A/B只支持当前没有XCTest专属故障，旧15秒/timebase0失败仍保留，次序XCTest先、App后不消除预热可能；音频**间歇根因未定**，不能把双端一次成功写成系统修复或可听真机声音。

A/B初次独立实测两端匹配并通过，首版shell收尾中文紧贴`$EVIDENCE`被bash误读为变量、导致完整脚本退出非零；改为`${EVIDENCE}`后复跑两端完整脚本退出0。新增同输入/宿主/容器精确比较及5项Python验收测试，检查不匹配必须拒绝、单端失败不能伪装相同；脚本不会覆盖已有结果、拒绝非已启动模拟器、只清本轮UUID测试媒体目录且不关闭模拟器。两端nonmedia子集21项/5 suites复跑通过，15项Python门槛单元通过、文档链接/源包哈希及`git diff --check`通过；full46项未运行。详见[音频对照记录](s8-audio-clock-diagnostics.md)，保留#77间歇风险；#78的R146 TLS仍失败，S8继续进行中。

## S8补充：audio-only拆除前状态与PCM对照（2026-11-14，历史失败）

读取既有双端m4a时间线后校正：ready10秒截止时unknown/error=nil；约+15.2秒后KVO进入ready，最终buffer可用/duration4.975、rate1/playing，timebaseRate0和clock0。不是最终始终unknown，更不是ready即播放通过。当前SDK与Context7官方API核对后只增加状态读取，iPhone限定一次m4a探针仍失败：outputSuppressed=false/muted=false/volume1/sourceClock未覆盖/effectiveRate0。另自建无压缩1秒PCM也同样ready延迟、duration1已识别但时钟0；不经RSS/网络/压缩解码，不能只归因m4a。MP4原loopback对照1项通过，不外推所有AVPlayer坏或音轨可听；只读Mac默认设备存在/48000Hz也不认定主机音频正常或异常。

未设置clock/路由优先参与者、静音/音量、超时、系统设置或服务/设备重启，无生产补丁；新PCM独立类不混入S6批准集或非媒体通过集。官方网页直接抓取被fake-IP安全拦截，未放宽SSRF/代理，不把旧发布说明套到当前27.2。#77保留，命令、时间线和附件见[音频只读对照](s8-audio-clock-diagnostics.md)。

## S8补充：未知私有头的请求前阻断（2026-11-14）

审查发现S8测试边界仅拦Cookie/Authorization/Proxy-Authorization不足：新增loopback真实请求负例复现X-API-Key可发出，5项suite因服务器实际收到请求而失败。已改为公共传输头名称许可名单，未知私有头发出前拒绝，原正常GET/HEAD/确切跳转与预算保留；不修改生产认证/CookieJar或源私有头功能。公共头值仍需固定源/登录配置预审，不将名称名单说成通用安全代理。

首次Swift Testing函数名选择实际0项被wrapper拒绝；随后整个5项suite真正红→绿。将5项边界合同纳入nonmedia，10项verdict/shell单元通过，最新脚本双设备完整退出0各21项/5 suites、零失败/跳过。full46项仍未整套运行，nonmedia相对full25项未执行、其中2显式排除，stageAccepted=false，#77/#78保持。证据 `/tmp/readerfork-s8-header-gate-{iPhone,iPad}/`，原红/0项、命令和回滚见[私有头边界记录](s8-header-boundary.md)。未向公网发送fixture key，未改生产认证、原源包或权限，无真机安装/commit/push。

## S8补充：可重复自动回归与误放行保护（2026-11-14）

新增`validate_reader_fork_s8.sh`及verifier：明确full46项/12 suites和nonmedia16项/4 suites，精确用例manifest、普通/restricted日志探针、wrapper/summary/tree/最终控制台共同判定。前置仅接受当前可用iOS Simulator明确ID并复验实际设备，物理/未知/不可用/模糊目标在xctest前拒绝；原始包哈希改变或工程覆盖不执行请求，不覆盖旧xcresult。任何模式stageAccepted=false，full亦不等于阶段/发布验收。

10项Python/shell单元实际通过；新脚本nonmedia双设备完整退出0，各16项/4 suites。full46项只验证manifest/拒绝逻辑，未实际整套运行；nonmedia相对full未执行30项（含2项显式排除），不覆盖#77/#78。实际已失败R146 xcresult亦被verifier拒绝，框架3项通过不能掩盖其1项失败。首版最后echo的macOS bash全角相邻变量解析错误已用真实footer执行复现并修正，再完整双端验证。证据 `/tmp/readerfork-s8-gate-verified-{iPhone,iPad}/`；命令、失败与回滚见[自动回归门槛](s8-regression-gate.md)。

另iPhone原loopback MP4 seek/推进1项通过，限制了本地音频失败的外推；两个额外HTTP视频候选仅有限目录预审200后，因device/uuid/udid参数进一步审查而停止，不计播放器成功、不改标识或URL。无真机安装、commit/push、设备/音频服务重启、弱化TLS或新增依赖。

## S8补充：R146图片TLS时效复验（2026-11-14）

先从实际正文只读取首图准入元数据，再用确切URL哈希、无query/凭据、独立1 GET任务预算，通过生产RSSImageService实际尝试。两端均1图片连接事务、无HTTP状态、0凭据/边界拒绝，系统-1202，底层SSL -9814。当前SDK SecBase.h定义为errSSLCertExpired（chain had an expired cert），不能唯一归因哪一张证书、源站/CDN或代理/本地信任环境。没有绕过TLS、安装CA、更改网络节点/时间或重试。两页/正文4个事务301/200/200/200及状态重载仍通过；图片未进入已证明成功的解码，#78门槛保留。

iPhone独立1项失败，iPad该1项失败且3项安全元数据合成合同通过，不采用后者覆盖失败。最新非媒体子集双设备16项/4 suites零失败零跳过，明确排除真实MP3及R146图片TLS两项；完整用例集合核对，控制台模板原始载荷检查仍通过。证据 `/tmp/readerfork-s8-nonmedia-final/`，独立失败、SDK证据、命令与回滚见[R146 TLS记录](s8-r146-tls.md)。原始系统日志/xcresult不直接外发，测试输出仅白名单元数据。未更改生产TLS或安装手机，未commit/push。

## S8补充：B122空结果实源对照（2026-11-14）

两个无凭据同源GET、完全相同生产请求/规则链：原固定词HTTP200且输入DOM规则节点0/解析0；源内checkKeyWord HTTP200、有效DOM12/解析12。双设备结论一致，响应字节略有变化，不声称相同HTML。原零结果收敛到搜索输入/站点响应差异，不支持修改iOS解析器；未唯一确定词条/站点匹配原因，也不代表详情、封面或漫画图片链通过。旧合成fixture仍仅0网络合同。

最终两端各13项/3 suites零失败零跳过，显式排除R141音频；控制台原始模板载荷检查仍通过，不覆盖#77媒体失败。证据 `/tmp/readerfork-s8-b122-final/`，命令、边界、开发编译失败和回滚见[B122搜索记录](s8-b122-search.md)。原源包哈希不变，未安装手机或commit/push。

## S8补充：模板原始日志泄露与媒体复验失败（2026-11-14）

已用实际控制台合成探针复现AnalyzeUrl直接NSLog绕过统一脱敏，普通/restricted上下文都会输出模板表达式和结果；请求求值测试虽通过，外层日志校验明确失败。最小修复仅删除原始输出，保留求值语义。双设备合成探针和共享桥/非音频实源各12项通过，控制台无合成载荷。iPad首次ClangStatCache阶段超时未执行测试，保留并在同一DerivedData限定复验通过。

扩展实源回归中R141真实MP3未推进；不是框架后4项通过就能覆盖的失败。按既有方法追加纯本地音频对照，两端均ready10秒超时、status=unknown、clock8秒为0；未据此认定Mac主机音频/唯一根因，未自动重试/静音/调超时/重启服务或设备。#77阻碍当前媒体验收，37项历史通过仍属真实记录而非当前放行。命令、证据与回滚见[模板日志安全与复验](s8-template-logs.md)。非音频回归显式排除真实MP3，不能代替媒体门槛。

## S8补充：真实音频与快速退出进度（2026-11-14）

R141首分类→列表@put音频变量→正文java.get→生产原生媒体资源层→AVPlayer推进→RSSStore进度重载，在双设备各3个HTTP事务200、200、206下通过，推进500/503ms、无凭据、资源关闭。R141仍为type=0；不改变路由，不冒充原网页WebKit/iframe或真机声音已验收。R304/R187预审403停止，R306响应形状不匹配预期未继续。

此真实链发现关闭后进度0，已用本地0.25秒素材复现close/pause/background三个失败分支；根因是强制保存读取1秒UI采样旧值，而非网络、写盘或key。仅RSS强制保存改取真实时钟，并保护异步seek目标/当前加载修订、未就绪恢复和结束归零；原始书源/脚本路径与持久化格式不变。第一版直接读时钟的seek回归被本地测试捕获并修正；阅读页测试改为观察恢复位置之后新增0.5秒，未增加sleep/超时。

最终Reader-Fork-RSS-PoC、动态选择iPhone/iPad iOS27.2，各37项/9 suites零失败零跳过（XCTest9、Swift Testing28），xcresult完整集合已核对。本地退出/seek保护、HLS/签名重算/重开/撤销及既有S8资源/Cookie回归均通过。最终证据 `/tmp/readerfork-s8-audio.8r9KFy/final/`；命令、原失败、限制与回滚见[音频与进度记录](s8-audio-progress.md)。未装手机、未commit/push，S8仍未完成。

## S8补充：真实图片与受限Cookie（2026-11-13）

在已有S8证据上新增真实图片与合成Cookie闭环，没有修改生产代码或安装手机。已有普通Session delegate的重定向拒绝会被生产task delegate覆盖；用loopback对照复现后，新增S8专用URLProtocol发出前精确URL/哈希、无凭据GET和准入次数边界，允许请求仍由系统HTTP和原生产执行器处理。R146只准入经两次无Cookie/禁跟随301检查确认的确切HTTPS同源canonical URL，不开放整站或放宽TLS。

最终 `Reader-Fork-RSS-PoC` 隔离宿主、动态选择Xcode/iPhone/iPad（均iOS27.2），各23项/6 suites、零失败零跳过；xcresult已核对精确集合。R014真实链2个GET/200，实际JPEG 75,292 B、原生解码640×440，已读/收藏/图片地址重载通过；Jar=false/true两种合成列表→type=1规则→实际图片→状态重载各4次loopback请求，路径隔离与响应Jar语义通过。其余代表项再次通过，包括R146四个事务301、200、200、200和987字符正文；B122仍只是离线fixture。

命令、失败复现、宿主/缓存隔离、预算与回滚见[资源与Cookie记录](s8-resources-cookies.md)。最终证据 `/tmp/readerfork-s8-resources.22G9AG/final/`，开发失败日志保留于上层。未采用重启后0项框架结果；测试Cookie种入错误触发的既有主线程断言和隔离宿主设置快照初始化错误已在测试中修正，未修改生产实现。原307源性能观察未重跑，未增加性能或发布通过结论。

仍未验证/闭合：实际音视频/iframe播放器、真实受限Cookie/账号登录、B122空结果、R146外部图片TLS、iOS17和物理设备/发布门槛。#58/#64/#65独立，#73关闭；S8保持进行中。

## RSS 网页返回（#74，2026-11-13）

用户反馈独立RSS网页进入子页面后无法回到首页。固定Android基准的 `ReadRssActivity.kt` 在系统返回时先处理网页历史，并跳过刷新产生的重复项；无上一页时才退出阅读。iOS沿用自己的导航语义：当前会话有历史时显示独立“网页返回”，它只返回网页；Close仍关闭整个阅读容器，推入页的系统返回不变。

实现边界：

- 简单singleUrl沿原WebKit会话后退；带私有头、响应规则或页面桥的整页返回仍走 `RSSOpenTarget` / 共享执行器，重新绑定该页Cookie、脚本和图片上下文。只在文档提交后推进历史，最多保留100个导航目标/上下文，不另建响应缓存。
- 独立网页的已取得HTML使用公开 `loadSimulatedRequest` 加入WebKit历史；没有启用网页返回的文章/登录宿主仍保持原加载方式。保留 `loadWithBaseUrl` 选择，不强行赋予无base页面站点来源。
- `pushState` / hash返回恢复网页内状态，不重发文档；包括路径变化、从有hash退回无hash，以及无base的about:blank。刷新共享请求页替换当前历史目标，不制造重复后退步骤。监听按WebView生命周期撤销，旧容器不能清除新容器的返回绑定。
- 删除源或登录修订后返回不可用；共享执行器历史中的POST不自动重送，明确显示既有表单受限错误。没有添加历史监测JS、放宽TLS、扩展网页桥权限或改动用户数据。

最终验证：Xcode动态选择的iOS27.2 SDK，Reader-Fork-Dev，iPhone 18 Pro Max及iPad Pro 13-inch (M5)，均为iOS27.2 (24B8117)模拟器。

- iPhone / iPad各36项 / 8 suites通过，零失败零跳过；包含浏览器历史、刷新后一步返回、共享请求/私有头、恢复后的页面桥、POST不重送、源撤销、导航/图片/视口及请求合同。
- iPhone / iPad各5项生产工具栏UI通过，零失败零跳过：子页返回首页且不关闭容器、重开清除旧历史、AX5/深色下返回与关闭可点击，以及原有缩放/横屏/连续弹层。xcresult明确核对8个suite和5项UI的精确集合，不采用0项或缺suite的结果。
- `ruby scripts/check_localizations.rb` 通过：五种语言4114键；两个设计skill逐字节一致，S6脚本语法与 `git diff --check` 通过。S6脚本的UI精确白名单同步增加两项返回用例。
- 最终证据：`/tmp/readerfork-rss-history-acceptance.JEMzn2/final/` 的各设备unit/ui日志、xcresult、summary及完整tests树；此前同目录上层的附件记录UI截图。初始失败证明 `loadHTMLString` / `loadData` 不提供所需历史；刷新重复项由 `reload-red.log` 复现，再经 `reload-green.log` 和最终整合集验证。独立用例筛选曾执行0项且被wrapper拒绝，未采用该结果。
- API依据：Apple [loadSimulatedRequest](https://developer.apple.com/documentation/webkit/wkwebview/loadsimulatedrequest(_:response:responsedata:))；WebKit [227599](https://bugs.webkit.org/show_bug.cgi?id=227599)明确区分此API与不新增历史项的 `loadHTMLString` / `loadData`。本机SDK声明从iOS15可用，未引入高于最低iOS17的新API要求。

命令由 `scripts/sim.sh xcode` / `dest iPhone` / `dest iPad` 解析环境，使用 `YUEDU_SCHEME=Reader-Fork-Dev`、`scripts/xctest.sh` 串行运行 `RSSBrowserSessionTests`、`RSSWebNavigationTests`、`RSSNativeWebFlowTests`、`RSSWebInvalidationTests`、`RSSWebDocumentCacheTests`、`RSSWebViewportTests`、`RSSWebRequestTests`、`RSSWebLoadDiagnosticsTests` 和 `RSSWebDisplayUITests`。

未验证：iOS17、物理设备、真人VoiceOver及目标外站的实际返回；本轮只使用自建页面和loopback请求，不代替实源验收。没有安装手机、修改源包或推进S8其他门槛。回滚只撤回 `64149fd1` 之后本项的页面/本地化/测试/设计说明改动，保留此前提交与全部用户数据。

## RSS 订阅 Tab 导出 JSON 黑屏反馈（用户复测正常）

用户曾报告新「订阅」Tab的JSON导出界面黑屏，资源库推入的RSS同操作可保存。代码复核表明两者复用`RSSListView`、同一`RSSStore`、`RSSJSONDocument`与`.fileExporter`。用户随后自行复测反馈现已正常，明确要求移出当前问题序列；按其决定关闭，不修改生产导出代码。新增的双入口UI行为测试保留：iPhone iOS27.2、iPhone iOS26.2、iPad iOS27.2各2/2通过；Tab根页自动化实际点击系统保存，三个模拟器均导出330 B有效JSON、一条合成seed。一次冷启动Files Provider画面短时空白，随后Save控件可见；iOS26.2系统AX类型转换差异在测试中按可见控件坐标完成点击，不计为产品失败。

此测试与记录不代表手头物理设备的复测方式或长期系统保证。原用户复测结论以用户反馈为准；详细自动化证据及回滚见[导出记录](rss-json-export-diagnostics.md)。

## 原提交S7证据：独立入口、统一搜索和分类恢复

- 命令：`scripts/validate_reader_fork_s7.sh`，由 `scripts/sim.sh` 分别选择 iPhone/iPad；正常 Reader-Fork-Dev、iOS 27.2 (24B8117)。
- 最终结果：每设备 S5 268项/38 suites、S6 97项/19 suites、S7 63项/14 suites；全部零失败零跳过。S7 包含49项单元/集成与14项UI。
- 证据：`/tmp/readerfork-s7-final-gates.AFHzp6/{iPhone,iPad}/` 的日志、xcresult与汇总。红绿反馈见 [S7记录](s7-management.md)。
- 本地化4108键、固定源包哈希、`git diff --check` 通过。
- 未验证：真人登录/VoiceOver、真实WebDAV、iOS17、正式签名iCloud/App Group；跨文件恢复的强杀/重启原子性未验证，仅证实可捕获错误的回滚和原文件副本保留。不能写成完整发布通过。
- 回滚：撤回S7改动，保留源/文章、远端备份版本和本地恢复前副本；不恢复覆盖原版路径的旧写入。未Push，未执行真机或云归档。

## S0-01：模拟器环境

实际执行：

```bash
bash scripts/sim.sh doctor
```

结果：当前 Xcode 的模拟器 SDK 为 iOS 27.2，已安装 iOS 26.2 runtime，有可构建的 iPhone/iPad 设备。这里是本次环境记录，不是后续脚本应硬编码的版本或设备。

未发现 iOS17 runtime；未进行真机验证。后续发布门槛对应保持未完成。

## S0-02：最小构建设置解析

实际命令（目标运行时解析）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
DEST="$(bash scripts/sim.sh dest)"
xcodebuild -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader -destination "$DEST" \
  -disableAutomaticPackageResolution -showBuildSettings -json
```

结果：**退出码 74**，在依赖解析/二进制下载阶段失败，未得到有效 build settings JSON、未进入 App 编译。

决定性错误：

```text
xcodebuild: error: Could not resolve package dependencies:
failed downloading …/grpcpp.zip: A TLS error caused the secure connection to fail.
failed downloading …/FirebaseFirestoreInternal.zip: A TLS error caused the secure connection to fail.
failed downloading …/GoogleAppMeasurement.zip: A TLS error caused the secure connection to fail.
failed downloading …/FirebaseAnalytics.zip: The request timed out.
```

同一批还涉及 GoogleAppMeasurementIdentitySupport、grpc、openssl_grpc、absl、GoogleAdsOnDeviceConversion。下载地址均来自现有固定依赖引用的 `dl.google.com`，未更改版本。

完整命令输出保存在本机 `/tmp/readerfork-build-settings.9Mfy3s`。`-disableAutomaticPackageResolution` 不代表已缓存所有二进制，也不阻止缺少的二进制下载；此运行未启动 App 或用户源脚本。

## S0-03：下载连通性最小复现

实际请求（保留证书校验，HEAD、不下载完整包）：

```bash
curl -I --connect-timeout 10 --max-time 20 --silent --show-error \
  https://dl.google.com/firebase/ios/bin/grpc/1.69.1/rc0/grpc.zip
```

输出：

```text
curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to dl.google.com:443
```

说明：命令当时通过输出过滤器只显示HTTP/错误字段，包装shell的退出码不是curl退出码；上面的35是curl实际报告的错误。它复现了不依赖Xcode工程解析的同域TLS连接失败，但尚不能据此判断是网络线路、DNS、代理还是远端原因。

附加检查：当前进程未配置 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 等环境代理；系统 `scutil --proxy` 显示 HTTP/HTTPS/SOCKS 和 PAC 均关闭。没有扫描私有配置、修改代理或关闭证书校验。

### 当时的阻碍与恢复条件（已由后续产品决策替代）

在保留 SDK 的旧路线下，需要恢复 `dl.google.com` 官方下载的可用连通性，或配置用户授权的可用代理，再重跑最小HEAD和相同构建命令。不得关闭TLS校验、用未知镜像替换包、随意升级/降级依赖或通过新DerivedData绕过问题。

随后用户在 Q10–Q13 明确授权移除 Google/Firebase 及收费体系，见 [ADR-0004](../adr/0004-remove-google-and-billing.md)。因此下载线路恢复不再是产品前置条件；上面的 TLS 故障保留为历史证据，不记为已修复。移除真实调用方与依赖的工作仍须完成。

## S0-04：移除实施前核查的启动事实

- 根目录 GoogleService-Info.plist 不存在；项目多个资源阶段仍引用它。
- `RSSAppNotificationDelegate.application(...didFinishLaunching...)` 直接调用 FirebaseApp.configure。
- `FirebaseAuthManager` 初始化直接读取 Auth.auth；App 生命周期、订阅和同步入口也需跟踪。仅跳过 configure 并不足以完成本地模式。
- 当前 `TestFlightAccessController` 默认已经 `localDevelopment: true`，服务器准入检查实际不运行。不要照旧文档重复改这部分。

以上是首批代码修改前的证据。现按已确认的新路线逐批移除；独立 scheme/Bundle/共享数据空间和 App/RSS 测试门槛仍未完成。

## S0-05：Crashlytics 改为本地诊断（首批代码）

已实施：

- `CrashContext.swift` 不再导入 FirebaseCore/FirebaseCrashlytics，也不再创建 SDK 实例或上报网络请求；原调用接口转到现有 `DiagnosticLog`。
- 诊断上下文从远端 custom keys 改为进程内有界字典：最多64键、每值1024字节，锁只保护内存快照；更新本身不写盘，错误记录携带最新上下文。超限明确标记，不新增持久化 store 或写入队列。
- 保留非致命错误的 domain/code、卡顿活动栈和 MetricKit 的完整本地调用树；移除重复的远端 ExceptionModel 与安装标识注册。
- 新写入的诊断上下文、错误和 breadcrumb 在进入本地日志与 os_log 前脱敏。补 URL userinfo/query/fragment、整段 Cookie/认证头和结构化敏感字段处理；固定脱敏模式失效时不再静默跳过。
- Xcode 工程移除 Crashlytics 链接产品及符号上传脚本，其他 SDK 暂保留给尚未移除的调用方。对修改前备份做对象级比较：仅这3个对象及其引用被移除，无其他工程字段变化。
- `DiagnosticRedactorTests` 从原测试文件原样拆到独立文件，复用原来的5个回归；新增7个本地诊断测试，另复用9个 MetricKit 栈解析测试。

### 反馈闭环与执行结果

本批宿主环境：macOS 27.0.1 / Apple Swift 6.4.2；子集按 Swift 5 语言模式编译。iOS 类型检查使用当前模拟器 SDK 27.2、最低部署目标17.0。

1. 先运行 `bash scripts/test_local_diagnostics.sh`：退出1，原源码无法解析 FirebaseCore/FirebaseCrashlytics，证明这段诊断还依赖 SDK。日志：`/tmp/readerfork-diagnostics-red.log`。
2. 实现后加测 userinfo 与普通 query 同时存在的 URL，脱敏回归出现4个断言失败；修正替换顺序后通过。日志：`/tmp/readerfork-diagnostics-redaction-red.log`。
3. 最终运行同一脚本（串行）：**21 tests / 3 suites passed**，进程退出0。日志：`/tmp/readerfork-diagnostics-final.log`。
4. 下列 iOS 17 最低部署目标的诊断源码子集类型检查通过；RSS AppDelegate 文件语法检查通过：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -typecheck -swift-version 5 -sdk "$SDK" \
  -target "$(uname -m)-apple-ios17.0-simulator" \
  Modules/Services/Diagnostics/{CrashContext,DiagnosticEntry,DiagnosticLog,DiagnosticReportBundle,MetricKitCallStack,MetricKitDiagnosticReporter}.swift \
  Tests/HostDiagnostics/HostSupport.swift
xcrun swiftc -frontend -parse Modules/Services/RSS/RSSNotificationManager.swift
plutil -lint Yuedu-Reader.xcodeproj/project.pbxproj
bash -n scripts/test_local_diagnostics.sh
git diff --check
```

这里的17.0是项目最低部署目标，不是硬编码所安装的模拟器运行时。`plutil`、shell语法及diff检查均通过。没有本轮新增UI/用户文案，因此未运行本地化检查。

### 验证范围与仍未完成的工作

宿主脚本只编译真实诊断源码，不下载第三方依赖；StorageLocations 的宿主适配在意外访问 App 共享目录时立即失败，测试全部使用自己的临时目录。宿主本地化函数仅返回key，不是本地化UI验证。该子集测试不替代 App target 构建、`scripts/xctest.sh` 的 iOS/RSS测试、冷启动或真机 MetricKit 交付。

**该批结束时 S0 未完成。** 当时 Firebase 初始化、账号/Firestore、反馈及上传、StoreKit/Pro 均仍在。后续反馈移除见 S0-06；不能把这批子集验证写成 App 已离线独立。

回滚：工程修改前备份为 `/tmp/readerfork-s0-config.Q39thm/project.pbxproj`；仅在没有后续工程修改时直接恢复该备份，否则按对象级diff撤回。源码可按本批diff撤回，拆出的测试移回原文件；不清理用户数据/模拟器，不覆盖后续工作。宿主脚本仅删除它自己创建的临时构建目录，不改变 App DerivedData。

## S0-06：移除云端反馈/上传，保留本地通知与诊断

已实施的代码：

- 删除13个云端反馈/诊断上传源码文件及5个专属旧测试文件；删除前核查外部调用者并备份。原反馈测试中的通用日志前言用例移入本地诊断测试，不随功能移除丢弃。
- 设置直接打开本地诊断页；移除上传按钮、上传回执/状态和自动截图反馈入口，保留本地复制/分享。修改现有 DiagnosticsPageUITests，断言直接导航、无云端按钮及本地复制结果；**该 UI 测试尚未执行**。
- 删除反馈安装标识、APNs注册/回调与反馈通知分支；保留 RSS 本地通知分类、内容、角标和状态动作。
- 发现原 RSS 启动也在申请通知并注册 APNs，现改为启动只初始化本地通知。新增“设置 → 订阅通知”，读取权限不弹窗，只有用户按钮才请求；拒绝后引导系统设置，取消/系统错误不当作授权成功。
- 权限状态仍由 UserNotifications 拥有，新增用例不缓存或持久化第二份权限。页面请求有唯一 token，取消后晚到结果不能改写下一次请求。
- Entitlements 仅移除 `aps-environment`。与备份逐键比较通过，iCloud/App Group及其他键保持不变；Fork独立容器/签名仍待后续S0收尾。
- 本地诊断与通知新增文案同步五语言，新增页面有 Preview。没有自动授予通知权限，也未访问真实源网站。

### 本批实际自动验证

| 命令/检查 | 结果与范围 |
| --- | --- |
| `bash scripts/test_local_diagnostics.sh` | **22 tests / 3 suites passed**，退出0；真实诊断源码及通用日志前言恢复验证 |
| `bash scripts/test_rss_notification_authorization.sh` | **8 tests / 1 suite passed**，退出0；注入系统接口，验证读取不请求、授权/拒绝/错误、请求次数与取消前后行为；不弹真实权限框 |
| `python3 scripts/tests/test_fork_feedback_removal.py` | **5项通过**；仅静态防复活/配置检查，不代替App网络或UI行为 |
| `python3 scripts/tests/test_host_test_verdicts.py` | **3项通过**（各覆盖两个包装脚本）；模拟xcrun输出，确认0项测试和非零进程退出不会误报成功；这些模拟输出不计作业务测试 |
| `ruby scripts/check_localizations.rb` | 通过，五语言主表3964个键及其他已有表一致 |
| iOS17授权用例/诊断子集类型检查 | 通过；目标为最低部署版本17.0，当前模拟器SDK27.2 |
| 修改的Swift/UITest语法、shell语法、Entitlements解析、`git diff --check` | 通过 |

静态移除检查曾在删除旧模块前失败2项；删除后5项通过。权限宿主测试第一次遇到 `UNAuthorizationStatus.ephemeral` 不能在macOS构造，已将该参数限定在iOS；macOS只运行authorized/provisional参数，iOS对应分支仅有本批类型检查证据，不冒充真机执行。

主要日志：

- `/tmp/readerfork-feedback-removal-red.log`
- `/tmp/readerfork-rss-authorization-final.log`
- `/tmp/readerfork-diagnostics-feedback-final.log`

iOS类型检查命令：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -typecheck -swift-version 5 -sdk "$SDK" \
  -target "$(uname -m)-apple-ios17.0-simulator" \
  Modules/Services/RSS/RSSNotificationAuthorization.swift
```

两份宿主包装脚本均使用非零测试数量及最终成功结论作为门槛，并保留管道退出码。阶段级合同已补入 [执行计划 §3.1](implementation-plan.md#31-逐阶段自动验收关卡)：后续用例随各阶段实现补齐，不表示现在已有全部自动覆盖或远端CI。

### 未验证与下一步

**S0 仍未放行，S1–S8 未开始。** 本批未运行完整 App、DiagnosticsPageUITests、RSS集成回归或真实通知交付；子集测试与Swift语法检查不能替代它们。仍须移除账号/Firestore、StoreKit/Pro及其余SDK/资源，完成独立身份、关于页原版联系/条款入口核查，再通过App构建、冷启动与RSS基线。不得以本批“没有反馈调用者”的静态结果宣称整个App已无原版后台请求。

回滚：`/tmp/readerfork-s0-feedback.gZ3n6F/` 保存Entitlements原件、18个删除文件及 `removal-manifest.txt`。按本批diff选择恢复，先确认目标没有后续修改，不覆盖前一批或用户变更；通用前言测试与入口改动一起协调撤回。不清理模拟器/用户数据；WebDAV数据与原始源包未改变。

## S0-07：账号/收费依赖移除与独立构建阶段验收

### 实际实现

- 删除 Google/Firebase 账号、网关、Firestore执行器、StoreKit购买/会员/Pro与对应专属页面/测试；清除真实启动、前后台、Deep Link和阅读器调用者，不提供伪账号或恒真会员store。
- iCloud仍需要的合并算法、shadow元数据移至 `Modules/Services/iCloud/CloudSyncMerge.swift`；纯阅读设置与批量设置应用移到现有ReaderCore/SharedApp。数据字段与shadow持久化key保持不变，恢复后由iCloud自身刷新本地owner。
- 删除主题、背景、字体、笔记、翻页区块和AI入口的会员控制参数及付费跳转。新建后发现不再需要的恒真功能代理/目录也已删除；验收由真实主题、翻页网格、偏好同步和UI操作测试承担，不以恒真属性证明功能可用。
- 移除Firebase/GoogleSignIn SwiftPM产品和资源、Google OAuth/网关配置、StoreKit商品fixture；锁文件移除16个不再需要的pin，保留的11个pin版本/修订未变。未修改Swift语言/并发设置。
- `Reader-Fork-Dev` scheme、主App `dev.denis.readerfork.dev`、测试/Widget/ShareExtension、App Group和iCloud容器均采用独立命名。清空原版开发团队配置，不借用签名。
- 系统仅注册 `readerfork-dev` scheme，不抢占原版的 `yuedu`/`legado`。App内兼容解析旧导入链接，RSS旧导入链接改投Fork自己的scheme；原始src参数保留。
- 设置移除原版账号/联系渠道/收费条款，保留明确的上游项目与许可链接。ShareExtension五语言显示名区分原版。
- 公共书库原有Storefront地区查询保留：它不读取商品/交易/权益，不是会员准入。只读公共目录（例如青空目录）也不被当作Firebase账号后台一并删除；不能宣称整个App永不访问任何上游内容站点。

### 构建环境与已修复的阻碍

工具链由 `scripts/sim.sh` 解析；当前Xcode模拟器SDK27.2，运行时iOS26.2。实际 `-showBuildSettings` 显示 **Swift 6.0 / strict concurrency complete / 无默认actor隔离**，与工程修改前逐字段比较一致；旧skill中Swift5的记录不适用于当前工程。

首次恢复App编译后发现并修复：

- iCloud恢复适配引用了不存在的 `bookStore`，改为真实 `boundBookStore`。
- 删除付费参数遗漏一个页面背景调用方。
- 初次机械收敛布尔门槛误触两处原有比较/条件表达式，已按原diff恢复，不用改测试期望掩盖。
- Google授权专项测试和UI测试中的StoreKit fixture初始化仍引用已移除SDK，已删除仅购买相关部分，保留原UI测试主体。

对应失败日志保留在 `/tmp/readerfork-s0-first-app-test.log`、`/tmp/readerfork-s0-app-regression*.log`；随后74项初步回归通过。但该结果不等于最终验收，最终范围更广，见下文。

首次全范围验收还发现3个测试层问题，均建立单项复现后解决：

1. 新scheme的TestAction传了 `-onboarding.completed YES`，NSUserDefaults参数域覆盖了独立suite，导致“新安装显示导览”的测试失败。现仅保留 `-no-official-modules`；UI测试自行设置它们的启动参数。
2. 既有 `RunLoop.main.run(until: Date())` 并不保证采样回调执行，观察值断言读到空数组。测试改为等待ObservationRecorder真实采样通知，仍断言恰好一次变化及防抖窗口内无回写。
3. SwiftUI暴露了整行Switch和内部UISwitch；点击带Spacer的整行中心未切换。保存可访问性树/截图证据后，UI测试改点原生UISwitch本体，并仍断言值变化及恢复原值，不修改生产开关逻辑。

失败证据：`/tmp/readerfork-s0-full-scope.xcresult`、`/tmp/readerfork-s0-three-failures.xcresult`；最小回归通过证据：`/tmp/readerfork-s0-three-green.xcresult`。全部相关验收随后重新执行，未复用失败run冒充成功。

### 最终实际执行结果

自动入口：

```bash
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s0-final-acceptance \
  bash scripts/validate_reader_fork_s0.sh
```

- **203 tests passed，0 failed，0 skipped**，xcresult最终 `Passed`、xcodebuild退出0。
- 其中Swift Testing **193项/23个suite**、ReaderSettingsPublication XCTest **6项**、iPhone真实UI操作 **4项**。
- 覆盖RSS基线、页面路由、通知授权、iCloud纯数据合并/删除/冲突/shadow、阅读位置、设置发布与不变不写、主题配色、翻页网格、Deep Link、导览、本地诊断。
- UI实际完成：独立冷启动→设置→诊断→本地复制；字体入口打开系统选择器；Tab图标大小开关值真正改变并恢复；读取通知状态不弹权限框。
- 7项独立配置、5项反馈移除、3项宿主包装器合同检查通过。本地化五语言主表3968个key、Swift/shell/XML/plist解析及 `git diff --check` 通过。

额外阅读器端到端回归：

- 以 `scripts/reader_chrome_fixture.py` 的合成内容运行本地服务器，**仅绑定127.0.0.1:18771**；FIFO就绪事件后启动测试，结束只关闭本次服务，不用sleep等待。
- `ReaderFontImportUITests` **2项通过**：从本地源详情实际打开阅读器，进入阅读设置，字体/阅读设置两个入口都打开系统选择器；无StoreKit fixture或会员覆盖。日志 `/tmp/readerfork-s0-reader-font-regression.log` 与同名xcresult。
- iPad动态目的地运行 `DiagnosticsPageUITests` + `ForkLocalAccessUITests`，**4项通过**；日志 `/tmp/readerfork-s0-ipad-ui.log` 与同名xcresult。
- 未选择个人文件、未授予系统权限、未执行用户原包脚本。

构建产物另行核验：主App Bundle ID/显示名正确，最低部署目标17.0；Widget与ShareExtension产物均为Fork命名空间；App与debug dylib的 `otool -L` 无Firebase/GoogleSignIn/AppAuth，包内无GoogleService资源，Info无原版OAuth/网关配置。该检查是装配证据，不冒充全网络抓包。

### 阶段放行与剩余门槛

**S0本地构建与基线通过，可以进入S1。** 未验证：iOS17实际运行时、物理设备、真实通知交付、iCloud自有容器签名/跨设备同步、正式Release签名。当前容器未接入个人云数据；本地冷启动/阅读不依赖其成功。全RSS行为闭环仍须S1–S8逐段实现和验证，不因S0基线通过而宣布源全部可用。

回滚：`/tmp/readerfork-s0-account-billing/` 保存主要修改前副本、删除文件清单及config-before（工程、Info、scheme、entitlements、原lockfile）；新增/删除列表以当前git diff为准。逐文件审查后恢复，不一键reset用户工作区、不删除设备或书库。Fork已经产生的本地数据不因代码回滚清除；旧共享数据空间不得重新接入原版。

## S1-01：固定输入及媒体约束子集

详见[媒体PoC](media-poc.md)。新增8个合成源与4项基线测试，复用原视频fixture服务器并扩展7项实际播放器/HTTP/WebKit实验；13项既有视频帧回归同时运行。

实际命令与目的地同媒体PoC文档，`/tmp/readerfork-s1-fixed-input-media-2.log`/同名xcresult：**24通过、0失败、0跳过**，xcodebuild退出0。前两次HLS实验无显示consumer造成seek不完成，已用有界回调复现，再用真实AVPlayerLayer验证；保留失败日志，不归因于网络或伪造通过。

实测发现现有asset自定义头部跟随跨host重定向，RSS未来不得直接照搬私有认证头传播。WebKit初始URLRequest头不会传给图片，CORS默认仍生效。本轮没有修改生产媒体/网页实现，不是RSS媒体闭环完成。

原始两个包重新计算哈希与253/307项计数均一致；未复制到测试资源或执行其脚本。剩余网页播放器/生命周期/Cookie/资源通路及严格进程网络隔离未完成，S1继续进行，S2不放行。

回滚：删除S1新增fixture/测试/PoC文档，并将仅为复用抽出的VideoStillFixtureServer从Support移回原测试文件；保留S0实现、既有媒体文件与用户原包。不要整库reset。

## S1-02：网页媒体、Cookie、custom-scheme与隔离宿主

在 `bd6b0076` 提交后继续实现。网页MP4、iframe HLS、合成JS动态地址、AES-128 HLS key/分片及Cookie、脚本时机、baseURL、跨host/path Cookie与注销、白名单custom-scheme媒体和取消等，已新增实际行为验证。自定义scheme仅测试内存白名单，未新增生产代理或播放器。

新增 `Reader-Fork-RSS-PoC` scheme、`ReaderAppMain` 提前选择轻量宿主，避免构造原App及其自动服务。正常App实现仅移动 `@main` 标记，初始化/页面/通知/同步逻辑原样保留。正常Debug/Release仍调用原SwiftUI入口，不用PoC结果代替正常冷启动验收。

最终命令：

```bash
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s1-iphone-final-green bash scripts/validate_reader_fork_s1.sh
YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" \
  YUEDU_EVIDENCE_DIR=/tmp/readerfork-s1-ipad-final-green bash scripts/validate_reader_fork_s1.sh
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s0-final-host bash scripts/validate_reader_fork_s0.sh
```

结果分别为 **36/36、36/36、203/203**，最终xcresult均Passed且0失败/0跳过；日志/结果包位于对应目录。

保留失败事实：1px fixture受3x屏幕倍率影响，固定renderer.scale后解决；一次iPad actool裁剪阶段超时、未开始测试；独立宿主iPad音频重复3次失败，显式激活/恢复测试音频会话后重复3次及完整回归通过。详情与日志见[媒体PoC](media-poc.md)。

当前资源限制：现有asset自定义头可跨host传播；custom-scheme MP4在一个合成片段产生84次本地小Range请求，不可直接放大为外网请求。图片脚本解码/资源过滤/流程输入等S1余项未结束，S2仍不放行。

回滚范围：仅移除本批新增PoC测试、scheme、支持文件和ReaderAppMain，并把 `@main` 标记放回原App；RSSMediaPoCTests的测试辅助提取也一起还原。不要撤回 `bd6b0076` 的S0改造，不碰原始样本和用户数据。

## S1-03：资源与固定流程收尾

新增4项实际资源管道测试、8项固定流程测试，复用3项RSS编码与3项刷新竞态合同；最终自动入口已扩展到54项。实测内容与现状差异逐项记录在[媒体PoC](media-poc.md)。

- iPhone：`YUEDU_EVIDENCE_DIR=/tmp/readerfork-s1-closure-iphone bash scripts/validate_reader_fork_s1.sh`，**54通过、0失败、0跳过**。
- iPad：动态解析 `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"` 后同入口，`/tmp/readerfork-s1-closure-ipad`，**54通过、0失败、0跳过**。
- 两者最终xcresult均Passed，32项Swift Testing/22项XCTest；当前运行时iOS26.2。

保留首轮失败：RSS对loopback HTTP强制升级HTTPS导致请求超时，条目变量返回空值；见 `/tmp/readerfork-s1-flow-fixtures.log`。前者改用已有URLSession测试seam固定响应以隔离传输，仍记录升级后的真实请求，不修改生产HTTPS策略、不关闭安全检查；后者作为S4待修复的明确现状基线。共享fixture的Swift6 Sendable编译错误也已修正为先捕获URLRequest值，再进入锁闭包。

S1固定输入与平台可行性验证完成，**可以进入S2**。DASH、复杂Java资源正则及跨站私有头限制已明确；真机/DRM/画中画/全屏/后台/iOS17的未验证项留对应S6/S8验收。原始307/253项源包未执行或移动，S1通过不代表源全部可用。

回滚本批新增测试和fixture调整，不改生产RSS/媒体路由；保留先前已推送的S0与手动IPA工作流。

## S2：配置保真与可确认导入

实现和逐项边界见 [S2导入记录](s2-import.md)。实际iPhone最终101项通过；iPad最终99项行为+2项真实UI分别执行通过，均0失败/0跳过。真实307项包在测试临时store中读入、保存、重载、重新导出并逐字段比较，39类输入字段全部承载，0脚本执行/网络请求；原包没有复制到测试资源或提交。

已知扩大回归问题也保留在S2记录：旧Feed搜索AX两个用例失败，归S5；S1媒体音频在当前模拟器无法推进，本地不经RSS的m4a同样失败，归S6/S8环境阻碍，不能把此前S1通过当作本轮通过。S2本身的配置/UI门槛不包含媒体运行对齐，后续门槛不会因此取消。

## S3：作用域身份、状态与版本化快照

详见 [S3记录](s3-identity.md)。`scripts/validate_reader_fork_s3.sh`要求至少120项、0失败/0跳过。

- iPhone最终 `/tmp/readerfork-s3-acceptance-final/tests.xcresult`：**120通过**。
- iPad `/tmp/readerfork-s3-final-ipad-coalesced/tests.xcresult`：**120通过**。
- iPad真实导入UI `/tmp/readerfork-s3-import-ui.xcresult`：**2通过**。
- 旧重复记录在首次刷新前的UI投影/未读计数另补断言，iPhone44项回归通过后，再跑上述完整120项。
- 50源×200项状态测试初版新增全库查找造成78.960秒，owner派生索引后同测试4.601秒；这一数字含测试数据构造/6000次动作，不是App单次延迟。
- 实际WebDAV客户端MKCOL/PUT/GET在隔离URLSession/临时defaults验证，快照校验、404/401/损坏与恢复语义通过，未使用真实账户。

规则/标准Feed文章身份与探索/通知所用App ID保持一致，未知未来数据版本拒绝覆盖。配置/状态分文件落盘，签名媒体URL、正文和运行变量不进入RSS备份。恢复前原文件保留在 `rss-restore-backups`，多文件原子事务不是本轮保证；具体回滚与旧raw GUID歧义处理见S3记录。

## 手动IPA构建工作流

按用户要求新增 `.github/workflows/build-ios.yml`：仅 `workflow_dispatch`，没有PR、Push、Tag或schedule触发。参考指定legado-ios工作流的未签名archive→Payload→artifact方式，不复制其自动触发或模拟器/UI测试流程。使用稳定 `macos-26` runner所选Xcode，不把本机27.x作为硬性要求。

源码/依赖核查：本地LNPopupUI/LNPopupController声明Swift tools 6.2；CoreText依赖是Swift 6.0源码包，并非要求27.x的预编译二进制。发现 `ReaderViewportReporting.swift` 的27.1 `ReservedRegion` 只有运行时检查，补上与项目既有新SDK分支一致的编译器保护。旧工具链保留窗口safe-area路径，不更改Swift语言模式、并发设置或最低iOS17。SDK27.0这一不含27.1 API但会进入新编译分支的组合明确拒绝，不影响默认26.x runner。

实际验证：

- `python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v`：**16项通过**。包含YAML解析、仅手动触发、权限/Action SHA、依赖缓存边界、工具链预检分支，以及合成archive的Payload、权限/符号链接、扩展、平台、SHA-256和失败合同。
- `ReaderWindowObstructionsTests`、`ReaderViewportFollowsWindowTests`：**18项/2个suite通过**，使用本机动态解析的Xcode27.2/iOS26.2模拟器；日志 `/tmp/readerfork-ci-viewport-regression.log` 与同名xcresult。
- `xcodebuild -showBuildSettings -configuration Release -destination 'generic/platform=iOS' ... CODE_SIGNING_ALLOWED=NO` 成功，确认独立Bundle ID、Release真机SDK和关闭签名；记录 `/tmp/readerfork-ci-device-build-settings.json`。

**未验证：** 未触发GitHub构建，未执行完整Release archive；本机没有26.x Xcode。工具链预检的模拟输入及27.x本地回归不能冒充26.x云端编译成功。首次手动运行后必须补记实际archive/IPA结果。使用方式、较旧SDK的能力边界、未签名与发布限制见[手动IPA指南](../manual-ipa-build.md)。

工作流不会自行commit/push或发布Release，不包含原始源包。回滚只移除本次workflow/打包脚本/测试/指南并撤回viewport编译保护，保留S0及其他S1改动。

## 手动IPA工作流上线校验修正

首次Push `6594ad48` 后，GitHub拒绝了job级 `env` 对 `runner.temp` 的引用：[失败记录](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42373615431)。Actions API确认 `total_count=0`，没有分配构建job，也没有编译IPA。这是表达式上下文错误，不是PR/Push编译触发；先前YAML解析和包装测试不足以覆盖这一层。

已将三个临时路径移入toolchain step，通过 `RUNNER_TEMP` 生成并写入 `GITHUB_ENV`；新增回归先在旧文件复现失败，再验证修正后通过。工作流/打包合同现为**17项通过**。另从官方Release临时下载并校验SHA-256后运行 **actionlint 1.7.12**：原文件报三处runner上下文错误，修正后通过；没有给App添加依赖。

IPA仍仅允许手动运行。修正配置的Push不会启动IPA归档；云端26.x完整archive仍待用户首次手动触发，不能写为已经成功。

## 提交前复核

已按用户授权提交 `bd6b0076`（建立独立 Fork，移除账号收费体系并补齐验收基线），未push。提交包含S0独立Fork改造、参考文档和首批已通过的S1子集，不把S1整体写成完成。原始书源/RSS包、`.codegraph/`和Python缓存不纳入提交。

历史方案v1.0按既定SHA-256原样归档，原文的行尾空格不改动；`.gitattributes`仅对该文件放宽行尾空格检查，其余文件仍使用默认检查。提交前重新核验原文哈希、暂存区格式、配置/反馈移除/测试包装器合同与本地化。

## 已完成的文档验证

- v1.0 原文归档哈希仍为 `335fb104c7df3acfe7b0e45d7d26567fe47e5467965917afef75193b7f328cc3`。
- 原始书源/RSS包未改；哈希与最终方案一致。
- AGENTS.md、CONTEXT.md、ADR及新方案/计划完成UTF-8/LF、链接与关键决策检查。
- `git diff --check` 通过。v1.0原文既有尾随空白按归档保真要求保留。

App/扩展编译、S0相关RSS回归和上述UI操作已有实际通过证据；用户代表源联网、RSS网页媒体完整闭环与真机播放尚未验证。

## S4：共享源运行时、请求和撤销闭环

以下为主体2253426c提交前的历史通过记录；后续补充曾失败，最终在获批新增的官方27.2 runtime通过238项，详见本节末尾。完整输入/断点与边界见 [S4记录](s4-runtime.md)。新增 `scripts/validate_reader_fork_s4.sh`，强制 Reader-Fork-Dev、检查所有选定 suite/用例真实执行以及最终零失败/跳过，不能以总数掩盖未执行的合同。

- `YUEDU_EVIDENCE_DIR=/tmp/readerfork-s4-final-iphone bash scripts/validate_reader_fork_s4.sh`：iPhone 17 Pro Max / iOS26.2，233项、33 suites，0失败/跳过。
- 通过 `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"` 切换目标，`YUEDU_EVIDENCE_DIR=/tmp/readerfork-s4-final-ipad bash scripts/validate_reader_fork_s4.sh`：iPad Pro 13-inch (M5) / iOS26.2，相同233项、0失败/跳过。
- 工具链由 `scripts/sim.sh xcode` 解析，本次 Xcode27.2 / SDK27.2；App 实际编译仍为 Swift6，不修改语言/并发配置。
- 共享会话/RuleData、跨请求jsLib、文章变量与字段时序；URL options/编码/登录检查/无规则Feed/304；域/path Cookie、实际HTTP重定向、源限流；取消排队/LRU淘汰/超时与旧结果拒写均已行为覆盖。
- jsLib阶段包装和header解析的超时绕过由故障注入复现（5个失败断言），修复后进入完整回归。未来状态文件阻止执行而不覆盖；外部变量更新撤销旧票据。
- 原 PoC 后台注册失败在 Dev scheme 保留原断言后通过。首次扩大门槛遇到默认禁用的私有书源实服务用例，门槛拒绝；最终只选择同文件3项合成认证回归，实服务未验证。
- 五语本地化、shell语法、文档链接/编码和 `git diff --check` 通过；原始253书源/307RSS包哈希未变，不纳入提交。

未解决/未验证：偶发 test module emission 超时（未修改代码或DerivedData的重跑通过，不宣称根因已修复）；队列/Keychain QoS警告；JavaScriptCore不保证杀死纯JS无限循环；真人登录、S5分页/S6网页媒体、iOS17/真机、正式iCloud签名及Xcode26.6 archive。S4不构成这些门槛或整体RSS可用性通过。

回滚必须整体撤回本阶段RSS适配及对应共享修改，保留 `rss_runtime_variables.json` 数据；旧S3版本不能直接读取新的封装，若降级需要显式转换并保留opaque变量备份，不清空用户数据。不自动push/release。

### S4补充：前台owner与JSC地址截断（诊断与新环境验收通过）

进入S5调用链核查后发现RSSFeedView漏传owner，先用真实View/HTTP/重建store复现3断言失败，再补齐参数。该项通过，但扩大门槛 `/tmp/readerfork-s4-foreground-iphone/tests.xcresult` 为234项、233通过、1个JSC崩溃、0跳过。S5暂停，补充代码未提交。

最小化和区分实验见 [JSC诊断](../../Technotes/RSSJSCContextLifetimeCrash.md)。裸JSContext正常App宿主也能崩溃；隔离宿主、独立CLI、纯JS字面量和ASan通过没有被当作修复。随后LLDB取得系统36位掩码截断高地址的证据；上游WebKit06d5550移除这一假设。

用户明确批准后执行`xcodebuild -downloadPlatform iOS -architectureVariant arm64`，新增官方iOS27.2 runtime，未移除26.2设备/数据。最终正常Reader-Fork-Dev、完整App界面、ASan关闭：

- `/tmp/readerfork-s4-runtime-repair-iphone/tests.xcresult`：iPhone18 Pro Max / iOS27.2(24B8117)，238项、35 suites、0失败/跳过。
- `/tmp/readerfork-s4-runtime-repair-ipad-ready/tests.xcresult`：iPad Pro13-inch(M5) / 相同runtime，238项、35 suites、0失败/跳过。
- 首轮新iPad运行2项WebKit超时；`simctl bootstatus <动态UDID> -b`后原4项专项和完整238项通过，没有删用例或扩大超时。
- `RSSForegroundRuntimeTests`、`RSSArticleScriptObjectTests`进入S4门槛，原同源取消/重建使用100次循环。五语文案、shell/Python解析、文档链接与`git diff --check`通过。

本地补充验收恢复通过，中文提交后继续S5。**旧26.2系统二进制没有被修复；26.2真机/最低iOS和发布兼容仍未放行。** 本次没有生产JSC补丁或初始化/安全策略绕过，所有诊断探针已撤回。

## S5：打开优先级、分类/远程搜索与分页

完整合同、RED/GREEN和边界见[S5记录](s5-browsing.md)。新增 `scripts/validate_reader_fork_s5.sh`，沿用正常Reader-Fork-Dev、动态设备/工具链和零失败/跳过门槛；每个选定suite/指定用例必须实际执行。

- `YUEDU_EVIDENCE_DIR=/tmp/readerfork-s5-accepted-iphone bash scripts/validate_reader_fork_s5.sh`：iPhone18 Pro Max / iOS27.2(24B8117)，**268项、38 suites、0失败/跳过**。
- `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" YUEDU_EVIDENCE_DIR=/tmp/readerfork-s5-accepted-ipad bash scripts/validate_reader_fork_s5.sh`：iPad Pro13-inch(M5) / 同runtime，**268项、38 suites、0失败/跳过**。
- 工具链由 `scripts/sim.sh xcode` 解析，Xcode27.2 / SDK27.2，Swift6；没有更换DerivedData、清除模拟器数据或使用ASan/隔离宿主替代门槛。
- 覆盖14项浏览合同、6项实际页面合同、10项搜索/工具栏VoiceOver，以及S2–S4的238项共享运行时、导入、状态/备份回归。实际搜索Return与加载更多产生了对应HTTP请求及作用域内容，不只检查控件存在。
- 合法空页、singleUrl优先、正文分页、动态URL validator、WebKit跨origin私有头、redirectURL提取基址均先复现再修复。私有头通过共享请求执行器隔离，响应送入WebKit，不重复POST或建立不受限代理。部分正文持久保存且保留未完成标记。
- iPad旧测试事件错误在首次267项门槛中失败，改用UITextField原生主动作后重新完整验收；后续补充redirect基址用例发现并修复真实提取层问题，最终以268项结果为准。
- 五语Localizable各4013键通过；新页面有Preview。提交前检查shell/内嵌Python、文档链接/编码、源包哈希和 `git diff --check`。

未验证/后续：完整交互规则网页、charset/bodyJs/登录与子资源认证、Cookie回写、网页桥/黑白名单和媒体状态仍属S6；真实站点、音频时钟、iOS17/真机、DRM、iCloud签名及Xcode26.x archive尚未通过。首文档能显示不替代这些门槛。

回滚保持S4基线及RSS数据：整体撤回S5路由/分页与共享层修改；新增可选字段兼容旧文件，降级前保留备份并只处理被partial标记的全文缓存，不能把部分结果当完整文章，也不清空来源/阅读状态。原始源包、Android基准和签名配置未修改；S5验收时未push或启动云构建，后续用户授权的Push/云归档见下节。

## S5后置：Push与手动IPA归档修复

用户明确授权将S5 Push，随后按需手动运行云归档，完成相关前置并归档后自动进入S6。origin/main已从37379c37推进至a60f9d45，之后推送两个归档兼容修正79b170a5和f25a18af。原始源包、索引和临时二进制未纳入提交。

- run42455851293：WorkIndexService旧错误消失，ReaderViewportFragmentHost.prepare actor隔离诊断失败；显式MainActor参数修正，本机23项阅读器绘制回归通过。
- run42456748792：上述隔离诊断消失，但Swift6.3.3在Double的isolated(any) reabstraction thunk IRGen崩溃；ChapterTitleInspectorView把Binding函数值透传改为同步包装，保留MainActor/Sendable。原生Slider及模型9项通过。
- [run42460767989](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42460767989)：head=f25a18af，Xcode26.6/Swift6.3.3/SDK26.5，17项合同、完整Release真机archive、打包与上传成功。下载IPA的checksum/ZIP/身份/扩展/Mach-O平台与未签名属性已实测验证，#35完成。
- 产物：`reader-fork-dev-unsigned-ipa-42460767989-1`，本地 `/tmp/readerfork-ipa-42460767989/ipa/`，35,348,658字节，SHA-256 `08befc70818be381c83ec3d266eda31916ed14e3f9c55e2b7b16489749292dc4`；细节及失败证据见[归档记录](ipa-first-run.md)。

没有修改Swift/并发检查、优化级别、最低系统、依赖/签名或云工具链，没有清用户数据或更换DerivedData。云归档不替代媒体门槛；IPA不等于可直接安装或真机行为通过。#36复验结果见下节。

## S6前置：模拟器音频时钟恢复与媒体复验

#36在本轮官方27.2正常Dev宿主中先复现：HTTP音频10秒未ready；本地AVURLAsset可ready但时钟停0，MP4对照通过。证据 `/tmp/readerfork-media-clock-iphone.xcresult`、`/tmp/readerfork-media-clock-controls.xcresult`。宿主/模拟器环境检查、bootstatus及同文件宿主afplay后，两种音频实际推进，后续冷启动原用例也通过；不能唯一归因于某一步，也不宣称修好了系统引擎。完整原始诊断/边界见[音频时钟记录](../../Technotes/RSSSimulatorAudioClock.md)。

- 正常Dev宿主 `scripts/validate_reader_fork_media.sh`：iPhone/iPad各36项/5 suites/0失败跳过；包括本地音频、带认证头的HTTP音频seek/推进、MP4/HLS真实播放、WebKit资源与安全边界、图片/媒体fixture。证据 `/tmp/readerfork-media-prerequisite-iphone/tests.xcresult`、`/tmp/readerfork-media-prerequisite-ipad/tests.xcresult`。
- S1完整PoC `scripts/validate_reader_fork_s1.sh`：两设备各55项/0失败跳过，证据 `/tmp/readerfork-media-s1-iphone/tests.xcresult`、`/tmp/readerfork-media-s1-ipad/tests.xcresult`。新本地音频使原54项增加1项；隔离宿主不代替上述正常宿主。
- 新门槛只等待bootstatus真实信号，不自动重试或改路由；新增用例保留原媒体超时与实际时钟断言，不静音、不推进伪造进度。失败状态在播放器拆除前采集。

#36当前环境前置恢复通过，归档后自动开始S6。仍有底层环境机制未确认的风险；旧26.2、iOS17/真机、DRM与S6生产资源/媒体闭环未被本轮放行。若再次失败需保留RED，不可当成环境已知问题跳过。无生产音频修改，回滚仅撤回新测试/脚本并保留用户数据。

## S6进行中：规则文档首批接入

完整范围、失败证据及未完成项见[S6工作记录](s6-rule-web.md)。已将显式规则description/正文从普通Feed净化路径分流，保留交互HTML/iframe，按源执行preload/finished和启动页脚本/样式、baseURL开关；enableJs=false不执行源/页面脚本。普通Feed包括仅标记Legado导入的Feed仍保持安全净化。原生滚动恢复/保存独立于页面JS，等待contentSize实际信号，不逐帧发布Store状态；异常脱敏并提供原生重试入口。

- 初始规则文档3项RED有5个issues；滚动首次RED有3个issues，单凭didFinish恢复仍失败1项，尺寸观察修正后通过。
- 正常Dev宿主，官方27.2，两设备各22项/3 suites/0失败跳过：`/tmp/readerfork-s6-first-rule-iPhone.xcresult`、`/tmp/readerfork-s6-first-rule-iPad.xcresult`，包括6项新规则文档、6项既有页面和10项工具栏AX。
- 相同代码S5完整回归，两设备各268项/38 suites/0失败跳过：`/tmp/readerfork-s6-first-s5-iPhone/tests.xcresult`、`/tmp/readerfork-s6-first-s5-iPad/tests.xcresult`。五语各4014键通过。

**首批接入时S6未完成，未阶段提交/Push。** 首文档与撤销补充见下节；本节22项局部结果不替代完整阶段验收，不推进S7。

## S6补充：首文档共享响应与已加载网页撤销

证据、完整命令及回滚见[S6第二批记录](s6-rule-web.md#第二批实现首文档响应合同与网页撤销)。

- 准备好的请求携带charset/bodyJs、变量和原文章上下文，响应复用ModernParserBridge共享半段；实际Big5→bodyJs→WebKit DOM、200/403登录检查、同源两文章并发、不重复动态URL/POST均已运行。
- 网页通过RSSStore现有运行时登记撤销；覆盖登录/真实凭据修订、配置、外部变量、删除、自身导航后撤销、切换owner与生产拆除旧JS realm。取得同源turn后重验凭据，拒绝排队期间被更新的旧请求。
- 正常Reader-Fork-Dev，Xcode27.2/SDK27.2、官方iOS27.2(24B8117)，iPhone18 Pro Max与iPad Pro13-inch(M5)各**63项/6 suites/0失败跳过**：/tmp/readerfork-s6-request-lifetime-final-iPhone.xcresult、/tmp/readerfork-s6-request-lifetime-final-iPad.xcresult。
- 选择RSSRuleWebTests(6)、RSSWebRequestTests(5)、RSSWebInvalidationTests(4)、RSSOpeningViewTests(6)、RSSToolbarVoiceOverTests(10)、AnalyzeUrlTests(32)，xcresult树确认各用例实际执行。早期无匹配的AnalyzeUrlResponseBodyTests筛选器已纠正，不能记成该suite通过。
- 同代码S5完整回归，各**268项/38 suites/0失败跳过**：/tmp/readerfork-s6-request-s5-final-iPhone/tests.xcresult、/tmp/readerfork-s6-request-s5-final-iPad/tests.xcresult。这与63项有重叠，不合并宣称独立测试总数。
- 本批各原始失败都先有RED；包括丢失响应选项、四类Store撤销、真实凭据修订、导航generation、owner变化、拆除后旧文档，以及排队期间凭据CAS刷新。原文章bodyJs绑定缺失也复现并修正；测试失败退出先等待落盘，未改生产文件权限。
- 五语Localizable各4015键、原包SHA-256及git diff --check通过；未执行原始私人源脚本、未加依赖/权限、未改签名/并发策略、未更换DerivedData或清数据，没有新的云构建/提交/Push。

**该批结束时S6继续进行，不放行、不推进S7。** 当时证明首文档和文档级撤销；后续补充见下节，不把历史局部结论当阶段完成。iOS17/真机、真人登录、DRM与iCloud正式签名仍未验证。回滚本批不改变持久格式或删除RSS/凭据数据。

## S6补充：有限动作桥、Cookie授权与生产WebKit位图

完整边界、RED与回滚见[S6第三批记录](s6-rule-web.md#第三批有限网页动作cookie生命周期与生产图片资源)。

- 有限动作桥/同源后续导航接入生产WebKit；原生目的页路由尚未全部接通，不把组件行为通过当完整UI通过。
- Cookie按真实domain/path/属性同步；凭据变化后旧响应不能写Cookie；过期/会话Cookie不能从旧扁平快照复活；响应不能给无关域种Cookie。这些均先有真实RED，再修正同一生产路径。HttpOnly图片响应Cookie到达WebKit后续真实fetch，网页JS仍不可读。
- 合成密文经过共享RSS jsLib/coverDecodeJs及私有头HTTP请求，字节到达生产WK图片；启用JS、禁用JS、动态src/innerHTML/srcset及黑名单网络前阻断已运行。能力scheme仅登记图片，不接管http(s)或建立任意请求代理；外站不带其他站点Cookie。
- 正常Reader-Fork-Dev、Xcode/SDK27.2、官方iOS27.2(24B8117)，iPhone/iPad各**32项/7 suites/0失败跳过**：/tmp/readerfork-s6-image-cookie-iPhone.xcresult、/tmp/readerfork-s6-image-cookie-final-iPad.xcresult。
- 同代码S5回归各**268项/38 suites/0失败跳过**：/tmp/readerfork-s6-image-cookie-s5-iPhone/tests.xcresult、/tmp/readerfork-s6-image-cookie-s5-final-iPad/tests.xcresult。命令为scripts/xctest.sh的7个专项suite及scripts/validate_reader_fork_s5.sh，iPad由scripts/sim.sh dest iPad选择；执行串行，未额外build/clean或更换DerivedData。
- 五语各4020键、git diff --check、两原包SHA-256及Android固定基准已核对。没有运行私有源包脚本或新云构建。

**S6仍未阶段完成。** 尚需真实原生动作UI、图片type=1/附件、SVG/复杂资源、生产音视频及进度/恢复/竞争、cacheFirst/showWebLog、完整三态/AX/视觉与真机。用户最新要求持续推进到S8；仍不把硬件、签名或未执行场景写成通过，不自动Push/release。

## S6补充：媒体资源会话与门槛脚本（未放行）

- 命令：`scripts/validate_reader_fork_s6.sh`（iPad设置 `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"`）。
- 结果：iPhone/iPad各S5回归268项、S6专项73项，零失败零跳过；证据 /tmp/readerfork-s6-gate-iPhone、/tmp/readerfork-s6-gate-iPad。
- 未验证/未完成：cacheFirst、页面级媒体UI路径、前后台/重启续播/播放竞争、复杂资源、视觉与VoiceOver、真机（0个codesigning身份）、iOS 17、DRM、真人登录。详见 s6-rule-web.md 第四批。
- 回滚：撤回RSSMediaResourceSession、RSSTypedArticleView、RSSWebConsoleLog及对应接线；不删除RSS状态。未提交、未Push。

## S6补充：cacheFirst、页面级媒体与首次真机

- 模拟器：scripts/validate_reader_fork_s6.sh，iPhone/iPad各S5 268项 + S6 92项，零失败零跳过（/tmp/readerfork-s6-gate3-*）。
- 真机：scripts/device_dev_test.sh，iPhone 17 Pro / iOS 27.2，免费个人团队签名、无iCloud与App Group，92项全部通过（/tmp/readerfork-device-s6.xcresult）。
- 修复：无iCloud签名下启动即崩（CKContainer陷阱），增加READER_FORK_NO_ICLOUD编译条件；正常构建行为不变。
- 未验证：真机人工观感/声音、真实源、iCloud/App Group、iOS 17、DRM。未提交、未Push。

## S6阶段收尾

- 命令：`scripts/validate_reader_fork_s6.sh`（iPhone 18 Pro Max / iPad Pro 13-inch (M5)，iOS 27.2 runtime 24B8117）。
- 结果：两设备各S5回归268项/38 suites + S6专项97项/19 suites，零失败零跳过；证据位于/tmp/readerfork-s6-gate4-iPhone、/tmp/readerfork-s6-gate4-iPad。
- 本地化校验通过；`git diff --check`通过；固定输入哈希未变。
- 真机：iPhone 17 Pro / iOS 27.2，92项通过（/tmp/readerfork-device-s6.xcresult）；用户手动确认视频画面和声音正常。
- 未验证：iOS 17、DRM、真人登录、真实源、正式签名下的iCloud/App Group。
- 回滚：revert S6提交；RSS源/文章数据格式未变，cacheFirst缓存位于Caches，可丢弃。

## 2026-11-14评审修复（截至2026-11-15，非S8全面验收）

固定上游`cc566a84`在独立修复分支整合，未提交/推送。详细问题映射、当前命令证据、历史失败、未验证项与回滚见[评审修复记录](review-repair-2026-11-14.md)。

本轮最小行为回归：导入/修订/状态等67项9 suites；实际0–4条目布局及AX单列2项（含5个参数用例）；认证与文章图片解码1项；来源说明实际呈现1项；Fork UA实际请求1项；默认停用/手动恢复/地域与模块资源7项3 suites。各自日志和xcresult路径见修复记录，不能拼接为全量阶段通过。

用户后续选择[默认停用六插件与两公共书库](builtin-modules-defaults.md)；刚新增的内置青空快照和来源切换已撤回，不添加不需要的包体。源包[java静态统计](java-static-audit.md)不执行规则，不能替代运行时验收。

证书策略按[ADR-0005](../adr/0005-app-wide-server-trust.md)接受App可控制连接的无效服务器证书，但旧R146图片失败保留、尚未以新策略复验。S8人工门禁继续未闭合，不宣称所有系统连接应用同一策略。

YCK205完整真实入口已修复：按钮页→3.x一键导入→原生确认→RSS预览，新增36、更新0、跳过0、错误0；1项UI测试0失败0跳过，未保存/刷新，见[实源入口记录](yck205-online-import.md)。

最终定向回归：`.git/review-final-focused-green.log`68项11 suites，`.git/review-final-defaults.log`8项3 suites；包含两浏览器统一分流、取消/有界下载、图片/布局、源修订、TLS、WebDAV、iCloud同步逻辑与默认停用/手动恢复。实际命令见两个专项记录。新完成信号测试曾超时，已保留失败证据并修正冻结输入的偏好累积；没有把跳过或0项运行当成通过。

用户授权提交并Push本轮固定合并与修复分支。不会据此清空数据、发布、改正式签名或把S8人工待验改成通过。

## 2026-11-15：LegadoPro名称与本版iCloud暂停

用户对3.0（4）自签后的首屏前退出提供IPS，异常栈为CloudKit与SwiftUI StateObject，主程序UUID匹配公开RC1；缺少具体异常reason与签名后entitlements，不把权限推断写成精确结论。用户最新选择本版暂时取消iCloud并将显示名改为LegadoPro，见[ADR-0006](../adr/0006-pause-icloud-for-current-release.md)与[本轮准备记录](legadopro-3.0-rc2-preparation.md)。

- 已停止iCloud入口、状态请求、启动／前后台自动调用，并移除CloudKit权限申请；保留代码和数据、WebDAV与章节刷新。Bundle ID／App Group／URL scheme不变，版本3.0（5）。
- 本轮命令：`python3 -B -m unittest scripts.tests.test_fork_configuration -v`为9项OK；`python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v`为19项OK；新暂停回归先1项失败后通过。
- `ruby scripts/check_localizations.rb`五语InfoPlist.strings各17键、Localizable.strings各4267键、分享扩展各1键一致；actionlint v1.7.12官方归档checksum核验后运行工作流检查退出码0；文档本地链接与`git diff --check`通过。
- 没有本地编译或新增模拟器运行。新增Swift运行时测试尚未执行；等待新的固定提交Actions归档与用户自签手机启动复验，不能宣称原闪退已经消除。
- 不覆盖RC1 tag或资产，不清空用户数据，不修改签名账号／主数据身份。回滚本轮相关代码和配置不需数据迁移，恢复iCloud仍需权限与设备回归。S8人工验收仍未闭合。

### 固定提交云构建与新包核验

用户授权后提交并Push `5ac9b1b9`，[Actions 43691532133](https://github.com/DenisZheng/Yuedu-reader/actions/runs/43691532133)在Xcode26.6／Swift6.3.3／SDK26.5完成43分6秒归档、打包与上传，三步最终success。下载后ZIP/checksum、版本3.0（5）、LegadoPro五语显示名、主App与两个扩展身份、权限、未签名／无profile、arm64 iPhoneOS minos17.0均实际核验。SHA-256为`cb28a56e39e6792420f8dfb27d08adc2c3c17974b643de75178cd4bcdd3ebf22`；主程序UUID为`F1B97B1E-4852-3807-AD51-6A8AF71DAD50`。

完整命令、产物入口、gh首次上游404的处理和未验证项见[云交付记录](legadopro-3.0-cloud.md)。新副本已放用户下载目录，不覆盖旧包或RC1。未替用户重签／安装，手机首次启动仍待用户复验，不能把归档通过写成原闪退已解决。

## 真机JSON导入：调试与无断点确认耗时

用户后续确认App可启动并进入书源／RSS导入，但自签Release文件点击无响应；最新本地Debug两类导入成功。详细设备识别纠正、权限拒绝、开发签名信任、原失败与当前范围见[真机JSON诊断](json-import-device-diagnosis.md)。Debug按用户最新要求本地编译安装，Release继续使用Actions。

- `scripts/device_dev_test.sh`实际本地Debug编译、安装、启动，SDK27.2／目标iOS27.2.1，决定性输出`TEST BUILD SUCCEEDED`、`App installed`、`Launched application`。没有执行Swift测试，不以build-for-testing等同测试通过。
- 原脚本TMPDIR斜线在xcconfig生成`//`注释截断，先复现签名路径误变T目录，规范化原WORK路径后复用同一DerivedData；`python3 -B -m unittest scripts.tests.test_device_dev_script -v`先1项失败后1项OK，未关闭签名检查。补齐新增iCloud测试的CloudKit import。
- 自签调试被明确拒绝后停止；用户批准Debug并自行信任开发签名后附加成功。一次回调卡住确定为断点暂停，已恢复；后续全部分离调试器。Time Profiler目标Offline记录超时，退出13且无trace，不宣称有采样证据。
- 临时DEBUG数字日志已验证实际行为：用户先书源后RSS，本次书源885项，合并5ms、发布3ms、确认函数28ms；RSS变更300项、399源，后台编码落盘43ms（main=false），保存事务455ms。读取诊断文件退出0。RSS455ms不含生成变更方案、任务排队与最终UI绘制，书源确认不等待后台落盘。
- 本窗口主线程停顿612/324/340ms，没有5–30秒证据；不能把日常RSS源库管理的多次写入算成同一次导入重复落盘，也未证明前后数据起点相同。没有更换SDK或保存算法，不能把本次正常当作SDK问题已经排除或原Release故障已修复。
- 未提交／Push本轮诊断改动，未重新发布或覆盖RC1，原始源包和设备日志不分发。诊断完成时撤回临时数字日志即可，不需删除用户源库。后续同Release IPA开发签名对照需要用户单独批准，S8人工仍未闭合。

### 对照与收尾补充

用户批准后自行卸载，原App数据不再可备份；同原SDK26.5云Release IPA仅在暂存副本重新开发签名，指令／字符串段与UUID一致，签名验证退出0。安装成功后用户手动信任，启动退出0；无断点下用户书源与RSS均正常导入。由于卸载也改变起点，不断言轻松签某个权限已锁定；但不再以SDK26.5必然不兼容为由换SDK或猜测改导入代码。

收尾精准撤回临时日志，三个生产导入文件与HEAD一致。`python3 -B -m unittest scripts.tests.test_device_dev_script -v`为1项OK；`YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AuthAndICloudConfigurationTests'`为模拟器4项／1 suite通过，最终`TEST SUCCEEDED`。只保留已验证的开发脚本路径修正、测试CloudKit import和文档，不自动commit／push。

用户另要求本地IPA：SDK27.2的Debug真归档`ARCHIVE SUCCEEDED`，暂存副本去签名／profile后打包。下载目录新增`LegadoPro-3.0-build5-local-Debug-SDK27.2-unsigned.ipa`及`.sha256`，71,968,086字节，SHA-256为`399292252d5a26a5cbad061d7dd4992ca5b3d74ac88aa004fa3df317669409b7`；ZIP、三个Bundle身份／版本／平台、可执行权限、所有Mach-O未签名／无profile及二进制无临时标签已核对。未安装这份包或覆盖旧IPA，交付当时用户年度自签后的结果尚未验证；完整命令与限制见[真机JSON诊断](json-import-device-diagnosis.md)。

## 年度自签IPA的实际身份／权限审计

用户后续报告该本地SDK27.2包自签后仍“点JSON不返回”，并提供`LegadoPro_3.0_20261115_200253.ipa`。只读审计ZIP、`codesign --display --xml --entitlements -`、`security cms -D`和`codesign --verify --deep --strict`，退出0；三个可执行文件指令／字符串段及UUID与原包一致，无新增动态库，实际SDK27.2/minos17.0未变。原IPA审计前后SHA相同，未修改。

实际发现：三个不同Bundle ID的CodeDirectory Identifier正确，但都签入同一固定、与Bundle ID不匹配的application-identifier，且用同一个固定App ID profile；三个签入字典与profile许可模板完全一致。iCloud-services签入字符串`*`而非Apple要求的字符串数组，还签入了无关App Groups。Info额外增加UISupportsDocumentBrowser=true、将MinimumOSVersion17.0改10.0并移除硬件能力声明；原文件共享／原地打开开关已为true且未变。get-task-allow=false正常，不能当JSON选择根因。

详见[自签静态审计](selfsigned-ipa-audit-2026-11-15.md)。这些是已证实的包／授权合同差异，不是已执行的签名修复。仍需真实签名设置或服务商修正、签后IPA复查与手机选择行为复验；不伪造profile、不硬改越权App ID、不自动改Bundle ID／删扩展／数据。没有重新编译、安装或公开上传用户包，也未绕过V2EX网页读取的安全拦截。

## 自签文件选择的源码对照与设备日志

用户补充Aminark/legado-ios默认自签可选JSON，随后要求直接采集当前失败包日志。固定参考commit`5f033e4d00ff0ac7055aec7020c536ab800c8cbc`只读比较：参考书源入口显式原生asCopy=true、delegate持有scope、真实关闭后后台协调读；本Fork书源已回调即刻start，但同步读取／解析且缺协调；RSS另走后续异步load。普通书籍三文件不能直接作为书源/RSS故障链。详见[源码对照](json-picker-source-comparison.md)。没有复制GPL产品源码或改Swift。

原生`log collect`普通权限尝试退出77（要求root），停止后用户批准并自行在Mac终端管理员采集，未向Agent提供密码。归档本地保存，助手`log show --archive ... --info --debug --style ndjson`退出0，取得8071条带时间的相关事件，区间21:49:11–21:53:49（+0800）。关键三条各48次：书签无法解析、NSCocoaErrorDomain257无法创建URL、准备交付的文件数组为空。当前SDK头文件确认257=NSFileReadNoPermissionError。具体失败阶段为系统向App交付所选文件URL时授权书签被拒绝，不是JSON内容解码／普通书籍copy报错；不能单凭日志断言哪个签名字段导致，不能声称回调绝无触发或已修复。

[设备日志定位](json-picker-device-log-2026-11-15.md)保存命令、脱敏时间线和限制，原始归档不公开。SDK、签名设置、App数据与代码均未改变；当前仅完成诊断，后续原生复制模式或正常App交付日志对照仍需行为验证，S8不标通过。

## TutorialPedia 257文章适用性核验

读取用户保存到根目录的文章，原文未改。[文章核验](json-picker-article-review.md)指出其混用macOS App Sandbox/iOS，当前SDK的withSecurityScope创建／解析选项明确iOS不可用，URL.hasSecurityScopedResource非公开成员。实际`xcrun swiftc -typecheck -target arm64-apple-ios17.0 -sdk <当前SDK> .git/article-ios-api-probe.swift`退出1，报“URL has no member hasSecurityScopedResource”和“withSecurityScope is unavailable in iOS”。这是文章API负向核验，不是App构建／测试失败或修复通过。

文章UIKit的旧.import复制意图与公开现代asCopy=true一致，是针对本次有效URL交付失败的下一轮对照方向；安全scope示例、文档关联、永久书签不是当前系统书签解码失败的直接修复。未照文添加macOS权限、永久书签或把所有scope返回false当统一拒绝；没有改App。Apple DocC直连也被fake-IP安全检查阻止，未绕路，依据来自Context7官方文档及本机SDK／类型检查。

随后按实测三条错误链通过MCP／网页定位并用GitHub MCP核验nxnative#1148原评论：2026-11-14报告同签名／安装方式仅改变匹配AppID后恢复原地文件夹选择，同不匹配身份下asCopy=true单文件副本导入可用；2026-11-15维护者接受受控结果关闭issue。这与本Fork旧失败包身份不匹配／当前日志／可用参考复制导入相符，增强“原地授权失败、复制导入可兼容”的解释，但不是本Fork实际修复通过。推荐小范围真实JSON入口复制导入对照，不把目录长期访问也强制复制，不改身份／权限／SDK。链接与范围见[文章及检索核验](json-picker-article-review.md)。

## JSON原生复制导入实现与本地Debug交付

用户授权改代码后，书源两个文件入口及RSS JSON入口改为共同的公开UIKit asCopy=true单文件选择器；scope对象保持至读取结束／确认页退出，选择结果与真实关闭齐全后仅交付一次，取消和旧轮回调不复活。后台协调读取复用原BookSourceStore／RSSImportService的解析、确认与大小限制，不改普通书籍三个文件、不新增依赖、store或parser，不改签名身份、profile、原文件／用户数据。详见[实现与交付](json-copy-import-implementation.md)。

动态Xcode／模拟器、Reader-Fork-Dev串行执行`scripts/xctest.sh`选择DocumentCopyImportTests、RSSImportServiceTests、ReviewImportRegressionTests，最终退出0：`Test run with 23 tests in 3 suites passed`、`** TEST SUCCEEDED **`。首次异步Thread.isMainThread编译限制已按现有模式修正；系统未呈现时扩展名getter的非关键断言移除，实际import模式／时序／权限／业务边界断言保留通过。不把内部文件测试当重签File Provider验收。

复用既有真机DerivedData、Debug、generic/platform=iOS、本地未签名archive退出0（`** ARCHIVE SUCCEEDED **`）；打包退出0，ZIP/profile/签名结构与复制SHA核验完成，SDK27.2/minos17.0，LegadoPro3.0（5）。下载目录新增`LegadoPro-3.0-build5-local-Debug-JSON-copy-import-unsigned.ipa`（72,013,515字节），SHA-256为`59824f6c337e00a9fceeaa80e1c61813806fa4d2961088c3272737ed8b835827`，旁有sha256校验文件。未覆盖旧IPA、未重签或安装，未commit/push/触发Actions。

`ruby scripts/check_localizations.rb`退出0。用户随后确认上述新Debug包自签后“OK了，可以了”，本次JSON文件选择／导入原症状恢复；这是用户真机反馈，不冒充助手自动执行，也不展开为逐入口独立记录或所有源兼容。用户同时授权提交并push本轮相关修复。收尾额外执行`python3 -B -m unittest discover -s scripts/tests -p 'test_device_dev_script.py' -v`，1项／OK，验证此前TMPDIR路径修正。S8仍不标完成，最低iOS17／iPad／VoiceOver等人工范围不冒充通过。

## 2026-11-20：电影源首次文章的过期会话误报

用户报告影视组第一个「电影」源的任意条目首次打开提示“订阅来源或登录状态已变更，请重新打开”。只读确认其为根目录私有包的第154项、规则网页类型；登录脚本用于切换资源接口，description生成iframe，不是RSS原生AVPlayer附件。未修改、提交源包或运行分类规则的批量请求／登录动作。

- 普通同结构页面与原电影规则的隔离重放均正常。因此没有把源脚本本身判为根因，也没有改缓冲、播放器或源UA。
- **原提示的确定复现**：先缓存RSS会话，再只推进其访问版本，不改源配置、登录头或用户凭据。`RSSRuntimeState.isActive=true`而`isCurrent=false`；`BookSourceSession`仍以“存活”判断缓存可复用，新页面绑定后被撤销。`firstArticleRebindsStaleCachedAccess()`在修改前为1项／2个issue，日志明确为上述提示且文档被清空，最终`** TEST FAILED **`。
- **最小修复**：`Modules/Core/BookSource/BookSourceSession.swift`的可用性判断改用`state.isCurrent`，让新页面获得当前会话；不授予旧文档访问权，不取消真正的源编辑、登录变化、变量修改或删除撤销。仍复用已有会话缓存／脚本桥，没有新增解析器或持久数据。
- **实际验证**：动态选择Xcode／模拟器，SDK为iPhoneSimulator27.2、`Reader-Fork-Dev`、串行`scripts/xctest.sh`。选择`RSSWebInvalidationTests`、`RSSRuntimeIntegrationTests`及`RSSMoviePageReplayTests`，退出0，决定性输出`Test run with 27 tests in 3 suites passed after 12.572 seconds`、`** TEST SUCCEEDED **`。包含首次网页保留、过期会话重新绑定、旧页面仍失效，以及原有凭据／并发撤销回归。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export TEST_RUNNER_RSS_MOVIE_REPLAY_INPUT="<隔离的RSSSource JSON路径>"
bash scripts/xctest.sh -- -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/RSSWebInvalidationTests' \
  -only-testing:'yuedu appTests/RSSRuntimeIntegrationTests' \
  -only-testing:'yuedu appTests/RSSMoviePageReplayTests'
```

私有重放输入为`RSSSource`的Codable JSON：从已预审的电影规则取必要字段，声明URL替换为loopback；测试用本机JSON条目、海报和iframe替换所有实际加载资源，不执行sortUrl和登录按钮，不复制源规则到公开fixture。未提供该环境变量时，私有重放suite禁用；此时只能报告其余实际执行项，不能把禁用项计为通过。

**实源与视频边界**：以源声明UA、无Cookie／个人账号、低并发、限定响应大小只读默认API第一页：1次GET返回200／20项。随后只检查前3个条目各1个无query的HTTPS HLS链接，均返回404；未跟随重定向、改UA重试、取媒体key或segment。该结果不代表整个源不可用，也没有测出seek恢复时间。仍需与Android实际可播条目的名称／当前接口对齐，或用户允许真机验证。原电影真实页面完整闭环、快进改善、iPhone／iPad和最低iOS17没有验证，S8不标通过。

本轮未安装到手机、打包、提交或push。回滚仅恢复本轮`BookSourceSession.isActive`判断并撤回对应新增测试；不还原同文件之外的先前UA／CF改动，不清理用户源包、模拟器或既有数据。

## 2026-11-20：葫芦视频分类脚本提前求值修复

用户补充根目录私有包第45项「葫芦视频」打开提示“RSS源脚本执行失败，请查看诊断”。静态预审确认：分类脚本只读请求一次分类API，生成的URL含未来页码与源变量模板；列表为JSON，类型0、非singleUrl、preload关闭。没有运行媒体脚本、登录动作或修改源包。

- **原错误复现**：以声明UA、无Cookie／个人账号、禁止自动重定向、256KiB预算读取分类API一次，200／application/json／4504字节／29项，非CF challenge。隔离URLProtocol将这份响应供给原分类脚本，`RSSCategorySourceReplayTests`修改前1项失败、`.scriptFailure`，最终`** TEST FAILED **`。
- **最小复现**：不联网，只让JS返回含`{{page}}`的分类URL；普通URL控制用例正常，`@js:`和`<js>`两种包装均失败。固定Android commit `330e606c4d57e08adc056ff8ab7a4132c784da9a`的`RssSourceExtensions.sortUrls()`直接`evalJS(script)`，不经正文规则解析。用户批准补齐现有工具固定依赖后，`lc.py oracle`实际输出原样保留的模板字符串，`typeof=string`；Rhino1.8.1／jsoup1.16.2下载后匹配项目固定SHA-256，仅进入Gradle工具缓存，没有加入App或改Android。
- **根因与最小改动**：iOS `LegadoRSSScraper.resolveSortEntries`把整个分类JS送入`ModernRuleEngine.getString`，正文规则的`makeUpRule`抢先执行字符串内的模板，分类阶段没有`page`而产生脚本错误。现在在原`withRuleContext`中直接调用已绑定的JS evaluator，并复用原字符串转换；源鉴权、取消、交互要求、脚本超时和错误检查不变。不改通用正文模板规则、不引入新JSContext／解析器、不按源名或域名分支。
- **默认列表闭环**：预审后按空的隔离源变量、page=1只读默认列表API一次，200／JSON／6125字节／15项；512KiB预算，无Cookie、改UA重试、重定向或实际媒体资源。私有重放覆盖同一原分类脚本→29分类→默认列表15条，并验证`pic`文章变量与两个固定请求。真实首入口使用`{{source.getVariable()}}`而非`{{key}}`，公开自建回归同时验证未来页码和源变量在请求阶段求值。
- **实际结果**：动态Xcode／模拟器、iPhoneSimulator27.2 SDK、`Reader-Fork-Dev`，串行`scripts/xctest.sh`选择下面4个suite，最终退出0：`Test run with 29 tests in 4 suites passed after 12.250 seconds`、`** TEST SUCCEEDED **`。原脚本固定输入错误消失，已有电影首次页面／凭据与取消回归仍通过。中间私有测试误将首入口当作无页码模板、又误认其取key，依据源配置修正了本轮新断言；新增列表变量断言的可选访问编译错误亦已修正，不把这些中间运行算作通过。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export TEST_RUNNER_RSS_CATEGORY_REPLAY_INPUT="<隔离分类重放JSON路径>"
export TEST_RUNNER_RSS_MOVIE_REPLAY_INPUT="<隔离电影重放JSON路径>"
bash scripts/xctest.sh -- -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/RSSRuntimeIntegrationTests' \
  -only-testing:'yuedu appTests/RSSCategorySourceReplayTests' \
  -only-testing:'yuedu appTests/RSSWebInvalidationTests' \
  -only-testing:'yuedu appTests/RSSMoviePageReplayTests'
python3 -I scripts/legado-compat/lc.py oracle "<自建纯JS字面量case JSON路径>"
```

分类重放JSON包含`source`（必要字段的RSSSource Codable）、`body`和`listBody`（两份已捕获JSON的base64）。运行时只把源origin换成合成host，复用既有固定响应工具，不加载封面、网页、媒体或个人登录。原始响应与源规则留在隔离暂存目录，不作为公开测试资源。未提供相应环境变量时私有suite禁用，不能把它计为通过。

本轮是RSS单源修复；旧YCK批跑的1330／1331／1329包缺失，未下载旧源包、启动全包审计或报告LC可用率／GATE PASS。视频播放和seek、MuiPlayer外部资源、真实页面人工操作、真机／iPad／最低iOS17仍未验证。回滚只撤回本轮分类求值改动和对应新增回归，不撤销先前电影会话／UA／CF修复，不删除用户数据或源包。未提交、push、发布或安装到手机，S8仍不标完成。

### 隔离模拟器人工复测准备

按用户选择继续模拟器：串行测试清理后目标模拟器处于Shutdown，`simctl bootstatus <动态目标> -b`实际完成启动。复用已安装的最新Debug App，动态`get_app_container`取得App数据路径，新建独立`rss-manual-*`目录，仅写入「电影（单页测试）」与「葫芦视频」两条配置。原包、原RSS数据和其他目录没有改动；电影临时副本的分类脚本只保留使用原sourceComment求值的“最近更新”入口，不执行原分类的ajaxAll／重试，因此不是电影完整分类验收。葫芦规则保持原样，图标仅指向本机拒绝端口，未播媒体或操作验证。

`simctl launch --terminate-running-process ... -rss-store-dir <新目录>`返回Debug Bundle ID与PID；进程检查确认存活，截图确认App显示中文探索根页。SDK27.2／iPhone 18 Pro Max，模拟器窗口已打开；尚未自动点击订阅源，未把启动／截图记为实源或播放通过。后续由用户点击订阅验证两条源并给出实际可播条目／seek时间。正常启动时不带`-rss-store-dir`即可恢复原数据入口，不删除测试目录或既有数据。

用户随后在上述新模拟器中手动点击订阅并打开葫芦视频，确认“现在能进列表”。这是用户的实源首列表反馈，原打开时报脚本失败的症状已恢复；不冒充助手自动UI测试，也不扩展为视频播放、快进或电影源完整分类通过。

## 3.0.1（build 6）提交与本地Debug交付准备

用户随后反馈视频仍不能播放，并要求先提交push、再编译到下载目录；本轮不再扩大播放器排查，不把首列表恢复写成媒体通过。用户确认版本从3.0（5）递增为3.0.1（6），只改统一版本xcconfig。提交范围为RSS会话／分类／原生网页UA与CF提示修复、相关测试和本记录；私有源包、响应、暂存目录及无关用户文件不提交。

既有已交付Debug IPA使用`dev.denis.readerfork.dev`及其两个扩展身份，当前脚本默认只允许Release。新增明确的`--configuration Debug`打包模式，不改写Bundle ID；默认Release和拒绝混合身份、缺扩展、模拟器、覆盖旧IPA等检查保留。新模式先复现不支持configuration参数；修复后`python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v`实际24项／OK，版号解析及`git diff --check`均退出0。App行为沿用本轮已执行的29项／4 suites结果，不把包装测试当作播放或真机验证。代码提交`15d3c138`已先推送origin/main，再执行以下归档和交付。

### 3.0.1（6）实际归档与下载文件

旧Debug真机临时DerivedData／xcconfig已不存在，未重建该路径或clean；沿用最近本地归档的默认DerivedData。动态选择Xcode，SDK27.2，`Reader-Fork-Dev`／Debug／generic/platform=iOS，禁用签名和自动更新依赖，新archive位于`.git/rss-3.0.1-build6.JE9zdTKY/LegadoPro-3.0.1-Debug.xcarchive`。`xcodebuild archive ...`实际退出0，决定性输出`** ARCHIVE SUCCEEDED **`。随后`python3 -B scripts/package_unsigned_ipa.py --archive <上述archive> --output <新目录>/ipa --configuration Debug`退出0。

下载目录新增`LegadoPro-3.0.1-build6-local-Debug-unsigned.ipa`及同名`.sha256`，不覆盖旧包。主App和两个扩展均为3.0.1（6）、iPhoneOS、最低iOS17，Debug身份家族与上次包一致；ZIP CRC、可执行权限、三Bundle ID、复制SHA一致，三个Mach-O均无LC_CODE_SIGNATURE，未包含profile或签名资源目录。72,245,310字节，SHA-256为`a6eafa419b55a6a722650ca374eaa64a3be11bf856200b344facdb5491385406`。实际校验记录保存在本次`.git`暂存目录，无原始源包或私有响应进入IPA。

这是本地Debug未签名真机产物，需要用户自行签名后安装；未安装本次包或重签，不承诺签名服务的权限配置。用户反馈的视频不能播放尚未修复，不能把归档、打包或首列表恢复当作媒体通过。回滚版本或代码使用普通后续提交，不force push；不删除旧IPA、用户App数据或源包。

## 2026-11-21：上游导入不变不写与原文调试旁路清理

用户批准按建议实施两项高优先级补丁，基于`c3eec5e1`只适配`0236a2da`的导入no-op和`50ccb769`中三个共享运行时文件的原文控制台输出；不整包合并、不改路由、持久格式、版本、依赖、权限或播放器。来源、必要适配、命令和回滚见[本批记录](upstream-noop-privacy-batch-2026-11-21.md)。

- 有效RED：自建单源重复导入3次，写盘1→4、发布3、修订+3；保留本地字段后的无变化确认导入亦重写。3项中1控制通过、2失败／6issues，`** TEST FAILED **`。首轮误把生命周期flush当等待的文件未就绪不作为原问题证据，已改用现有`queuedWritesLanded()`。
- 修复沿既有内容比较记录changed，无变化且无新增时提前返回，不发布／保存；真正修改、新增、身份／时钟／重复URL和导入选项保持。移除source级NSLog及JS异常／脚本print／toast／logType原文旁路，接口和UI提示仍保留，CSRF可选初始化失败通过既有AppLogger记录数值错误码及取消。没有照搬上游空异常handler或整批日志删除。
- 实际GREEN：动态Xcode／iOS27.2 iPhone模拟器／Reader-Fork-Dev／串行`scripts/xctest.sh`，选择新隔离导入、脚本诊断兼容、SourceImportPlan、BookSourceImportOptions、RSSRuntimeIntegration、DiagnosticRedactor六个suite，退出0：`Test run with 48 tests in 6 suites passed after 4.556 seconds`、`** TEST SUCCEEDED **`；`python3 -B -m unittest scripts.tests.test_source_debug_logging_privacy -v`为3项／OK。旧共享书源库测试在首次GREEN的编译阶段主动排除，无测试执行，不计通过。
- 保留现有AppLogger、源作者java.log、SourceAPIErrorLog、诊断与错误回调。本轮只清理已识别旁路，不声明全项目隐私审计或历史日志清理完成。没有运行实源、真机、iPad／最低iOS17或视频播放验收；视频不能播放仍未修复。

本轮未提交／push／打包，下载目录此前3.0.1（6）IPA不含这些新改动。工作区与源包保留，只反向撤回本轮文件即可回滚，S8不标完成。

## 当前 Fork 全功能差距复核（c3eec5e1 + 既有工作区）

用户要求重新对照固定 Android 基准，范围不限于 RSS。本次只审计和补文档导航，不修改业务代码、原始包、配置或既有未提交改动；详细两端源码、差距类别、优先级与边界见[当前功能差距复核](current-feature-parity-audit.md)。

- 实查 iOS HEAD `c3eec5e15297f28649ec70fdee2da1a1ceaf6358`，Android HEAD `330e606c4d57e08adc056ff8ab7a4132c784da9a`，未更新基准。当前四个生产文件的既有导入／日志改动计入阅读范围，不等同已交付 IPA。
- 两包离线 JSON／类型／哈希统计：书源253项（208文本／3音频／32图片／3文件／7视频），RSS307项全部type=0；SHA-256与固定方案一致。未运行源脚本或公网请求。
- `python3 -I scripts/legado-compat/lc.py status`：1330／1331／1329包均MISSING，历史r20 fingerprint不同，不报告当前可用率或GATE PASS。
- `bash scripts/sim.sh doctor`：SDK27.2，runtime仅26.2／27.2，没有iOS17；仅检查环境，没有启动App。
- 当前生产RegexSanitizer在macOS合成探针实际复现：`a++a`→`a+a`、`(?>a+)a`→`(?:a+)a`，原表达式不匹配`aa`、改写后匹配；输出`MACOS_REGEX_DIFFERENCE_CONFIRMED cases=2`，退出0。命令及本地`.git/parity-audit.zatJSUG3/`证据见报告。这是语义差距复现，不是修复／iOS17／完整规则引擎通过。
- 结论（按用户后续反馈修正）：RSS旧入口／运行时／分页／网页／图片／管理缺口不能再原样报缺失；**真实视频已能播放，只有偶发快进异常，作为小Bug单列，不属于功能缺失**；S8具体人工／平台验收记录仍分别保留。非RSS确认保留mainJs、批量正文／副文、完整段评、type=3下载导入、规则语义、RuleSub、完整备份／跨端协议、导出编辑、分组／换源细项、有限Java/API、Web/MCP、UMD等差距；Dict/Cron／iCloud等遵守既有排除／暂停决策。

未执行Android／iOS App测试、build／archive、安装、媒体／seek、真实登录／WebDAV、迁移、性能或无障碍验收；不把历史记录写成本次通过，S8仍不标完成。回滚只撤回新报告、导航和本节，不删除用户数据或既有工作区。

本次用户纠正：真实视频已经可以播放，偶尔快进有问题属于小Bug，不是功能缺失。已据此修正[当前功能差距复核](current-feature-parity-audit.md)的结论、R1分类和后续安排；旧“不能播放”仅保留为当时观察，不再作为当前功能缺失的依据。确认来自用户实际使用反馈，助手未重测播放／快进或定位根因，没有修改播放器代码。

文档收尾：`python3 -B .git/parity-audit.zatJSUG3/check_docs.py`退出0，`DOC_FORMAT_LINK_CHECK_OK files=3 localLinks=57`（UTF-8／LF／无尾空格／代码围栏及本次范围内相对链接）；首次`git diff --check`指出本节末尾新增空行，移除后复查退出0，`GIT_DIFF_CHECK_OK`。本次没有新增UI文案，不声称运行本地化或App测试。

## 首批功能对齐：隔离分支自动验收（2026-11-21）

本批按用户确认只做正则语义、书源配置保真、文件型书源与RuleSub配置包订阅更新。用户最新确认视频已可播放，偶发seek是后续小Bug；本轮未重新测试视频。方案和人工确认清单见[首批功能实施与验收](first-functional-parity-batch.md)。

- 分支／目录：`feature/legado-functional-parity`／同级`Yuedu-reader-legado-parity`，基于`c3eec5e15297f28649ec70fdee2da1a1ceaf6358`。
- Android本地HEAD实际核对为`330e606c4d57e08adc056ff8ab7a4132c784da9a`，没有修改或切换基准。
- 环境：`uname -s`输出`Darwin`；`scripts/sim.sh doctor`选择SDK27.2和iPhone 18 Pro Max／iOS27.2。目标ID由脚本解析，使用`Reader-Fork-Dev`和原DerivedData，串行测试，不clean，不新建DerivedData绕过错误。
- 原始合同RED：`contracts-red.log`显示6项／14个问题／`TEST FAILED`；文件生命周期补充RED显示7项／3个问题，复现取消列表加载后ready复活和本地解析时删源仍留新书。
- 文件网络证据：现有本机有限服务器实际收到一次POST、正文`id=42`和声明头部。下载原始TXT字节完整保存、书架元数据重载一致。URLProtocol中`httpBody`为nil的仪器问题通过真实传输观察排除，不更改请求来满足断言。
- 规则订阅证据：书源、RSS与替换规则的实际owner提交；手动确认、静默、同内容不写、作者版本、失败、取消、删除／改配置的晚到保护、写入失败恢复均有隔离测试。替换规则测试指定独立文件，不读写生产单例快照。
- 重活证据：日志出现`source.file.download ... main=false`、`rule.subscription.load/persist ... main=false`和`replace.persist ... main=false`。这只证明被记录的工作不在主线程，不是全App性能认证。

### 实际命令和结果

工作目录为隔离工作区：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -l .artifacts/first-parity/final-behavior-2.log -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/FirstParityContractTests' \
  -only-testing:'yuedu appTests/BookSourceConfigurationPersistenceTests' \
  -only-testing:'yuedu appTests/RuleSubscriptionTests' \
  -only-testing:'yuedu appTests/SourceFileImportTests' \
  -only-testing:'yuedu appTests/ParserRegressionTests' \
  -only-testing:'yuedu appTests/RegexUnmatchedGroupTests' \
  -only-testing:'yuedu appTests/RegexTimeoutCancellationTests' \
  -only-testing:'yuedu appTests/BookInfoMergeTests' \
  -only-testing:'yuedu appTests/SourceImportPlanTests' \
  -only-testing:'yuedu appTests/LocalBookImportServiceTests' \
  -only-testing:'yuedu appTests/RSSImportServiceTests' \
  -only-testing:'yuedu appTests/ReplaceRuleDeduplicationTests'
```

实际退出0：`Test run with 81 tests in 11 suites passed after 13.341 seconds`、`TEST SUCCEEDED`。前面的XCTest框架0项结论不作为证据；后面的Swift Testing实际81项才是结果。

`ParserRegressionTests.swift`不是同名suite，第一次该selector没有匹配。按文件中的6个真实suite额外执行，未修改旧测试期望：

```bash
bash scripts/xctest.sh -l .artifacts/first-parity/parser-regressions.log -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/CrossParserCompatibilityTests' \
  -only-testing:'yuedu appTests/BrowserImportPlainTextRegressionTests' \
  -only-testing:'yuedu appTests/BookSourceModelTests' \
  -only-testing:'yuedu appTests/RegressionEdgeCaseTests' \
  -only-testing:'yuedu appTests/RuleEngineAPITests' \
  -only-testing:'yuedu appTests/RegexSanitizerTests'
ruby scripts/check_localizations.rb
git diff --check
```

解析器实际退出0：`Test run with 42 tests in 6 suites passed after 0.946 seconds`、`TEST SUCCEEDED`；两个最终批次合计123项／17 suites。

文档和新增文本另运行`python3 -B .artifacts/first-parity/check-delivery.py`，实际输出`Document checks OK: 3 documents, 106 local links; 14 new text files UTF-8/LF/whitespace OK`；收尾`git diff --check`退出0。本地化实际输出`Localization OK: Modules, Targets use 3022 literal keys, all in Resources/zh-Hant.lproj/Localizable.strings`，五语言46个新增key、格式参数及权限资源检查通过。中间新增测试的字段名及Swift Testing抛错宏编译问题已修正，不算行为RED，也不改变生产行为或旧期望。

### 边界与合入判断

自动验收通过，但未进行新页面人工点击、阅读器打开、VoiceOver／大字、真实服务／登录、iPad、真机或最低iOS17测试；提供Preview不代表这些已经验证。只完成本地规则订阅存储，不扩展WebDAV清单或Android迁移。替换包的未支持作用域／超时明确拒绝，相关`js/showRule/sourceUrl`不猜测执行；不宣称全包可用率或替换规则完整兼容。

未提交、合入、push、发布、安装手机、改正式签名或删除用户数据。main仍有原来的运行时／导入／日志及审计未提交修改，保持原处；合入前需用户人工确认并单独整合重叠修改，当前不能标记满足主线合入条件。`.artifacts/`日志与暂存输入不加入业务提交。回滚方式是保持隔离分支未合入，日后回退采用经用户确认的正常提交；不清理工作区、force push或直接覆盖有新格式数据的安装。


### 专用模拟器人工验收环境（2026-11-21，用户授权准备）

用户要求打开模拟器、预置验收条件，并允许使用目录中昨天提供的实源。只准备隔离环境，不把启动或fixture返回记为人工行为通过。

- 动态读取当前可用iPhone 18 Pro Max／iOS27.2的device type和runtime，`simctl create`创建专用设备 **Legado 首批验收 1121-1158-940f**（`4746A8B1-A20F-4A64-B98F-F866A7DA2627`）。原设备、原容器与原数据保持不动。`bootstatus -b`实际Finished；复用最近通过测试的Debug App，`simctl install`和`launch`成功，中文探索页截图已捕获，App进程仍存活。
- 当前Xcode没有常见的Simulator.app，已定位并打开`Contents/Applications/DeviceHub.app`；Info.plist与本地程序元数据确认其提供设备／模拟器界面，进程实际启动。用户需在DeviceHub选择上述专用设备打开画面；未自动授予屏幕、辅助功能、登录或系统权限。
- 原包静态解析为253书源／307 RSS，其中type=3共3条：登录版Z-Library、优品文档、知轩藏书。预置原书源#104知轩与#55优品，保留原解析和请求规则，只在验收副本设分组、排序、关闭首页自动发现并加版本标记；不自动登录Z-Library。另预置RSS#180少数派（禁用，需用户主动启用才抓文章）和一条关闭的验收专用替换规则。
- 只监听127.0.0.1的临时包服务提供手动知轩v2、静默知轩v3、RSS配置v2、替换规则v2、10秒慢响应、HTTP503和无效格式，共7项订阅。全部autoUpdate关闭，配置版本／远端名称分组是测试副本，不是作者正式更新；真实站点由用户点击后请求。正向四端点实际HTTP200／每包1项，失败fixture实际503，元数据数量和格式已检查。
- 两个原包前后SHA-256一致，没有执行真实脚本、访问源站、购买、发布、外部导入或个人登录。旧YCK工作流仍报告三个pack缺失，本轮不是LC全包审计，不报告可用率或GATE PASS。
- 私有暂存目录为`.artifacts/manual-parity-3f367c74dc/`，含环境记录、包副本、界面截图、人工步骤和「重新打开验收App.command」。重启脚本语法检查通过，仅操作专用App，不重置数据。本机服务保持运行供用户验收；私有副本不提交。

验证入口：先「设置→规则包订阅」按①手动→②静默→⑤取消→⑥失败→⑦格式错误，再检查③RSS和④替换规则；文件流程从探索放大镜搜索书名进入知轩结果，优品搜索“旅行”用于格式受限检查。阅读器打开、实际实源可用性和用户人工结果仍待反馈，不能用这些准备结果代替。


### 用户人工验收确认（2026-11-21）

用户在上述专用模拟器条件准备后明确反馈：「我按你的验收步骤，都验收OK了」。据此将本批约定范围的人工关卡记为通过，结合此前实际执行的123项／17 suites自动结果，本批功能验收通过，可以进入合入准备。

确认依据是用户实际操作汇报，不是助手自动点击或媒体验证。范围以临时目录人工指南为准：文件型源下载→书架→开始阅读，①手动／②静默／③RSS配置／④替换规则更新，⑤取消／⑥HTTP503／⑦格式错误，以及重启和显示检查。用户未提供独立的逐项截图、书名或请求明细，因此不追加全源可用率、全部格式兼容或辅助技术认证结论；真机、iPad、最低iOS17和VoiceOver专项验证没有新增独立证据。

本条反馈记为验收确认，不擅自解读为commit、合入或push指示。当前分支仍为`feature/legado-functional-parity`，HEAD为起点`c3eec5e15297f28649ec70fdee2da1a1ceaf6358`，代码及文档尚未提交。main仍有原来的BookSourceStore、ModernParserBridge等重叠未提交改动；没有覆盖、挪动或清理。合入需用户明确指示，先保留／整合这些变更，再对整合结果执行最小相关回归。本轮只更新验收记录，不重复未变化代码的测试。
