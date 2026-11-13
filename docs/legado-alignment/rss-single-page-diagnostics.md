# RSS 单网页源：403、浏览器会话与User-Agent对照

## 当前结论

用户报告的实际提示为「加载失败／重试」，不是已确认的404。准确目标是用户后补的399项RSS导出中第20项，分组「1第一道路」、源名「禁漫天堂-漫画」；旧307项RSS包不存在此条，不能用旧R062或书源模块代替它。

在用户手机上，本轮故障已恢复，并完成划掉App后重开、两次进入RSS的验证。当前可用组合是：用户更换后的VPN节点、`rss-native-browser-v2` 的连续WebKit会话，以及该源 `"header": "{}"`（使用真实WebKit默认User-Agent）。定向日志记录了403验证页后同会话导航到200；重开复测的14条目标事件中，4次收到200、3次完成200，没有新的403，用户确认两次均看到正常网站内容。

必须分开看三个观察：原iOS首文档原生请求遇403即失败；改为连续WebKit会话后，旧VPN节点下App和Safari均验证循环；用户换节点后Safari恢复而App仍循环，仅将该源Android13/Chrome118 User-Agent移除后App恢复。最后一次配置对照支持User-Agent是当前环境中的相关因素，但不是站点唯一原因的证明，不推导所有源都应忽略配置，也不承诺任意VPN出口都能通过。

主分支S7/S8工作区没有安装到手机。本轮三个手机构建均来自隔离的 `15a29143f8254bbdb4be8e70e8216a0d92223d25`；用户分别授权了仅诊断版、HTML错误页实验版及浏览器会话候选版的无线原位安装。默认UA对照也得到明确授权，由用户通过App源JSON编辑器完成。未卸载、清数据、禁用TLS或自动操作真人验证；VPN节点由用户手动更换。

## 输入、环境与隐私

- 后补导出：用户下载目录 `yuedu-rss-legado.json`，399项，SHA-256 `f8f319de7a4dc1f2f718819fc2c7d9a08ea9315e68d1be1bbde6c9b622a6640a`。只做单项静态预审，不复制整包到仓库/测试资源，不覆盖原始253/307项包。
- 目标初始配置：`singleUrl=true`、`cacheFirst=false`、`enableJs=true`、`enabledCookieJar=true`；仅Android13/Chrome118 User-Agent头，无源JS库、登录、正文转换或资源规则。成功对照后只将该源header改为字符串`{}`，无线读取RSSStore验证该字段为空对象、源地址及身份不变；未修改原399项导出或253/307项原始包。
- 真机：iPhone 17 Pro，iOS27.2.1，`dev.denis.readerfork.dev` 3.0.1 (1)，已有Personal Team签名与 `READER_FORK_NO_ICLOUD`。iCloud/App Group不在本轮验证范围。
- 诊断只记录尝试ID、源身份摘要、阶段、耗时、HTTP状态或系统错误域白名单/数值码。URL、查询、header、Cookie、异常原文、证书和正文不进入新日志。未知错误域不输出；underlying链最多3层。
- 私有证据目录：`/tmp/readerfork-rss-jm-device.goCIZn/` 和 `/tmp/readerfork-rss-jm-diagnostic.CipksA/`。原日志、设备标识、签名配置均不提交；引用只用白名单解析后的统计/事件。

## 真机观察

