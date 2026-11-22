# 上游精选修复分步验收（2026-11-22）

## 边界

用户确认按只读评估的建议逐步执行。起点为 Fork `a732eae9`，上游固定为 `78199517ffbc4952ba145968322fdd1055093be6`。本批不整包合并、不恢复账号／收费／iCloud，不修改依赖、权限、版本、源包或持久格式。自动验收时不提交／推送；用户随后明确授权将本批提交并正常推送到 `origin/main`，不打包或发布。

来源为上游 CHANG-JUI-LIN 的 MPL-2.0 仓库；只摘取行为修复，不复制 Android 代码、真实源规则或素材。四步已按登录、书架无障碍、探索变量读取、自动阅读的顺序完成本地自动验收；不等于 S8／发布验收通过。

| 步骤 | iPhone 本次最终回归 | 其他本次证据 |
| --- | --- | --- |
| 登录源快照／菜单诊断 | 18 项，0 失败／跳过 | 原始菜单异常 RED→GREEN；源码隐私 5 项 OK |
| 书架无障碍 | 6 项，0 失败／跳过 | iOS 26.2 同 6 项通过 |
| 探索变量读取 | 14 项，0 失败／跳过 | 20→1 次读取，转到后台 |
| 自动阅读 | 22 项，0 失败／跳过 | 状态、三种宿主、真实窗口图层绘制 |
| iPad 综合 | 60 项，0 失败／跳过 | 覆盖上面四步；无 runtimeWarnings |

集合包含重复用例，不相加宣称唯一用例总数。以下命令记录当次实际参数；重跑应使用新结果目录／标签，不覆盖原日志或复用已存在的 xcresult。


环境实查：`bash scripts/sim.sh doctor` 选择 Xcode 27.2、iOS 27.2 iPhone 18 Pro Max；当前没有 iOS 17 runtime。`xcodebuild -showBuildSettings -json` 确认主 App 为 Swift 6.0、strict concurrency complete，未设置 approachable concurrency 或默认 actor isolation；技能文档中的 Swift 5／minimal 是旧记录，本批不改语言模式。使用 `Reader-Fork-Dev`、原 DerivedData 和 `scripts/xctest.sh` 串行测试。

本机原始日志与 xcresult：`.artifacts/upstream-selected-FTa5tKnl/`，不提交。

## 第一步：登录源快照与残留日志

来源：`0f2735ec` 的登录源快照片段、`50ccb769` 的登录菜单调试清理片段。

实际改动：

- `runLoginJS` 和 `runButtonJS` 在主线程取得源值，再交给现有脚本线程；不新建执行器。
- 移除菜单前后的两次诊断求值及原文 `NSLog`。额外求值会重置 `engine.lastError`，导致原始按钮异常丢失。
- 保留动态标签、重新载入菜单、toast 和原错误报告。
- 现有按钮函数返回原任务句柄，测试可等待真实执行结果；DEBUG 下提供已安装 View 的测试回调，避免在未挂载的 `@State` 上验证。内部源更新入口用于测试，不改公共 UI 或运行时协议。

### RED

`LoginMenuExecutionTests` 用自建离线脚本走实际按钮函数。移除诊断前为 2 项、1 失败，`** TEST FAILED **`：带旧诊断标记的源执行 `throw` 后，错误报告为 nil；普通源及正常按钮控制项符合原行为。

```bash
python3 -B -m unittest scripts.tests.test_source_debug_logging_privacy -v
```

新增源码合同初轮为 5 项、2 失败：登录源快照缺失、原文控制台旁路仍在。源码检查不是线程竞态或日志抓取的行为证据。

首轮 Swift 测试未挂载 View，产生状态访问警告。随后改为实际挂载 View；受控队列下点击后更新源的用例在补显式快照前也通过，因此它是稳定性控制项，不宣称原线程竞态已被实际复现。移除菜单诊断的原始异常失败已独立复现。

### GREEN

最终只选择隔离菜单、源诊断兼容、LoginUiV2 和旧表单的安全子集：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
A=.artifacts/upstream-selected-FTa5tKnl
bash scripts/xctest.sh -l "$A/login-isolated-green.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$A/login-isolated-green.xcresult" \
  -only-testing:'yuedu appTests/LoginMenuExecutionTests' \
  -only-testing:'yuedu appTests/SourceDebugLoggingCompatibilityTests' \
  -only-testing:'yuedu appTests/LoginUiV2Tests' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/dynamicLoginUiSharesLoginUrlContext()' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/dynamicViewNameResolvesInLoginUrlContext()' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/staticLoginUiDynamicViewName()' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/loginFormResultIsJavaMap()' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/viewNameReadsResultAsJavaMap()' \
  -only-testing:'yuedu appTests/BookSourceLoginTests/blankLoginFieldIsRequired()'
