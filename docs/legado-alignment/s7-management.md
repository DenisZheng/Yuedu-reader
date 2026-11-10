# S7：独立入口、源管理与版本化备份

S7 本地自动门槛通过；这不代表发布验收通过。前置 S6 提交为 `5e6e06e2`。用户已确认真机视频画面和声音正常，并要求暂停真机测试、按阶段提交后继续 S8；本阶段没有连接手机、改签名或触发云归档。

## 实现与边界

- 默认五 Tab：探索｜书架｜订阅｜资源库｜设置。`RSSTabRoot` 承载根模式的 `RSSListView`；资源库推入同一业务页面、使用同一 `RSSStore`，推入时仍为 inline 标题。定制清单、主题写回、Onboarding、设计白名单和两份设计 skill 同步更新。
- 搜索从探索和书架的放大镜进入。将“统一作品搜索”从旧 Tab 标题/导航标志中分离，保留书源、书架、远端/公有书库的原有搜索管道。搜索结果进入详情后返回仍保留结果，源指定范围搜索不被扩大。
- 规则源的长按菜单进入“来源设置”：已有行为开关、Legado JSON 全字段编辑、登录、源变量和可视化调试。JSON 编解码离开主线程；解析复用导入解析器，保存保留本地 source.id，检查同址冲突和编辑期间修订，并等待落盘结果。读取失败的变量文件不显示成可保存的空值、不覆盖原文件。
- 调试直接调用生产分类、列表、正文分页用例，不另写请求或解析器，也不持久化调试产生的文章。输出字段是否有值、计数、分页目标和结果类别；规则/脚本原文不进诊断，URL 去除 userinfo/query/fragment/options，异常只显示固定类别。重新开始/取消的旧任务不能追加结果或结束新任务。
- WebDAV 分类：书源、书架、替换规则、RSS。新版本位于 `/readerfork-dev/backups/<UTC时间-设备摘要-随机后缀>/`，独立目录必须由服务器返回 201，不能覆写已有目录；各分类文件完成后最后写 manifest。历史最多检查最近 50 个目录，缺少/损坏 manifest 的版本不列出，认证/网络错误不伪装为空。
- manifest 记录格式版本、分类白名单、大小及 SHA-256；恢复先下载、校验内容和空间，再修改本机。网络字节读取复用 `SourceRequestExecutor` 的流式上限与取消能力：目录响应 1 MiB、manifest 64 KiB、分类不超过声明大小及 64 MiB。WebDAV 不读写 RSS CookieStore，不跨 origin 传递 Basic 凭据。畸形 XML 明确失败，禁用外部实体。
- 恢复前保留精确本地文件副本。文件写入错误回滚已写分类，RSS 使用其 owner 保留的完整正文/链接/变量/状态回滚，而不是用去敏、有损的云快照回滚。回滚再次失败会明确报错，原副本不删除。旧 `/yuedu/` 覆盖写入 UI 已撤掉；S3 `/readerfork-dev/rss-v1.json` 传输接口保留，不做 Android 整包互通。

## 可失败反馈

| 证据 | 原始失败与修正 |
| --- | --- |
| `/tmp/readerfork-s7-gate-iPad/s7.xcresult` | iPad 根 Tab 是系统顶部按钮而非 `XCUIElementTypeTabBar`，10 项 UI 定位失败；按实际可访问性树调整测试，不改产品布局。 |
| `/tmp/readerfork-s7-ipad-back2.log` | 屏幕左边缘手势展开 iPad 系统侧边栏，没有 pop；iPhone 继续验边缘返回，iPad 验原生返回按钮。 |
| `/tmp/readerfork-s7-unified.pMEOid/tests.xcresult`、`/tmp/readerfork-s7-focused.N7afQd/tests.xcresult` | 统一搜索与 Tab 标志解绑；Gutenberg 固定响应真实搜索→详情→返回，两设备执行成功，不以“出现输入框”代替搜索能力。 |
| `/tmp/readerfork-s7-safety-red.nfqzNN/tests.xcresult` | 2 项测试产生 6 个问题：诊断泄露规则/异常原文、重启调试旧任务串日志，以及其他分类失败后误用云快照回滚导致 RSS 正文/链接/变量丢失。 |
| `/tmp/readerfork-s7-safety-green.fkhIzm/tests.xcresult` | 上述失败闭环及 RSS 第四个文件写入失败后的真实 owner/磁盘回滚通过。 |
| `/tmp/readerfork-s7-final-focused.s7HUUv/tests.xcresult` | 13 项：包含变量文件损坏、取消、空间不足、checksum、未知版本、路径越界、精确恢复和 AX 元素回归。 |

## 最终门槛

环境：`Reader-Fork-Dev`；`scripts/sim.sh` 动态选择当前 Xcode、SDK、iPhone/iPad，iOS 27.2 runtime 24B8117。

```bash
# 分别运行，两次不能共用 resultBundlePath，也不并行争用模拟器。
YUEDU_EVIDENCE_DIR=<新目录>/iPhone bash scripts/validate_reader_fork_s7.sh
YUEDU_DEST="$(bash scripts/sim.sh dest iPad)" \
  YUEDU_EVIDENCE_DIR=<新目录>/iPad bash scripts/validate_reader_fork_s7.sh
ruby scripts/check_localizations.rb
git diff --check
```

最终证据：`/tmp/readerfork-s7-final-gates.AFHzp6/{iPhone,iPad}/`。

| 两设备分别执行 | 数量 | 结果 |
| --- | --- | --- |
| S5 回归 | 268 / 38 suites | 零失败、零跳过 |
| S6 网页/资源/媒体专项 | 97 / 19 suites | 零失败、零跳过 |
| S7 专项 | 63 / 14 suites（49 单元/集成 + 14 UI） | 零失败、零跳过 |

脚本核对 xcresult 最终结果、非零数量及每个 suite 实际执行。上述集合可能包含历史重叠用例，不据此宣称独立覆盖数。本地化 4108 keys 通过；固定源包 SHA-256 未变，`git diff --check` 通过。没有额外 build/clean 或新建 DerivedData 绕过失败。

## 未验证与发布限制

- iOS 17 runtime、真人 VoiceOver 使用、真实 WebDAV 服务、正式签名 iCloud/App Group 不在本阶段证据范围；当前没有这些环境，不标通过。
- WebDAV 自动回滚覆盖可捕获的下载/校验/空间/取消/文件写入异常。**跨文件恢复不是进程崩溃原子事务**：若系统在多文件替换中终止进程，需要从 `Library/webdav-restore-backups/<UUID>/`、`Library/rss-restore-backups/<UUID>/` 保留的原文件恢复；未做强制杀进程自动恢复实验，列为 S8 发布限制。
- 来源设置的单位/集成测试验证数据结果，AX 检查不等于真人全程编辑/登录走查；调试目前侧重规则源列表/正文，资源层详细事件仍从现有诊断入口查看。
- 不宣称每个真实源均可运行，也不扩大 DRM、后台播放或外部播放器支持。

## 回滚

撤回 S7 提交及相应 UI/测试/五语文案即可回到前置入口；不要删除本地 RSS 配置、正文或状态。新建的远端版本保持不动，不重新启用会覆盖原版 `/yuedu/` 的写入。若恢复过程中发生不可恢复的磁盘故障，先保留并核对上述恢复前副本，不能以重新同步代替诊断。