| 构建及操作 | 真实结果 | 结论范围 |
| --- | --- | --- |
| 已安装稳定版，无线读取App持久日志 | before 2380项，after 2396项；RSS事件已被泛化脱敏，无底层状态 | 不能靠既有日志判404/TLS或归因缓存 |
| `15a29143` + `rss-web-load-v1` | 94条目标事件，47个尝试均 `phase=document event=failed httpStatus=403`，200–852ms | 首文档原生请求收到403；没有交给WebKit |
| HTML错误页实验版，第一次打开 | HTTP200，682171 bytes，1448ms取得，1458ms提交WebKit；用户确认RSS内网站打开 | 本轮200成功，不证明403处理有效 |
| 同VPN继续进入 | 新增9个尝试：3次200、6次403；403约5668–5928 bytes，全部提交WebKit，8次总文档完成 | 用户确认出现CF验证并循环；WebKit完成不等于验证成功 |
| `rss-native-browser-v2`，原UA及旧VPN节点 | 14条目标增量，4次浏览器响应403并完成403；Safari同网络也循环 | 浏览器路径实际生效，但单改路径未解决；当前外部限制并非App独有 |
| 用户仅换一个VPN节点，仍保留原UA | 用户确认Safari正常、App仍失败 | 在该节点继续核查App及源配置差异 |
| 同一新节点，仅将该源header改为字符串`{}` | 用户确认网站正常；15:26:16 UTC收到403，15:26:27收到200，15:26:39完成200 | 同WebKit会话的验证后导航成功；没有自动求解验证码 |
| 保持新节点和空header，划掉App后重开并两次进入 | 用户确认均正常；14条目标增量，4次响应200、3次完成200，0次403 | 原始重开/再进入场景通过；其中一次后续导航只有响应，没有完成事件，不计完成 |

用户说「成功了，已进诊断页」的一次反馈，已明确更正为成功重现并进入App设置诊断页，并非网站打开。本记录不将其计作成功。

无线安装/日志访问能工作。曾遇设备锁定10003/10002、控制通道reset、远程启动4016；它们属于调试连接或启动工具，不是RSS请求根因。一次启动用了工具返回的persistent identifier却被CLI拒绝为无效base64，改用标准Bundle ID启动后成功，无需重装。

尝试系统日志时，`log collect`要求管理员权限；用户限定授权仅该App和本轮时间窗。实际工具提示真机忽略predicate，并返回 `Device not configured (6)`，无归档。因无法满足采集范围，已停止此路径，没有收集全设备日志或更改系统配置。

## 代码合同与本地对照

Android固定基准中，`ReadRssViewModel.loadUrl`准备AnalyzeUrl后，`ReadRssActivity`的URL observer调用 `WebView.loadUrl(url, additionalHeaders)`。iOS原实现通过共享 `SourceRequestExecutor`取首文档，运行登录/响应处理后要求2xx，再用 `WKWebView.load(data, …, baseURL:)`展示；同源导航也会取消WebKit并以原生请求重送。

仅诊断版在生产首文档自建503场景先复现“没有具体诊断事件”，补齐后22项/5 suites通过，0失败/跳过。它不改变请求/重试/UI或数据格式。

HTML错误页实验版的25项/5 suites通过，只证明自建HTML的DOM和脚本能呈现、错误状态保留、没有自动重试，以及原认证/缓存/撤销回归。该方案真机出现验证循环，不能据此放行。

随后新增 `RSSBrowserSessionTests`，以相同自建页面比较生产路径与直接WKWebView。源启用CookieJar后，两者Cookie、UA与DOM存储可延续；只有生产路径的首请求及表单缺少浏览器原生导航的Fetch Metadata，直接WKWebView对照通过。首轮fixture误用了默认关闭CookieJar，产生的失Cookie失败已排除，不能用于归因真实源。

当前候选已撤回HTML错误实体灌入实验，恢复受限请求原有非2xx错误合同；没有私有头、响应处理、登录/源脚本、资源规则、限流或cacheFirst要求，且启用CookieJar的简单singleUrl网页，从第一请求直接由同一个非持久WebKit会话加载。保留源User-Agent，CookieStore仍是持久owner；只允许同origin导航留在当前网页，私有头请求继续由共享执行器约束重定向。

候选在iPhone模拟器完整定向 **26项/6 suites通过、0失败/跳过**，覆盖浏览器首请求、403页面、POST200、UA/Cookie/Referer/sessionStorage/localStorage连续性、源删除/登录撤销、禁脚本及私有头跨站剥离。第一批23项中的旧HTML导航撤销用例出现2个失败断言，同条件单独4项通过后完整26项通过；保留失败证据，不宣称该间歇根因已唯一定位，没有清理模拟器或放宽等待。候选标记为 `rss-native-browser-v2`，真机结果见上表；主工作区整理了同一行为改动及类型化诊断，另补默认UA的真实HTTP/DOM一致性回归。

