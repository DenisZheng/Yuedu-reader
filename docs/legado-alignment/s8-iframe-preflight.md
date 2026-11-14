# S8：R265/R267 iframe 资源链的只读预审（2026-11-14）

## 当前验收归属（2026-11-14）

用户已确认“保留能力，转人工”：R265/R267真实播放归#58人工／发布验收，仍为未验证，不继续阻塞独立开发。生产iframe／JS支持保持原样；本页“不能自动打开”只描述代理的自动联网边界，不是App禁用iframe。下一步记录卡见[人工／发布清单](s8-release-checklist.md)，执行前仍须另行确认精确目标和人工测试环境。

## 判断

**本轮不能安全地自动打开R265/R267的真实iframe。** R265仅在既有精确首页GET预算内获取100条，离线解析其生产规则生成的条目HTML；100条均为跨源HTTPS iframe，100个目标都带query，同一个第三方host哈希，未发现直接video/source/audio资源。源配置`enableJs=true`、`loadWithBaseUrl=true`，其iframe内容、脚本和后续媒体子请求未审阅。WebKit的子frame和后续子资源不会受到S8测试专用URLSession发出前边界的统一保护；不能仅凭主页面HTTP200、子frame URL可解析或既有合成fixture播放就自动加载第三方iframe。

R267仅静态读取固定源包配置（0网络）：也是HTTPS规则列表、同一第三方iframe目标host，模板带query，自己的源URL另有三个query键。本轮**没有**请求其源首页、iframe或视频。静态筛选56个含`audio`/`video`/`source`/`iframe`字面标签的RSS源配置时，按HTTPS、无显式私有头/登录/源脚本标记筛出的只有R265/R267；这个字符串筛选有漏检/误检可能，不等同可用媒体源全集，更不授权执行第三方页面。

## R265最小受控行为

当前`S8RepresentativeSourceTests.testPreScreenedPublicHTMLMediaRuleListPage`复用固定307条原始包hash、预审R265源配置及生产`RSSFetcher`；只允许**一个**精确URL、无凭据/缓存、GET，禁未准入跳转。结果HTML交给`SourceScriptThread`上的SwiftSoup，只数标签/目标元数据与完整host SHA-256，不输出源名、请求URL、query值、完整正文、headers或第三方页面内容。最多120条/4 MiB HTML，变化时先失败并重新审阅，绝不自动扩展域名/重试。

| 当前受控观察 | iPhone | iPad |
| --- | ---: | ---: |
| 实际列表HTTP事务 | 1 GET / 200 | 1 GET / 200 |
| 生产解析条目 | 100 | 100 |
| 含媒体标记的条目 | 100 | 100 |
| iframe / 直接media | 100 / 0 | 100 / 0 |
| iframe跨源 / query | 100 / 100 | 100 / 100 |
| 条目HTML内script/preload | 0 | 0 |
| URL格式不符 / 内嵌凭据 | 0 / 0 | 0 / 0 |
| iframe/媒体子请求 | **0** | **0** |

父条目没有script **不代表子frame没有脚本**。记录目标host哈希仅用于变化检测，不代表准入该host任何path/query或已审查内部子资源图。两端`xcresult`各1项/0失败/0跳过，最终证据`/tmp/readerfork-s8-r265-final-{iPhone,iPad}.xcresult`及同前缀日志；SwiftSoup解析异常被转成固定错误，不让外部HTML/URL经XCTest异常文本输出。先前冻结形状的回归在`/tmp/readerfork-s8-r265-guarded-{iPhone,iPad}.xcresult`，早期未加断言的观察在`/tmp/readerfork-s8-r265-preflight-{iPhone,iPad}.xcresult`，均不替代最终安全错误边界。

## 合成对照不等于实源成功

复用已有合同，在同一27.2模拟器运行`RSSRuleWebTests`（生产文章View保留交互description与同源iframe，含配置JS/基址）和`RSSWebResourcePoCTests/testWebHLSDynamicURLActuallyPlaysInsideIframe`（自建127.0.0.1固定页面/媒体、实际WebKit HLS分片和时钟）。iPhone/iPad各7项（6+1），零失败/跳过，结果在`/tmp/readerfork-s8-iframe-fixture-{iPhone,iPad}.xcresult`。

两组fixture分开验证，**尚未证明生产RSSArticleReaderView中R265页面的真实第三方iframe可加载或播放**；PoC的配置为其自建静音素材显式放宽了自动播放手势，生产配置没有照搬。没有把fixture、列表HTTP200、iframe存在或WebView加载完成称作真实R265媒体闭环。

## R146 TLS与下一步

[R146系统信任记录](s8-r146-tls.md)已经在独立确切首图请求上复现`NSURLErrorDomain -1202`、底层`errSSLCertExpired (-9814)`，iPhone/iPad均无图片HTTP状态也未证明解码。当前没有需要修改iOS解析器或取消TLS校验的证据；保持图片受限/错误状态，等待在保持同一安全边界下证书链有效时重新验收。另按独立预审完成[R217一张真实公开WebP](s8-r217-image.md)，不覆盖R146，也不覆盖R217其余16个图片目标。不能因同一错误反复请求或更换网络/CA来刷过。

对R265/R267 iframe：R217是RSSImageService通过有界URLSession读取一张固定图，不代表WebKit子frame已获得同类请求边界。仍需取得允许探测的**精确第三方入口和可界定的子资源图**，或选择不含第三方脚本/无限子请求的独立代表网页；若无法约束WebKit子frame/认证/请求预算，则保留真实iframe未验、只做本地合成能力合同。改变网站访问权限或产品安全策略须另行决策，不以静态hash代替准入。

## 验证与回滚

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad串行同跑
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/S8RepresentativeSourceTests/testPreScreenedPublicHTMLMediaRuleListPage'
# 仅合成对照，不访问真实第三方iframe
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/RSSRuleWebTests' \
  -only-testing:'yuedu appTests/RSSWebResourcePoCTests/testWebHLSDynamicURLActuallyPlaysInsideIframe'
```

回滚仅撤去R265测试内新增的静态审计/变化检测断言与此证据说明，不更改原源包或生产WebKit路由；不回滚历史列表行为和#74。未修改生产TLS/认证、安装手机、commit/push、关模拟器或清既有数据。
