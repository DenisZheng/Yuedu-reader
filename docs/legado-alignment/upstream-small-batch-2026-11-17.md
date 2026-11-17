# 上游首批六项修复适配与验收（2026-11-17）

## 结果与范围

按用户“按复审修改问题，按建议小批引入上游合并”授权，在`merge/upstream-small-fixes-20261117`引入六项修复。起点为`40065b99a212a64da2dd4a5af6b9fbc319211a21`；采用精选补丁适配，不整包merge36提交，不引入其余功能。**本次提交承载已验收的六项补丁及正式记录，用户仅授权本地提交，不Push或发布**，main引用仍为40065b99。

[复审核对记录](validation.md)中的活性副作用、历史提交／推送、旧build5与当前代码验收边界已更正；用户原始复审稿保持未跟踪，不随本批提交。[只读评估](upstream-5671a240-assessment.md)保留为授权前快照。rc.1继续保留原始身份并标记已知CloudKit启动风险，不移动／删除tag或自动创建Release。

| 固定来源 | 已适配的修复 |
| --- | --- |
| `66124f63` | 长章逐页重复桥接改为一次桥接；图片行／装饰块直接读取底层CFString |
| `97b4f5b7` | 将调用方取消传播到完整／首屏detached排版，循环及时退出，残缺结果不入缓存 |
| `e8bc688b` | 真实拆除后阻止旧章节等待者因generation变化重新启动布局 |
| `68e2c544` | 目录系统Menu改用隐藏装饰图标标签，保留VoiceOver排序值 |
| `a4df38b6` | iOS27使用原生List滑动动作，旧系统保留手动置顶／删除动作，避免重复 |
| `5905b06d` | 空搜索框静置时仍展示最近搜索／最近阅读，不因结束搜索而失去点击目标 |

没有升级YueduCoreText、其他依赖、工程版本或构建号，没有恢复Pro／账号／后台，没有引入模块JS、模块3.0.2或首页／详情重设计，没有fetch／pull或改Android基准。六项是代码修复来源，**不表示Git祖先已经整合至5671a240**；原固定共同祖先仍为dbd25567。

## Fork适配与来源

上游原作者为CHANG-JUI-LIN，沿仓库现有MPL-2.0及NOTICE保留来源；本批不复制Android代码、源脚本或新增素材。逐文件记录：

| 文件 | 来源／必要适配 |
| --- | --- |
| `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift` | 66124f63／97b4f5b7；只改字符串读取与取消，不引入后续framesetter窗口化 |
| `Modules/Core/ReaderCore/CoreText/PageRenderingProvider.swift` | 97b4f5b7；新增readerTeardown原因，RED阶段仅先建立该枚举合同 |
| `Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift` | e8bc688b；区分永久拆除与普通布局失效，保留普通取消后的合法重试 |
| `Modules/Features/Reader/ReaderView.swift` | 97b4f5b7；并入Fork原ReaderTeardownProbe，保留网页／视频释放，朗读未停止时不取消引擎，不改onDisappear |
| `Modules/SharedUI/Components/ChapterListOrder.swift` | 68e2c544；保留系统Menu、标签／value、现有Preview与排序合同 |
| `Modules/Features/Bookshelf/HomeView.swift` | a4df38b6；保留Fork书架、滑动删除确认与五Tab，不覆盖整个上游文件 |
| `Modules/Features/Search/SearchRecentsPanel.swift` | 5905b06d；Fork搜索为推入页，**不引入上游搜索Tab根标题滚动锚点** |
| `Tests/iOS/yuedu appTests/CoreTextLongChapterPaginationTests.swift` | 改编66124f63／97b4f5b7固定HTML基准，补首屏取消回归，新增注释／测试说明用中文 |
| `Tests/iOS/yuedu appTests/ReaderChapterSupplyTests.swift` | 改编e8bc688b受控构建门闩回归，不用等待延时 |
| `Tests/iOS/yuedu appTests/BookshelfRowVoiceOverActionsTests.swift` | 改编a4df38b6；真实BookRow+原生List动作，不读写书架，不使用上游尚不存在的WindowHost，不新增sleep轮询 |
| `Tests/iOS-UI/SearchRecentsTapUITests.swift` | 改编5905b06d；经Fork探索入口推入，补最近阅读及激活空搜索后的点击，使用隔离书架／空书源 |
| `Tests/iOS/yuedu appTests/CoreTextImageBoundaryTests.swift` | 自建Unicode图片行与直排显式装饰块数据，补足私人EPUB缺失时的字符串／几何覆盖 |

测试中可访问性automation开关沿既有目录VoiceOver测试的方式启用并恢复，只存在测试target，不进入生产权限／API。新增用例按条件／真实事件等待；原有目录VoiceOver测试本身仍有历史sleep轮询，未把它说成已重构。

