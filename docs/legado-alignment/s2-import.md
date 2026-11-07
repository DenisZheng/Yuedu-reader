# S2：导入和源配置保真

## 交付边界

S2仅负责配置识别、比较、确认、保存、导出及独立的首次刷新结果，不宣称源脚本、分类/正文/媒体行为已对齐。原始 `sourceUrl` 是 `sourceKey`，不因HTTP升级、重定向、Feed发现或缺名称而改写。求得的标准Feed地址单独保存在 `resolvedFeedURL`，Legado请求仍以原始key/规则为准。

### 一个导入用例

`RSSImportService` 的输入为文件、数据或远程包；`RSSImportSession`管理确认、保存、重试与刷新；`RSSStore`仍是唯一持久化owner。RSS页面的本地文件、URL与Share/Open-In都进入同一个确认sheet，不在View里编排JSON→写盘→抓取。

- 数组和单对象均可识别；`sourceUrls`按顺序展开。坏项单独报告，合法项仍可选。
- 同批相同原始key首项优先，后项明确标重复，不偷偷覆盖。
- 缺名称使用URL host或key摘要，不把query、URL options、登录账密或脚本当显示名。
- 外包 `_id`只作为未知配置保留，不能指定本地source.id。
- 已存在同key源更新时保留本地id、名称、分组、enabled、排序、自定义普通Feed规则和通知设置；规则与其他源配置更新。确认页显示新增/更新/跳过/错误与配置变更数量、未知字段数量。
- 预览取消不写盘。比较期间本地集合修改使计划失效，必须重新比较；不拿旧快照覆盖用户后来的修改或复活删除项。

### 配置字段

`RSSSource`新增可选配置字段，使Fork已有JSON可继续解码；`configurationVersion=1`标记本轮导入。`RSSContentType`是独立整数域，可保留未知整数，不能与BookSource类型互换。

新增承载：`type`、`startHtml/startStyle/startJs`、`nextContentUrl`、`searchUrl`、`variable`、`preloadJs/preload`、`cacheFirst`、`showWebLog`、`enableReadRecord`。已有规则、登录、样式及请求字段继续沿原属性持有。已知字段验证类型，不把布尔数值或对象静默转换成字符串。

未知字段和显式nullable null以规范JSON `Data`存入 `preservedLegadoFields`，支持嵌套数组、对象、大整数、布尔和null；已知非null字段不再保存第二份副本。导出以模型为准并合回未知值。数据持有和导出保真不代表对应运行功能可用。

### 下载与展开预算

- 每份解码后响应8 MiB，总计24 MiB，最多32个不同包URL、4层嵌套、2000项（另允许1条达到预算的报告）。
- 每份下载请求20秒、资源40秒，最多4次HTTP重定向；不允许HTTPS降为HTTP或URL内嵌账密。URLSession流式读取，在解压后累计字节，超限立即取消。
- 导入包下载使用无CookieJar、无凭据存储、无缓存的临时session，不执行源headers/JS、不打开登录页面、不改变TLS/ATS。
- 去环只作用于包下载URL（去fragment），**从不用于源key**。
- Share通用URL尚未识别文件类型时，使用既有书源512 MiB上限；识别为RSS后仍受上述RSS预算约束。它不是任意大包或登录下载入口。

### 保存与首次刷新

保存确认等待真实磁盘完成，首次刷新是保存后的单独按钮。刷新失败/取消不撤销已保存配置；没有可刷新的列表、取消、部分失败和成功分别显示。复用 `RSSFeedRefreshService`的指定sourceIDs入口，不另写刷新请求循环。列表元数据回填仅针对已启用的普通Feed，不能因导入后进入列表而执行Legado脚本。

为保证大包导入不卡主线程且不伪报成功，`RSSStore`写入改为后台编码/原子写入，按dirty files合并并保留串行顺序；刷新batch在边界等待落盘。写失败不计writeCounts，保留dirty失败并提供重试；读取损坏的文件不会被空状态覆盖。新任务有有限系统后台时间，不阻塞主线程。启动时原有load架构尚未整体改写。

