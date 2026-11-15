# 固定上游首批合入记录（2026-11-15）

## 结果与边界

按用户确认，只合入已评估的前7个上游提交至`dbd25567`。本地分支为`merge/upstream-dbd25567`；不自动Push，不引入后续11个提交、模块格式3.0.2、Z-Library或探索／详情重设计。原评估见[合入价值评估](upstream-cbb9a6a5-assessment.md)。

| 项目 | 固定值 |
| --- | --- |
| 合入前Fork | `a0ff4497ac66330b8008e3e124c360bde3390486`，原分支`fix/review-2026-11-14`保留 |
| 上游共同基线 | `cc566a8433a64ffdd8fe1c50ea7e3d10f885968d` |
| 本批上游目标 | `dbd255672cf14111f7fdeba8ce8c6bc9e64bb3db` |
| 上游新增范围 | `cc566a84..dbd25567`，`git rev-list --count`实际输出`7` |
| 合并方式 | 新分支上`git merge --no-commit --no-ff dbd255672cf14111f7fdeba8ce8c6bc9e64bb3db`，验证后生成本地merge提交 |
| 实际文本冲突 | 仅`Modules/Services/iCloud/ICloudSyncManager.swift`；不是整批18提交 |

`a0ff4497`是Fork合入前HEAD，不是上游提交范围的起点；上游差异起点仍为`cc566a84`。本轮没有fetch/pull，不更新Android基准，不恢复账号、Firebase或收费功能。没有更改工程依赖、版本、签名、CloudKit容器、模块默认开关、RSS生产代码或ADR-0005证书政策。

## 实际改动

### 上游7个连续提交

| commit | 行为 |
| --- | --- |
| `f784bada` | 删除阅读器未使用的第二条预取路径，仍使用共享章节预取 |
| `1d229ba9` | 目录每次body只过滤一次，保留正序／倒序及匹配语义 |
| `469cb801` | iPad双页在章节内配对，重开恢复到原双页组合 |
| `1b50ec9b` | 在线书缺少位置文件时按书架进度打开；漫画缺目录时补取目录，未显示正文前不覆盖同步位置；iCloud恢复后合并文本阅读位置 |
| `780b9bc2` | 同章漫画页码变化也触发元数据写入；离开前景保存当前页，保留debounce及不变不写 |
| `77a172e2` | 分组书架的行滑动菜单优先于外层横向分页，文件夹／行外仍可分页 |
| `dbd25567` | 增加选择模式分页回归，与前一个手势修复配套 |

### Fork必要适配

- iCloud保留`SyncRecord`、`SyncMerge`及既有shadow key；`CloudSyncMerge.swift`不变，不恢复Firestore。`resolveMerge`保留原始本地集合的fingerprint，首次合并的筛选不能掩盖需要写回本地的改变。
- 首次无shadow且**正文版本相同**时，本地进度落后于云端则采用云端位置，不按本地文件较新的保存时间覆盖云端。不同`textVersion`的坐标不可比较，保留已有版本隔离；新增用例先失败，再加版本检查后通过。
- 这仍有已披露的取舍：新设备首次同步前故意翻回较早位置，可能让位于云端较后位置；不能称为无损恢复。有shadow后仍按既有时间／变更规则合并。
- 上游新书架UI种子原来覆盖默认`books_meta.json`。改为显式`-shelf-test-dir`的临时目录；未提供隔离目录时拒绝写种子。两个书架UI suite移除已不存在的StoreKit测试配置及自动应答系统权限的代码，不恢复收费体系。
- 目录请求失败的新增日志只记录错误类型，避免记录可能带私有URL或脚本结果的异常原文。
- 两项新增漫画目录测试改为观察加载／错误事件，不用sleep等待状态稳定。
- RSS真实布局测试在各条目观察`ReadyImages`，不在懒父容器聚合后观察；原图片、认证、几何及瀑布流条件均保留，未放宽超时或断言，未修改生产RSS实现。

## 原始失败与对照

