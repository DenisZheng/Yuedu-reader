# RSS JavaScriptCore 地址截断诊断与验证

## 结论

**阻碍已定位，当前官方 runtime 上的 S4 补充验收通过。** 这不是 RSS 文章对象越界或取消后复用 JSContext 的修复：LLDB 证实本机 iOS 26.2 系统 JavaScriptCore 在解开 rope 字符串时，用36位掩码截断了有效高地址。

经用户明确批准，通过 Xcode 下载并新增官方 iOS27.2 runtime，保留26.2设备和数据。在未修改生产JS引擎、源脚本、最低iOS17、ASan或安全设置的条件下，正常 `Reader-Fork-Dev` 的 iPhone/iPad **各238项、35 suites、0失败、0跳过**通过，包含原始同源取消/重建100次、最小平台重现和真实前台持久化。

**没有修补旧26.2系统二进制，也没有证明26.2真机不受影响。** 旧runtime的失败证据继续保留；最低系统和真机兼容仍是S8发布门槛。

## 独立的应用缺陷：前台漏传owner

1. `RSSFeedView.refresh` 未向 `RSSFetcher` 传 `owner`，因此前台请求无法读取或持久化 `RSSStore` 的源变量。
2. 新增 `RSSForegroundRuntimeTests.foregroundUsesPersistentOwner`，走真实 View `.task` → loopback HTTP →规则→store。旧代码出现3个断言失败：标题为空、变量未存入、重建store后仍缺变量。证据：`/tmp/readerfork-s4-foreground-owner-red.xcresult`。
3. 补入 `owner: store` 后该用例通过。扩大门槛时另暴露了下面的平台崩溃；这两件事不能混为一个原因。

## 复现与最小化

原崩溃：`RSSRuntimeIntegrationTests.cancellationAndQueuedArticle()`；第一篇被取消，第二篇重新绑定后执行 `rssArticle.title + '|' + java.get('marker')`，在转回Swift String时崩溃。扩大运行 `/tmp/readerfork-s4-foreground-iphone/tests.xcresult` 为234项、233通过、1崩溃、0跳过。

去掉RSS网络、取消、RuleData和共享解析器后，正常App宿主仍可用公开JavaScriptCore API重现：

```swift
var previous: JSContext? = JSContext()
_ = previous?.evaluateScript("'prior'")
let current = JSContext()!
previous = nil
current.setObject(["title": "B"], forKeyedSubscript: "rssArticle" as NSString)
current.setObject("B", forKeyedSubscript: "marker" as NSString)
let text = current.evaluateScript("rssArticle.title+'|'+marker")?.toString()
```

对应测试：`RSSArticleScriptObjectTests.nativeContextReplacement()`，循环100次。原生API仅用于平台诊断；生产仍使用 `RSSRuntime` / `JSCoreEngine`。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/RSSArticleScriptObjectTests' \
  -only-testing:'yuedu appTests/RSSRuntimeIntegrationTests/cancellationAndQueuedArticle()' \
  -only-testing:'yuedu appTests/RSSForegroundRuntimeTests'
```

设备和工具链动态解析；如复核旧26.2，须从 `simctl list devices --json` 选择其现有UDID传给 `YUEDU_DEST`，不能误把新runtime结果写成旧环境通过。

## 决定性证据

正常App宿主的LLDB记录：`/tmp/readerfork-s4-lldb-registers.txt`，对应 `/tmp/readerfork-s4-native-lldb-registers.xcresult`。调试时仅暂停/附加读取栈、寄存器、内存和反汇编，没有修改指令或寄存器来使测试通过。

- 系统框架：JavaScriptCore `8623.1.14.10.9`，iOS26.2（23C54）。
- 原生API的栈：`JSRopeString::resolveToBuffer` → `resolveRope` → `JSValueToStringCopy` → `-[JSValue toString]`。
- 保存的packed fiber：`x9 = 0x856000702a048900`；对应有效指针为 `0x702a048900`。
- 系统反汇编使用 `and x26, x9, #0xfffffffff`，只有36位。
- 解码后 `x25/x26 = 0x2a048900`；随后 `ldr x8, [x25, #0x8]` 在 `0x2a048908` 报 `EXC_BAD_ACCESS`。
- 周围实际JSString对象位于 `0x702a048560` 等高地址，失去的高位与掩码精确对应，不是仅凭相似崩溃栈猜测。

上游依据：

