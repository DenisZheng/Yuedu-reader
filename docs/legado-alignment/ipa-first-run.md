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
