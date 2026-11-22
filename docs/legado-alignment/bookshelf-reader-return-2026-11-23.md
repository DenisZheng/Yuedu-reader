# 书架封面开书后自动退回（2026-11-23）

## 故障与固定基线

用户报告已读书从探索的「继续阅读」能打开，从书架点封面却播放打开动作后退回。基线为 Release `3.0.2（7）`（Tag `legadopro-v3.0.2`，代码 `f9de39b8`），工作区 HEAD `81a7127a` 仅比该 Tag 多发布记录。

采用隔离 `-shelf-test-dir` 和空书源、自建 TXT，真实打开、翻页、退出、再从探索与书架恢复。不运行真实书源、不清除用户书库。原失败命令为 `scripts/xctest.sh` 的 `BookshelfReaderResumeUITests/testReadBookStaysOpenFromShelfListAndExplore`：正文短暂出现后消失，断言「翻页后必须仍在阅读器」失败；层级确实返回书架根，不是只因书名/正文匹配错误。

按该次测试进程过滤日志可见：`startPush accepted` 后约两秒，`coordinator reconcile: reader controller popped externally; resetting state`。现有沉浸式测试在系统 StatusBar 查询处失败，不能当作本故障证据。

## 原因与最小化对照

上次书架搜索修复增加了 SwiftUI 值路由注册；同一栈还由 UIKit 直接推入 `ReaderHostingController`。SwiftUI 的值路径没有这个 UIKit 页面，阅读状态刷新后会把它移除。去掉搜索注册即可使同一个隔离用例完成四次开书/翻页/退出，但那会破坏搜索入口，所以不能作为交付。

保留失败的逐变量对照，不把尝试写成修复：

| 对照 | 实际结果 |
| --- | --- |
| 原基线 | 书架正文短暂出现、自动退回，RED |
| 仅去掉目标闭包的书库环境捕获 | 仍退回 |
| 仅临时移除搜索值路由注册 | 原开书用例通过，但搜索功能缺失，不交付 |
| 注册移到独立修饰器 | 列表/网格两项仍失败，搜索两项通过 |
| 导航外壳与订阅书库内容分离 | 列表/网格仍失败 |
| 仅隔离转场代理的自有回调 | 仍失败 |
| UIKit 与 SwiftUI 明确区分导航所有权 | iPhone 开书/搜索四项通过 |

全部无效尝试已撤回，没有保留新的计时等待、动画时长调整、转场代理改写或禁用搜索。证据目录 `.artifacts/bookshelf-open-x0E8ID/` 含每次 log / xcresult；相关标签为 `resume-red`、`closure-probe`、`registration-probe`、`fixed-ui`、`shell-ui`、`delegate-ui`、`host-ui`。

## 最终实现

- [BookshelfNavigationHost](../../Modules/Features/Bookshelf/BookshelfNavigationHost.swift)：一个原生 UIKit 容器拥有封面阅读器 push/pop；嵌入的原 SwiftUI 栈只管理书架内页和搜索值路径。不是另一套阅读器或播放器。
- [HomeView](../../Modules/Features/Bookshelf/HomeView.swift)：公开入口保留，原书架状态和动作在私有内容 View 中保持原实现；导航 coordinator 由外层保留，不能再由内部 SwiftUI 探针覆盖到值路径栈。
- 原 `ReaderNavigationCoordinator`、`ReaderNavigationTransitionDriver`、`ReaderHostingController` 和动画实现没有最终差异；同一个 reader/进度 owner 不变。
- UIKit hosting 边界转交现有 environment，使书库、主题、语言、AppDependencies 和根 Tab 可见性继续可用。拆卸沿既有 owner-scoped 延后清理，避免更新图时同步发布状态。
- [BookshelfReaderResumeUITests](../../Tests/iOS-UI/BookshelfReaderResumeUITests.swift)：列表/网格两种布局，同一本书从书架、探索及搜索页返回后重复打开；必须实际正文、翻页和关闭，不能以动画中短暂显示算通过。

## 实际验证

环境由 `scripts/sim.sh` 解析：macOS、当前 Xcode、iOS 27.2，scheme `Reader-Fork-Dev`；串行，不创建新的 DerivedData、不 clean。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -l .artifacts/bookshelf-open-x0E8ID/host-ui.log -- \
  -only-testing:'yuedu appUITests/BookshelfReaderResumeUITests' \
  -only-testing:'yuedu appUITests/SearchStreamingSelectionUITests' \
  -resultBundlePath .artifacts/bookshelf-open-x0E8ID/host-ui.xcresult
```

`SearchStreamingSelectionUITests` 配合已有 `scripts/search_selection_fixture.py`；它只运行本地可控双源，正常测试结束后本次服务已停止。

iPhone 最终 `Executed 4 tests, with 0 failures`、`** TEST SUCCEEDED **`、退出 0。覆盖列表/网格各四次开书（含探索继续阅读、搜索入口返回后恢复），以及搜索进行中/暂停结果导航。

另将 `YUEDU_DEST` 设置为 `$(bash scripts/sim.sh dest iPad)`，只执行 `BookshelfReaderResumeUITests`，日志 `ipad-ui.log` / `ipad-ui.xcresult`；iPad 最终 `Executed 2 tests, with 0 failures`、`** TEST SUCCEEDED **`、退出 0，覆盖原模态阅读器的列表/网格开书、探索和搜索入口返回。没有用 iPad 结果冒充 iPhone 封面动画验证。

本轮未新增用户文案，已运行 `ruby scripts/check_localizations.rb`，输出 `Localization OK`；`git diff --check` 无错误。新增容器及书架入口保留 Preview，但没有把 Preview 当行为验证。

## 发布与未验证边界

用户后续授权：修复验收后提交 Push，将有问题的 `3.0.2` Release 改回草稿下架（保留 Tag/历史/附件），升为 `3.0.3（8）` 后用既有工作流构建一次。**不监视 CI**，待用户通知完成再校验新产物和发布；此时不称新版 Release 已完成。

真机、最低 iOS 17、真实在线书/媒体和完整无障碍未由本轮自动测试验收；不能把 TXT/模拟器结果外推为所有格式。回滚只反向撤销本次导航容器及书架挂接和新增用例，不改书库、进度、源配置或签名。恢复旧值路由+UIKit直接推入的同栈结构会重新引入此故障，不能在不了解风险时作为稳定版恢复。
