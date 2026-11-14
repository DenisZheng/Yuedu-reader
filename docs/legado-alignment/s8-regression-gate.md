# S8自动回归门槛（2026-11-14）

## 用法与范围

新增`scripts/validate_reader_fork_s8.sh`，复用已有`xctest.sh`、PoC隔离宿主和DerivedData，不重置设备或数据。

```bash
# 默认full；R146图片是外部证书链前置条件，两种模式都不运行、不计通过
bash scripts/validate_reader_fork_s8.sh full

# 明确的非媒体开发子集，不替代完整媒体或S8验收
YUEDU_EVIDENCE_DIR=/tmp/s8-nonmedia-run bash scripts/validate_reader_fork_s8.sh nonmedia
# iPad串行同跑，设备不硬编码
YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" \
  YUEDU_EVIDENCE_DIR=/tmp/s8-nonmedia-ipad bash scripts/validate_reader_fork_s8.sh nonmedia
```

| 模式 | 精确集合 | 明确不包含的范围 |
| --- | --- | --- |
| full | 当前47项/12 suites | R146图片（外部前置条件）、原307规模/全包导入、旧47项整合集、完整S0–S7、iOS17/真机/人工/发布 |
| nonmedia | 当前22项/5 suites | full中25项未执行：23项所属suite未选择，2项在选中suite内显式排除（真实MP3、R217真实图片）；R146图片同样不运行 |

**外部前置条件（2026-11-14）**：`testReviewedR146ImageRequiresSystemTrustAndNativeDecode`由第三方证书链决定（`-1202/-9814`），客户端无修复路径。它保留在源码中可单独运行，但不属于任何模式；verifier输出`externalPreconditionsNotRun=1`，结果树里出现该用例会按多出项目拒绝，所以它既不会让门槛失败，也不会被计为通过。证书链恢复后把它从`EXTERNAL_PRECONDITIONS`移回即可。

`nonmedia`的5个suite是`AnalyzeUrlLogSafetyTests`、`RSSSharedBridgeTests`、`S8RepresentativeSourceTests`、`S8TLSFailureMetadataTests`和`S8RequestBoundaryTests`。此前5项头部边界在[私有头阻断修正](s8-header-boundary.md)后纳入。新加的R128仅读一页无图预审属于nonmedia，R217名单图实际下载仅列入full并由nonmedia明确排除。nonmedia也含R014图片，不意味着所有媒体都关闭；名字表示不尝试当前播放/TLS障碍及R217单图，而不是完整资源能力验收。

**任何模式都输出`stageAccepted=false`。** full也仅是所列自动回归，不包括尚未闭合的原网页/iframe真实播放、受限登录、物理设备声音、iOS17、WebDAV/iCloud签名和人工VoiceOver。不能自动推进阶段或发布。

## 运行前与结果保护

- 只允许明确UDID且存在于当前`simctl`可用iOS Simulator列表的目标，拒绝`platform=iOS`、未知ID、不可用设备和名称回退。验后还核对xcresult实际模拟器ID，避免误装手机。
- 强制`Reader-Fork-RSS-PoC`，拒绝隐式package/workspace覆盖；固定两个输入源包SHA-256，缺失/变化时在请求前退出，不输出包内容。
- 拒绝覆盖已有xcresult；不删除旧失败、缓存或用户数据。
- 精确用例manifest由`verify_reader_fork_s8.py`维护。总数、成功/失败/跳过/预期失败、每个标识、重复/多出/漏项、最终xcodebuild结论均校验，不只检查suite存在或框架中途成功。
- 普通/restricted两次模板控制台探针必须完成，日志不得包含其合成表达式/结果。wrapper返回非零时即使summary看似通过也拒绝。
- 失败也尝试导出最终summary/tests树；结果不存在不回退为成功。模式输出区分`explicitExclusions`与`notSelectedFromFull`，不把0 skipped当作全量覆盖。
- 所有业务请求仍受各测试的精确URL、预算、凭据与TLS边界；脚本不增添站点准入或重试。

## 实际验证与开发失败

- 10项Python单元测试通过，包含物理目标在任何xctest调用前拒绝的shell对照；也验证假Passed、零项、缺失/重复/换项、日志漏探针/载荷、设备错配及真正执行bash footer。
- 更新后的`nonmedia`双设备完整退出0，各22项/5 suites、零失败/跳过，精确集合及模板探针通过；证据 `/tmp/readerfork-s8-current-nonmedia-iPhone.kDBTd1/`、`/tmp/readerfork-s8-current-nonmedia-iPad.42BVWD/`。R128受控只读实源一页20条无图检查也在此集合内。
- 历史证据：`/tmp/readerfork-s8-header-gate-{iPhone,iPad}/`（21项/5 suites）及`/tmp/readerfork-s8-gate-verified-{iPhone,iPad}/`（初版16项/4 suites）保留；更新后的22项结果见上一项。所有结果各自含xcresult、log、summary、tests树及当次模拟器清单。
- **full已实际整套运行：iPhone/iPad各47项/12 suites通过**，零失败/跳过/预期失败，证据`/tmp/readerfork-s8-full-iPhone.skTNEI/`、`/tmp/readerfork-s8-full-iPad.44CJ0U/`；同轮原始本地音频合同双设备各1项通过（`/tmp/readerfork-s8-audio-contract-174833-{iPhone,iPad}.xcresult`）。此前的48项manifest含R146图片，从未整套运行过。真实MP3/本地音频的历史失败及随后同文件双宿主有限复查见[音频记录](s8-audio-clock-diagnostics.md)；R146 TLS独立失败保留在[TLS记录](s8-r146-tls.md)。此前37项实际通过属于历史完整聚焦批次。

`R217`单张图及`R128`无图停止的资源边界与证据见[R217记录](s8-r217-image.md)。初版脚本在16项已通过后的最后一条echo因`$EVIDENCE`紧邻全角括号，被当前macOS bash误读为带首字节的变量，`set -u`导致脚本非零；当时流程不能写作整体通过。已先用执行真实footer的单元对照固定复现，再改`${EVIDENCE}`/`${MODE}`明确边界，10项单元及上述双设备完整脚本均通过。原结果保留`/tmp/readerfork-s8-gate-iPhone/`。

```bash
bash -n scripts/validate_reader_fork_s8.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/tests -p 'test_s8_regression_verdict.py' -v
```

## 其他只读预审与停止点

同轮为区分平台视频能力，原loopback MP4 seek/实际推进对照1项通过（`/tmp/readerfork-s8-local-mp4-control.xcresult`）；不能由本地音频失败推断所有AVPlayer或Mac主机音频已坏。

固定307项RSS样本的type均为0，原生资源层测试不改变其产品路由。额外静态筛选中两个无显式脚本/私有头的HTTP视频候选R169/R191，各只做了一次有预算、不跟随跳转的目录预审，HTTP200仅为传输观察；继续精审发现device/uuid/udid等参数，本轮保守停止，不枚举/替换标识或继续加载其视频，也不计实源播放器通过。没有升级或改写原包URL来制造兼容结论。

回滚只撤去这组脚本、verifier和测试/文档；保留数据与已有S8/#74修改。无commit/push、真机安装、权限、CA、路由或依赖变更。
