# S4：共享运行时接入（补充验收通过）

前置 S3 为 `6177891e`；S4 主体为 `2253426c`。前台owner漏传已补齐；另以LLDB定位到旧26.2系统JSC的36位地址截断，经用户批准新增官方27.2 runtime后，正常 Reader-Fork-Dev 的 iPhone/iPad **各238项、35 suites、0失败/跳过**通过。没有修改生产JS引擎或源脚本规避问题。补充提交后恢复S5；旧26.2环境及最低系统/真机仍按[诊断边界](../../Technotes/RSSJSCContextLifetimeCrash.md)保留，不宣称旧系统已修复。

## 当前实现

- RSS 使用 `BookSourceSession` / `SourceScriptHost` / `ModernParserBridge`，不再每次抓取新建独立 `JSCoreEngine`、自行拼 URL 或注册另一套请求桥。
- `SourceRuntimeOverrides` 只适配 RSS 原始元数据、凭据命名空间和状态接口；RSS `type` 不写进 `bookSourceType`。凭据/cache key 由 RSS 本地 ID 与原始 sourceKey 派生，与书源、其他源或修改后的 sourceKey 隔离。
- `RSSRuntimeState` 是会话工作副本；`RSSStore` 仍是唯一持久 owner。`rss_runtime_variables.json` 改为 schemaVersion=1 的封装，分别保存键值变量和 opaque `source.setVariable`，兼容 S3 旧键值表；不增加第二个持久 store 或第七个状态文件。
- 源会话跨分类、列表、正文保留 jsLib 全局；完整用例持有 source turn，网络仍异步。RuleData 逐流程/条目创建，`getString(mContent)` 不改当前文档，`setContent`、getElements、put/get 使用共同回调。流程结束清理临时 bindings/back-references。
- `RSSStore` 的弱生命周期登记不是缓存，保证已经被共享 LRU 淘汰、但尚未完成的请求也能撤销。取消不重放已经执行的脚本；未执行的排队用例允许重新绑定一次。
- `SourceRequestExecutor` 是 native 和 java.* 的共同网络执行边界：每源限流、实际请求取消、精确 Cookie 选择、重定向去私有头。URL options 仍由 AnalyzeUrl 解析。
- 自动 Cookie 请求只用目标域/path 的系统 Cookie 匹配，不使用脚本 getKey 的兄弟域兼容回退。CookieJar=false 不保存自动响应 Cookie，但仍发送显式 Cookie。跨 origin 重定向移除源私有头及原手工 Cookie。
- 登录头/凭据修改增加 revision compare-and-set，旧上下文不能覆盖新的登录状态；通知在状态锁外发送。`source.removeLoginHeader` 修正为只删登录头，不删除登录凭据。
- 后台浏览器、验证码、WebView、搜索、剪贴板等动作返回可识别的需交互结果，不自动展示 UI。前台登录/网页呈现仍由 S6/S7 完成。
- RSS 诊断通过 Task/JS 队列作用域脱敏：不记录任意源日志、脚本异常文本、body 或 headers；保留白名单阶段、哈希 sourceID、数字状态/计数。正常 App/书源日志不受作用域污染。
- 原 jsLib 的阶段包装、动态 header 解析会绕过 JS 执行预算。现改为受同一预算约束，超时清楚报错、撤销副作用权限、不提交部分变量；旧 generation 不回写新上下文的阶段/头缓存。测试使用 30ms 预算和有限 250ms CPU 循环，生产预算仍为 30s。
- 不可读/未来版本的运行变量文件阻止源执行且保留原文件；外部变量更新撤销旧票据和会话。合并工作副本时再次核验票据与运行时，而不只在请求开始检查。
- 文章脚本对象按 Android 顺序设置字段：解析期间 origin/sort/type 尚未赋最终值，description 规则可补充空标题；文章 scope/变量与展示类型分开。
- 无 ruleArticles 的 Legado Feed 也走同一请求运行时，再交给既有 XML/JSON Feed 解析器；已解码 XML 只修正声明中的编码。支持登录检查和 304，不改变原始 sourceKey。

