# 2026-11-14评审修复记录（截至2026-11-15）

对应[原评审](review-2026-11-14.md)。原报告保留原样；本记录不把历史问题、自动测试或人工待验项目改写为全面验收通过。

## 修复范围

| 问题 | 本轮处理 |
| --- | --- |
| P0-1 固定上游整合 | 在`fix/review-2026-11-14`整合固定`cc566a84`，28处冲突已解决；保留Fork身份、免费本地能力与RSS状态。合并未提交/未推送 |
| P0-2 深链/空书源/下载限额 | 系统及两浏览器宿主统一分流进入RSS预览；空bookSourceUrl不进入书源库；共享有界下载与取消保护；[YCK205真实按钮入口](yck205-online-import.md)预览36项、0错误 |
| P1-2 字段宽容化 | 对照固定Legado Gson合同转换字符串/数字/Boolean字段，保留sourceKey；修正数量进入真实比较预览 |
| P1-3 scheme取舍 | 继续不争用原版scheme；粘贴导入链接经统一分流，不宣称Safari能直接唤起未注册scheme |
| P1-4/5 列表与图片 | 0列表、1大图、2两列、3分列瀑布流、4三列；辅助字号单列。实际条目视图截图与布局已验证；缩略图走唯一RSSImageService，源请求头/文章变量/coverDecodeJs已执行验证 |
| 图片上下文补修 | 字节求值没有经过ModernRuleEngine.jsEvaluator，显式传递本次runtimeRuleBindings，防止rssArticle在图片解码时缺失 |
| P1-6 身份与上游资源 | UA改ReaderForkDev；用户后续选择默认停用六插件与两公库，内置青空快照已撤回；默认不自动请求，手动启用路径保留，见[默认策略](builtin-modules-defaults.md) |
| P1-7 java覆盖 | 两包只读静态扫描并核查RSS shim，见[脱敏统计](java-static-audit.md)；不是所有源可用证明，不盲目开放addBook/文件/系统能力 |
| P2-1 全量撤销 | 源级配置修订与全局导入计划修订分开；发现地址/排序不撤销请求，配置/变量只撤销相关源；整库替换/恢复仍撤销全部。源A变更期间源B真实在途请求正常完成、1次请求 |
| P2-2 备份 | 用户界面明示原始规则/URL/脚本可能含凭据、只备份到可信服务器；不破坏sourceKey或伪称源配置完全脱敏 |
| P2-3 导入资源 | 分块有界接收代替逐字节追加；嵌套集合URL拒绝localhost/字面私网，保留顶层用户主动输入的本地URL取舍 |
| P2-4 后台残留 | 删除已获授权的5项Firebase根配置、functions/、aozora发布workflow；本地备份`.git/review-backend-backup.tNJD9L`。未删除gateway或其他workflow，未改部署 |
| P2-5 源说明/历史字段 | 来源说明以原生纯文本显示。固定Android原生RSS路径的enableReadRecord检索只命中RssSource实体；不把它擅自变成禁用已读/滚动/媒体进度的开关 |
| P2-6 分页差异 | 继续以整批isSubset判断重复，而非只看首尾；部分重叠可能多取一页，不是漏内容修复，保守差异保留 |

证书政策已按用户后续决定调整为[ADR-0005](../adr/0005-app-wide-server-trust.md)的App可控制连接接受无效服务器证书。该决定不降低TLS协议下限、不代表系统控制连接全部采用该策略；没有接受测试结束自动擦除模拟器。

## 当前行为证据

环境由`scripts/sim.sh doctor`解析：Xcode所选模拟器SDK iOS27.2，iPhone18ProMax/iOS27.2；不代表iOS17或真机通过。

- `.git/review-core-fixes.log`：67 tests/9 suites通过，含导入修正、307实包、源修订并发、状态/浏览/图片回归。
- `.git/review-actual-row-test.log`：2 tests/1 suite通过，包含0–4五个参数用例与AX单列。6份实际条目截图在`.git/review-actual-row.xcresult`，已导出本地检查；不是纯字段判断。
- `.git/review-thumbnail-green.log`：1 test/1 suite通过，源头与Referer到达网络、文章标题/变量参与coverDecodeJs，图片原生解码；Retina尺寸误差已通过固定fixture像素比例修正。
- `.git/review-source-note-test.log`：1 test/1 suite通过，后台Vision识别本地原生页截图确认说明可见；不使用远端OCR或修改系统权限。
- `.git/review-ua-green.log`：1 test/1 suite通过，实际请求、session默认header和Readium请求UA一致。
- `.git/review-aozora-resource-green.log`的10项为已撤回快照的历史测试，不代表当前默认。新策略`.git/review-builtin-regression-green.log`7 tests/3 suites通过，默认停用、手动恢复与重启保持。
- `python3 -m unittest scripts/tests/test_source_java_audit.py`：4 tests，OK；构建目录生成器7 tests为已撤回方案的历史证据。
- `ruby scripts/check_localizations.rb`：5语种4267 keys与2954个literal keys校验通过；`git diff --check`实际执行exit0。

失败日志仍保留本地：早期导入fixture错误、图片rssArticle上下文缺失、尺寸/网格布局错误、UA旧身份与目录在线依赖的red记录。一次选错Swift Testing方法标识导致0项测试，wrapper已判失败；没有把该次`TEST SUCCEEDED`当成通过。

## 未闭合与新增回报

最终定向回归：`.git/review-final-focused-green.log`68 tests/11 suites通过；`.git/review-final-defaults.log`8 tests/3 suites通过；YCK205真实网页入口1项通过、0失败0跳过，预览新增36项0错误。新布局测试曾因较旧SwiftUI偏好覆盖已完成图片状态超时，截图证明图片已经显示；固定输入完成信号改为累积，未增加sleep或绕过真实解码。

1. S8继续是“自动回归通过、人工待验”。iframe真实播放、受限真人登录、iOS17、正式签名/iCloud/App Group、DRM和人工VoiceOver等仍未闭合；不生成阶段完成或发布批准。
2. R146旧TLS失败保留；新政策后的真实图片仍待单独公网预算复验，不能宣称源站证书链已修复。
3. 用户新增YCK205空预览问题已按真实按钮→确认→预览闭合，见[记录](yck205-online-import.md)；没有自动保存/刷新36个实源，不宣称所有规则可用。
4. 未做全项目、全源、全媒体或全部许可审查；用户已授权记录后提交并Push修复分支，真实源包与本地捕获保持未入库。

回滚：使用合并前保存在`.git/review-repair.*`的基线与获授权后台清理备份，按改动块人工恢复；不自动merge abort/reset、不删除用户数据。新RSS可选字段保持读取兼容；恢复旧客户端前保留RSS文件。内置模块可从设置手动启用；撤回默认策略不删除有效缓存、模块文件或自建数据。