## 已执行证据

环境：动态解析Xcode27.2、iOS26.2模拟器；未使用新的DerivedData。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 原始缺名/字段/外部id故障 | 3项、18个失败断言，已复现后修正 | `/tmp/readerfork-s2-fidelity-red.xcresult` |
| 307项原包实际导入→磁盘重载→导出逐字段比对 | 307项、39类输入字段、0差异、0请求/脚本执行 | `RSSRealPackImportTests`，纳入下面阶段入口 |
| iPhone最终S2合同+UI | 101通过，0失败/0跳过 | `/tmp/readerfork-s2-final-iphone/tests.xcresult` |
| iPad最终S2合同 | 99通过，0失败/0跳过 | `/tmp/readerfork-s2-final-ipad-split/tests.xcresult` |
| iPad最终真实确认/取消/重导/最大Dynamic Type UI | 2通过，0失败/0跳过 | `/tmp/readerfork-s2-final-ipad-split/ui.xcresult` |
| 五语言、脚本语法、diff | 已执行通过 | `ruby scripts/check_localizations.rb`、`bash -n`、`git diff --check` |

复现命令：

```bash
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s2-acceptance bash scripts/validate_reader_fork_s2.sh
export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s2-ipad bash scripts/validate_reader_fork_s2.sh
```

入口包含99项单元/宿主行为和2项真实UI，必须全部执行且不允许skip。全包审计从工作区原文件读取，不进入测试资源或提交；未对真实源发请求。输入SHA-256保持 `0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45`。

测量记录：307项比较、JSON处理和磁盘写入的trace均在 `main=false`；首次导入配置文件写1次，重导307项全为unchanged且不写。不是全App性能达标结论。

## 失败和未验证项（不得省略）

- 临时session不继承全局URLProtocol注册，最初网络测试走到外网TLS失败；改用真实loopback合成HTTP验证，不向生产session强塞测试协议。
- 原同步落盘测试立即重建store而失败，改为等待新增真实 `flushPersistence`边界，不用sleep掩盖竞态。
- iPad将宿主私有AX开关测试与XCUITest放同一个执行会话时卡在automation idle；截图已保存、app主线程采样空闲，配置9ms落盘。单独UI2项通过，最终入口隔离执行会话，不延长截止时间。证据 `/tmp/readerfork-s2-final-ipad/tests.log`、`/tmp/readerfork-s2-ipad-hang.sample`。iPad截图的系统CJK字形显示异常，不能据此宣称真机中文视觉验收完成。
- 扩大RSS VoiceOver suite时两个未修改的Feed搜索测试只找到“筛选”，系统报告search item的navigationItem不匹配；记录到S5搜索验收，S2入口仅选择本轮修改的导入按钮合同，不伪称整个RSS UI suite通过。
- S2后重跑S1媒体时模拟器音频ready超时/时钟停住；最小**本地m4a，不经网络/RSS**亦停在0秒。生产媒体与原S1测试没有为此改动，不通过增加超时或静音来放行。记录为环境/媒体阻碍，S6/S8需重跑；原先S1通过的证据仍是此前环境下的结果，不冒充本轮回归通过。证据 `/tmp/readerfork-s2-audio-isolation.xcresult`、`/tmp/readerfork-s2-local-audio-diagnostic.xcresult`，最小诊断副本 `/tmp/readerfork-s2-local-audio-diagnostic.swift`。
- iOS17实际菜单→文件选择和真机、iCloud签名/同步、DRM与后台媒体未验证。保留既有dismiss handoff，不声称模拟器替代这些门槛。

## 回滚

S2新属性均为可选，已存旧源仍可读取；不要删除用户RSS数据。回滚前保留Fork自己的 `rss_*.json`备份，旧程序不会消费的新属性不能被旧版本重存后当作仍保真。S2不迁移条目主键、媒体进度或源脚本引擎。对已发布数据进行降级时，应保留配置备份，而不是清空独立空间。
