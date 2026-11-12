# S7：WebDAV 中断恢复与后台重载

## 结论

在用户确认的 `0f31f857` 基础上补齐 WebDAV 跨分类事务、启动恢复、owner 重载和 UI 故障注入。**S7 双设备自动阶段门槛已通过**：S5 各270项/38 suites，S6 各99项/19 suites加网页UI 3项，S7 各93项/20 suites，零失败、零跳过。两条模拟器音频输出时钟用例按用户确认移出模拟器门槛，源码、原始失败和稳定版真机证据仍保留，范围详见下文。

没有恢复回退前整包提交，也未把本批工作区安装到手机。用户已授权推送已验证改动，随后继续 S8；实源、人工与正式发布条件仍单独追踪。

## 实现

### 跨分类事务

- `WebDAVRestoreJournal` 是独立 `actor`，固定 role 白名单，不接受 manifest 或日志内的路径；原文件副本、大小、SHA-256 和 `active.json` 在专用 utility 队列完成。
- `active.json` 在任一目标替换前原子发布；所有目标成功且 owner 重载完成后才删除。进程在中间退出时，下一次启动按当前安装路径重建目标映射并恢复精确原字节。
- 恢复路径拒绝重复分类、未知 role、未知格式、损坏副本和符号链接目标；恢复校验全部副本后才开始替换。恢复任务取消不会取消补偿，失败保留 journal 供下次启动重试。
- RSSStore 在跨分类 IO 前撤销旧 request ticket、使运行时失效并阻止新 ticket；RSS 的正文、链接、收藏、状态和运行变量使用 owner 状态回滚，不以有损云快照替代。
- 文件写入、RSS owner、书架/书源/替换规则发布和重载失败都保留 active journal，并尝试恢复旧 owner；恢复前后的 revision 不一致时拒绝发布，避免过期快照覆盖用户新编辑。

### 后台重载

- `BookSourceStore`：JSON 解码、去重在后台完成，主线程只做带 revision 检查的发布；不重复同步读整文件。
- `ReplaceRuleStore`：后台解码/去重后发布，revision 不匹配时拒绝。
- `BookStore`：后台准备书架 JSON、保留本机阅读记录、修复章节摘要；章节变更在发布点应用，revision 不匹配时拒绝，主线程不等待磁盘读取。
- 启动前恢复通过 `WebDAVRestoreLaunch` 运行在普通主 RunLoop 之外的后台任务；恢复完成后再进入 SwiftUI App，失败显示原生重试页面。没有把 `App.main` 放进一个长期占用 MainActor 的异步任务。

## RED → GREEN

| 证据 | 结果 |
| --- | --- |
| `/tmp/readerfork-s7-restore-red.VuXz5p/` | 首个恢复闭环 RED：2 项测试 7 个问题；RSS 旧 ticket 未失效，RSS 正文/运行变量在跨分类失败后丢失。 |
| `/tmp/readerfork-s7-restore-owner-green.SSeryc/` | owner 事务修正后 44 项/4 suites 通过；RSS 旧 ticket 和正文/变量回滚闭环通过。 |
| `/tmp/readerfork-s7-journal-green.IIoFYK/` | journal、owner安全、既有WebDAV/RSS回归共49项/5 suites通过；启动强杀 UI 2项通过。 |
| `/tmp/readerfork-s7-restore-checked.EukcKe/` | 真实 target build settings：Swift 6.0、strict concurrency complete、无 approachable/default actor isolation、最低iOS17；相关单元78项/9 suites、恢复UI3项通过。 |
| `/tmp/readerfork-s7-revision-green.bneNXJ/` | 早期revision guard回归：60项/8 suites通过；随后新增owner发布前故障用例在 atomic-owner最终复核中覆盖。 |
| `/tmp/readerfork-s7-final-focused-both.gRVbZQ/` | iPhone/iPad owner、journal、WebDAV/RSS、管理/调试和后台重载各76项/13 suites通过，0失败/0跳过；包含书架/书源revision冲突保护和owner发布前故障注入。 |
| `/tmp/readerfork-s7-final-ui-restore-import.1whs6g/` | iPhone/iPad入口聚焦UI各10项/7 suites：恢复3项、五Tab、资源库、订阅滑动、Tab ownership、公共书库搜索、RSS导入取消/确认与Dynamic Type，全部通过。 |
| `/tmp/readerfork-s7-after-audio-gate-iphone.2fHi2e/` | 完整 `validate_reader_fork_s7.sh`：S5 270/38、调整后S6 99/19 + UI 3、S7 93/20，均通过。 |
| `/tmp/readerfork-s7-after-audio-gate-ipad.I0OYZb/` | 完整 `validate_reader_fork_s7.sh`：S5 270/38、调整后S6 99/19 + UI 3、S7 93/20，均通过。 |

UI测试中的 iPad 首次损坏 journal 用例在 AX5 下原生 `ContentUnavailableView` 可见但 identifier 位于容器层；已改为只给重试 Button 设置 identifier，iPhone/iPad重跑均通过。测试未通过改变生产数据边界。

## S6/S7模拟器音频用例范围调整与阶段结果

本轮按用户要求，从**模拟器S6门槛的执行集合**排除两个真实音频输出时钟单测：`RSSMediaPoCTests/testAudioActuallySeeksAndAdvances` 与 `testLocalAudioActuallyAdvances`。测试源码与断言保留；本轮不将其计作模拟器通过。双设备旧失败及干净启动复现证据仍在下方记录。依据是两台iOS27.2模拟器都失败，且单独干净启动仍复现音频单元启动超时/timebase停0；已验收的稳定提交`15a29143`真机S6 101项含本地与HTTP音频实际时钟断言。其他RSS媒体传输、MP4/HLS视频、WebKit与资源合同仍由模拟器执行。

