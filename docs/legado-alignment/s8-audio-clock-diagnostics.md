# S8：audio-only时钟历史停滞与当前宿主对照（2026-11-14；根因未定）

## 当前状态：未定位的间歇风险，转监控（2026-11-14）

按用户决定，#77不再持续阻塞S8。原始合同`RSSMediaPoCTests/testLocalAudioActuallyAdvances`在iPhone/iPad模拟器各单次实跑1项通过（`/tmp/readerfork-s8-audio-contract-174833-{iPhone,iPad}.xcresult`），随后full门槛内R141真实MP3两端推进500/502ms。**根因仍未定位，这不是修复结论**；下文历史失败证据全部保留。

重开条件：该断言再次失败；出现`unknown`停滞、`timebaseRate=0`、时钟不推进或`-66681`；真机或网页播放器出现同类症状。重开时先保存拆除前AVPlayer/AVAudioSession状态，再围绕该次失败做最小实验。没有新失败时不再循环重跑。

## 交错A/B采样工具与2026-11-14首轮执行结果

首轮A/B固定XCTest先、Standalone后且各一次，不能排除起始宿主与预热混杂。新增 `scripts/compare_reader_fork_s8_audio_interleaved.sh`：同一已启动模拟器上多轮（默认3轮，`YUEDU_AUDIO_AB_ROUNDS`限1–5）交替先行宿主——奇数轮XCTest先、偶数轮Standalone先；每轮新UUID目录、同一fixture、同一App构建，沿用同一探针代码与限定比较器；任一轮未ready/未推进即停止并保留该轮证据，**不重试**。Standalone先行的轮次由脚本预置fixture目录，`RSSAudioHostComparisonTests`改为接受逐字节相同的已预置输入（原XCTest先行行为不变）。

实测发现xcodebuild test每次重装App会轮换数据容器：脚本改为在每次XCTest之后、Standalone之前现场解析容器并把探针报告立即复制到宿主；Standalone先行轮两端容器必然不同，比较器新增`--allow-rotated-container`——只容忍容器/输入**路径**哈希差异，仍强校验同一bundle哈希、同一输入内容SHA-256与字节数；默认无标志行为与原脚本完全一致（比较器单测6项通过，含轮换容忍的正反例）。

**首轮执行（iPhone 18 Pro Max，iOS 27.2，Xcode 27.2，2026-11-14 16:29–16:35）**：3轮全部通过，奇数轮XCTest先行/偶数轮Standalone先行，两端均ready且时钟推进、timebaseRate/effectiveRate=1；轮2标记`containerRotated=true`（内容身份仍校验通过），轮1/3为严格同容器。另有2对先前中断轮的已收集数据经同一比较器验证通过（XCTest先行，同容器）。今日合计5对采样、10次探针，**均未复现时钟停滞**。

- 证据：`/tmp/`下`readerfork-audio-host-interleaved.grILi7`（3轮完整，含final.json）与`readerfork-audio-host-interleaved.klmaT5`、`readerfork-audio-host-interleaved.woLC0a`（各1对中断轮的补全验证）。
- `RSSMediaPoCTests/testLocalAudioActuallyAdvances`的独立复检在交错会话中因xcodebuild沙箱拒绝未运行；之后已在主会话双设备补跑通过，见上节。交错证据目录在主会话不可见，本节数字为转交结果。
- 解释边界：交替先行增加了对“固定宿主顺序”假设的反证，但5对均为同日同模拟器的前台采样，未覆盖冷启动或历史故障现场，也不能量化排除全部预热因素；间歇故障未复现≠根因已定位或永久修复，不外推真机、可听声音或网页播放器。若再红，保留现场并比较该轮起始CoreAudio状态。

## 用户纠偏后的公开案例与方向重排（2026-11-14）

先前搜索偏向Apple API/当前版本，没有先按完整错误链查相似案例，也没有建立正常App与XCTest对照，过早偏向环境假设。以下一手或作者原始记录仅作可验证假设，不作为当前根因：