iPad系统限制没有被隐藏：静置最近条目一次点击可执行；搜索框已经激活且为空时，首触仍可能被系统用于结束搜索，列表保留，第二次点击执行。本次在iPad验证该明确行为，没有私有拦截或延时绕过。

## 原始失败与相同输入对照

先加回归／readerTeardown原因枚举，尚未加入行为修复时运行：

- `red-unit-ready`：xcresult为7失败、0通过、0跳过；长章四倍正文耗时比9.24，期望小于6；完整／首屏取消仍排出页面；真实拆除后仍得到ready布局；目录两种排序的value均丢失；置顶／未置顶书籍均同时有“删除”与“删除书籍”。
- `red-ipad-ui`：2失败、0通过、0跳过；最近搜索及最近阅读在搜索框静置时不存在。
- 最初`red-unit`是新测试适配的编译错误（只读isPinned、闭包self），不是原问题RED；修正fixture写pinnedAt与显式self后才得到上述行为失败。新增图片测试第一次亦因缺少YueduCoreText显式import编译失败，修正后实跑，不冒称失败轮已验收。

| 同一iPhone模拟器／固定HTML | 修复前 | 修复后 |
| --- | --- | --- |
| 99,990字符 | 369ms，159页 | 198ms，159页 |
| 399,960字符 | 3,413ms，635页 | 707ms，635页 |
| 四倍长度耗时比 | 9.24 | 3.56 |
| 857,790字符 | 16,372ms，1,362页 | 1,576ms，1,362页 |

这是本机会话的单次模拟器对照，不是实机／用户全部书库性能承诺。固定段落刻意不含相邻CJK标点，以隔离整章重复桥接；复杂Unicode／CJK／横竖排另有相关回归，不借该基准证明全部排版成本线性。

## 环境、命令与结果

实际环境：Xcode27.2（由scripts/sim.sh解析），iOS27.2 iPhone18 Pro Max／iPad Pro13-inch（M5）；旧runtime按可构建设备清单动态选最老版本，为iOS26.2 iPhone17 Pro Max。doctor未列出iOS17.x。全部使用Reader-Fork-Dev、原DerivedData、scripts/xctest.sh串行，不clean、不删模拟器或用户数据。测试构建提供本批Debug编译证据，没有额外build／Release归档。

所有日志／xcresult在未跟踪`.artifacts/upstream-small-batch-2026-11-17/`，不加入提交。以下整理本轮实际参数，`A`只缩短重复路径：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-Dev
A=.artifacts/upstream-small-batch-2026-11-17
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l "$A/green-unit.log" -- \
  -resultBundlePath "$A/green-unit.xcresult" \
  -only-testing:'yuedu appTests/CoreTextLongChapterPaginationTests' \
  -only-testing:'yuedu appTests/ReaderChapterSupplyTests/teardownStopsSupersededRetry()' \
  -only-testing:'yuedu appTests/ChapterListOrderVoiceOverTests' \
  -only-testing:'yuedu appTests/BookshelfRowVoiceOverActionsTests'

export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
bash scripts/xctest.sh -l "$A/green-ipad-ui.log" -- \
  -resultBundlePath "$A/green-ipad-ui.xcresult" \
  -only-testing:'yuedu appUITests/SearchRecentsTapUITests'

export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l "$A/iphone-regression.log" -- \
  -resultBundlePath "$A/iphone-regression.xcresult" \
  -only-testing:'yuedu appTests/ReaderChapterSupplyTests' \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -only-testing:'yuedu appTests/CoreTextChunkSlicerImageLineTests' \
  -only-testing:'yuedu appTests/ChapterListOrderTests' \
  -only-testing:'yuedu appTests/ReaderVideoPresentationTests' \
  -only-testing:'yuedu appTests/SourceBrowserVideoReturnTests' \
  -only-testing:'yuedu appUITests/SearchRecentsTapUITests'

export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
bash scripts/xctest.sh -l "$A/ipad-regression.log" -- \
  -resultBundlePath "$A/ipad-regression.xcresult" \
  -only-testing:'yuedu appTests/ReaderChapterSupplyTests' \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -only-testing:'yuedu appTests/CoreTextChunkSlicerImageLineTests' \
  -only-testing:'yuedu appTests/ContentRevisionPaginationTests' \
  -only-testing:'yuedu appTests/CJKLineBreakPolicyTests' \
  -only-testing:'yuedu appTests/ChapterListOrderVoiceOverTests' \
  -only-testing:'yuedu appTests/BookshelfRowVoiceOverActionsTests' \
  -only-testing:'yuedu appTests/ReaderVideoPresentationTests' \
  -only-testing:'yuedu appTests/SourceBrowserVideoReturnTests'

