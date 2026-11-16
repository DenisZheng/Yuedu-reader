# 书源网页横竖视频返回修复（2026-11-16）

## 结果与范围纠正

用户指出竖屏视频返回后仍会反复弹出，并确认入口为**书源网页**，通过**右划或导航返回**离开播放页。上一轮 `32d372a6` 只用横向 MP4 验证 `ReaderView` 内嵌网页的暂时全屏覆盖；没有覆盖竖向素材，也没有覆盖本次 `JsBridgeBrowserView` 的真正退出路径。之前的通过不能外推为所有书源视频返回均正常。

本次固定输入实际复现：书源浏览器的 SwiftUI 内容拆除后，同一个旧 WKWebView 仍可播放并保持 / 进入系统全屏。已修复浏览器的媒体拆除；iPhone / iPad Simulator 最终各 **10 项通过**（XCTest 4 项 + Swift Testing 6 项）。不修改视频方向选择、源包、HTML/JS 的正常执行、登录数据、播放器依赖或网络权限。

## 复现与原因

`JsBridgeBrowserRepresentable.dismantleUIView` 原来只移除脚本消息 / 剪贴板桥，没有暂停并禁止旧页面恢复媒体、关闭 WebKit 系统媒体展示、停止加载或销毁原文档。

用既有自建 `video-still-portrait.mp4` 在真实 WKWebView 中播放，检查解码尺寸高度大于宽度、播放时钟超过 0.05 秒；通过实际导航 pop 与移除 SwiftUI 内容触发**生产 dismantle 方法**。随后模拟晚到的媒体回调，对仍存在的旧视频调用 `play()` / `webkitEnterFullscreen()`。

修复前日志 `browser-return-red-behavior.log` / `fullscreen-and-navigation-red.log`：

```text
SOURCE_BROWSER_VIDEO_RETURN retry=attempted state=1 fullscreen=true
XCTAssertTrue failed - 已返回的源网页必须无法恢复媒体播放
XCTAssertEqual failed ... - 关闭的源网页不能再次弹出系统视频全屏
** TEST FAILED **
```

`state=1` 是 `WKMediaPlaybackState.playing`。这个结果证明旧页面没有被正确终止；单个 `fullscreen=true` 不能区分原全屏尚未关闭与新全屏进入，因此不把它单独当成精确的重复进入次数证据。

最小复现保持同一个 WKWebView、不执行实际源脚本，也没有 SourceBrowserPresenter 请求队列：排除了“方向变化重新加载网页”和“多个源请求排队”作为这条复现的必要条件。没有按画面方向猜测或修改旋转逻辑。

## 最小共享修复

只改 `Modules/Features/BookSource/JsBridgeBrowserView.swift` 的真正拆除分支：

1. `setAllMediaPlaybackSuspended(true)`：不只是暂停当前播放，旧页面的用户 / 脚本不能自行恢复媒体。
2. 停止加载、解绑 navigation / UI delegate、注销 KVO、清空旧 bridge 的 reload / cookie-confirm 回调，防止已经关闭的 UI 再驱动旧页面。
3. 在 `.defaultClient` 隔离 world 中清空原 DOM 和事件监听，再调用 `closeAllMediaPresentations`，最后加载空文档。不让页面 world 覆盖清理逻辑；仅处理已经关闭的文档。
4. 文档清理失败仅记录 SDK error domain / code，并继续必要的系统媒体关闭 / 空文档清理；不输出异常正文、URL、Cookie 或 headers，也不把失败标成源解析成功。

不在 `onDisappear` 做这个清理：视频全屏暂时覆盖仍打开的浏览器时，原网页必须保留并能继续播放。没有统一去掉有效源网页的脚本 / iframe，也没有清除网站存储、登录 Cookie 或用户数据。

Apple 合同经 Context7 和官方文档核查：

