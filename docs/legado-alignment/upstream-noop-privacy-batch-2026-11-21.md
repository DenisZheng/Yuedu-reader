# 上游导入不变不写与调试日志清理（2026-11-21）

## 结果与范围

用户批准按[上游评估](upstream-78199517-assessment.md)实施剩余两项高优先级改动。基于 Fork `c3eec5e1`，只适配书源重复导入与共享源脚本的原文控制台旁路；不整包 merge／cherry-pick，不恢复账号、付费或 iCloud，不改播放器、依赖、权限、版本或持久格式。

- 同内容重复导入不再发布整库、推进 `mutationRevision` 或排队写盘；真正改变内容或新增的导入仍正常保存。
- 移除源级 `NSLog`、JS 异常的重复 `print`、脚本 `print` 与 toast／logType 的任意原文控制台输出；接口、提示与异常传播保留。
- 本次不自动 commit／push／打包，先前下载目录的 3.0.1（6）IPA 不包含本轮新改动。视频不能播放仍未修复。

## 来源与必要适配

上游作者 CHANG-JUI-LIN；沿仓库 MPL-2.0／NOTICE 保留来源，没有复制 Android、私有源规则或素材。

| 来源 | 本轮实际适配 |
| --- | --- |
| [`0236a2da`](https://github.com/CHANG-JUI-LIN/Yuedu-reader/commit/0236a2da1dead5528dc87787b934b76ac0beccd5) | `BookSourceStore.importSources` 复用原来的 `hasSameContent` 比较，记录是否有真实变更；无变更且无新增时提前返回原导入数量。保留 ID、作者时钟处理、导入选项、重复 URL 后项覆盖、排序与合并落盘路径。没有引入上游全套 import route／字段采样／Crashlytics 面包屑。 |
| [`50ccb769`](https://github.com/CHANG-JUI-LIN/Yuedu-reader/commit/50ccb7699422b2e94d4c7c25f546908ead6b89c1) 的部分改动 | 仅触及 `ModernParserBridge.swift`、`JSCoreEngine.swift`、`LegadoJSBridge.swift` 的原始控制台旁路。没有照搬 37 文件的整批日志删除、空异常 handler 或其他诊断清理。 |

`primeDiscoverCookiesIfNeeded` 原来在可选初始化失败时只用 `NSLog` 输出异常描述。现在通过既有 AppLogger 报告数值错误码和取消标记，不输出可能携带 URL／正文的异常原文；请求和 Cookie 逻辑不变。取消按 trace、其他失败按 error 记录，不用空 catch 假装成功。

脚本 `print`、`java.logType` 仍存在但不再复制原文到控制台，源作者可继续使用原有 `java.log`；`java.toast` 仍将提示交付到主线程。现有 AppLogger、SourceAPIErrorLog、SourceDiagnosticContext、请求指标、章节／探索流程及错误回调保留。本轮是已识别旁路的清理，不声称完成了全项目日志隐私审计或删除了历史日志。

## RED：原行为的实际复现

新增 `BookSourceImportNoOpTests` 使用自建源和独立目录，不碰共享书源库。首轮测试误把 `flushPendingWrites()` 当作等待；该函数只保持后台存活，导致读取时文件尚不存在。改为现有异步 `queuedWritesLanded()` 后才得到以下有效 RED，不用 sleep／同步阻塞或放宽断言。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -- -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/BookSourceImportNoOpTests'
python3 -B -m unittest scripts.tests.test_source_debug_logging_privacy -v
```

有效 RED 为 3 项，1 个改变／新增控制用例通过，2 项失败、6 个 issue，`** TEST FAILED **`：

- 相同源重复导入 3 次，写盘计数从 1 增到 4，发布 3 次，修订增加 3，文件被重新替换。
- 保留本地名称、分组、开关和排序后的同内容确认导入，仍替换文件并增加修订。
- 真正修改、重复 URL 最后一项生效、新增和落盘的控制项正常。

源码隐私 gate 修改前 3 项均失败，精确锁住共享 bridge 的 `NSLog`、JS 执行器的原文 `print`、toast／logType 控制台旁路。该 gate 是源码合同，不被当作运行时日志抓取或真实源验证。

## GREEN：实际验证

环境：动态选择 Xcode 与 iPhone 18 Pro Max／iOS 27.2 模拟器，SDK 27.2、`Reader-Fork-Dev`、既有 DerivedData、串行测试，没有 clean 或另建缓存绕错误。

```bash
bash scripts/xctest.sh -- -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:'yuedu appTests/BookSourceImportNoOpTests' \
  -only-testing:'yuedu appTests/SourceDebugLoggingCompatibilityTests' \
  -only-testing:'yuedu appTests/SourceImportPlanTests' \
  -only-testing:'yuedu appTests/BookSourceImportOptionsTests' \
  -only-testing:'yuedu appTests/RSSRuntimeIntegrationTests' \
  -only-testing:'yuedu appTests/DiagnosticRedactorTests'
```

退出 0，决定性输出：`Test run with 48 tests in 6 suites passed after 4.556 seconds`、`** TEST SUCCEEDED **`。新回归确认重复导入 3 次不增加文件替换、DiskWriteTally、发布或修订；源内容改变或新增仍保存。JS `print`／`logType` 可调用且后续求值正常，异常仍进入错误回调，toast 交付到主线程。既有导入选择／选项、RSS 并发撤销与凭据、DiagnosticRedactor 回归通过。

`python3 -B -m unittest scripts.tests.test_source_debug_logging_privacy -v` 为 3 项／OK：原文旁路消失，同时源作者诊断、错误回调和 UI 提示入口仍存在。

第一次 GREEN 构建原计划包括旧 `BookSourceSelectedImportTests`，检查发现它们会临时替换共享书源库；在编译阶段主动终止，确认没有执行任何 Swift 测试，随后排除该 suite，用本轮隔离回归覆盖真实确认导入。中止运行不计为通过，不用覆盖共享数据换取验证。

完整日志和 xcresult 位于本地 `.git/upstream-noop-privacy.giDctEi7/`，不提交测试目录或私有响应。没有新增用户文案，所以没有改本地化资源或声称本轮运行了本地化检查。

## 限制与回滚

未执行真机、iPad、最低 iOS 17、真实源请求或全项目日志审计；没有重测视频播放／快进。测试构建已提供编译证据，不重复单独 build／archive。

回滚仅反向撤回本轮 4 个生产文件、2 个新增 Swift 回归及源码隐私 gate；不恢复整个工作区，不撤销之前 RSS／JSON 导入修复，不改用户源包，不删除现有数据、历史日志或旧 IPA。
