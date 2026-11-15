# 真机JSON导入诊断：选择、调试暂停与确认保存耗时

## 开发签名对照阶段结论（2026-11-15）

**后续结果：** 用户确认[JSON原生复制导入修正包](json-copy-import-implementation.md)自签后可以正常选择／导入。本节以下保留修正前的调查过程，不再代表最终状态；系统书签257日志与源码对照见[设备日志定位](json-picker-device-log-2026-11-15.md)。

用户在LegadoPro 3.0（5）自签Release上反馈书源／RSS JSON点击后不返回；同文件在旧Mac直接安装测试版可导入。不能仅凭这个描述判定JSON类型过滤、CloudKit或SDK为原因。用户随后确认本地Debug两类导入均可成功，一度认为确认到保存需要5–30秒；最新无断点操作没有卡住。

最新实测支持：书源确认函数与RSS保存事务没有5–30秒耗时；早先一次Debug“回调卡住”确定是调试器人为暂停。随后同SDK26.5的原云Release IPA仅改开发签名新装，用户确认书源与RSS均导入正常，因此不支持因SDK26.5必然不兼容而换SDK。但用户手动卸载也改变数据和安装注册起点，仍未精确锁定年度自签权限／包处理差异，不宣称原自签方式已修复。

## 真机与构建

- 物理iPhone由用户通过USB连接，iOS27.2.1。最初错误将`reality=simulated/transportType=sameMachine`的模拟器认成真机，已纠正；真实设备经指定名称查询建立CoreDevice连接，不自动配对／开启权限。
- 本地Debug使用`Reader-Fork-Dev`，SDK27.2；此前云Release使用SDK26.5。用户最新约定：Debug直接本地编译安装，Release才走Actions。
- 自签包LLDB最终明确`Not allowed to attach to process`，已停止，不换工具绕过权限。按用户新授权安装合法开发签名Debug，实际签入`get-task-allow=true`，描述文件有效且包含目标手机；未索取或输出证书私钥／密码。
- Debug签名与项目既有个人团队流程一致，暂不具备App Group与CloudKit授权，不修改生产配置。安装后系统先拒绝启动，用户自行确认开发者信任后启动、附加成功。

## 实际执行与失败证据

```bash
bash scripts/sim.sh doctor
# 环境检查退出码0
READER_FORK_TEAM=<现有开发团队> READER_FORK_DEVICE=<物理手机UDID> bash scripts/device_dev_test.sh
# 最终：** TEST BUILD SUCCEEDED **
# App installed / Launched application with dev.denis.readerfork.dev bundle identifier.
python3 -B -m unittest scripts.tests.test_device_dev_script -v
# 修改前：Ran 1 test / FAILED (failures=1)
# 修改后：Ran 1 test / OK
```

上述真机阶段没有执行Swift测试，仅`build-for-testing`提供编译证据。收尾额外执行`YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AuthAndICloudConfigurationTests'`，模拟器实际4项／1 suite通过，决定性输出`TEST SUCCEEDED`；不把模拟器回归写成真机测试。真机开发脚本默认TMPDIR末尾斜线导致拼接路径含`//`，xcconfig把其后内容当注释，签名路径截成`T`目录，报`Entitlements file "T" was modified during the build`。规范化同一个WORK路径后复用原DerivedData成功，不开启`CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION`。另补齐新增iCloud测试缺少的`import CloudKit`。

无权限自签附加、首次未信任启动和上述失败均保留在本地`.git/`，不冒充通过。真机调用栈证明早先一次停在SwiftUI `FileImportExportBridge.documentPicker(_:didPickDocumentsAt:)`入口，是调试断点暂停。已分离并恢复；后一次反馈“从文件导入卡住”时进程running、阶段断点0命中，短暂读取后立即分离的主线程栈为`mach_msg/__CFRunLoopRun/UIApplicationMain`，不是当场JSON解析阻塞。后续没有继续挂断点。

```bash
xcrun xctrace record --template 'Time Profiler' --device <目标手机> --attach <Debug PID> --time-limit 90s --output <新trace路径>
# 退出13：Timed out waiting for device to boot
# 未生成trace；xctrace列为Offline，而CoreDevice物理wired连接为connected。
```

没有Time Profiler采样证据，不以该工具失败推导App或SDK根因，也不自动改变隐私／调试权限。

## 最新无断点测量

临时`[JSONImportTiming]`只记录数字、线程标记和书源／RSS类型，不记录JSON、URL、规则、请求头或凭据；使用既有`SourcePerfTrace`与`DiagnosticLog`，在确认末尾异步flush。未更换SDK、解析器、保存算法或数据身份。

