# 上游精选修复与排版依赖验收（2026-11-28）

从 Fork `4cd00126` 建立 `integration/upstream-8ed900e8`，与 [Yuedu iOS 上游 `8ed900e8`](https://github.com/CHANG-JUI-LIN/Yuedu-reader/commit/8ed900e89f375e27e3aba0d30b5bc2a353f256b0) 对照。先做两批修复，再升排版库。没有整包合并上游，没有带入账号、付费、iCloud、权限、版本号或 RSS 背景迁移；不含主工作区另有的书架白边补丁。移植来源为 CHANG-JUI-LIN 的 MPL-2.0 上游，见下表；没有复制 Android 源码、实源脚本或新增第三方媒体素材。

| 阶段 | 范围与来源 | 从失败到通过 |
| --- | --- | --- |
| 第一批 `398ec327` | `db57c94f` 在同一把锁内读写脚本等待时间；`e2329e01` 只取「写新 JS 上下文」的修复；`0eb6e985` 替换 UIKit 持有的旧占位邻页；`c12ad0fb`、`c63c0a05` 区分估算页与真正的 EPUB 续读目标，并先登记续读意图。 | `batch1-clock-red` 的并发用例使测试 App 崩溃；`batch1-red` 有 4 项、3 项失败：超时拖到旧脚本结束、邻页未更换、占位页提前交付续读。`batch1-green` **44 通过、0 失败／跳过**。 |
| 第二批 `ffd59236` | `d25d7468` 书源验活不再按时间重写整库：正常结束、停止或进入后台时保存已完成结果；不改 RSS 验活。`b2637832` 在共用原生播放器上把 HLS 限为 2×、保留 MP4 的 3×，显示可用倍速。 | `batch2-red` 的 33 秒自建验活有两次整库更新；HLS 长按与手动选择仍下发 3×。`batch2-green-final` 只更新一次且重新打开仍有结果；停止只保存完成项，播放实测速率 HLS 2×、MP4 3×，RSS 凭据撤销、签名重取、播放进度及回前台不自动续播均有回归。**16 通过、0 失败／跳过**。最终倍速用例使用隔离 RSSStore，不写标准视频链接历史。 |
| `YueduCoreText` 升级 | `0.18.1` → [`0.30.1`，`e23db269`](https://github.com/CHANG-JUI-LIN/YueduCoreText/commit/e23db26946f11f4d6b103dea46733b8717de5377)。只改这一项依赖；保留原 minor 版本约束、iOS 17 部署下限和 Fork 的排版失败回退策略。适配测试的旧 CSS API（`f23f5f4b`、`b2519219`）和浮动跨页（`0328f4ce`），不引入上游失败页策略。 | `coretext-0.30.1-iphone-final` **82 通过、0 失败／跳过**，覆盖 EPUB 续读、竖排／滚动、源位置映射、字体与样式、超高浮动跨页、表格两格文字实际绘制及仍不支持内容的回退。`coretext-0.30.1-ipad` **6 通过、0 失败／跳过**，含 4 项双页／邻页回归和 2 项实际 UI 测试：从书架列表、网格开书、翻页并从探索续读。 |

## 依赖基线与差异

- `coretext-baseline` 在 `0.18.1` 执行 60 项：59 项通过。一项旧断言要求 `width:auto` 浮动必须回退，但旧依赖已支持。改测浮动宽度与旁边正文位置，仍在 `0.18.1` 运行 `coretext-baseline-auto-width`，1 项通过。
- 新版 App 能编译；旧版测试仍引用已移除的浮动错误、背景位置与重复字段，先适配这些测试。`0.30.1` 下合并边框的表格和负 `em` 缩进都可用，对应旧「不支持」用例改测真正还不支持的嵌套浮动与 `ex` 单位；新增正向用例确认允许的输入实际排版。没有重录或放宽旧整书几何快照。本次仅执行该测试文件的合成章节用例，不运行依赖私有 EPUB 语料的整书对比。
- `xcodebuild -resolvePackageDependencies -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev` 输出 `YueduCoreText … @ 0.30.1`。解析 `Package.resolved` 确认其余 pin 逐项相同；`plutil -lint -- Yuedu-Reader.xcodeproj/project.pbxproj` 为 `OK`。`ruby scripts/check_localizations.rb` 确认五种 `Localizable.strings` 一致（4,388 个键）。

## 复验与边界

Xcode 27.2（27B52），`Reader-Fork-Dev`，iPhone 18 Pro Max 和 iPad Pro 13-inch (M5)，均为 iOS 27.2 模拟器。实际使用下列命令格式，所有最终轮次均输出 `** TEST SUCCEEDED **`。本地 `.artifacts/upstream-8ed900e8-validation/` 有各轮的 `.log`、`.xcresult`、准确选择器与依赖配置备份；这些不提交。复验使用新的结果目录，不覆盖旧证据。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad 轮次改用 iPad
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -- -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/BrowserLayoutPageEngineTests'
```

只用自建／既有本地样本，没有验证真实站点、真机、iOS 17 运行时或 Release IPA，也不声称消除了用户遇到的偶发冻结。没有引入 JavaScriptCore 私有 watchdog，旧脚本超时后仍可能继续运行；系统强杀时，书源验活可能丢掉上一次保存之后的结果。本次不是 S8 或发布验收。三个改动分开提交；如需回退，可按范围撤销对应提交，不清空书库或订阅数据。
