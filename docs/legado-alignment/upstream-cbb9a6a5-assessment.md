# 固定上游 cbb9a6a5 合入价值评估（2026-11-15）

## 判断

**值得小步跟进稳定性修复，不建议为了模块格式3.0.2立即整批合入18个提交。** 首选先合入前7个提交至`dbd25567`，验证后再取独立无障碍/自动阅读修复；模块能力与探索/详情重设计单独安排。用户当前不用内置插件，新格式不是RSS交付的紧急前置条件。

以下评估记录的是授权合并前的只读分析：当时没有fetch/pull、切换分支、真实merge/cherry-pick、提交或Push，也没有运行上游测试，不能据此认为上游改动已通过验收。用户后续确认只合入前7提交至`dbd25567`，实际改动、失败对照和验证见[首批合入记录](upstream-dbd25567-integration.md)；其余11提交仍未合入。

## 固定边界和规模

| 项目 | 实测 |
| --- | --- |
| Fork当前HEAD | `a0ff4497ac66330b8008e3e124c360bde3390486`，分支`fix/review-2026-11-14` |
| 已整合上游／共同基线 | `cc566a8433a64ffdd8fe1c50ea7e3d10f885968d` |
| 评估目标 | 本地已有`cbb9a6a5` commit对象，没有更新远端引用 |
| 新提交数 | `git rev-list --count cc566a84..cbb9a6a5` → `18` |
| 完整范围 | 220 files，+12337/−2499 |
| 前7提交范围 | `cc566a84..dbd25567`：33 files，+1322/−701 |
| 最后一个提交 | `cbb9a6a5`自身124 files，+5013/−555，不是孤立schema补丁 |
| RSS服务／运行时 | `Modules/Services/RSS/`零文件改变 |
| RSS界面 | 仅`RSSFeedView`一行改为`.hidesRootTabBar(hasBottomBar: true)` |
| 共享规则层 | `RuleListMapping.swift` +41/−10，新增模块id/volumes和无链接卷项，不能说整个共享解析层零改动 |
| 依赖/工程 | 未改Packages、Package.resolved、project.pbxproj或scheme；版本配置变为3.0.2/build1 |
| 新素材 | 13项JPEG合计400092字节，仍需按来源说明逐文件确认分发许可 |

因此“无RSS核心改动”基本成立，但不等于“RSS零回归风险”：隐藏Tab的共享实现、解析映射、持久化与导航有间接影响。

## 值得优先跟进的提交

### 第一批：稳定性与数据保护（前7个，保持上游连续祖先）

| commit | 作用 | 价值/重点 |
| --- | --- | --- |
| `f784bada` | 删除阅读器第二条未使用预取路径 | 收敛重复实现、减少未来维护；验证实际共享预取与过期URL刷新不回归 |
| `1d229ba9` | 目录过滤每次body只计算一次 | 避免每行重扫长目录的放大开销；验证匹配次数与目录正倒序 |
| `469cb801` | iPad双页按章节配对 | 修复重开落在另一组双页；验证跨章节边界与恢复稳定性 |
| `1b50ec9b` | 重装／恢复后在线书按同步进度打开 | 防止位置文件晚到时先开第1章、再把同步位置覆盖；**数据风险高，必须人工适配Fork的iCloud合同** |
| `780b9bc2` | 漫画同章页码变化触发元数据写入 | 防止刚翻页就退出后进度丢失，保留既有debounce与不变不写 |
| `77a172e2` | 分组书架行滑动与分页手势仲裁 | 修复置顶/删除菜单无法打开；要区分横向分页、行滑动和选择模式 |
| `dbd25567` | 补选择模式分页回归 | 与前一个配套，不单独拿行为改动而省掉验证 |

### 第二批：可独立评估的修复

- `68e2c544`：目录排序按钮的VoiceOver值，单文件改动，收益明确。
- `a4df38b6`：iOS27书架不重复宣告系统已有滑动动作；低版本仍保留手动无障碍动作，带专项测试。
- `5a0ec0fd` + `9657149a`：自动阅读闪回旧页与仿真揭页，两个提交配套拿，不只取最后一项。
- `c83143ba`：AI人物抽取拒绝原因更具体，用户配置AI时有价值，不是RSS前置。
- `9331800c`：书源调试日志复制便利，但复制完整summary/detail前要确认脱敏，不能恢复未经处理的URL query、正文或异常原文导出。
- `2acbe102`：阅读设置完整导出，功能有用但涉及17个文件与导入/持久化合同，单独验证，不当作无风险文案升级。

第二批使用选定提交时先查依赖，不把隔开的commit都当成可直接cherry-pick。后续整合仍保持固定目标，不追浮动upstream/main。

### 第三批：功能／产品变化，暂不作为跟进理由

- `fe4c28d8`：去掉首页顶部轮播图，保留其列表；这是上游产品选择，不是Fork必须接受的bug修复。
- `3f99738b`：封面色详情hero与统一目录，30个文件，包含视觉/导航变化。
- `40d74169`：模块评论、作者页、书架题材，41个文件；新增站点请求与详情层状态。
- `cbb9a6a5`：Apple Books式首页、系列页及3.0.2格式，124个文件，还加入Z-Library模块与新素材。不能仅为格式兼容把整套重设计视为必要修补。