1. **漫画同章快速翻页落盘**：合并前运行`UpstreamMangaPersistenceRegressionTests`，1项失败；重载后`mangaPage`实际为`0`，期望`5`。日志`.git/merge-dbd-manga-red.log`。合并后同一测试在核心集合中通过，证明不是只检查存档字段。
2. **不同正文版本首次同步**：直接采用上游首次偏向云端的政策时，`ReadingPositionSyncTests/firstSyncKeepsDifferentTextVersionsApart()`1项失败、2个断言错误，本地版本2的位置被云端版本1覆盖。日志`.git/merge-dbd-text-version-red.log`。补版本检查后的阅读位置／漫画／源收敛集合18项通过。
3. **RSS测试信号遗漏**：补充集合和独立suite曾出现样式3／4超时，不能把首次失败删除后只报成功。诊断中同一失败样式四次图片请求、四次图片加载完成、运行时队列`0`，但父容器没有收到最后一次`ReadyImages`通知；日志`.git/merge-dbd-rss-flow-probe.log`。合入前HEAD单次对照通过，不能据此排除既有间歇问题。把观察点下移到各条目后，移除全部临时诊断代码，原42项集合通过；这里修正的是测试观察信号，不宣称修复了生产图片请求或R146实图。

临时诊断日志与xcresult仅在`.git/`本地保存，不提交，不复制真实源包或私人请求配置。

## 执行环境与命令

实际环境：Xcode27.2（27B52）、iOS27.2 Simulator；iPhone18 Pro Max与iPad Pro13-inch（M5）。均由`scripts/sim.sh`按调用时环境解析，不按名称硬编码destination。`doctor`只有iOS26.2／27.2 runtime，没有iOS17；日志`.git/merge-dbd-doctor.log`。正常`Reader-Fork-Dev`scheme、既有DerivedData、串行测试，没有clean、新DerivedData或擦除模拟器。

公共准备：

```bash
bash scripts/sim.sh doctor
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
```

以下为实际运行的相关集合；集合间有重复用例，不相加宣称独立用例总数。

```bash
bash scripts/xctest.sh -l .git/merge-dbd-core.log -- \
  -resultBundlePath .git/merge-dbd-core.xcresult \
  -only-testing:'yuedu appTests/UpstreamMangaPersistenceRegressionTests' \
  -only-testing:'yuedu appTests/ReadingPositionSyncTests' \
  -only-testing:'yuedu appTests/ReaderTOCFilterTests' \
  -only-testing:'yuedu appTests/OnlineShelfProgressOpeningTests' \
  -only-testing:'yuedu appTests/SpreadRestoreStabilityTests' \
  -only-testing:'yuedu appTests/ChapterPrefetchWindowTests' \
  -only-testing:'yuedu appTests/RefreshedChapterURLPrefetchTests' \
  -only-testing:'yuedu appTests/FixedPagePositionSaveTests' \
  -only-testing:'yuedu appTests/ICloudSyncShadowCommitTests' \
  -only-testing:'yuedu appTests/ICloudSyncChangeDetectionTests'

bash scripts/xctest.sh -l .git/merge-dbd-position-green.log -- \
  -resultBundlePath .git/merge-dbd-position-green.xcresult \
  -only-testing:'yuedu appTests/ReadingPositionSyncTests' \
  -only-testing:'yuedu appTests/FixedPagePositionSaveTests' \
  -only-testing:'yuedu appTests/ICloudSourceSyncConvergenceTests'

bash scripts/xctest.sh -l .git/merge-dbd-shelf-ui.log -- \
  -resultBundlePath .git/merge-dbd-shelf-ui.xcresult \
  -only-testing:'yuedu appUITests/BookshelfRowSwipeUITests' \
  -only-testing:'yuedu appUITests/BookshelfGroupsUITests/testSwipingPagesBetweenGroups'

bash scripts/xctest.sh -l .git/merge-dbd-fork-boundary-final.log -- \
  -resultBundlePath .git/merge-dbd-fork-boundary-final.xcresult \
  -only-testing:'yuedu appTests/ReaderViewModelChapterStateTests' \
  -only-testing:'yuedu appTests/AuthAndICloudConfigurationTests' \
  -only-testing:'yuedu appTests/ForkBuiltinModulesDefaultsTests' \
  -only-testing:'yuedu appTests/RootTabCustomizationTests' \
  -only-testing:'yuedu appTests/ReviewRSSPresentationTests' \
  -only-testing:'yuedu appTests/RSSImageServiceTests'

export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
bash scripts/xctest.sh -l .git/merge-dbd-ipad.log -- \
  -resultBundlePath .git/merge-dbd-ipad.xcresult \
  -only-testing:'yuedu appTests/SpreadRestoreStabilityTests' \
  -only-testing:'yuedu appTests/iPadReaderAdaptationTests'

export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l .git/merge-dbd-toc-failure-final.log -- \
  -resultBundlePath .git/merge-dbd-toc-failure-final.xcresult \
  -only-testing:'yuedu appTests/FixedPagePositionSaveTests/blankReaderSavesNothing()'
```

