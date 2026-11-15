# 书源视频退出循环与漫画长图修复（2026-11-16）

## 结果与范围

按用户授权分析、修复并本地提交两个问题，不自动 push、安装手机或发布。修复前建立失败回归，修复后 iPhone / iPad Simulator 各 **15 项通过**（XCTest 1 项 + Swift Testing 14 项）。没有更改用户源包、持久化格式、默认阅读模式、签名或依赖。

视频复现针对 `ReaderView` 的源生成网页 / 内嵌媒体分支：全屏播放覆盖阅读器，退出后网页被重新创建，导致 `autoplay` 再次执行。独立 type=4 的 `VideoPlayerView` 路径没有改动，也没有把本次结果外推为所有视频源或真实网站均可播放。

## 固定 Android 参考

基准 `../legado` 的 HEAD 实查为 `330e606c4d57e08adc056ff8ab7a4132c784da9a`，没有修改或更新该仓库。

- `app/src/main/java/io/legado/app/ui/video/VideoPlayerActivity.kt`：`onStop` 与 `onDestroy` 分开；销毁时释放网页、停止加载、保存进度并释放播放器。iOS 对应使用既有 `ReaderTeardownProbe.dismantleUIView` 作为真正离开阅读器的信号，而不是把被全屏播放器覆盖的 `onDisappear` 当成销毁。
- `app/src/main/java/io/legado/app/ui/book/manga/recyclerview/MangaVH.kt`：纵向阅读加载成功后按内容高度布局，图片沿阅读宽度呈现；横向仍使用 `FIT_CENTER`。iOS 复用现有跨页 `UIScrollView`，对长图扩展高度并保留缩放，不另建漫画加载器。
- **明确差异**：Android 横向模式本身仍会整页缩小；本 Fork 的“高宽比达到 3:1 自动按宽度展示并允许纵向滚动”是针对用户此次问题的补充适配，不声称 Android 已有相同自动阈值。

