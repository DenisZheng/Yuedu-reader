# 订阅 Tab 导出 Legado JSON：入口对照记录

## 用户反馈与结论

用户最初报告订阅Tab根页的JSON导出黑屏；双入口模拟器测试未复现，而且用户随后自行复测反馈已无问题。按用户确认，此项关闭，不再作为当前S8阻塞；本轮没有生产导出代码修正。代码复核发现两个入口复用 `RSSListView`、同一个 `RSSStore`、`RSSJSONDocument` 与 `.fileExporter`。

## 已执行的行为对照

新增 `Tests/iOS-UI/RSSExportPresentationUITests.swift`，用 `-seed-rss-articles` 固定的本地合成源分别从两入口操作系统文件保存界面，不联网、不读用户私有源包。

- iPhone 18 Pro Max / iOS 27.2：2 项通过，0 失败/跳过；xcresult：`/tmp/readerfork-rss-export-check27.B8YfPx/tests.xcresult`。
- iPhone 17 Pro Max / iOS 26.2：2 项通过，0 失败/跳过；xcresult：`/tmp/readerfork-rss-export-check26.HMeVud/tests.xcresult`。
- iPad Pro 13-inch (M5) / iOS 27.2：2 项通过，0 失败/跳过；xcresult：`/tmp/readerfork-rss-export-ipad.DuVeFk/tests.xcresult`。
- 两个平台的两条路由均出现系统 Save 控件。Tab 根页自动化继续触发保存；iOS 26.2 iPhone 与 iOS 27.2 iPhone/iPad导出件可读、330 B、合法 JSON 数组、包含1条合成测试源。摘要 `b24591800c1fa15b0b7d36aba4b18b5001a9deeb1349e23dc52e3d0010831a61`。
- 一次旧测试在 File Provider 首次打开期间短时看到空白界面，随后无障碍树出现 Save 控件；早期 12 秒断言不足以区分首次初始化与永久黑屏。当前回归等待系统 Save 控件，冷加载后两系统全绿。
- iOS 26.2 的 UI 自动化对 Save 按钮出现 legacy/modern AX 类型不一致；测试改用该系统控件的可见坐标完成点按。重复测试遇到既有同名测试文件时，只处理系统“替换”确认。以上是测试工具和系统文件面板现象，不是应用导出失败证据。

## 用户复测状态

用户随后自行复测 RSS JSON 导出反馈现已正常，并要求将此问题移出当前开发序列；该事项已关闭，不再是S8阻塞。模拟器两入口自动化和文件写出证据仍保留于本记录。生产导出代码没有改动。

## 回滚

本轮只新增 UI 自动化测试与诊断记录，无生产导出行为变更。删除 `RSSExportPresentationUITests.swift` 与本记录可回滚新增覆盖。模拟器 Files / File Provider中的合成文件未清理，未复制进仓库。

---

复测命令（目标由现有脚本动态解析）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" YUEDU_SCHEME=Reader-Fork-Dev \
  bash scripts/xctest.sh -- -only-testing:'yuedu appUITests/RSSExportPresentationUITests'
```
