# 首次手动IPA归档记录

用户手动触发 [run 42378269272](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42378269272)，基于 `37379c37`，Xcode26.6/iOS SDK26.5。

- 工具链预检、17项工作流/打包合同和锁定依赖解析成功。
- Release真机archive失败；IPA打包和上传均跳过，**没有IPA产物**。
- 原始完整错误在失败artifact `reader-fork-build-failure-42378269272-1`，本地归档 `/tmp/readerfork-ipa-failure-42378269272/readerfork-archive.log`。GitHub步骤日志截断在编译中途，不能只读那份截断日志判断原因。

唯一已报告编译错误：

```text
Modules/Services/Works/WorkIndexService.swift:302:30:
error: failed to produce diagnostic for expression
let series = sidecar.flatMap { series(in: $0.values, for: record) }
```

本地最小兼容修正是将闭包调用限定为 `Self.series(...)`，消除与正在初始化的局部变量同名的查找歧义。没有修改算法、Swift语言版本或增加Xcode27要求。现有8项WorkIndexService行为测试已在当前Xcode27.2执行通过（纳入S2回归）；**本机无Xcode26.6，修正后的26.x云归档尚未再次执行，不能宣称问题已验证解决**。

后续：提交进入远端后仍需手动构建检验，再核验IPA及checksum。未自动重跑云构建或发布。本页及S2提交只记录实测结果，不把构建配置预检、模拟器编译或显式限定调用当作完整archive成功。

回滚：仅撤回方法调用的 `Self.` 限定；不触及锁定依赖、身份或签名配置。

## S5 Push后的归档修复

用户批准先Push S5、按需触发手动云归档，再处理前置并进入S6。远端main已更新为 `a60f9d45`，包括前述 `Self.series` 修正。

[run 42455851293](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42455851293) 使用Xcode26.6(17F113)、Swift6.3.3、iPhoneOS SDK26.5。17项工作流/打包合同和依赖解析通过；archive仍失败，没有IPA。原WorkIndexService诊断不再出现，完整artifact中的当前唯一编译错误为：

```text
ReaderViewportFragmentHost.swift:232:83:
error: sending 'prepare' risks causing data races
note: task-isolated 'prepare' is captured by a main actor-isolated closure
```

`update`及其Entry/UI状态均在MainActor；`place`把prepare延后到同次update的候选队列，但参数函数类型没有保留该隔离。最小修正为 `prepare: @escaping @MainActor (Entry) -> Void`，不添加Task/队列，不移动绘制工作，不降低Swift6并发检查。Xcode27.2上的最小示例不能复现旧编译器诊断，因此只能把实际26.6 archive作为最终修复反馈，不能用本机编译冒充。

- 完整失败日志/xcresult：`/tmp/readerfork-ipa-42455851293/failure/`。
- 本机正常Dev宿主的CoreText/Browser viewport回归：`/tmp/readerfork-ipa-fragment-isolation.xcresult`，23项/2 suites通过，覆盖提前绘制、预算/复用、像素及绘制不在主线程。
- 修正版仍需下一轮云归档、IPA结构和checksum验证；本小节不把#35标为完成。

该修正回滚只涉及回调actor标注及说明，不改变签名、最低系统、包版本或App数据。

### Swift6.3.3 IRGen崩溃

前述修正已提交并Push为 `79b170a5`。后续 [run 42456748792](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42456748792) 不再出现prepare隔离诊断，但Swift6.3.3在Release IR生成时崩溃。完整证据在 `/tmp/readerfork-ipa-42456748792/failure/`：

```text
While emitting IR SIL function "@$sSdScA_pSgIeAghyg_SdIeAghn_TR"
SyncCallEmission::setArgs
llvm::SmallVectorBase<unsigned int>::grow_pod
```

`swift-demangle`说明该符号是Double参数、isolated(any)/Sendable函数从直接参数到泛型间接参数的reabstraction thunk。仓库唯一直接透传getter/setter的 `Binding(get: get, set: set)` 位于ChapterTitleInspectorView.doubleBinding。最小示例对比显示：直接透传会产生这一类isolated(any)转换thunk，而 `Binding(get: { get() }, set: { value in set(value) })` 不产生它。保留原来的MainActor/Sendable合同和同步调用，不添加actor跳转或不安全隔离豁免。

- 原生字号UISlider的valueChanged事件验证Double绑定的读取、更新及恢复：与标题字重AX、模型回归一起9项/2 suites通过，`/tmp/readerfork-ipa-binding-native.xcresult`。
- 首版新增测试用NSObject默认accessibilityIncrement未发原生控件事件而失败，修正为实际UISlider值和valueChanged；没有修改生产交互来迁就测试。该项不冒充VoiceOver手势回归。
- 这是针对明确IRGen转换的最小代码修正；本机工具链不能复现Swift6.3.3崩溃，不能仅以SIL对比或9项测试关闭#35。修正已提交并Push为 `f25a18af`，随后完成下列真实云验收。

## 最终云归档与产物验收通过

[run 42460767989](https://github.com/DenisZheng/Yuedu-reader/actions/runs/42460767989)，head=`f25a18af03dc51fd258924078e13496ccff3dd16`：Xcode26.6(17F113)、Swift6.3.3、iPhoneOS SDK26.5，最终 **success**。依赖解析、17项工作流/打包合同、Release真机archive、IPA打包/checksum、artifact上传全部成功；没有关闭并发检查、修改优化级别/Swift版本、更换DerivedData或升级云端Xcode。

下载artifact `reader-fork-dev-unsigned-ipa-42460767989-1`（ID `13610428055`），到 `/tmp/readerfork-ipa-42460767989/ipa/`，执行并通过：

- `shasum -a 256 -c Reader-Fork-Dev-unsigned.ipa.sha256`。
- ZIP全包CRC、Payload唯一App、可执行权限、主App及两个扩展的iPhoneOS平台与Fork Bundle ID。扩展使用项目既有 `.widget` / `.shareextension`，不是临时检查脚本最初误写的 `.share`。
- Mach-O `LC_BUILD_VERSION`：`platform IOS`、`minos 17.0`、`sdk 26.5`；`codesign -dv`确认未签名，无embedded provisioning profile。

IPA大小 **35,348,658字节**，SHA-256：

```text
08befc70818be381c83ec3d266eda31916ed14e3f9c55e2b7b16489749292dc4
```

#35至此按真实失败路径修复并验证完成。产物按工作流保留14天，未上传Release/TestFlight，不把大二进制加入源码提交。它仍是需要用户自行签名的IPA，不能证明真机安装、iCloud/App Group授权、最低系统实际运行或RSS媒体行为通过。

修复记录归档后按用户顺序继续#36音频时钟前置，通过后自动进入S6；不把归档成功代替媒体门槛。
