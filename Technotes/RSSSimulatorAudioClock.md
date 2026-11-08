# RSS模拟器音频时钟：环境恢复与前置复验

## 结论与范围

待办#36是任务编号，不是36个测试。旧iOS26.2上的故障为：音频可加载/seek，但AVPlayer时钟停在0或2秒；本地音频也复现，不能把它仅归因于RSS或网络。S5后在官方iOS27.2上再次复现，再恢复到两设备实际播放通过。

**当前开发环境的媒体前置门槛恢复通过；底层系统音频故障机制未唯一定位。** 这不是生产播放器补丁，也不证明旧26.2、真机或完整S6媒体路径通过。

## 本轮可重复反馈

正常 `Reader-Fork-Dev` App宿主，Xcode/设备由脚本解析，实际Xcode27.2 / SDK27.2 / iOS27.2(24B8117)。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -l /tmp/readerfork-media-clock-iphone.log -- \
  -resultBundlePath /tmp/readerfork-media-clock-iphone.xcresult \
  -only-testing:'yuedu appTests/RSSMediaPoCTests/testAudioActuallySeeksAndAdvances'
```

- 初次失败：10秒内未ready、error=nil，不是合法空媒体。
- 加入不经RSS/网络/headers的本地AVURLAsset对照，`/tmp/readerfork-media-clock-controls.xcresult`：本地ready成功，但8秒内时钟仍为0；MP4视频对照通过。
- 附件记录：本地duration约4.975秒、likelyToKeepUp=true、输出Speaker、48000Hz、playback/default；HTTP音频发出两次GET，可得duration但status仍unknown。原附件已导出到 `/tmp/readerfork-media-clock-controls-attachments/`。
- `/usr/bin/afinfo`确认同一AAC/m4a的44100Hz、单声道、5秒；宿主默认输入/输出存在且为48000Hz。随后宿主 `/usr/bin/afplay` 播放同一文件实际约6秒正常结束。

## 区分实验与恢复边界

先明确以下候选：模拟器音频服务、HTTP/headers加载、App音频会话干扰、样本/codec问题。整个过程未修改生产音频实现、样本或系统音量。

启动目标设备并执行 `xcrun simctl bootstatus <动态UDID> -b` 等待真实系统就绪；同轮还执行了上述宿主afplay检查。随后本地音频和原HTTP音频2项通过，附件显示本地时钟0.2006秒、rate=1、timeControlStatus=playing、timebaseRate=1。证据 `/tmp/readerfork-media-clock-bootready.xcresult`。

只重启本轮由代理启动的iPhone、保留全部App/模拟器数据，不再afplay，原HTTP音频冷启动复验也通过：`/tmp/readerfork-media-clock-cold-repeat.xcresult`。因此不能仅凭一次前后变化声称bootstatus或afplay是唯一修复原因；记录为宿主/模拟器音频环境恢复，保留原RED证据。没有关闭旧设备、删除数据、重置Simulator或重启系统音频服务。

新增本地播放用例与失败状态附件作为平台诊断/回归；网络音频、视频、HLS仍保留原seek和真实时钟断言，没有改成静音、手动推进时间或延长截止时间。附件现在在播放器拆除前采集，避免teardown把time变成NaN而丢失关键状态。

## 最终门槛

新增 `scripts/validate_reader_fork_media.sh`，固定正常Dev宿主，先等待bootstatus；不自动重试或修改音频路由。检查最终Passed、零失败/跳过、全部suite及本地音频/网络音频/MP4/HLS指定用例实际执行。

```bash
YUEDU_EVIDENCE_DIR=/tmp/readerfork-media-prerequisite-iphone bash scripts/validate_reader_fork_media.sh
YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" \
  YUEDU_EVIDENCE_DIR=/tmp/readerfork-media-prerequisite-ipad bash scripts/validate_reader_fork_media.sh
```

| 门槛 | iPhone18 Pro Max | iPad Pro13-inch(M5) |
| --- | --- | --- |
| 正常Dev宿主媒体前置 | 36项/5 suites，0失败跳过 | 36项/5 suites，0失败跳过 |
| S1隔离PoC完整回归 | 55项，0失败跳过 | 55项，0失败跳过 |

- 正常宿主证据：`/tmp/readerfork-media-prerequisite-iphone/tests.xcresult`、`/tmp/readerfork-media-prerequisite-ipad/tests.xcresult`。
- S1命令仍为 `scripts/validate_reader_fork_s1.sh`，仅通过YUEDU_DEST选择设备；证据 `/tmp/readerfork-media-s1-iphone/tests.xcresult`、`/tmp/readerfork-media-s1-ipad/tests.xcresult`。隔离PoC结果只作补充，不替代正常宿主。新本地音频用例使原54项增为55项，与待办编号无关。
- 源包SHA-256不变；新shell及内嵌Python解析、文档本地链接/UTF-8/LF及 `git diff --check` 提交前校验。

## 后续与回滚

#36当前开发环境前置可关闭，记录归档后自动进入S6。S6仍要验证真实生产资源路径、认证隔离、播放竞争和持久进度；S1的跨host私有头测试是在记录旧asset选项会泄漏，不能误读为生产安全通过。真机、最低iOS、DRM和旧系统兼容不由本轮放行。

若同类故障再次出现，门槛必须保留失败，不以自动重试/静音或放宽断言消掉；先跑本地音频对照并保存拆除前状态与系统路由。底层机制未确认是剩余环境风险。

本轮无生产补丁；回滚只撤回新增测试/状态附件和媒体前置脚本，保留诊断证据与所有用户数据。不能将环境恢复写成iOS音频引擎已修复。