| 检查 | 实际决定性输出 |
| --- | --- |
| 核心集合 | `✔ Test run with 40 tests in 10 suites passed`、`** TEST SUCCEEDED **` |
| 版本隔离／同步／漫画集合 | `✔ Test run with 18 tests in 3 suites passed`、`** TEST SUCCEEDED **` |
| 书架UI | `Executed 9 tests, with 0 failures (0 unexpected)`、`** TEST SUCCEEDED **` |
| 清除诊断后的Fork边界集合 | `✔ Test run with 42 tests in 6 suites passed`、`** TEST SUCCEEDED **` |
| iPad双页与恢复 | `✔ Test run with 8 tests in 2 suites passed`、`** TEST SUCCEEDED **` |
| 日志适配后目录失败不覆盖位置 | `✔ Test run with 1 test in 1 suite passed`、`** TEST SUCCEEDED **` |
| 五语言资源 | `ruby scripts/check_localizations.rb`：主资源5文件4267键，Modules／Targets使用2954个literal key均有对应文案 |
| 文档格式与链接 | 4份相关Markdown为UTF-8／LF且有末尾换行，63个本地相对链接目标存在 |
| 差异格式 | `git diff --check HEAD`退出0，无输出；未发现临时`DEBUG-upstream-rss`代码 |

目录日志适配后另一次命令选择了不存在的失败测试名和正确的成功测试名，实际只执行成功恢复1项，不把它报成2项；失败分支已用上表的`blankReaderSavesNothing()`单独补验。

UI前后比较默认书架文件SHA-256：`Library/Application Support/books_meta.json`均为`4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945`，旧Documents文件均不存在；`cmp`确认一致。日志`.git/merge-dbd-shelf-{before,after}.sha256`，没有自动清除设备数据或接受权限。

文档链接、UTF-8／LF格式和`git diff --check`作为收尾检查；原始源包、用户已有评审资料、`.codegraph/`、`.workbuddy/`、`__pycache__/`不加入提交。

## 未验证与回滚

- 本批不跑公网源、真实iCloud双设备／恢复、WebDAV完整回归、R146新证书政策实图、真实登录、真机媒体、人工VoiceOver、最低iOS17、正式签名或发布。配置／合并fixture通过不能代替这些验收。
- S8继续是“自动回归已有证据、人工待验”，没有标为阶段完成；既有未闭合项见[发布收口清单](s8-release-checklist.md)和[评审修复记录](review-repair-2026-11-14.md)。
- 书架手势依赖SwiftUI的UIKit容器结构；当前iPhone27.2的9项交互通过，不外推最低系统或未来系统。
- 本批只确认目录过滤避免每行重复扫描，不给出真实大书库性能或内存提升结论。
- 本地合并提交的第一父提交为`a0ff4497`、第二父提交为固定`dbd25567`。原`fix/review-2026-11-14`保留合入前版本；干净工作区可切回该分支查看，不删除数据。需要正式撤回时，经确认对本次merge执行`git revert -m 1 <本次merge提交>`，不reset、force-push或清理模拟器。
- 高风险iCloud文件合并前备份在`.git/merge-dbd25567-backup.lrggXi/`；仅本地保留，不把备份或测试捕获作为分发内容。