```

最终退出 0，`** TEST SUCCEEDED **`；xcresult 为 **18 通过、0 失败、0 跳过、runtimeWarnings 为空**（15 Swift Testing＋3 XCTest）。同一离线按钮异常现在保留；队列控制项仍使用点击时源，正常动作无错误。五项源码隐私检查最终为 `OK`。

中间 `login-green` 运行了旧 `BookSourceLoginTests` 全 suite，40 项通过，但其中两项既有测试写入真实域名的共享 Cookie，首轮新测试另有未挂载状态警告。这轮不作为数据隔离或无警告结论；无法事后证明运行前这些 Cookie 是否存在，不宣称它们未被影响，也不自动恢复／清理。后续仅用上面的安全方法选择器，不运行联网 suite。

### 第一步限制与回滚

登录步骤后来已纳入下文 iPad 综合自动回归；未验证真实账号、真机、iOS 17 或人工交互走查。测试构建提供编译证据，不重复单独 build。

回滚只反向撤销本步登录 View、隔离菜单测试及 Python gate 的差异；不恢复整个工作区、不删源包、用户数据或已有日志。

## 第二步：书架无障碍动作

来源：`eaa3d7b7`。`HomeView` 读取 VoiceOver／Switch Control 状态：开启时不提供行滑动，`BookRow` 自己提供置顶和删除；关闭时保留原生滑动及已有确认删除。方格补置顶动作，编辑态不提供破坏性动作。行的等价比较包含滑动状态，既有 Preview 保留。

测试只挂载自建行／方格，不设置书架或全局布局偏好；仅测试 target 启用并恢复无障碍运行时、读取汇总动作，以条件等待代替上游 sleep／布局延时。

- `voiceover-red`：原列表的汇总动作中置顶、删除各出现 2 次，方格置顶为 0 次；最终 6 项失败。另有编辑态 nil 动作数组被测试误当错误、普通触控不应要求转子去重的测试假设，已分别纠正，原无障碍核心断言不放宽。
- `voiceover-green`：6 项 XCTest 通过，0 失败／跳过／runtimeWarnings，`** TEST SUCCEEDED **`。
- `voiceover-older`：动态选择最老可用 iPhone runtime（iOS 26.2）运行同 6 项，`** TEST SUCCEEDED **`。未安装 iOS 17，未做真机实际朗读或 Switch Control 手动走查。

命令：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
A=.artifacts/upstream-selected-FTa5tKnl
bash scripts/xctest.sh -l "$A/voiceover-green.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$A/voiceover-green.xcresult" \
  -only-testing:'yuedu appTests/BookshelfRowVoiceOverActionsTests'
```

旧 runtime 的 destination 从 `bash scripts/sim.sh list` 的可构建 iPhone 中按版本取最小值，不按固定名称或 UDID 选择。回滚仅反向撤回本步 `HomeView.swift` 与无障碍测试差异，不删除书籍或改偏好。

## 第三步：探索每页只读取一次源变量

来源：`53a2d1c4` 的按页读取思路；只适配当前首屏 provider，不引入上游新首页或其他作者／题材页面。保留 Fork 已有 mainJs `book.type` 位标记优先级，不按书源类型数字替代。

`BookSourceProvider` 的网络结果与已保存页面共用一个非隔离异步条目构造函数：加载结束后读取一次当前源模式，并在后台构造最多 20 项条目。保留原请求、Cookie 初始化、首屏存储、条目身份、封面头与页面限制；没有新增缓存。空页面不读取变量。

先加入计数入口及固定 fixture，仍保留逐书读取／主线程构造。`entries-red` 为 4 项、2 失败／2 通过：网络页读取 20 次且在主线程，已保存的 4 本读取 4 次；mainJs 位标记和合法空结果控制项通过。

同一自建输入为 20 本书、346,918 字节源变量 JSON。本机会话的单次观测：

| 观察 | RED | GREEN |
| --- | --- | --- |
| 源变量读取次数 | 20 | 1 |
| 读取发生在主线程 | true | false |
| 变量解析累计线程 CPU | 50.08 ms | 2.79 ms |

这只是本次模拟器固定输入的变量解析成本，不是整个首页耗时、内存或真机性能承诺。已保存页面的回归确认 0 请求、读取一次、条目与原逐书路径相同。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
A=.artifacts/upstream-selected-FTa5tKnl
bash scripts/xctest.sh -l "$A/entries-green.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$A/entries-green.xcresult" \
  -only-testing:'yuedu appTests/BookSourceRowEntriesTests' \
  -only-testing:'yuedu appTests/SourceCategoryCardsTests'
