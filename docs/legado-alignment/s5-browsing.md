# S5：打开优先级、分类/搜索与分页

**本地固定输入门槛通过。** 前置S4补充提交为 `b9ff8fea`。正常 `Reader-Fork-Dev` 宿主、官方iOS27.2 runtime上，iPhone/iPad各 **268项、38 suites、0失败/跳过**。这不是S6网页资源/媒体或S8实源、真机和发布验收。

## 实现边界

- `RSSOpenTarget` 统一解析入口：singleUrl优先于列表规则/分类/startHtml；支持静态URL、`名称::URL`、jsLib参与的动态sortUrl；非singleUrl才求值startHtml，空结果进入列表。普通手工Feed不因旧singleUrl默认值污染而误开网页。
- `RSSArticleContentService` 选择描述、正文规则或原网页。规则description即使很短或含交互HTML也优先于旧全文；列表封面独立保存，不能伪造description阻止正文请求。普通Feed仍使用原安全文章/全文提取路径。
- `RSSListPage` 返回实际请求/最终URL、下一页、变量和作用域；合法空页是成功结果。列表next相对于请求地址，文章链接和正文next相对于最终文档地址；缺少next不能回退为当前页URL。
- `RSSFeedSession` 只拥有浏览临时状态，`RSSStore`仍是文章和状态的持久owner。刷新、分类/查询切换、下一页、重试、取消有独立请求目标与generation；配置票据不匹配或晚到结果不提交。只有成功提交才推进页码，失败重试原页；追加保持既有位置及响应顺序。空分类/查询不回退全源缓存。
- 原生分类Picker、searchUrl远程搜索、无searchUrl时本地筛选、加载更多/重试/取消接入上述会话。后台刷新跳过前台启动HTML求值；前后台复用 `RSSFeedRefreshService.apply` 提交，而不是由View编排请求/写盘。
- 列表默认最多50页，区分空页、重复页、链接循环和预算终止。正文首个next为单链接时顺序跟进；首组为多链接时按给定顺序合并，各分支继承首页文章变量且不递归其next。正文最多50页，追加内容还有字节预算；后页失败/循环/预算返回部分结果，不伪装为完整正文。
- 只有源类型与文章类型均为web才拼接正文；image/video保留单结果。新增可选 `contentType`、`fullTextIsPartial` 字段向后兼容旧记录；部分内容由RSSStore保存，重新加载后仍标明未完成，显式重试可完成。

## 实际发现并修复的问题

### 打开与分页合同

- 合法空页：旧实现将空集合报错。`/tmp/readerfork-s5-empty-red.xcresult` 为RED；移除空集合异常后，空页与Flow fixture 9项通过（`/tmp/readerfork-s5-empty-green.xcresult`）。空白响应/非法解析与合法空集合仍区分。
- singleUrl优先级：6种合成配置组合在旧实现出现13个issues（`/tmp/readerfork-s5-opening-red.xcresult`）；修正后不请求列表且动态URL/fragment正确。
- 正文分页：旧单页实现2个issues（`/tmp/readerfork-s5-content-red.xcresult`）；补齐多页、变量、重试与持久部分结果。
- 请求地址与redirect地址：`/tmp/readerfork-s5-redirect-bases.xcresult` 复现文章URL落到旧目录、正文后页404。原因是extractor已在提取href/src时按旧base绝对化，之后设置redirect已太晚。共享引擎将文档最终地址传到提取层，同时保留列表next的原请求基址。修复后17项专项通过（`/tmp/readerfork-s5-redirect-bases-green.xcresult`）。

### 条件GET与安全请求