export YUEDU_DEST="$(bash scripts/sim.sh list | python3 -c 'import sys
rows=[line.strip().split(" — ") for line in sys.stdin if line.startswith("iPhone ")]
assert rows,"没有可构建iPhone"
version=lambda row:tuple(map(int,row[1].removeprefix("iOS ").split(".")))
oldest=min(map(version,rows)); candidates=[row for row in rows if version(row)==oldest]
picked=next((row for row in candidates if "Pro Max" in row[0]),candidates[0])
print("id="+picked[2])')"
bash scripts/xctest.sh -l "$A/older-voiceover.log" -- \
  -resultBundlePath "$A/older-voiceover.xcresult" \
  -only-testing:'yuedu appTests/ChapterListOrderVoiceOverTests' \
  -only-testing:'yuedu appTests/BookshelfRowVoiceOverActionsTests'

export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l "$A/synthetic-images-ready.log" -- \
  -resultBundlePath "$A/synthetic-images-ready.xcresult" \
  -only-testing:'yuedu appTests/CoreTextImageBoundaryTests' \
  -only-testing:'yuedu appTests/yuedu_appTests/coreTextPaginatorMakesBlockRenderableImagesTappable()' \
  -only-testing:'yuedu appTests/yuedu_appTests/coreTextThemeUpdateRecolorsImageBlockBackgroundMatchingReaderBackground()' \
  -only-testing:'yuedu appTests/yuedu_appTests/epubBlockBoxReservesPaddingAndMarginsInReflowLayout()'
```

RED命令与对应GREEN使用相同选择器；red-ipad-ui只选择两个静置点击用例。旧runtime选择过程保存在会话命令，实际destination由UDID传入。重跑须改用新run标签／xcresult路径，保留原始证据，不删除旧结果来重用路径。

| run | xcresult实际通过／失败／跳过 | 决定性结论 |
| --- | --- | --- |
| green-unit | 7／0／0 | `** TEST SUCCEEDED **`；Swift Testing为5项、目录含2个参数case，XCTest书架2项 |
| green-ipad-ui | 3／0／0 | `Executed 3 tests, with 0 failures`、`** TEST SUCCEEDED **` |
| iphone-regression | 56／0／3 | 框架声明52项Swift，实际通过49；加4媒体XCTest、3搜索UI；`** TEST SUCCEEDED **` |
| ipad-regression | 58／0／3 | 框架声明55项Swift，实际通过52；加6书架／媒体XCTest；`** TEST SUCCEEDED **` |
| older-voiceover | 3／0／0 | iOS26.2目录／书架动作保留；`** TEST SUCCEEDED **` |
| synthetic-images-ready | 5／0／0 | Unicode图片行、直排装饰块、合成图片点击／重着色及盒模型；`** TEST SUCCEEDED **` |

计数来自`xcrun xcresulttool get test-results summary --path <本轮xcresult> --compact`的passedTests／failedTests／skippedTests，不以框架声明总数抹去跳过；集合有重复，不相加宣称唯一用例总数。

三个跳过为`glossaryCoverChunkDraws`、`theDealLastImageChunkDraws`、`appDefaultsChunksDraw`，它们依赖作者私人机器上的EPUB。没有删除或放宽这些测试；单独补跑的5项自建／既有合成用例无跳过，不能把它们写成原书也已通过。

`ruby scripts/check_localizations.rb`实际退出0：`Localization OK: Resources/*.lproj/Localizable.strings (5 files, 4285 keys)`，Modules／Targets的2972个literal key均有对应文案。本批不新增用户文案或资源键。

交付检查`python3 .artifacts/upstream-small-batch-2026-11-17/check-delivery.py`实际输出`SMALL_BATCH_CHECK_OK docs=7 localLinks=108 swiftFiles=12 greenRuns=6 dependencyChanges=0 stagedFiles=0`：格式／本地链接、命令bash语法、固定来源、xcresult计数与分支／依赖边界均核对。`git diff --check`退出0。检查脚本起初把已有源文件历史尾空格也纳入，核对HEAD与工作区均为5处后改为只查新增文件及diff，不清理无关旧代码。

## 未验证、发布与回滚

- 最低iOS17、真机、实际VoiceOver朗读、后台连续朗读保持、真实源／个人登录及新云IPA／年度自签均未验证。TTS未停止时的引擎保留分支沿上游合同保留，不用媒体空书架fixture冒充实际后台朗读通过。
- ReaderView暂时全屏覆盖与真正拆除、源浏览器横竖媒体退出，在两端既有合成媒体回归通过；它们不等于实际站点或真机实播。
- 新发布必须先形成固定commit，再针对该commit归档并核对自签／人工门槛；旧5ac9b1b9产物不包含本批。未改变S8未完成状态，不监控或触发旧构建。
- 原工作区4份文档修改已在`.artifacts/upstream-small-batch-2026-11-17/preexisting-tracked.patch`备份；用户源包、未跟踪评审与其他资料不清理或纳入提交。
- 本批提交包含7生产文件、5测试文件及6份正式文档，不包含用户原始复审稿。若需撤回，经确认后对本批提交执行对应git revert，保留用户其他工作与资料；不reset／clean、force-push或删除设备数据。