- [setAllMediaPlaybackSuspended](https://developer.apple.com/documentation/webkit/wkwebview/setallmediaplaybacksuspended(_:completionhandler:))：true 时网页或用户不能自行恢复播放；`pauseAllMediaPlayback` 只暂停。
- [closeAllMediaPresentations](https://developer.apple.com/documentation/webkit/wkwebview/closeallmediapresentations(completionhandler:))：关闭系统全屏 / PiP 展示，完成回调在关闭完成后运行。本次实际测试全屏，没有实际进入 PiP。
- [视频全屏事件](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/Using_HTML5_Audio_Video/ControllingMediaWithJavaScript/ControllingMediaWithJavaScript.html)：`webkitbeginfullscreen` / `webkitendfullscreen` 是 iOS 视频全屏事件，进入需要媒体能力和用户动作条件。测试使用公开 DOM API，不修改权限或私有属性。

接口支持最低声明 iOS17；本次没有 iOS17 runtime 验证。

## 实际验证

环境由 `scripts/sim.sh xcode` / `dest` 动态解析：Xcode / Simulator SDK27.2，iPhone 18 Pro Max、iPad Pro 13-inch (M5)，均为 iOS27.2。使用既有 `Reader-Fork-RSS-PoC` / DerivedData 串行测试，不重复 build / clean。

测试服务器只监听 127.0.0.1、临时端口和有限请求，使用已提交自建 MP4。新浏览器测试使用 `.nonPersistent()` 网站存储，避免读取 / 同步个人 Cookie；测试窗口将拆除委托给生产 representable。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-RSS-PoC bash scripts/xctest.sh \
  -l .artifacts/portrait-source-video/iphone-verified-final.log -- \
  -only-testing:'yuedu appTests/SourceBrowserVideoReturnTests' \
  -only-testing:'yuedu appTests/ReaderVideoPresentationTests' \
  -only-testing:'yuedu appTests/SourceBrowserJavaBridgeTests' \
  -only-testing:'yuedu appTests/SourceBrowserAuthenticationTests/authenticatedFirstLoad()' \
  -only-testing:'yuedu appTests/SourceBrowserAuthenticationTests/currentCredentialsAndIsolation()'
```

iPad 同一选择，只将 destination 改为 `$(bash scripts/sim.sh dest iPad)`，日志为 `ipad-verified-final.log`。

| 覆盖 | iPhone | iPad | 证据性质 |
| --- | --- | --- | --- |
| 源浏览器横向 / 竖向视频关闭 | 2 项通过 | 2 项通过 | 实际视频时钟、尺寸、真实 WebKit 系统全屏进入 / 关闭完成、导航拆除后晚到媒体回调不能恢复全屏 |
| ReaderView 横向 / 竖向视频暂时覆盖 | 2 项通过 | 2 项通过 | 实际媒体播放；普通全屏 UIKit 覆盖验证网页实例不重建，真正移除仍释放；不是系统播放器手势测试 |
| 同步网页 Java 桥 | 4 项通过 | 4 项通过 | 原同步请求 / 绘制 / 配置合同，不修改源脚本以通过 |
| 合成认证与初始请求 | 2 项通过 | 2 项通过 | 当前认证传播 / 隔离、确切初始请求；没有运行需要外部 key 的 live 测试 |

两端最终决定性输出：

```text
Executed 4 tests, with 0 failures
Test run with 6 tests in 2 suites passed
** TEST SUCCEEDED **
```

横向最终 `retry=removed state=0 fullscreen=false`；竖向最终 `retry=removed state=3 fullscreen=false`。`state=0` 为 none、`3` 为 suspended：两种状态都不可恢复播放，旧视频节点已移除，不能再次全屏。

### 过程中未通过的验证

- 初次日志父目录不存在；创建本次诊断目录后使用同一 wrapper，没有测试结果前不记通过。
- 新测试首次编译发现缺少 Combine import、async 调用放在 XCTest autoclosure 中；修正测试编译后才取得上述行为失败。
- 初轮 iPad `ipad-final.log` 的两项源浏览器初始全屏断言失败：iPad 的 play 默认仍内联。没有删除断言，改为显式请求公开 `webkitEnterFullscreen` 并等待真正 `webkitbeginfullscreen`，不靠 sleep 等状态。
- 随后的 iPad `ipad-fullscreen-event-final.log` 仍有竖向 `state=3 fullscreen=true`。媒体已经被禁止恢复，但系统展示是异步关闭；这不是整套通过，也不能只凭该 flag 断言新全屏已经重开。收尾改为先清空旧 DOM / 回调再关闭系统展示；测试子类只**观察生产 close API 的真正完成回调**，不自己再关一次来掩盖问题。
- 回调版 `callAsyncJavaScript` 的参数 label 与 async 版不同。编译报 extra trailing closure 后，读取本机 `WebKit.swiftinterface` 确认：回调版是 `in frame`、`in contentWorld`，async 版才是 `contentWorld`；按实际 SDK 合同修正，没有改语言模式或构建设置。

`ruby scripts/check_localizations.rb` 本会话实际输出 `Localization OK: Resources/*.lproj/Localizable.strings (5 files, 4267 keys)`，权限 / 扩展资源检查也通过。本次没有修改用户文案或布局。`git diff --check` 无输出、退出0。

收尾七个候选文件的 UTF-8 / LF、Markdown 代码块 / 相对链接、原始源包哈希与最终测试日志核查输出 `PORTRAIT_VIDEO_FORMAT_AND_EVIDENCE_OK files=7 testsPerDevice=10 sourcePackUnchanged=true`；`git diff --check` 无输出、退出0。源包、日志和其他既有未跟踪文件不加入提交。

## 未验证与回滚

- 未取得具体源名 / 用户录屏；没有执行真实书源或个人账号、具体章节、广告 / DRM / 直播源，不宣称所有网站都能播放。
- 用真实媒体与导航 pop / SwiftUI 拆除验证返回，不是实际右划的 XCUITest，也没有人工视觉 / VoiceOver 验收。
- 未验证独立 type=4 `VideoPlayerView` 的全部退出路径、真机、iOS17、PiP、Release / IPA 或签名安装。
- 不推送、不触发或监控 Actions，不重装手机、不删除源或用户数据。`.artifacts/portrait-source-video/` 的日志仅保留本地，不提交。

回滚由操作员仅对本次提交执行 `git revert`，撤回浏览器拆除改动、两个测试和本次文档；不撤回已完成的漫画修复或上一轮长图修复，不做整库 reset / 清缓存。
