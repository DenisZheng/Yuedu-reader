# JSON复制导入修正与本地Debug交付

## 修改边界

针对设备日志已复现的书签257／空URL交付，用户授权修改真正书源与RSS JSON入口。独立使用公开UIKit API实现，不复制GPL参考产品代码，不接管所有选择器或目录访问，不新增依赖。

- `Modules/SharedUI/Components/DocumentCopyPicker.swift`：显式`asCopy:true`、单文件导入。原生delegate接管系统副本授权，结果与真实sheet关闭两个事件齐全后仅交付一次；每轮身份隔离，取消与旧回调不能复活结果。记录无路径／内容的选择数量、取消与关闭阶段。
- `Modules/Services/LibraryStore/ImportedDocumentCopy.swift`：不可变、可Sendable的范围持有对象；只平衡成功start，读取期间保留授权，不删除用户文件。共享`DocumentImportReader`使用NSFileCoordinator提供的可读URL及读前／读后大小检查。
- `BookSourceAddFlow.swift`：两个真实文件入口都用相同适配器。文件读与解析移出MainActor同步回调，仍由原`BookSourceStore.parseForImport`生成原确认流程；取消／新请求丢弃旧结果，不自动写库。
- `RSSListView.swift`／`RSSImportReviewSheet.swift`：复制结果等待选择器实际关闭才展示确认页，并持有副本至这轮确认流程退出，仍由原RSSImportSession／RSSImportService加载比较。
- `BookSourceStore.importData`与`RSSImportService.load(.file)`复用协调读取，保留各自大小限制与错误文案。

未修改普通书籍AddBookView／BookFileProtection；未改Bundle ID、profile、全局签名设置、iCloud产品边界或现有用户数据。未commit／push／Actions／安装／重签。

## 实际验证

动态解析Xcode／模拟器，使用Reader-Fork-Dev、当前可用模拟器，串行：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -l .git/json-copy-tests.log -- \
  -only-testing:'yuedu appTests/DocumentCopyImportTests' \
  -only-testing:'yuedu appTests/RSSImportServiceTests' \
  -only-testing:'yuedu appTests/ReviewImportRegressionTests'
```

最终退出0：`Test run with 23 tests in 3 suites passed`、`** TEST SUCCEEDED **`。新增7项覆盖实际原生选择器复制模式、双事件顺序、取消和旧轮、scope生命周期、真实协调文件读取与上限／不存在、书源仅确认不保存及取消、RSS仍走原parser。内部文件测试不冒充重签File Provider行为通过。

首次构建被异步上下文Thread.isMainThread限制阻止，按已有RSS写法使用同步闭包读取诊断值后修正；随后仅扩展名显示的未呈现getter断言失败，系统getter不是文件交付模式合同，移除该非关键断言，实际import模式断言保留并通过。没有绕测试失败或用框架中途通过冒充全部通过。

`ruby scripts/check_localizations.rb`退出0；没有新增用户文案，复用既有本地化键。`git diff --check`收尾检查。测试已提供模拟器编译证据，不另跑模拟器build／clean。

## 本地真机Debug产物

使用既有真机DerivedData与临时开发xcconfig，动态Xcode，配置Debug、generic/platform=iOS、关闭签名；新archive路径`.git/json-copy-debug-ipa.5nozj2vx/LegadoPro-Debug.xcarchive`。本地归档退出0，`** ARCHIVE SUCCEEDED **`。不改全局配置、不新建DerivedData绕错误。

使用`python3 -B scripts/package_unsigned_ipa.py --archive <上述archive> --output <本次新目录>/ipa`，退出0。主App／两个扩展均无签名、profile及签名资源目录；ZIP CRC与复制SHA一致。Mach-O实际SDK27.2、minos17.0，LegadoPro3.0（5）。

下载目录新文件：`LegadoPro-3.0-build5-local-Debug-JSON-copy-import-unsigned.ipa`，未覆盖旧IPA；同目录`.sha256`可核验。

- 字节数：72,013,515
- SHA-256：`59824f6c337e00a9fceeaa80e1c61813806fa4d2961088c3272737ed8b835827`

## 真机验收与回滚

请从这份新未签包用当前同一证书／签名配置签名，先不再同时调整权限或Info选项；按原方式安装，不先卸载或清数据。分别验证书源JSON和RSS JSON：点击选择后选择器退出、出现原确认页、确认后导入成功，取消不产生新数据；若失败保留原界面并采集同一日志窗口。

用户于2026-11-15确认使用上述新Debug IPA自签后“OK了，可以了”，本次JSON文件选择／导入原症状已恢复。此为用户真机反馈，不是助手自动驱动的设备测试；未提供每个入口独立录屏／指标，不扩展为所有源、所有设备或S8完整验收通过。最低iOS17、iPad／VoiceOver及第三方提供器仍保留未验证范围。

回滚代码仅撤回本次选择器／范围持有／协调读改动，回到此前SwiftUI入口；不撤用户其它未提交修改，不删除既有数据、原archive或旧IPA。新副本读取不更改原文件，无数据迁移。
