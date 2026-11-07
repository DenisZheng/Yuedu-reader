# S3：条目身份与状态基础

## 合同与边界

S3把稳定身份、内容/状态归属、更新失效和备份格式连接到现有RSS链路。它不实现S4脚本运行合同、S5完整分页状态机或S6播放器接入。源配置/状态仍由 `RSSStore`持有，没有第二个RSS store或播放器进度缓存。

### 稳定身份

- 文章ID：`rss1:` + SHA-256（source.id、作用域类型、作用域key、原始条目key的UTF-8长度前缀序列）。不拼接不受控分隔符；不丢URL的query/fragment/options。
- 作用域为Feed、分类或搜索；分类取原始名称和URL，搜索取原始query；**页码不参与身份**。
- `RSSItem`区分 `rawKey`与App `id`，初始化/`identified`集中分配。规则抓取在脚本执行器内绑定分类身份；标准Feed解析、HTML摘要和身份哈希移到后台，View只拿值快照。
- 附件ID：`rss-media1:` + 文章ID/附件稳定key摘要。媒体进度保存在 `RSSArticleStatus.mediaProgress`，不以签名URL为key。S6负责把真实播放器读写连接到此owner，S3测试是状态基础，不是播放通过。
- 刷新替换当前作用域；其他分类/查询不被删除，缺席收藏继续保留。重复页/相同内容不重写；分页追加可以复用同一个合并入口。

### 内容与状态

配置保留在 `rss_sources.json`，内容/文章变量/附件描述保留在 `rss_articles.json`，已读、收藏、阅读位置和播放进度由 `rss_article_status.json`权威持有。早期记录中的状态字段继续作为升级兼容快照存在，并由同一owner维护投影；新状态动作只写状态文件，不触发正文全库落盘。

源级运行变量使用RSSStore的 `rss_runtime_variables.json`（source.id → 字符串变量表），与文章变量分离。该运行文件不进入WebDAV快照，S4负责与共享脚本上下文接线。配置中的作者声明 `variable`不是CookieStore或已经登录的凭据。

为消除已复现的状态动作扫描全库，增加**不落盘的派生索引**：文章ID→所属源/位置、旧ID→无歧义新ID、源→未读数。它们在内容写入点更新，只索引现有内容，不复制另一份可写内容或状态。

### 失效与删除

`RSSRequestTicket`记录源ID、配置revision和认证revision。前后台刷新、RSS列表与正文抓取在返回时检查票据和取消；源修改、删除/重导或登录变化使旧结果失效。当前配置revision是store级保守失效，因此无关配置更新也可能要求重试；没有为了少一次重试接受旧结果。

删除清理所属内容、状态、运行变量、元数据和索引；晚到结果不能复活已删源，陌生文章ID不能创建状态。旧无归属状态仅在还有同旧ID的记录时保留作兼容；最后一个所属记录删除后清除。

### Fork升级

配置版本为1；文章/状态 `identityVersion=1`。缺少版本的Fork早期记录读取时使用其原始id和所属sourceId得到新身份，并保留 `legacyID`供旧通知/链接查找。只有唯一映射可以路由；相同GUID跨源的旧链接不能随机命中一源。

早期已读/收藏从各源记录中已有的状态快照继承，不把无法归属的全局raw GUID状态广播到所有源。无法证明归属的旧状态仍留在本地文件，不在备份中伪造归属。新状态写入使用规范ID。未知配置、内容或状态版本拒绝解码；沿S2损坏文件保护，不用空集合覆盖未来格式。

## WebDAV快照

新增 `/readerfork-dev/rss-v1.json`，不覆盖原版RSS或既有书源/书架/替换规则路径。

