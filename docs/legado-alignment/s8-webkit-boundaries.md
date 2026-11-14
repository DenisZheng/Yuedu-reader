# S8：WebKit iframe公开边界可行性（2026-11-14）

## 结论

**能做静态URL过滤，也能在`WKNavigationDelegate`拒绝特定frame文档导航；做不到在公开的WebKit navigation delegate + `WKContentRuleList`组合上实现外部脚本驱动的逐请求准入、实时计数预算或逐子资源取消。因此R265/R267第三方iframe继续不联网加载。** 本轮仅用本地`VideoStillFixtureServer`（loopback）和WebKit，不访问任何真实源/第三方目标，不改生产代码，不改TLS/Cookie/权限。

## 双设备探针

新增两个`RSSWebResourcePoCTests`合同：

1. 主页面、iframe和嵌套iframe各一份本地HTML；加入声明式规则：默认block两个loopback host/port，再用静态精确路径例外放行审阅过的入口和一个公开资源URL。未授权图片、fetch、嵌套frame里的图片都被挡在服务端之前；允许资源URL重复取两次时都得到200；允许的redirect入口可到达服务器，但redirect目的地址未获准，因此目的请求为0。该过程产生6个本地HTTP请求；delegate只报告3次document navigation（顶层+两个frame），看不到图片、fetch或redirect后的子请求。精确形状与主/嵌套frame数在fixture中断言。
2. frame设置跨源本地`localhost`文档目标；navigation delegate看到`targetFrame.isMainFrame == false`并返回`.cancel`，本地服务记录该未批准frame地址0次HTTP请求。说明委托可拦文档导航，而非任意资源访问。
3. 同批加入既有`RSSSchemeResourcePoCTests.testStopLoadingCancelsHeldResourceAndSuppressesLateDelivery`，3项均双设备通过。它只证明App**自行注册的自定义scheme task**收到`stop`后可以取消受控图片任务并拒绝晚到结果；不接管HTTP(S)，也不证明WebKit公开联网子资源管线提供可枚举的取消回调。

最后双设备结果：`/tmp/readerfork-s8-webkit-boundary-final-{iPhone,iPad}.xcresult`；日志同名`.log`。每端总计3项、0失败、0跳过，精确集合含两个新增网络边界探针和一个已有scheme取消合同。控制台安全计数行以`S8_WEBKIT_BOUNDARY`为前缀，不记录外站URL/内容。

## API能力边界及设计判断

- `WKNavigationDelegate.decidePolicyFor navigationAction`能检查当前由WebKit提升为**文档导航**的`WKNavigationAction`，包含frame信息，并对文档返回allow/cancel。测试验证frame与nested-frame文档可观察/可拦。
- `img`、CSS资源、脚本副作用触发的`fetch`等普通subresource不会逐项进入navigation delegate。本地实际6个事务中只收到3个导航回调；另外重复资源fetch与redirect入口请求没有delegate准入回调。这是本轮采用的导航委托自身范围，不假定任意媒体实现的每个内部segment都是独立导航。
- `WKContentRuleList`是预编译的声明式过滤规则，没有运行期Swift事件、来源/状态依赖回调或累计预算状态。测试证明精确允许URL可重复读取，且单次允许的重定向仍会对新目的URL再由静态规则过滤。规则可过滤，却无法在第N次后改变决定、按真实条目变量动态准入新的URL，亦不能报告外部脚本下一步会发哪些请求。
- WebKit提供的`stopLoading()`是整个WebView级别取消，不会给App一个外部HTTPS子资源task集合，供逐条计数、查原因和撤销。delegate `.cancel`仅对它实际送达的文档导航动作生效。已有scheme cancellation test可控自定义handler task，与公开HTTP(S)子资源不是同一路径。
- R265实际父条目全部含跨源带query iframe，source开启JS与base URL。即使R265列表/iframe host已hash预审，查询值与子frame后续请求图仍由网页运行时决定；host hash不构成URL准入。现有生产`RSSSourcePageSheet.Coordinator`对`targetFrame.isMainFrame == false`的HTTP/HTTPS/about文档导航允许继续，生产resource rules没有可以对任意第三方脚本fetch实时限次的hook。故本轮**不在生产加宽frame许可、不创建全站代理**。

任何公开API能静态block已知pattern或取消整页加载，不等于具有“有上限、每个请求发出前确切匹配并能取消”的运行时门。`URLProtocol`、自定义scheme接管HTTP(S)、忽略证书/信任以及第三方网络节点访问均不采用。

## 下一步

保留R265/R267真实iframe状态为“未验证”。若后续有网站提供、获得允许测试且可静态限定的固定media URL清单，可只对那些公开GET用生产`RSSImageService`/`RSSMediaResourceSession`逐个做有限访问；这不是验证其活页面/JS播放器。要验证真实活动iframe，需要额外的、由用户认可的风险范围或受控隔离网络/Browser engine能力设计，并单独评估产品安全与架构；本次不把候选实现/私有平台技巧作为方案默认值。

另行验证R146、音频#77和其他S8项目保持原状；这份PoC不宣布S8完成。

## 复现命令与回滚

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad串行重跑
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/RSSWebResourcePoCTests/testPublicWebKitBoundariesBlockUnknownSubresourcesButCannotCountRequests' \
  -only-testing:'yuedu appTests/RSSWebResourcePoCTests/testNavigationDelegateRejectsUnapprovedCrossOriginIframeBeforeRequest' \
  -only-testing:'yuedu appTests/RSSSchemeResourcePoCTests/testStopLoadingCancelsHeldResourceAndSuppressesLateDelivery'
```

如需撤回，可移除`RSSWebResourcePoCTests.swift`中新加的两个loopback案例及`FixtureNavigationPolicyProbe`/pattern构造器，再删本文档；不碰既有媒体/自定义scheme合同、用户源或生产实现。未安装物理设备、清理/关闭模拟器、提交或推送。
