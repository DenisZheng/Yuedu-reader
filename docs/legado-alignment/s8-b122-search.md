# S8：B122空结果的实源对照（2026-11-14）

## 判断

**原搜索输入的响应没有规则所需DOM；源内检查词在相同iOS请求/解析链上得到12条。当前没有证据支持修补iOS解析器。**

这将旧的“HTTP200/零条，不知是否解析差异”收敛为**搜索输入/站点响应差异**，但不声称已唯一确定词条是否不存在、站点匹配策略或其他服务端原因。页面没有命中本次检查的显式“无结果”文案或挑战标记；这些负面标记不单独作为正常页面/无需交互的证明。

本轮只验收B122真实搜索页请求与规则解析，不访问详情、目录、封面或漫画图片，不代表整个图片书源可用，也不混入#64漫画翻页。

## 固定输入与边界

- 使用原固定253项书源包的第122项，SHA-256不变；不修改或复制原始包。
- 只允许预审的type=2图片书源。header、登录、jsLib、coverDecodeJs及脚本特征为空；URL只有首页/page和key模板。
- 原测试词与该源已有`ruleSearch.checkKeyWord`各读取首页一次；两个值不写日志。没有自动枚举词、抓首页标题再搜索或访问其他路径。
- 每项两个精确URL、总准入上限2，HTTP分派前边界继续拒绝外站、未准入URL、非GET、body和凭据；认证/Cookie三种存储事先都必须为空。
- 采用生产`renderSearchURL`、`WebFetcher.fetchPage`、`HTMLResponseDecoder`、`BookSourceParsingPipeline`/共享BookSourceSession，不创建另一套源解析器。原包加载和HTML/DOM处理离开MainActor；不执行返回网页脚本或自动开启验证码页。
- 独立SwiftSoup选择器只用于测量输入是否有规则预期节点，并检查h2标题/href是否非空。若DOM存在有效节点而生产解析仍为空，测试必须失败继续定位，不能当作通过。

## 实际观察

该批次最终两端各13项/3 suites、零失败零跳过；这是**非音频子集**，显式排除了R141真实MP3。后来加入独立R146 TLS回归，它仍失败，复验本子集时同样显式排除，见[R146记录](s8-r146-tls.md)；该失败不由13项覆盖。#77本地音频ready/时钟门槛仍阻碍当前媒体放行。

| 输入与观察 | iPhone | iPad |
| --- | ---: | ---: |
| 原测试词 HTTP/字节 | 200 / 20,322 | 200 / 20,367 |
| 原测试词 规则节点/有效节点/解析 | 0 / 0 / 0 | 0 / 0 / 0 |
| 源内检查词 HTTP/字节 | 200 / 34,135 | 200 / 34,209 |
| 源内检查词 规则节点/有效节点/解析 | 12 / 12 / 12 | 12 / 12 / 12 |
| 实际GET/凭据/未准入目标 | 2 / 0 / 0 | 2 / 0 / 0 |

响应字节数会变化，不能据此声称两端收到逐字节相同页面；可比较的是规则节点与解析结果的同一差异。旧合成DOM仍解析1条/0网络，只是离线合同，不替代这次实源对照。

## 复验

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad串行同跑
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/AnalyzeUrlLogSafetyTests' \
  -only-testing:'yuedu appTests/RSSSharedBridgeTests' \
  -only-testing:'yuedu appTests/S8RepresentativeSourceTests' \
  -skip-testing:'yuedu appTests/S8RepresentativeSourceTests/testPreScreenedRSSAudioResourceAdvancesAndProgressReloads' \
  -skip-testing:'yuedu appTests/S8RepresentativeSourceTests/testReviewedR146ImageRequiresSystemTrustAndNativeDecode'
```

最终证据：`/tmp/readerfork-s8-b122-final/{iPhone,iPad}.xcresult`及同目录日志、summary、tests树。两端真实控制台还证明普通/restricted模板探针没有表达式/结果原始输出。没有把被显式排除的音频算作通过或“零跳过即全部功能通过”。

开发时首个构建因静态源加载辅助方法仍引用实例预审函数而失败（`/tmp/readerfork-s8-b122-shape.log`，0项执行）；将无实例依赖的预审函数移到文件私有作用域后修正，未改变其失败行为。单独诊断成功证据`/tmp/readerfork-s8-b122-shape-compiled.xcresult`，最终以双设备子集为准。

## 下一步与回滚

B122当前不需要修改生产解析器或原源规则。详情、章节/漫画图片和翻页另验；R146自己的图片TLS、真实网页/媒体、登录、iOS17及发布门槛仍未闭合。

回滚仅撤去本次实源响应形状审计和共用测试辅助调整/文档片段；保留原离线fixture、其他S8/#74修改、输入源包和用户数据。无手机安装、commit/push或新依赖。