Cloudflare官方[WebView要求](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/)要求JavaScript、DOM存储、稳定User-Agent及浏览器环境。官方要求仅用于解释候选因素，不能替代本站对照；证据经Context7查询，直接抓官方URL因本机fake-IP地址限制未成功，未修改网络或工具安全配置。

## 验证命令与证据

使用项目既有脚本、动态解析工具链/模拟器，串行测试并复用原DerivedData。诊断隔离工作树位于 `/tmp/readerfork-rss-jm-diagnostic.CipksA/source/`。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- \
  -derivedDataPath "$EXISTING_DERIVED_DATA" GIT_COMMIT_SHA=15a29143 \
  -resultBundlePath "$EVIDENCE/tests.xcresult" \
  -only-testing:'yuedu appTests/RSSBrowserSessionTests' \
  -only-testing:'yuedu appTests/RSSWebLoadDiagnosticsTests' \
  -only-testing:'yuedu appTests/RSSWebRequestTests' \
  -only-testing:'yuedu appTests/RSSWebDocumentCacheTests' \
  -only-testing:'yuedu appTests/RSSWebInvalidationTests' \
  -only-testing:'yuedu appTests/RSSOpeningViewTests'
```

证据目录中的 `diagnostic-verified.xcresult`为仅诊断版22项最终结果；`403-html-final2.xcresult`为错误页实验25项结果；`browser-session-control-red.xcresult`为浏览器对照的红结果；`browser-native-verified.xcresult`/summary为新路径26项/6 suites最终结果。本地化4111键、Info.plist解析和`git diff --check`通过。编译失败、0项匹配、首次无终局、错误页实验回归失败等中间批次保留，均不计通过。

真机证据同目录保留：`rss-v1-reopened-redacted-events.json`、`rss-cf-loop-redacted-events.json`为早期失败；`rss-native-browser-redacted-events.json`为新路径仍403；`rss-default-UA-redacted-events.json`记录403→200；`rss-default-UA-reopen-redacted-events.json`及`default-UA-source-verification.json`记录重开保持和配置核验。默认UA日志文件覆盖从上一采集点到成功的完整时间窗，含修改前403，不将该窗内所有事件都归为修改后。

`native-browser-package-manifest.json`记录构建标记、源补丁SHA-256、包/回装路径和签名核验；`native-deployment-status.json`的安装及启动退出值均为0。源补丁摘要为 `9cbb4562495509b4eb24887abd2e4135a38427e2978ea415216edc66b01c6bdb`，稳定基线与主工作区后续整理分别保留。

## 回装与未验证

安装前从干净15a29143重建稳定包，签名深校验、Bundle ID、profile设备授权及有效期通过；另存 `/tmp/readerfork-rss-jm-diagnostic.CipksA/rollback/YueduReader.app`。回装使用同签名Bundle ID原位覆盖，不卸载、不删除用户数据。该开发profile记录的有效期为2026-11-16 UTC，后续回装前必须再次核对。

当前手机保留已验证的 `rss-native-browser-v2` 和该源空header配置。原单源JSON已备份于私有证据目录的 `single-source-UA-before-private.json`；恢复配置时通过现有JSON编辑器只恢复header，避免重新导入覆盖其它本地状态。回装稳定包会恢复旧加载行为，本轮未执行回装。

主工作区回滚仅撤回本轮 `RSSSourcePageSheet`/`RSSOpenTarget`相关差异以及新增policy、诊断与测试文件，不还原整个工作区或删除原S8草稿。实源新节点上的打开与重开通过，不代表跨站导航、所有其它源、最低iOS17、真实iPad或长期站点可用性已验；本轮不记S8完成或发布通过，不自动commit/push。