通过`devicectl device copy from --domain-type appDataContainer`仅读取当前诊断文件，退出码0，共99条。用户先书源后RSS，最新安全记录：

| 时间UTC | 实际测量范围 | 结果 |
| --- | --- | --- |
| 11:09:46 | 书源内存合并 | 885项，main=true，5ms |
| 11:09:46 | 书源发布／排队保存 | main=true，3ms |
| 11:09:46 | `BookSourceImportCoordinator.confirmImport`函数 | selected=885，28ms |
| 11:11:52 | RSS后台编码／落盘 | sources=399，main=false，43ms |
| 11:11:52 | `RSSStore.commitImport`保存事务 | changed=300，sources=399，455ms |

**范围限制：** 书源确认函数不等待后台写入实际完成；RSS保存事务包含发布和等待落盘，但不含`RSSImportService.changes`生成方案、点击后任务排队和最终界面绘制。不能把455ms当整个用户操作耗时。

同时间窗口MainThreadMonitor记录612ms、324ms及RSS保存附近340ms的短暂停顿；612ms在书源确认记录4秒之后，不能归入28ms确认函数。没有本窗口5–30秒主线程停顿证据。RSS还有多次日常写入，源数量从385逐步减少到99后再增加到399；这些不能当成同一次导入重复落盘，也不能假设前后源库起点相同。书源日志尚未记录新增／更新分解，不能仅凭885项判定是初次还是重复导入。

## 同云Release IPA的开发签名新装对照

用户批准开发签名对照后，自行手动卸载当前Debug。安装前查询同Bundle ID App数0，数据无法再备份；未由助手删除App／数据，也不假称严格单变量。原IPA SHA-256为`cb28a56e39e6792420f8dfb27d08adc2c3c17974b643de75178cd4bcdd3ebf22`，在本地新暂存副本中复用同一现有开发证书、真实Debug entitlements与描述文件重新签名，不申请App Group／CloudKit。

- 三个可执行文件签前后`__text`／`__cstring`哈希一致；主程序UUID仍为`F1B97B1E-4852-3807-AD51-6A8AF71DAD50`，平台iPhoneOS、SDK26.5、minos17.0。
- `codesign --verify --deep --strict`退出0，原IPA未修改。当前工具默认权限输出不是XML，首次读取中止后核对仅解包、未签名／安装；显式`--xml`并改用新暂存完成，不覆盖原产物。
- `devicectl device install app`退出0。首次启动Security拒绝后停止；用户自行信任后`device process launch`退出0，未挂调试器。
- 用户实际用原JSON分别导入书源和RSS，均正常。由此先不换SDK、不改解析器／保存算法；具体年度自签权限或安装注册差异仍待签名后IPA等证据。

## 本地未签名Debug IPA交付

用户另要求本地编译IPA放下载目录，由其使用年度签名自签。使用本机SDK27.2执行`xcodebuild archive -configuration Debug`，复用既有真机DerivedData，`CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_REQUIRED=NO`，决定性输出`ARCHIVE SUCCEEDED`（退出0）。原归档／dSYM保留，只在新归档副本中清除签名和profile，再用现有`scripts/package_unsigned_ipa.py`打包。

- 文件：下载目录`LegadoPro-3.0-build5-local-Debug-SDK27.2-unsigned.ipa`及同名`.sha256`，未覆盖旧文件。
- 大小：71,968,086字节；SHA-256：`399292252d5a26a5cbad061d7dd4992ca5b3d74ac88aa004fa3df317669409b7`。
- ZIP／SHA-256、三个Bundle版本3.0（5）与身份、iPhoneOS／最低声明17.0、可执行权限、全部Mach-O无签名及profile为0已实际核验；二进制无`[JSONImportTiming]`临时标签。
- 不云编译、不替用户安装此未签名包，也不发布／覆盖旧Release。该SDK27.2 Debug包尚待用户年度签名后复验，不能与此前开发签名成功等同。

## 收尾与边界

临时数字日志和对应SourcePerfTrace包装在测量结束时已精准撤回，当时三个生产导入文件与HEAD一致；此后另按[复制导入方案](json-copy-import-implementation.md)修改真正文件入口。保留开发脚本路径修正及回归、CloudKit测试import补齐、Debug本地／Release云编译约定和诊断记录。原始源包与设备日志不纳入提交。回滚本轮开发脚本／测试修正不需删除用户数据；S8人工验收仍未闭合。
