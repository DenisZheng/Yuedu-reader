# S1 固定输入与媒体 PoC（进行中）

S0已通过；本页记录S1已执行的子集和仍缺的验收。**不代表RSS网页/媒体已经接入生产路径，也不放行S2。**

## 固定输入

- Android合同来源：[RSS执行契约](rss-source.md)，固定基准commit见总方案。
- 新建 `Tests/iOS/yuedu appTests/Fixtures/RSSAlignment/rss-alignment-sources.json`，8个自行编写的合成源，未复制用户源包或原始规则脚本；全部网络地址使用 `fixture.invalid`。
- SHA-256：`b725de91f308a3468efa64a1c8b125d449381070c6cd47874238534edb73c81f`。
- 测试只导入JSON及解析内嵌的短HTML，不访问上述域名、不执行导入源的jsLib或启动脚本。
- 视频复用既有 `Fixtures/VideoStill` 中的黑/蓝合成画面、音频与分片，不新增二进制素材或播放器依赖。原入库commit为 `1ec3f3b0`；公开分发仍执行项目逐文件许可审查。
- 新JSON采用唯一basename，因为Xcode同步测试资源会扁平复制；避免与既有Gutenberg的 `sources.json` 冲突。

| Fixture名称 | 目标行为 | 当前观测/后续阶段 |
| --- | --- | --- |
| single-mixed | singleUrl优先，并求值动态启动URL | 当前仍误入列表；S5替换基线断言 |
| start-html | 非singleUrl启动HTML/CSS/JS | 当前导入丢失；S2/S6 |
| interactive-description | 短交互HTML优先于全文抓取 | 解析确实保留iframe/onclick；阅读层优先级仍待S6 |
| images | type=1、图片解码、非正文拼接 | 当前类型和正文下一页丢失；S2/S6 |
| video | type=2、单媒体结果与请求上下文 | 当前类型丢失；S2/S6 |
| search-pages | key/page/分类与两种分页独立 | searchUrl、nextContentUrl丢失；S2/S5 |
| identity-runtime | 原sourceKey包含query/片段/options不变；变量/jsLib有正确owner | 原sourceKey往返保留；变量和未知字段丢失，S2/S3 |
| web-controls | preload/finished区别，源开关与资源过滤 | 部分网页字段丢失；S2/S6 |

`RSSAlignmentFixtureTests` 中明确标为“S1差异记录”的断言是**现状基线**，不是产品的正确期望。对应阶段实现后必须改成目标合同，不可为了保留绿色而继续维持已知错误。

## 已有实际媒体与WebKit证据

测试类：`RSSMediaPoCTests`（7项）、`RSSAlignmentFixtureTests`（4项）以及复用服务器后的 `VideoEpisodeStillTests`（13项）。

服务器从原视频帧测试抽到 `Tests/iOS/yuedu appTests/Support/VideoStillFixtureServer.swift`，只绑定127.0.0.1临时端口，最多16连接/128请求、64KB请求头；显式固定响应，无远程代理。读取媒体文件在专用队列，不在主线程做服务器IO。通过NWListener ready事件开始测试。

| 场景 | 已执行的结果 | 能证明什么/不能证明什么 |
| --- | --- | --- |
| MP4 + Referer | AVPlayerLayer显示consumer、seek到2秒、时钟推进到2.2秒之后 | 当前模拟器真实加载/播放，不代表所有codec或真机 |
| HLS + Referer | 请求playlist/init/分片，seek及推进成功 | 分片实际加载，不是只检查m3u8文本 |
| 原生音频 | M4A seek及推进成功 | 不代表锁屏、后台或系统打断恢复 |
| MP4/HLS帧提取 | 既有测试实际解码蓝色帧和时长 | 不代表网页内播放器 |
| HTTP | 无Referer返回403；HEAD无body；首段、后缀、开放Range返回206；越界416 | 测试服务器的合同与实际传输可复现 |
| WKWebView初始头部 | 主文档收到自定义头，图片请求未收到并实际403 | 初始URLRequest不能代替子资源认证 |
| 跨origin fetch | 无CORS响应被浏览器拒绝；显式允许响应成功 | 未关闭WebKit安全检查，跨origin不携带主文档自定义头 |
| 现有asset跨host重定向 | 127.0.0.1重定向到localhost，目标仍收到合成的X-Fixture-Auth | **安全约束**：现有HeaderedMediaAsset不能直接作为RSS私有认证传播策略 |