## 已运行的中间验证

均为本机 Xcode 27.2、iOS 26.2 模拟器；这些不是阶段放行结论。

| 证据 | 结果 |
| --- | --- |
| `/tmp/readerfork-s4-context-typed.xcresult` | 12 项通过，4 suites：基础共享上下文及书源队列/登录/变量回归 |
| `/tmp/readerfork-s4-first-integration.xcresult` | 43 项通过，6 suites：S1断点转目标合同、RSS解析/编码/身份 |
| `/tmp/readerfork-s4-diagnostic-boundary.xcresult` | 47 项通过，7 suites：诊断、ajaxAll、编码 |
| `/tmp/readerfork-s4-runtime-contract-red2.xcresult` | 7 项中 2 项失败：坏 jsLib 仍报通用 parseError；旧请求能写入 stale 登录头 |
| `/tmp/readerfork-s4-invalidation-green.xcresult` | 16 项通过，4 suites：修复后覆盖上述断点及书源队列/登录/变量 |
| `/tmp/readerfork-s4-interaction-and-cancel2.xcresult` | 20 项通过，4 suites：需交互、取消、CAS、ajaxAll、源浏览器认证 |
| `/tmp/readerfork-s4-http-cookies.xcresult` | 21 项通过，3 suites：实际 loopback HTTP 重定向和 CookieJar、版本化状态、S3身份/WebDAV |
| `/tmp/readerfork-s4-ruleless-feed-retry.xcresult` | 29 项中 1 项失败：PoC scheme 不执行普通 App 的后台任务注册；其余用例通过。最终门槛必须使用 Reader-Fork-Dev 重跑该项，不能跳过或修改期望 |

补充诊断：数次 xcodebuild 在 module emission 阶段超过命令 1000 秒预算。保留 `/tmp/readerfork-s4-ruleless-feed.log`。没有据此修改构建环境或更换 DerivedData；相同源码的 test frontend 独立诊断约 36 秒完成（`/tmp/readerfork-s4-test-frontend.log`），随后原 wrapper 可执行测试。尚不能归因于某条 Swift 表达式。一次采样误匹配了外层 bash，不能当作 compiler 栈证据。

## 主体提交前的门槛与断点闭环

`scripts/validate_reader_fork_s4.sh` 固定使用 Reader-Fork-Dev，通过 xcresult 同时检查整体结果、非零数量、零失败/跳过，以及每个选定 suite/单独用例确实执行。覆盖共享 runtime/书源、Cookie/真实 loopback 重定向、登录/变量、诊断、S2 导入保真与 S3 身份/持久化/WebDAV；不执行原包脚本。

| 证据 | 最终结果 |
| --- | --- |
| `/tmp/readerfork-s4-final-iphone/tests.xcresult` | iPhone 17 Pro Max / iOS26.2：233项，33 suites，0失败/跳过 |
| `/tmp/readerfork-s4-final-ipad/tests.xcresult` | iPad Pro 13-inch (M5) / iOS26.2：233项，33 suites，0失败/跳过 |
| `ruby scripts/check_localizations.rb` | 五语文案检查通过，Localizable各4010键 |
| `bash -n scripts/validate_reader_fork_s4.sh`、`git diff --check` | 通过 |