- 修改源请求头后仍发送旧ETag：`/tmp/readerfork-s5-validators.xcresult` 复现。配置、认证及外部变量变化现在清除该源validator，不删除文章或阅读状态。
- 仅清除配置缓存不够：同一动态源脚本把请求从`/one`切到`/two`时仍带旧ETag，`/tmp/readerfork-s5-dynamic-validator-red.xcresult` 复现。`SourceRequestExecutor`在Cookie应用后计算实际URL/method/headers/body指纹；只有匹配时才应用缓存条件头。新字段可选，旧的无指纹运行时metadata会先进行一次无条件请求；换目标的重定向移除旧条件头。查询metadata不覆盖全源metadata，查询304也保持查询作用域。
- WebKit原生加载带自定义源头的请求，会在跨origin重定向继续发送私有头：`/tmp/readerfork-s5-original-redirect.xcresult` 真实双loopback服务器复现。不能只依赖WebKit自动移除Authorization。
- 首文档改由已验证的 `SourceRequestExecutor` 执行，再把响应交给WebKit；URL options中的POST/body保留且只发送一次，跨origin不传播源私有头。不复制请求解析器、不用URLProtocol接管子资源、不接管系统http(s) scheme。实际View传入持久owner，关闭/配置失效取消旧任务。相关20项核心/页面合同进入最终门槛。

### 原生控件测试

- 原搜索AX测试只收集button，漏掉实际可输入的searchField；修正为检查搜索字段标签、键盘焦点及输入，未为旧断言改变生产搜索UI。
- 新的页面用例不仅检查控件存在：实际输入、触发原生Return主动作后，断言searchUrl收到请求、查询文章显示且原分类行消失；实际激活“加载更多”后断言第二页请求和追加内容。
- iPad首轮门槛267项中1项失败（`/tmp/readerfork-s5-closure-ipad/tests.xcresult`）：测试把`editingDidEndOnExit`等同原生搜索提交。运行时确认SwiftUI注册了`primaryActionTriggered:`；改为UITextField的原生主动作后，两设备实际查询均通过。没有延长超时、修改生产搜索或删除iPad断言。临时诊断输出已撤回。
- loopback服务器原本仅支持GET/HEAD，POST测试先返回405；只为显式测试路由增加受限POST和有限body读取，并断言服务器实际收到body，未放宽生产请求权限。

## 最终验收

工具链通过脚本动态选择：Xcode27.2 / SDK27.2，Swift6，正常Dev App宿主；iOS27.2(24B8117)。未使用ASan或隔离PoC宿主替代本阶段门槛。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s5-accepted-iphone bash scripts/validate_reader_fork_s5.sh

export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s5-accepted-ipad bash scripts/validate_reader_fork_s5.sh
```

| 目标 | 结果 | 证据 |
| --- | --- | --- |
| iPhone18 Pro Max | 268项 / 38 suites，0失败/跳过 | `/tmp/readerfork-s5-accepted-iphone/tests.xcresult` |
| iPad Pro13-inch(M5) | 268项 / 38 suites，0失败/跳过 | `/tmp/readerfork-s5-accepted-ipad/tests.xcresult` |

脚本保留每次log、xcresult、summary.json和测试树；检查最终Passed、零失败/跳过以及每个选定suite/指定用例确实执行。覆盖S5的14项浏览合同、6项实际页面合同、10项AX及S2–S4的238项回归。

五语文案各4013键校验通过。新页面补Preview；shell/内嵌Python解析、Markdown本地链接/编码、原始源包SHA-256与`git diff --check`在提交前核对。

## 剩余门槛与回滚

- 本阶段首文档打开不等于受控规则网页完成。交互description的最终展示、preloadJs/injectJs、完整charset/bodyJs/网页登录流程、子资源认证和Cookie回写、网页桥来源/frame校验、外链/黑白名单、滚动及媒体状态继续在S6实现和验收；不宣称这些能力已由入口测试覆盖。
- 真实第三方站点、真人登录、iOS17/真机、DRM、后台媒体/音频时钟及正式iCloud/发布仍未验证。旧26.2 JSC失败环境保留，见[JSC诊断](../../Technotes/RSSJSCContextLifetimeCrash.md)。Xcode26.x archive另有独立门槛。
- 回滚应整体撤回S5路由/会话、共享请求/提取层修改及对应测试，保留S4基线与所有RSS数据文件，不清空源缓存或阅读状态。新增字段可选；若降级到不认识部分结果标记的S4版本，应先保留完整备份，并仅清除被标为partial条目的全文缓存字段，避免旧版本把部分结果当完整正文。
- 本轮不push、不启动云构建、不修改签名/账号、原始源包或Android基准。