更新后的完整S7脚本在iPhone与iPad均通过：S5各270项/38 suites，S6各99项/19 suites加网页UI3项，S7各93项/20 suites，零失败零跳过。S7自动门槛放行。真实WebDAV/源、iOS17、正式签名云能力等发布条件仍待单独验证。

原始失败证据 `/tmp/readerfork-s7-final-iphone.TmvyxX/` 与 `/tmp/readerfork-s7-final-ipad.YSf6JL/`：调整门槛前，两设备均先通过S5 270/38，后在HTTP音频10秒未ready、本地时钟停0失败。干净启动后单独运行本地音频也复现，证据 `/tmp/readerfork-s7-audio-cleanlaunch.iQclh5/`：出现 `AQMEIO timed out`、`CA_UISoundClientBase ... failed start`、缺少acoustic ID/hardware支持及 `FigFilePlayer err=-12864`；setActive返回Playback/Speaker/48kHz，但ready延迟、timebase停0。未修改生产音频、音量、路由或断言。当前模拟器launchctl查询无`com.apple.mediaserverd`服务；较早相同宿主36/36通过证据也保留。证据支持模拟器音频环境阻塞，但没有唯一定位更深层Apple服务原因。

## 范围调整前的模拟器音频独立控制复现

为区分应用后台竞争与模拟器音频服务，先终止当前iPhone模拟器中的 Reader-Fork-Dev App，再只运行 `RSSMediaPoCTests/testLocalAudioActuallyAdvances`。最新证据 `/tmp/readerfork-s7-audio-cleanlaunch.iQclh5/` 仍失败：`setActive` 正常返回 Playback/Speaker/48kHz，但 item 从 status 0 等待约11秒仍未ready；约15秒后日志出现 `AQMEIO.cpp timed out`、`CA_UISoundClientBase ... failed start`、`LoudnessManager ... cannot get acoustic ID`、`IsHardwareSupported ... disallowing hardware` 和 `FigFilePlayer err=-12864`，最终 status 才变为1，但 time=0、rate=1，8秒时钟断言失败。它不是 S7 恢复代码触发的全量套件竞争。

当前模拟器的 `launchctl` 查询也没有 `com.apple.mediaserverd` service；这与此前两台模拟器完整S6的相同 ready/timebase 失败及较早的36/36成功证据相互对照，足以把本轮门槛归类为当前模拟器/主机媒体服务环境阻塞，但不能从现有证据唯一确定更深层的 Apple 媒体服务根因。没有重启模拟器、改音量/路由、放宽阈值或修改生产音频实现。该失败在用户确认范围调整后仍作为未覆盖模拟器能力的诊断证据保留；当前门槛的双设备通过结果见上文。

## 入口与管理边界

- iPhone聚焦 UI 中原先受横屏状态影响的资源库、订阅滑动动作和 Tab ownership 用例已加入测试内 portrait 恢复/滚动准备，三项重跑通过；这修正的是测试隔离，不改变产品布局。
- iPhone公共书库搜索固定 fixture 通过；iPad相同聚焦入口通过。
- 真实源、真实WebDAV、真人 VoiceOver/登录、iOS17、正式签名/iCloud/App Group仍未验证。

## 双设备聚焦回归汇总（附加证据，完整阶段门槛已通过）

最终owner回归 `/tmp/readerfork-s7-final-focused-both.gRVbZQ/`：iPhone/iPad各76项/13 suites，零失败、零跳过；包括journal重建/幂等/checksum/路径安全/崩溃恢复、RSS票据和owner回滚、书架状态/章节摘要恢复、revision冲突。

最终入口回归 `/tmp/readerfork-s7-final-ui-restore-import.1whs6g/`：iPhone/iPad各10项/7 suites，零失败、零跳过；包括恢复fixture3项、五Tab、资源库订阅入口、RSS滑动动作、隐藏前置Tab后的stack、公共书库本地fixture搜索，以及RSS导入取消/确认和Dynamic Type。较早 `/tmp/readerfork-s7-final-ui-both.lreDPl/` 仅作历史中间证据，不作为最终结论。

完整 `scripts/validate_reader_fork_s7.sh` 已在双设备通过，S7自动门槛放行；S8开始执行。以上聚焦回归是完整阶段套件以外的附加证据。

## 推送前 Release 复核

额外执行动态 toolchain/destination 下的 `Reader-Fork-Dev` Release simulator build，首次在 `WebDAVVersionedBackup.swift` 报 `cannot find 'beforeStoreReload' in scope`：属性只在 DEBUG 定义，调用未受相同条件保护。证据 `/tmp/readerfork-prepush-release.iq2Q4c/`。仅为该故障注入调用补 `#if DEBUG`，未改变恢复顺序或生产逻辑。

复核 `/tmp/readerfork-prepush-verified.y7qNNr/`：Release build实际成功；Debug恢复/书架/RSS/导入和合成规模回归81项/11 suites通过，零失败、零跳过。此前双设备完整S7结果继续有效；本次不是正式签名archive或真机安装。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)"
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev \
  -configuration Release -destination "$YUEDU_DEST" -disableAutomaticPackageResolution build
```

## 交付与回滚

按用户授权提交/推送已验证改动，原始源包及本地审计目录不入库；S8继续以独立未完成阶段记录。回滚应整体撤回本轮WebDAV journal、启动恢复、后台owner重载、故障fixture、UI状态隔离测试及五语言“本地数据恢复”文案，不删除源、文章、手机或模拟器数据。