命令（设备和工具链仍由脚本解析，表中的名字只记录这次环境）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s4-final-iphone bash scripts/validate_reader_fork_s4.sh
export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
YUEDU_EVIDENCE_DIR=/tmp/readerfork-s4-final-ipad bash scripts/validate_reader_fork_s4.sh
```

- PoC 的后台注册失败在 Dev scheme 实际通过，未删除或修改断言。
- 补齐排队取消后的重新绑定、34个会话触发 LRU 淘汰后的撤销、java.ajax 中取消后继续执行脚本的 cache/Cookie/登录头拒写、字段赋值顺序和未来版本保护。
- 首次扩大门槛 `/tmp/readerfork-s4-acceptance-iphone/` 被脚本正确拒绝：有1项默认禁用的 `liveShushanComments`。它需要个人 API key/外部书源服务，不属于S4固定输入；最终改为精确选择同文件3项合成认证回归，没有启用私有凭据或删除实服务用例。真人登录仍待后续验收。
- `/tmp/readerfork-s4-acceptance-iphone-final/` 的超时故障注入有5个断言失败：库执行超预算后仍联网、持久化并报成功。修正阶段包装和 header 的超时边界后，`/tmp/readerfork-s4-js-timeout-guard.xcresult` 45项通过，随后纳入最终233项门槛。
- `/tmp/readerfork-s4-closure-iphone/tests.log` 也曾在 test module emission 超过1000秒。没有修改源码/清缓存/换DerivedData，同命令重跑40.8秒完成232项；最终新增owner变量失效覆盖后两设备均通过233项。构建偶发停顿的根因仍未知，不能宣称编译器问题已修复。
- xcresult 仍包含既有队列/Keychain路径的 QoS 优先级警告；测试通过不构成主线程、内存或吞吐性能放行，S8需独立采集。

## 补充验收（已通过，保留旧环境失败）

- `RSSFeedView.refresh`遗漏`owner: store`，真实View/HTTP/持久化测试先复现3个失败断言；修正调用方后通过。
- `/tmp/readerfork-s4-foreground-iphone/tests.xcresult`：234项、233通过、1崩溃、0跳过；不是阶段通过。
- 崩溃可最小化到正常App宿主内的两个JSContext回收与原生字符串连接；PoC宿主或ASan通过不作为修复。
- `/tmp/readerfork-s4-native-default-final.xcresult`再次关闭ASan后仍失败；前台owner用例通过，最小上下文用例崩溃。
- LLDB确认地址`0x702a048900`被系统36位掩码截成`0x2a048900`；WebKit上游06d5550移除同一假设。见诊断文档的寄存器与反汇编证据，不是仅凭栈名推测。
- 经批准新增官方iOS27.2 runtime（未删除旧设备/数据），使用相同正常Dev宿主、完整App界面和未更改的脚本表达式。新增两个suite、原取消/重建各100次全部通过。
- 最终iPhone：`/tmp/readerfork-s4-runtime-repair-iphone/tests.xcresult`；最终iPad：`/tmp/readerfork-s4-runtime-repair-ipad-ready/tests.xcresult`。均238项、35 suites、0失败/跳过。
- 新iPad首次有2项WebKit超时；等待系统bootstatus就绪后，原4项专项及完整238项通过，未改测试/延长时间。失败证据保留在诊断文档。
- 所有临时App启动/界面缩减、LLDB暂停探针已撤回。五语本地化、脚本/文档检查及`git diff --check`通过。

## 边界与回滚

- 沿用 S3 的 store 级配置 revision 保守失效；无关配置更新也可能要求重试，不为降低重试数接受旧结果。
- 仅执行自建/去敏 fixture。未运行原始 307 项包的脚本，不把全包导入保真当作所有源可用。
- JavaScriptCore 原有 timeout 能停止等待并丢弃上下文，但不承诺强制终止任意纯 JS 无限循环；撤销的上下文不能再写 owner/凭据或发起新请求。没有引入私有 API 或新 JS 引擎。
- iOS17、旧26.2真机、真机媒体、正式签名/iCloud、Xcode26.6 archive和媒体时钟仍未验证或未解决，留在对应门槛；27.2模拟器通过不能代替这些验证。
- 回滚应整体撤回本阶段 RSS 适配与相关共享改动；运行状态文件保留，不能以清空用户数据、切换新 DerivedData 或重置模拟器规避问题。