Apple 的 [allowsInlineMediaPlayback 合同](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/allowsinlinemediaplayback) 经 Context7 查询：iPhone 的 HTML 视频除配置外还依赖 `playsinline`；[视频播放说明](https://developer.apple.com/documentation/webkit/delivering-video-content-for-safari)指出退出全屏后同一视频元素可以继续内联播放。本次不改源 HTML / JS 或强制关闭自动播放，只避免错误地销毁并重建同一元素。

## 复现与根因

### 视频

按优先级核查了三个方向：阅读器错误销毁网页、选集关闭回调重复发起播放、源脚本额外打开全局播放器。第一个方向在生产 `ReaderView` 的实际 UIKit 全屏覆盖 / 退出调用链复现；后两个方向未建立本次缺陷的证据，没有做猜测性改动。

原实现的 `onDisappear` 无条件调用 `EPUBVideoPlaybackManager.stopAll()` 和 `ReaderWebEmbedManager.stopAll()`。全屏播放也触发该回调，因此源网页及其 JS 被清空。返回时源生成页属于无需再次点按的内容，被重新加载，再次执行 `autoplay`。

修复将这两个媒体释放调用移到既有真实拆除信号 `ReaderTeardownProbe`：暂时覆盖复用同一媒体实例，真正退出仍释放资源。

### 长图

用 400 × 4000 的合成图缩小变量：直接放入生产 Nuke 缓存后，翻页布局把它适配成 80 × 800，跨页容器仍只有一屏高。无需网络或图片解码就能复现，根因是整页 `min(widthScale, heightScale)` 布局，不是下载或解码改变了图片比例。

修复：

- 高宽比 ≥ 3:1 的图片 / 漫画归档页按页宽等比展示，顶端对齐；普通页、PDF、固定版面 EPUB 保持整页适配。
- 跨页容器高度扩展到长图高度；普通页使用独立的真实视口尺寸，不跟随长图高度放大。双页邻页的加载与重试控件也按真实视口定位。
- 关闭 pinch / double tap 不关闭长图的普通滚动。
- 翻回长图保留 1x 的滚动位置；缓存命中、异步新图加载与放大走同一布局路径。
- 不把页码替换成长图分段身份，不改存储或每本书的阅读模式。

## 实际验证

环境：本机动态解析的 Xcode / iOS Simulator SDK 27.2；iPhone 18 Pro Max、iPad Pro 13-inch (M5)，均为 iOS 27.2 Simulator。当前编译日志的 Swift language mode 为 6，没有修改任何语言 / 并发构建设置。

```bash
bash scripts/sim.sh doctor
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-RSS-PoC bash scripts/xctest.sh \
  -l .artifacts/media-reader-fixes/iphone-final-15.log -- \
  -only-testing:'yuedu appTests/ReaderVideoPresentationTests' \
  -only-testing:'yuedu appTests/FixedPageLongImageTests' \
  -only-testing:'yuedu appTests/FixedPagePageLayoutTests' \
  -only-testing:'yuedu appTests/FixedPageZoomableScrollViewTests' \
  -only-testing:'yuedu appTests/FixedPagePageCachedImageTests'
```

iPad 同一命令仅将 destination 改为 `$(bash scripts/sim.sh dest iPad)`，日志改为 `.artifacts/media-reader-fixes/ipad-final-15.log`。测试串行执行，测试构建同时提供 App 编译证据，没有额外 build / clean 或替换 DerivedData。

| 执行 | 决定性结果 |
| --- | --- |
| 修复前 `.artifacts/media-reader-fixes/red.log` | XCTest 1 项 / 3 失败：`暂时覆盖不应销毁源播放器页面`、`返回必须复用同一网页`；长图 4 项 / 6 issues；`** TEST FAILED **` |
| iPhone 最终 | `Executed 1 test, with 0 failures`；`Test run with 14 tests in 4 suites passed`；`** TEST SUCCEEDED **` |
| iPad 最终 | `Executed 1 test, with 0 failures`；`Test run with 14 tests in 4 suites passed`；`** TEST SUCCEEDED **` |
| 本地化与文件检查 | `ruby scripts/check_localizations.rb`：五种语言 4267 个 Localizable 键通过；新增文件 UTF-8 / LF 与文档链接检查通过；`git diff --check` / `git diff --cached --check` 无输出、退出 0 |

最终视频测试使用只监听本机、临时端口的既有 `VideoStillFixtureServer` 和自建 MP4，断言真实 `currentTime` 推进、同一网页身份 / JS 实例不变，以及真正拆除后的资源释放；不是只有 HTML 标签或页面存在检查。测试没有读取个人账号或执行原始源脚本。

长图测试断言真实页面宽高、滚动到底部、1x 位置恢复、关闭缩放仍可滚动、未缓存图加载后高度和 2x 放大尺寸；既有普通页居中、双页书脊与缩放 / 缓存回归一并通过。

### 过程中未通过的验证

首轮修复后命令超时，日志停在 `SwiftEmitModule`，没有测试结果；没有将它记为通过。检查进程和日志后在同一 scheme / DerivedData 重跑完成编译。

第一次重跑的行为测试保住了网页，但测试仍持有旧 `UIHostingController`，只替换 window 的 root 并不会拆除 SwiftUI 内容，退出检查超时。已修正测试宿主：WKWebView 放在公共 UIKit 容器，真正退出明确移除 SwiftUI 内容并等待 dismantle 回调。没有延长断言超时或移除释放断言，最终两个设备均通过。

收尾审查发现长图撑高双页容器后，邻页的 spinner / 重试可能移到屏幕外。新增测试在 iPad 先以 2 个中心位置断言失败（`.artifacts/media-reader-fixes/paired-controls-red.log`），再将两种控件按真实视口中心定位；最终双端各 15 项通过，包含该错误状态回归。

## 未验证与回滚

- 没有用户具体源名 / 章节地址或录屏，本次使用自建输入锁定上述复现路径；未运行私有源脚本或真实网站播放。
- 未执行实际右划手势、长图拖动的 XCUITest、人工 VoiceOver 或视觉验收；自动测试覆盖的是全屏退出生命周期与真实 UIKit 滚动布局。
- 未验证 iOS 17 runtime、真机音画、签名安装或 Release。真机脚本依赖 `READER_FORK_TEAM` / `READER_FORK_DEVICE`，当前未设置，不自动推断团队或改手机数据。
- 长图只按原比例显示，不新增切片解码 / 缓存；极端大图的内存上限没有另做性能承诺。
- 本地 `.artifacts/media-reader-fixes/` 保留复现与构建证据，不加入提交。原始源包及既有未跟踪文件保持不动。

回滚仅撤回本次四个生产文件和两个新增测试、本文及验证索引的改动；无数据迁移，不需要删除书籍、清缓存或擦除模拟器。提交后由操作员执行针对该提交的 `git revert`，不使用整库 reset。