1. [2021年一手复现](https://stackoverflow.com/questions/66234186/ios-playing-audio-in-ios-13-throws-c-exception-freezes-app)：旧Simulator出现`timed out after 15.000s`、`AddRunningClient failed -66681`，音频不响/回调不运行。当前本地m4a和PCM日志也同时有15秒超时与-66681，症状比只搜ready/timebase更接近；但案例属于旧iOS，且作者关于Apple答复只是转述，不能证明27.2同一个系统bug。
2. [测试与正常App不同的一手案例](https://stackoverflow.com/questions/23593316/testing-avplayer-sounds)：测试内无声而App可播放，回答定位异步等待/对象生命周期。本轮对照已实际执行；XCTest和独立App在当前模拟器表现相同且均通过，见下方结果。
3. [GitHub runner-images #10902](https://github.com/actions/runner-images/issues/10902)：不同宿主/VM环境中，未请求音频输入的程序仍因Microphone权限条件造成CoreAudio启动延迟；维护者与报告者最后确认runner镜像处理后恢复。此为不同环境的一手记录，提示只读核查宿主/权限上下文，不能由Mac默认设备存在就排除此类问题，也不能要求用户先认定Mac音频坏了。
4. [Appium作者的headless说明](https://appiumpro.com/editions/58-how-to-test-on-headless-emulators-and-simulators-with-appium)明确headless仍可输出音频。因此这次只读进程检查发现Simulator GUI未运行、SimAudioProcessorService存在，也不能直接判定“必须开GUI”。Simulator音频设备可独立配置另见[Apple WWDC19](https://developer.apple.com/videos/play/wwdc2019/418/)。

本轮优先级中的第一项已在双设备完成：同一安装App/Bundle、同一App sandbox、同一Caches音频文件（sha256与路径哈希相同）、同一`RSSAudioHostComparison.run`播放器与AudioSession代码、相同10秒ready/8秒时钟截止，只改变是否由XCTest托管。

- **结果：** iPhone的XCTest独立探针0.506秒越过时钟边界，普通隔离App为0.417秒；iPad分别0.479/0.422秒。四次均ready、advanced、timebase/effectiveRate=1、无error、active状态。两宿主结果相同，因此本次不支持“XCTest宿主本身导致失败”；也不能单靠一次两端通过排除偶发问题。
- **同次原用例复查：** 既有`RSSMediaPoCTests/testLocalAudioActuallyAdvances`双设备通过；无压缩PCM对照通过，iPhone约0.512秒、iPad约0.469秒。
- **接回受控生产链：** 既有R141真实音频测试双设备各3个HTTP事务[200,200,206]，播放推进505/502ms，进度重载与资源关闭通过；没有凭据、未准入请求或增加请求预算。原网页WebKit音频/iframe仍未验。
- **解释边界：** 早先iPhone/iPad的m4a与PCM无声/ready延迟及`timebaseRate=0`是真实失败证据；当前只读状态与其不同。其间没有改生产音频实现、重启/关闭模拟器、清数据、调整音频路由或系统时间，因而只能说旧现象当前**未复现**，不能宣称已找到或修复根因。首次比较次序固定为XCTest先、独立App后，仍可能存在先后预热影响；A/B没有交错/重复，不能单独定因。
- iPhone证据：`/tmp/readerfork-s8-host-ab-final2-iPhone/`；iPad：`/tmp/readerfork-s8-host-ab-final2-iPad/`。各包含XCTest/App report、输入/容器哈希一致性、original recheck xcresult及最终状态。

**当前不采取主机权限/TCC写库、NullAudio/loopback驱动安装、重启服务或强制重启进程来“修复”。** 这些外部环境变更没有因果证明，也超出本次只读对照；不增加重复循环刷绿。若将来同一有限断言再次红，应留原始证据并比较起始CoreAudio状态，不把本次暂绿称永久解决。

本轮只增加调试模拟器的隔离探针与复用播放器实验辅助，没有改生产播放器行为。独立脚本`bash scripts/compare_reader_fork_s8_audio_host.sh`动态解析Xcode/设备，只准入已Booted的模拟器，不覆盖结果，保证同一个App container/精确音频文件并明确区分XCTest是否装入；不安装手机。当前两端完整脚本退出0，新增5项Python对照校验+既有10项门槛单元通过，模拟器非媒体子集两端各21项/5 suites也通过。对照XCTest类仅在DEBUG模拟器编译，不进入物理设备测试目标；补守卫后iPhone定向1项再次编译并通过（`/tmp/readerfork-s8-host-guard-regression.xcresult`）。没有运行真机/Release构建，不能声称其验证通过。首轮A/B本身两端成功，但旧脚本收尾`$EVIDENCE`紧跟中文导致`set -u`变量错误，不能写作脚本通过；改为`${EVIDENCE}`后两端完整复跑，原音频断言均实际执行1项通过。另在脚本尾检查双方真实推进和原断言，不能把报告已生成当作媒体通过；异常只清本轮隔离探针进程，其他设备/用户数据不清。证据位于`/tmp/readerfork-s8-host-ab-gate-{iPhone,iPad}/`。

旧本地m4a与PCM失败文件仍作为**历史失败证据**保留：

| 时间线 | iPhone旧对照 | iPad旧对照 |
| --- | ---: | ---: |
| setActive返回 | +0.060s | +0.046s |
| ready等待返回，仍unknown | +10.137s | +11.233s |
| 后续KVO进入ready | +15.337s | +15.238s |
| clock等待返回 | +18.193s，time=0 | +19.315s，time=0 |

这部分只说明旧失败的拆除前状态，不描述本轮现状。旧本地m4a测试在10秒ready截止时`status=unknown/error=nil`，随后调用play；拆除前附件显示它后来已经ready，仍不推进：

在2026-11-14当前独立A/B中，这组音频状态改为ready/advanced、timebase/effectiveRate=1。旧失败仍是真实历史记录，但不能把失败前的状态当作当前系统恒态。

## 假设与有限对照

1. **非混音路由抑制/显式静音/覆盖时钟**：用当前SDK公开只读属性核查，而不是主动抢占路由来测试。
2. **压缩m4a解码路径异常**：自建标准无压缩PCM/WAV，沿相同会话/ready/真实时钟条件对照。
3. **更广的audio-only输出路径或隔离宿主/平台状态**：如果PCM也停，不能只归因m4a/压缩解码；MP4正对照用于限制外推范围，不能证明其中音频可听。

实际结果：

- 新m4a只读诊断仍失败：`outputSuppressed=false`、`muted=false`、volume=1、sourceClock没有覆盖，effectiveTimebaseRate=0，最终ready/clock0。没有证据支持这次是非混音抑制标志导致。
- 新建1秒44100Hz单声道16位正弦PCM/WAV同样失败：ready10秒截止unknown，约+15.229s才ready；最终duration=1s、buffer可用、error=nil、rate=1/playing、有效timebaseRate=0、clock0。这不经RSS、网络、认证或压缩解码，不能再只归因m4a格式。
- 先前同iPhone loopback MP4 seek与真实推进1项通过。不能外推所有AVPlayer失效，也不能用视频时钟证明音轨可听。
- 只读`system_profiler`观察到当前Mac默认输入、输出和系统输出设备记录存在，sample rate=48000。未输出设备名、UID或用户信息；这既不是实际主机播放测试，也不支持认定Mac主机音频坏了。

- 旧m4a失败：`/tmp/readerfork-s8-audio-output-state.xcresult`，附件`/tmp/readerfork-s8-audio-output-attachments/`。
- 旧PCM失败：`/tmp/readerfork-s8-pcm-control.xcresult`，附件`/tmp/readerfork-s8-pcm-control-attachments/`。
- 当前A/B双端和原用例复查：`/tmp/readerfork-s8-host-ab-final2-{iPhone,iPad}/`。
- 当前PCM及R141真实生产音频回归：`/tmp/readerfork-s8-current-media-{iPhone,iPad}.xcresult`和同前缀log/summary。

没有自动循环重试。这两个新探针分别检验不同假设，沿用ready10秒/时钟8秒，不静音、不调音量、不延长等待、不设置sourceClock/路由优先参与者、不重启音频服务或设备。

## API证据与安全限制

Context7先查询Apple AVFoundation，返回官方文档；再核对当前SDK `AVPlayer.h`：

- [`AVPlayerItem.timebase`](https://developer.apple.com/documentation/avfoundation/avplayeritem/timebase)仅供观察，不能通过修改其time/rate模拟播放成功；有效rate变化还包括音频硬件漂移补偿。
- [`audioOutputSuppressedDueToNonMixableAudioRoute`](https://developer.apple.com/documentation/avfoundation/avplayer/audiooutputsuppressedduetononmixableaudioroute)当前SDK从iOS26可用；只在`#available`分支读取，最低iOS17路径不调用它。
- [`sourceClock`](https://developer.apple.com/documentation/avfoundation/avplayer/sourceclock)默认nil代表自动选择；SDK明确提醒改用不适当时钟可能导致音视频漂移。本轮没有设置它。

官方网页后续直接抓取因本机TUN/fake-IP安全拦截未成功；没有添加SSRF许可或更改代理。搜索没有提供足以证明当前27.2同一问题的发布说明，不把旧Xcode15.1或其他播放器/Spatial Audio问题套到当前AVPlayer，也不声称是已确认系统bug。

## 代码与复验

只增加共享的只读状态字段及独立`S8AudioClockDiagnosticsTests`。新PCM类不加入既有S6批准的选择集，也不加入声称已通过的S8非媒体子集；原模拟器音频断言没有删除、弱化或改成metadata即通过。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/S8AudioClockDiagnosticsTests'
```

旧iPhone/iPad失败路径的结论为历史/间歇：两轮当前独立A/B各一对，两种宿主均前台立即ready并推进；随后原本地音频断言、PCM正弦对照、R141真实音频链双设备通过。没有重启设备/服务、改音量/路由/时间或生产播放逻辑。S8中的R141原生媒体局部恢复通过，但规则网页/iframe、R146 TLS、登录和设备/发布门槛仍未闭合。该有限A/B不证明永久修复、可听声音或真机/iOS17通过。

回滚只撤去新的只读字段/测试辅助可见性、独立PCM诊断与文档；保留所有原音频测试和旧失败/通过证据、其他S8/#74修改与数据。无commit/push、手机安装、权限或新依赖。
