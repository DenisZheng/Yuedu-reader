# RSS 对齐验证记录

本文件只记录实际执行证据和阻碍。计划见 [implementation-plan.md](implementation-plan.md)，不能把环境检查或文档完成当作 RSS 已实现。

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
| S5–S8 | 按依赖顺序继续；Feed搜索AX、媒体时钟、真机/iOS17和云端archive问题须在对应验收前解决 |

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

回滚保持S4基线及RSS数据：整体撤回S5路由/分页与共享层修改；新增可选字段兼容旧文件，降级前保留备份并只处理被partial标记的全文缓存，不能把部分结果当完整文章，也不清空来源/阅读状态。原始源包、Android基准和签名配置未修改；不push或启动云构建。