- Envelope含固定format、原始payload字节与SHA-256；payload有schemaVersion、源/分组、最小文章描述和状态。
- 不含正文、媒体文件、文章链接/附件临时URL、源/文章运行变量或CookieStore。静态JSON header中的Cookie/Authorization去除；作者JS配置保持原样、不执行，也不被视为恢复了登录态。
- 内容缓存淘汰的条目，其已读/播放状态仍进入快照。恢复后保留稳定ID，缺少正文/链接的占位记录需刷新才能阅读全文。
- 完整校验版本、checksum、数量/大小、唯一ID、source关系和有限非负进度，之后才修改RSSStore。恢复清空请求验证器和运行变量，旧请求失效。
- 修改前原始RSS文件备份在本地Library的 `rss-restore-backups/<UUID>/`，不自动删除。落盘失败仍报失败，保留可回滚数据；不是多个独立文件的跨文件原子事务。
- HTTP 404才表示旧备份未含RSS；401/网络错误/损坏快照不能当作没有备份或恢复成功。WebDAV UI同时说明范围；冲突待确认不再先显示恢复成功，冲突分支不吞错误。

`RSSWebDAVBackupTests`注入隔离UserDefaults和URLSession，实际走原WebDAV请求构造、MKCOL/PUT/GET及状态码分支。它证明HTTP客户端合同和snapshot行为，不等于真实云服务/自有账号已验证。

## 验证与反馈

- 首轮跨源GUID、删除后晚到数据测试：2项5个失败断言，日志 `/tmp/readerfork-s3-identity-red.log`；修复后通过。
- 身份变化使旧断言把原始key当App ID而失败；已同时更新解析、收藏、探索条目等真实消费者断言，并保留rawKey合同，未改变Feed相对链接求值。
- 首次派生索引前，50源×200文章初始化/状态回归耗时78.960秒；同一测试加入owner索引后为4.601秒（均包含构造10000条和6000次状态动作，不是逐次UI耗时指标）。后续单次状态不再扫描所有文章，读取未读数不复制排序正文。
- 相同作用域刷新最初因与其他分类交错而改变数组顺序并写盘；现只比较当前作用域的有序内容，重复页不写。备份恢复后的未读投影另检查了已读→未读计数。
- WebDAV fixture最初漏读URLSession的httpBodyStream导致PUT假空；改为实际消费stream再验证往返。Foundation URL.path会省略目录尾斜杠，断言与该API结果一致，不改实际MKCOL URL。
- 新后台Feed解析的泛型trace closure曾令编译停在module emission；显式标注返回tuple类型后编译及46项回归通过，未切换语言版本/DerivedData。

阶段入口：

```bash
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s3-acceptance bash scripts/validate_reader_fork_s3.sh
export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s3-ipad bash scripts/validate_reader_fork_s3.sh
```

- iPhone：`/tmp/readerfork-s3-acceptance-final/tests.xcresult`，**120通过，0失败/0跳过**。
- iPad：`/tmp/readerfork-s3-final-ipad-coalesced/tests.xcresult`，**120通过，0失败/0跳过**。最终旧重复记录投影/索引修正在iPhone额外44项及完整120项再回归通过。
- iPad真实导入UI：`/tmp/readerfork-s3-import-ui.xcresult`，**2通过，0失败/0跳过**。
- 五语言检查、diff与脚本语法检查执行通过。

S2记录的Feed搜索AX、模拟器音频时钟和Xcode26.x云归档仍未解决，分别阻塞对应S5/S6/S8验收，不在此宣称通过。真实iCloud/RSS跨设备同步未实现为新能力；现有iCloud路径未替换。启动时既有RSS同步load仍是需要继续观察的性能边界，S3没有把启动IO优化算作完成。

## 回滚

不要用删除数据回滚身份。保留 `rss_*.json`和恢复前备份目录；要降级到raw-ID版本必须显式反向迁移，否则无法无歧义还原跨源状态。S3内容/状态是Fork自己的版本格式，不能拿旧原版程序重存后声称无损。网页媒体代理、播放器和原始307/253项源包未随S3更改。