首批结果：**24 tests passed，0 failed，0 skipped**，`/tmp/readerfork-s1-fixed-input-media-2.xcresult`。后续扩展及最终入口见下节。

重放：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
bash scripts/xctest.sh -t 300 -- \
  -only-testing:'yuedu appTests/RSSMediaPoCTests' \
  -only-testing:'yuedu appTests/VideoEpisodeStillTests' \
  -only-testing:'yuedu appTests/RSSAlignmentFixtureTests'
```

### 失败实验保留

- 首次无视频显示consumer，HLS的异步seek没有结束；900秒由测试包装器中止，不能算通过。日志 `/tmp/readerfork-s1-media-poc.log`。
- 将seek改成有5秒上限的完成回调，精确复现“seek无回调、播放时间停在2秒”，日志 `/tmp/readerfork-s1-hls-bounded-seek.log`。
- 加入真实AVPlayerLayer输出后，单项及整组通过。没有修改生产播放器，也没有以sleep或无限轮询掩盖问题。
- 新fixture最初重名导致Xcode Multiple commands produce，改为唯一basename后同一DerivedData重试通过，未clean或新建DerivedData。

## 平台证据与当前选择

经Context7核验Apple公开文档：

1. [setURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:))：不能注册WebKit已处理的https等scheme，否则抛异常。因此不采用私有scheme接管技巧。
2. [AVURLAssetHTTPCookiesKey](https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey)：有公开Cookie选项，但存在针对asset URL的适用边界，不能据此保证HLS不同host/path认证完整。
3. [AVURLAssetHTTPUserAgentKey](https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey)：UA有公开选项。现有任意headers选项 `AVURLAssetHTTPHeaderFieldsKey` 未见于公开初始化选项列表，不能把当前模拟器通过写成平台保证。

建议继续复用原生AVPlayer，但RSS私有认证必须按目标域/路径重新核准；任意头部不可直接附到整个asset后跨站传播。**本轮仅测量，不新增生产资源代理，不扩大权限。**

## 后续扩展：网页、资源通路与隔离宿主

当前自动入口：

```bash
bash scripts/validate_reader_fork_s1.sh
# iPad同样动态解析：
export YUEDU_DEST="$(bash scripts/sim.sh dest iPad)"
bash scripts/validate_reader_fork_s1.sh
```

使用专用 `Reader-Fork-RSS-PoC` scheme。新增 `ReaderAppMain.swift` 在构造App之前选择测试宿主；只有Debug模拟器且显式传入 `-rss-poc-isolated-host` 才使用空白窗口。常规Debug/Release仍调用原有 `yuedu_appApp.main()`，原App初始化、页面和生命周期代码不改。这样不是“关闭首页请求后其他后台任务仍运行”，也不读取/迁移用户书库后再跳过界面。

- `RSSWebResourcePoCTests` 新增7项：网页MP4、iframe内HLS、JS请求动态媒体地址；脚本禁用；preload→页面脚本→finished时机与主frame边界；base URL；CSS/脚本/图片实际加载；Cookie的host/path和注销；带Cookie的AES-128 HLS playlist/init/segment/key真实请求及解码播放。
- 加密HLS在测试中以既有CryptoSwift从原合成分片生成，不新增依赖、不加入新二进制素材；密钥仅为固定测试数据，不是DRM绕过。
- `RSSSchemeResourcePoCTests` 新增4项：custom-scheme HTML/图片、未列入白名单的资源拒绝、真实stop回调与晚到交付抑制、MP4/HLS实际播放。scheme handler只服务内存白名单，无任意文件访问或外站代理。
- 共享导航等待器对超时、失败和WebContent进程终止抛错；媒体等待仍以播放事件、加载事件为准，不用sleep稳定状态。
- `RSSPoCTestHostTests` 新增1项，验证专用宿主启用及未安装通知启动链路。验收脚本要求至少36项、0失败、0跳过，不能漏掉宿主验证仍成功。

### 最新实际结果

| 验收 | 结果 | 证据 |
| --- | --- | --- |
| iPhone模拟器，最终隔离宿主 | **36通过，0失败，0跳过** | `/tmp/readerfork-s1-iphone-final-green/tests.xcresult` |
| iPad模拟器，最终隔离宿主 | **36通过，0失败，0跳过** | `/tmp/readerfork-s1-ipad-final-green/tests.xcresult` |
| 常规App启动及S0回归 | **203通过，0失败，0跳过** | `/tmp/readerfork-s0-final-host/tests.xcresult` |

当前运行时均为iOS26.2，设备由脚本解析。PoC宿主日志未出现原首页的 `home.row`、`publicLibrary.opds.load` 等启动记录，测试所有业务资源来自loopback或内存白名单；这不是OS级防火墙/系统网络流量抓包结论。

### 失败复现与修正

- 位图fixture最初未固定UIGraphics renderer.scale，在3x设备生成了3像素而非1像素，三个测试因此失败。固定输出scale=1后通过，没有把断言改成某一机型的3。
- 一次切换iPad目的地在actool资源裁剪阶段耗尽外部命令预算，未开始测试，不算通过。S1脚本现沿用仓库900秒构建预算；各播放器/导航的5/8/10秒等待上限不变。
- 独立入口不再带普通App的音频初始化副作用，iPad音频出现ready超时或播放停在2秒。单项重复3次均失败，日志 `/tmp/readerfork-s1-ipad-audio-repeat.log`。只增加显式AVAudioSession.playback激活并在测试后还原，3次重跑及两种设备完整36项随后全部通过，日志 `/tmp/readerfork-s1-ipad-audio-session.log`。同步会话调用在后台Task执行并等待结果；未改生产播放器、未加长媒体截止时间。

### 资源方案约束

在当前模拟器，公开WKURLSchemeHandler可以完成合成MP4/HLS播放；此前仅凭API说明不能断言“所有custom-scheme媒体都不可用”。但它仍不能接管http/https，也不能改变外站CORS。

一次记录中，custom-scheme MP4播放到0.24秒产生**84次本地handler请求**（大量小Range），HLS为**7次**；这是callback计数，不是外网请求数。详见 `/tmp/readerfork-s1-final-artifacts/` 中记录。不能直接把每次callback映射成一次上游网络请求，更不能据这段小视频承诺生产内存/带宽表现。

后续选择：普通网页优先原生http(s)+受域/路径约束的Cookie；需要解码或逐请求认证的受限资源可评估custom-scheme路径，但不全量改写外站URL，也不把任意认证头附到整个AVURLAsset。真正接入和资源预算约束在S6完成。

## S1仍待完成

- 源脚本图片bytes解码到实际图像加载的PoC，以及Android黑/白名单语义对应的资源过滤输入。
- 分页失败/重复/刷新竞态、源/文章变量隔离、登录检查和配置更新的固定流程输入扩充。
- DASH/DRM、全屏/画中画与跨站认证的限制清单收敛；真机、iOS17运行时、后台音频仍单列未验证。
- S1全面自动验收前不得标完成或进入S2。当前36项证明平台PoC与现状基线，不是RSS生产功能闭环或任意第三方网页播放器兼容。