- [WebKit 06d5550：Disable use of HAVE(36BIT_ADDRESS)](https://github.com/WebKit/WebKit/commit/06d5550e6d760d556d785bbdb21f3c2a49b8f68b)，2025-12-12，说明内核不能保证始终返回36位地址，移除这一假设。
- [JSString.h](https://github.com/WebKit/WebKit/blob/01e972896a4d668c0834abbf7c69a63024df2b25/Source/JavaScriptCore/runtime/JSString.h) 的 `CompactFibers.addressMask` / `fiber1()` 展示同一掩码解码方式。

上游提交支持根因判断，不据此推断所有Apple发行版包含哪个commit；新runtime是否可用以实际执行为准。

## 区分实验与误导性线索

| 输入/环境 | 实际结果 |
| --- | --- |
| 原同源取消/重建，正常Dev宿主 | 可重复崩溃；提高到同进程100次后稳定重现 |
| 两个裸JSContext，原生Dictionary/String输入 | 崩溃，`/tmp/readerfork-s4-native-jsc-dictionary.xcresult` |
| 显式NSString、显式JSVirtualMachine | 仍崩溃，不是换一层Swift桥即可解决 |
| 只返回一个字段、不拼接；全部JS字面量 | 通过；没有据此改源脚本绕过rope路径 |
| PoC宿主、独立模拟器CLI、ASan | 通过；这些会改变初始化/分配条件，不是修复证据 |
| 在PoC里单独初始化App、AppDelegate、CookieMirror、WKWebView/BrowserState、类查找hook | 均通过；未定位到某个App初始化组件造成内存破坏 |
| 根View逐段减少内容/修饰器 | 结果受构造和分配条件影响，不能把移除UI当作修复；所有探针已撤回 |
| 关闭ASan再用完整正常App | 仍失败，`/tmp/readerfork-s4-native-default-final.xcresult`、`/tmp/readerfork-s4-resume-native-red.xcresult` |

早期“上下文生命周期”命名保留为诊断文件路径；最终判断是系统地址解码问题，不再宣称JSContext回收本身有错误。

## 环境修复与最终门槛

用户批准后执行Apple公开命令：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
xcodebuild -downloadPlatform iOS -architectureVariant arm64
```

日志 `/tmp/readerfork-ios-runtime-download.log`。Xcode27.2自动安装iOS27.2通用设备runtime（24B8117）和专用设备变体（24B91016s），每份约8.32GB；本次验收使用24B8117。没有删除旧runtime、模拟器、App数据或DerivedData。

| 证据 | 结果 |
| --- | --- |
| `/tmp/readerfork-s4-jsc-new-runtime.xcresult` | 正常Dev宿主，6项/3 suites通过，包含4种字符串上下文、取消100次、前台owner |
| `/tmp/readerfork-s4-runtime-repair-iphone/tests.xcresult` | iPhone18 Pro Max / iOS27.2：238项、35 suites、0失败/跳过 |
| `/tmp/readerfork-s4-runtime-repair-ipad/tests.xcresult` | 新iPad首次运行236通过、2个WebKit用例超时；没有隐藏该失败 |
| `/tmp/readerfork-s4-ipad-browser-visible.xcresult` | 对新iPad执行`simctl bootstatus <动态UDID> -b`等待系统启动就绪后，原4项浏览器测试通过；没有修改测试/延长超时 |
| `/tmp/readerfork-s4-runtime-repair-ipad-ready/tests.xcresult` | 相同iPad Pro13-inch(M5) / iOS27.2：完整238项、35 suites、0失败/跳过 |

完整命令为 `YUEDU_EVIDENCE_DIR=<目录> bash scripts/validate_reader_fork_s4.sh`；iPad通过 `YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"` 选择。脚本包含两个新增suite，检查每个选择实际执行和最终零失败/跳过。新iPad首次WebKit超时的具体系统原因未进一步定性；后续专项及全量通过，不假称修复了浏览器生产代码。

## 保留的边界与回滚

- 仅增加一处前台owner参数、回归测试和门槛/证据文档；没有生产JSC绕过代码，也不通过关闭JIT/Gigacage/安全检查改变执行语义。
- 旧26.2模拟器组合仍是已知失败环境。最低iOS17、26.2真机和发布签名不因27.2模拟器通过而自动放行。
- 回滚前台参数修正会重新引入变量丢失；新runtime可并存，复核旧环境显式选择其UDID即可，无须删除新旧数据。
- 原有编译偶发停顿、媒体时钟和QoS警告各有独立门槛，不能由本次JSC结果推断已解决。
