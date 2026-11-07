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

本轮总结果：**24 tests passed，0 failed，0 skipped**，`/tmp/readerfork-s1-fixed-input-media-2.xcresult`。

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

## S1仍待完成

- 网页内MP4/HLS、iframe与JS播放器的实际运行；允许/禁止JS、preload/inject生命周期、相对base URL。
- Cookie按host/path/登录状态、图片解码、CSS/脚本资源、资源过滤与取消的PoC。
- 受限资源通路/自定义scheme的真实媒体请求，明确选择与不支持项；不能用URLProtocol的宿主请求测试代替WebKit子资源。
- 对DASH/DRM、跨站认证、视频全屏/画中画列清限制；设备实测单列。
- 分页失败/重复/刷新竞态、源/文章变量隔离的后续固定输入扩充。
- 严格网络隔离：上述PoC业务请求都为loopback；当前App测试宿主启动仍可能加载已有公共书库预览，不能称为整进程完全离线。
- S1全面自动验收前不得标完成或进入S2。真机、iOS17运行时、后台音频/DRM不包含在这24项结论中。