## 模块格式不是“只升级版本号”

新增合同横跨validator/model/client/provider/UI/cache：

- 3.0.1：reviews、列表id/volumes、searchesAuthors。
- 3.0.2：icon、globalParams、顶层detail、related、genre、参数belongTo/placeholders。
- globalParams由RuleModuleLibrary保存用户选择，再进入请求和缓存key。
- 评论/详情/相关作品会在打开作品详情时触发额外请求，仍需核查模块启用、hosts/redirect、缓存和取消。

上游实现继续不执行模块JS，并在validator限制模板名、参数循环与图标hosts，client复用send；这是积极点，但本轮未执行其安全或兼容测试。

当前Fork显式`requiredVersion=3.0.2`模块会被3.0.1版本检查拒绝；这是诚实的不支持，不是RSS故障。当前3.0.1 App版本也不表示已经支持新定义的全部3.0.1字段。**不能只提升MARKETING_VERSION或只放宽validator**，否则可能接受了新字段却不执行它们。若日后需要导入新模块，应该成套引入格式、请求、缓存、UI和行为测试，但没有必要同时启用内置站点。

## 完整合并的实际风险

### 只读预演

```bash
git merge-tree --write-tree --name-only HEAD cbb9a6a5
git merge-tree --write-tree --name-only HEAD dbd25567
```

两命令exit1表示存在冲突；只生成Git对象，不修改index/worktree，也没有MERGE_HEAD。

- 完整18提交：12个冲突路径，其中5个是本地化，其余为BookDetailComponents、AIRecommendationRow、ExploreHome、FeedbackThreadView、RuleModuleLibrary、ICloudSyncManager、Components。
- 前7提交：仅ICloudSyncManager 1个冲突路径。
- 日志仅保留本地：`.git/upstream-cbb9a6a5-merge-tree.txt`、`.git/upstream-first-seven-merge-tree.txt`。

**无文本冲突不等于语义兼容，预演不是构建通过。**

### 必须保持的Fork决策

1. **新Z-Library不能自动启用。** 当前`ruleModules.forkBuiltinDefaults.v1`只首次合并disabled集合；已执行该迁移的安装不会把新ID自动加入disabled。如果引入新文件又保持现逻辑，后续发布过滤只检查disabled，新插件可变成默认启用。必须先覆盖“旧安装升级出现新内置插件”的用例；不需要该插件时建议Fork不随包新增它，格式支持可单独保留。
2. **内置六插件／两公库的默认停用与手动启用保持。** 不覆盖disabled、hiddenInLibrary或自建模块；globalValues与停用是不同域。
3. **iCloud适配到本地合并实现，不恢复Firestore。** Fork已把同步模型移至CloudSyncMerge.swift。新首次同步偏向云端进度的政策必须使用Fork的SyncRecord/SyncMerge/旧shadow key，FeedbackThreadView继续保持删除，不能接受上游版本来消冲突。
4. **进度政策有明确代价。** 上游首次无shadow时，若本地位置落后于云端则偏向云端，不看本地时间；新设备首次同步前故意向前翻回较早位置可能丢失这次后退，应确认这项取舍而非宣称无损恢复。
5. **五Tab与RSS行为保持。** 探索｜书架｜订阅｜资源库｜设置；根标题白名单、RSS0–4布局、图片认证上下文、源级修订、两浏览器统一导入均保留。共享Tab过渡改变要覆盖订阅入口和文章返回，不能只验证上游四/五Tab结构。
6. **不恢复账号、后台、付费入口，不更改ADR-0005。** 本轮用户只问合入价值，不授权收窄/扩大证书政策、恢复后台或更改发布门禁。

## 合入时的最小验证范围（计划，尚未运行）

第一批重点：ReaderTOCFilterTests、SpreadRestoreStabilityTests、OnlineShelfProgressOpeningTests、ReadingPositionSyncTests、FixedPagePositionSaveTests、ChapterPrefetchWindowTests/RefreshedChapterURLPrefetchTests、BookshelfRowSwipeUITests与选择模式分页；加Fork已有iCloud同步/影子与不变不写回归。不用新DerivedData或clean绕过问题。

第二批按实际选取增加ChapterListOrderVoiceOverTests、BookshelfRowVoiceOverActionsTests、AutoReadControllerTests、ReaderSettingsExportTests与设置往返。不运行未选择功能的全量UI。

若整合第三批：ModuleFormat302Tests、ModuleReviewsTests、ModuleFormatDocumentationTests、旧3.0模块往返、globalParams缓存失效、hosts/redirect/禁JS/参数循环、旧安装新增插件默认停用、自建模块保留、详情额外请求取消、HomeDefaultsStoreMigrationTests；并保留RSS导入/布局/返回小回归。新图片另做许可核查。

所有批次都运行本地化、文档链接与git diff --check。最低iOS17、真机、真实站点登录、R146新TLS策略实图、S8人工／发布验收仍按既定清单，不能借上游合入自动标为通过。

## 本轮核查结果

- 固定commit范围和文件统计、两个merge-tree预演实际执行。
- 工作区没有tracked文件修改，保留用户已有未跟踪review、源包与工具目录。
- 没有运行新上游编译／测试，没有真实合并；后续授权合入前不宣称这些提交可直接发布。
