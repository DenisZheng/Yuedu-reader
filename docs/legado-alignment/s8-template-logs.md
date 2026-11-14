# S8：AnalyzeUrl模板日志安全与媒体复验边界（2026-11-14）

## 日志缺陷与修复

实源模板求值时发现`AnalyzeUrl.resolveTemplateExpression`直接调用`NSLog`输出表达式与结果，绕过AppLogger和RSS的restricted上下文。结果可能是Token、请求参数或正文；单独检查DiagnosticLog脱敏不能覆盖这个出口。

使用无网络、自建表达式与结果做真实控制台黑盒验证：

```bash
bash scripts/validate_source_template_logs.sh /tmp/readerfork-template-evidence
# iPad使用 YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" 串行同跑
```

该脚本动态解析Xcode/设备，使用已有PoC宿主/DerivedData，实际执行普通/restricted两个上下文，要求两个完成标记都出现，并检查xctest完整控制台不存在合成表达式/结果。不会因测试0项、只检查内存日志或静态grep代码而通过。

- 修复前：请求求值测试本身1项通过，但控制台检查`expression_or_result_logged=True`，整体退出1。证据`/tmp/readerfork-s8-template-red/`。
- 修复：仅删除直接输出表达式/结果的NSLog，返回原求值结果。没有更改URL模板、headers、重试、请求、规则或变量语义；普通书源也不能再走这个原始输出出口。
- 修复后：iPhone/iPad各1项（普通/restricted两个参数case），真实控制台`expression_or_result_logged=False`。证据分别`/tmp/readerfork-s8-template-green-iPhone/`和`/tmp/readerfork-s8-template-green-iPad-recheck/`。
- iPad首次运行在构建`ClangStatCache`阶段超时，未进入测试；`/tmp/readerfork-s8-template-green-iPad/`保留。确认无残留xcodebuild后只做一次限定复验成功，没有clean、换DerivedData或清模拟器。

扩展共享桥/非音频实源回归两端各12项、3 suites、零失败零跳过，控制台检查仍通过，证据`/tmp/readerfork-s8-template-no-audio/`。集合为`AnalyzeUrlLogSafetyTests`、`RSSSharedBridgeTests`和`S8RepresentativeSourceTests`，**显式排除了真实MP3用例**。这个12项是日志与非音频子集，不替代先前37项完整批次，也不能说明当前媒体门槛通过。

## 必须保留的后续媒体失败

原[音频/进度批次](s8-audio-progress.md)双设备各37项实际通过后，扩展日志回归中R141再次出现15秒内未推进。框架后面的4项日志/桥合同通过，不能覆盖xcodebuild最终失败。

| 对照 | 结果 | 证据 |
| --- | --- | --- |
| 扩展回归R141 | 15秒内没有越过0.5秒播放边界 | `/tmp/readerfork-s8-template-regression/iPhone.log` |
| iPhone本地音频，不经RSS/HTTP | ready10秒超时、status=unknown；随后8秒clock=0 | `/tmp/readerfork-s8-local-audio-control.xcresult` |
| iPad相同本地音频对照 | 同样ready超时、status=unknown、clock=0 | `/tmp/readerfork-s8-local-audio-iPad-control.xcresult` |

后来读取拆除前附件发现：ready截止时unknown，但约+15.2秒后变ready，最终仍timebaseRate=0/clock0；不能把截止时unknown说成最终始终unknown。旧PCM和只读输出状态证据以及随后双端XCTest/独立App、原音频/PCM/R141当前恢复通过的限定结果，见[精确音频诊断](s8-audio-clock-diagnostics.md)；间歇失败的根因仍未确定。

没有自动重试实源媒体、静音、增大等待、修改路由、关闭设备或重启音频服务。两端本地音频同时失败说明不能仅归因RSS/网络，但**不能据此断言Mac主机音频故障或认定唯一根因**。按[既有音频时钟诊断](../../Technotes/RSSSimulatorAudioClock.md)保留#77间歇风险。本节记录的是当时媒体失败，不能覆盖后来已实际通过的有限复查；也不能把复查写成整个媒体/发布门槛完成。

真实MP3测试另补了失败时的请求数、HTTP状态、边界拒绝数、原生item/timeControl状态和时钟元数据，之后可在拆除播放器之前定位；不输出URL、Cookie、响应、任意错误文案或关联的源正文。

## 验证与回滚

- `bash -n scripts/validate_source_template_logs.sh`、实际控制台红→绿、双设备12项子集、`git diff --check`与本地文档链接检查。
- 本轮未修改数据格式或原始源包，未安装手机、commit/push。
- 回滚限定为本轮AnalyzeUrl原始输出移除、合成用例/控制台校验脚本和诊断元数据；不整体覆盖S8或#74共享文件，不清理已有数据。原始输出存在泄露风险，不建议恢复；如果恢复调试能力应另做仅元数据的受控日志，而不是重新输出表达式或结果。