```

最终 `Test run with 14 tests in 2 suites passed`、`** TEST SUCCEEDED **`，xcresult 14／0 失败／0 跳过／无 runtimeWarnings；含分类卡片的数量、排序、错误、共享请求和已有封面 UA。测试均使用自建输入与独立首屏目录，不请求外站。随后纳入 iPad 综合回归；未测真机、iOS 17、大型真实首页或全项目性能。

回滚只反向撤回 `BookSource.swift` 的可选模式参数、provider 的按页后台构造和本步测试，不清首屏缓存或用户源变量。

## 第四步：自动阅读落地与揭页图层

来源：`5a0ec0fd`＋`9657149a`。在原有命令增加默认 false 的 `isAutoRead`，宿主区分正在执行／排队的自动翻页，并在落地、拒绝或被吸收时回报。控制器保持完整揭页，等回报后重置；期间最多计入一页已经显示的阅读时间，不跳过未看见的页面。手动翻页、退出和切换滚动清理等待。固定版面也接回报，不另建翻页通道。

仿真翻页中新页面会加入顶层，揭页采用 zPosition 1 保持在上方，不追逐 UIKit 插入顺序。Fork 的真正拆除、媒体释放及现有翻页／预读路径未被替换。

`autoread-red` 两项均失败：页边界揭页进度提前变为 0，下一次指定帧再次发出翻页请求。首次像素测试采用离屏 `layer.render`，修复后仍得到红色，不能代表屏幕合成；这轮 `autoread-green` 为 21 通过／1 失败。只调整测试为已挂载窗口的 `drawHierarchy(afterScreenUpdates: true)`：zPosition 0 的控制组实际绘制红色，生产配置实际绘制蓝色，保留失败证据，不修改生产方案来迁就离屏绘制。

新增回归不调用旧 `AutoReadControllerTests.makeController()`，避免清除全局速度偏好；旧 suite 只选纯帧算术方法。合成正文的三种分页 Coordinator 使用独立进度目录并确认非空图片：请求排队时保留旧揭页，回报时先重置，再换下一页图片。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
A=.artifacts/upstream-selected-FTa5tKnl
bash scripts/xctest.sh -l "$A/autoread-final.log" -- \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$A/autoread-final.xcresult" \
  -only-testing:'yuedu appTests/AutoReadPageBoundaryTests' \
  -only-testing:'yuedu appTests/ReaderPageTransitionQueueTests' \
  -only-testing:'yuedu appTests/ReaderPageTurnSmoothnessTests/curlTapRecognizerIsDisabled()' \
  -only-testing:'yuedu appTests/ReaderPageTurnSmoothnessTests/frameRateRequestIsHeldUntilTheLastTurnEnds()' \
  -only-testing:'yuedu appTests/AutoReadControllerTests/fractionFollowsElapsedTime()' \
  -only-testing:'yuedu appTests/AutoReadControllerTests/oneTurnPerBoundary()' \
  -only-testing:'yuedu appTests/AutoReadControllerTests/longFrameTurnsEveryPage()' \
  -only-testing:'yuedu appTests/AutoReadControllerTests/progressDoesNotDrift()' \
  -only-testing:'yuedu appTests/AutoReadControllerTests/nonsenseFrameIsIgnored()'
```

最终退出 0，`Test run with 22 tests in 4 suites passed`、`** TEST SUCCEEDED **`，xcresult 22／0 失败／0 跳过／无 runtimeWarnings。覆盖揭页保持、已读时间、慢转场、手动翻页、暂停、退出、滚动与书末，三种分页宿主和图层绘制；不把它写成真实长书、真机或人工完整阅读体验已通过。

## iPad 综合与交付检查

`ipad-selected` 使用 `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"`，其余沿同一 scheme／原 DerivedData。选择第一步的隔离菜单、诊断兼容、V2 和六个安全旧表单方法，第二步无障碍 suite，第三步变量及分类卡片 suites，第四步完整选择器。最终 xcresult 为 **60 通过、0 失败、0 跳过、runtimeWarnings 为空**；框架输出为 51 Swift Testing＋9 XCTest，`** TEST SUCCEEDED **`、退出 0。

`ruby scripts/check_localizations.rb` 实际输出 `Localization OK: Resources/*.lproj/Localizable.strings (5 files, 4383 keys)`，3071 个调用键齐全；本批未新增用户文案。两份原始源包 SHA-256 与方案一致；没有源包、依赖、权限、版本、签名或持久格式改动。

自动验收结束时，本批尚未提交／推送／打包；用户随后授权提交和 Push，仍不打包或发布。最低 iOS 17、真机、实际 VoiceOver／Switch Control、人类操作及真实账号／长书体验仍未验证。旧登录完整 suite 的开发模拟器共享 Cookie 风险保留在第一步，不清理或伪造恢复。

提交前核对：本地 `main` 与远端 `origin/main` 均为 `a732eae9`，暂存区为空；本批仅包含 11 个生产 Swift 文件、4 个 Swift 回归文件、1 个 Python gate 和 2 份验收文档，共 18 个文件。原始源包及本地产物不提交。复核六份 xcresult，结果与上表一致；代码和验证环境未变，不重复构建或运行测试。普通 Push 只触发本地化工作流，IPA 构建仍仅手动触发；提交／推送是否完成以实际 Git 输出和远端 `main` 的哈希核验为准。

第四步回滚仅反向撤回七个阅读器文件及新边界测试；前三步可按上文独立撤回。所有回滚均保留已有数据、日志和共享历史，不执行 reset／clean 或删除模拟器。
