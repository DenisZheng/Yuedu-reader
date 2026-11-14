# S8补充：真实音频资源与快速退出进度（2026-11-14）

## 结果

**R141真实规则提取→生产原生媒体资源层→播放推进→进度重载已通过；同时修复RSS媒体在两个UI采样之间退出时丢失进度。S8仍未完成。**

该批次最终iPhone/iPad各37项、9 suites、零失败零跳过。其后扩展回归再次遇到真实MP3及双设备本地音频ready/时钟失败，当前媒体门槛已重开，见[日志安全与后续复验](s8-template-logs.md)，不能用本次历史通过覆盖后续失败。XCTest代表源/边界9项，Swift Testing合同28项；已核对xcresult完整用例集合，不采用框架中途结果。设备由`scripts/sim.sh`选择，均为iOS27.2 (24B8117)模拟器，SDK27.2，使用已有`Reader-Fork-RSS-PoC`隔离宿主。

本轮没有安装手机、修改原始源包、提交或推送。此前#74网页返回和上一批S8资源/Cookie改动保留。#76的修复只改变RSS播放器路径，不将其解释成#65书源视频反复弹出已修复。

## 1. 实源选择与请求范围

预审结果分开记录：

| 来源 | 实际观察 | 决定 |
| --- | --- | --- |
| R304 | 单次只读目录GET返回403 | 停止；不改UA、加凭据或绕过限制 |
| R187 | 单次只读目录GET返回403 | 停止；未执行其正文脚本/媒体 |
| R306 | HTTP200，但JSON顶层不是规则预期的对象 | 预审停止；未执行原规则/媒体，不归因iOS解析 |
| R141 | 公开HTTPS目录200；正文200；MP3小Range预审206 | 进入受保护生产流程 |

R141没有登录、私有header、jsLib、预注入或网页完成脚本。目录中的已审查表达式仅为首页offset算术和`Date.now()`；正文仅额外允许一次`java.get('audio')`，读取列表`@put`保存的条目变量，不放行任意源JS。

- 原始sourceKey和URL参数不改。目录准入逐项检查origin/path、全部五个query参数、首页offset=0，以及本次25秒窗口内的时间值；其他静态参数变化、额外参数、第二页或外站/其他路径都由离线用例证明会被拒绝。
- 原始sourceUrl的默认目录与实际首分类并非同一个正文主机。初版白名单阻止了这个差异，后续按真实首分类重新进行一次正文预审；没有用整站/任意路径放行掩盖失败。
- 只选择同时符合预审正文/MP3主机哈希、HTTPS、无query/fragment/内嵌凭据的条目。Store可按日期重排，因此不假定其首条就是原JSON首条。
- 所有上游请求仍受S8发出前边界约束，总准入上限8。只有本项显式允许HEAD，其他实源测试仍只允许GET；POST、body、Cookie/Authorization和未准入目标继续拒绝。
- `RSSMediaRequestService`的请求构造、`RSSMediaResourceSession`资源图和AVPlayer不替换；通过已有Prepared/runtime值注入受保护Session。没有增加另一套解析器或播放器。

## 2. 实际生产链

```text
RSSFeedSession / 首分类
  → 条目rulePubDate中的@put保存audio变量
  → RSSArticleContentService / 正文java.get生成audio标签
  → 核对正文audio src仍为该条目的值
  → RSSMediaRequestService / RSSMediaResourceSession
  → VideoPlaybackController / AVPlayer实际推进
  → 关闭资源与RSSStore进度落盘
  → RSSStore重建
```

| 观察 | iPhone | iPad |
| --- | ---: | ---: |
| 目录条目 / 符合准入元数据 | 20 / 20 | 20 / 20 |
| 实际上游事务 | 3 | 3 |
| 状态 | 200、200、206 | 200、200、206 |
| 实际播放推进 | 500 ms | 503 ms |
| 凭据请求 / 未准入目标 | 0 / 0 | 0 / 0 |
| 进度重载 / 资源停止 | 通过 / 通过 | 通过 / 通过 |

这里的R141仍是type=0规则网页。本项证明真实源的列表/正文变量合同及提取出MP3后的**原生媒体资源能力**，不改变它的产品路由，也不冒充原规则网页WebKit/HTML audio或iframe播放器已经验收。没有验证物理设备声音、DRM或其他媒体格式。

自建`S8AudioRuleContractTests`另外证明相邻条目的`$.time@put:{audio:$.audioUrl}`和`java.get`不会串值，0网络。该用例从首次运行就通过；没有借此修改生产规则引擎或把合成结果当作实源成功。

## 3. 快速退出进度缺陷与修复

真实MP3最初已推进约0.5秒，但关闭后进度是0。缩小到自建本地视频，在0.25秒处固定比较时点，不使用网络或sleep：

- close、pause、切后台三种情况均失败；立即读取RSSStore已经是旧值，重载值与之相同。
- 误差约0.24–0.25秒，排除了网络、异步落盘覆盖或附件key不一致。根因是强制保存仍读取每1秒更新的UI采样。

`VideoPlaybackController`现在只对RSS强制保存读取就绪AVPlayer的真实时钟；普通UI采样频率、书源/脚本链接保存路径、RSSStore owner与持久化格式不变。

不能直接无条件读取时钟：首版修复被“seek到1.25秒后立即退出”用例抓出回归，会把用户目标覆盖成尚未完成seek的约0.25秒旧时钟。因此RSS额外跟踪seek是否完成和加载修订：

- seek完成前保留用户目标，旧采样不覆盖目标。
- seek回调必须匹配当前修订和当前item，且控制器尚未关闭。
- 新加载撤销旧seek状态；seek完成后重新使用实时采样。
- 未就绪恢复位置和播放结束归零语义保持。

本地回归覆盖三种退出、三种seek后立即退出、未就绪恢复，以及seek完成后继续推进并保存。原播放器整套6项也通过，包括HLS、签名过期重算、真实阅读页重开和凭据撤销。

阅读页旧测试还存在一个观察点问题：currentItem刚安装时其时钟可为0，随后恢复seek会跳过绝对0.5秒观察点。现改为在RSS保存位置/当前时钟的较大值之后观察新增0.5秒播放；没有加sleep、放宽超时或把页面出现当播放成功。

## 4. 命令与证据

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad串行同跑
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/S8RepresentativeSourceTests' \
  -only-testing:'yuedu appTests/S8RequestBoundaryTests' \
  -only-testing:'yuedu appTests/S8RestrictedCookieFlowTests' \
  -only-testing:'yuedu appTests/S8AudioRuleContractTests' \
  -only-testing:'yuedu appTests/RSSMediaProgressCaptureTests' \
  -only-testing:'yuedu appTests/RSSMediaPlaybackTests' \
  -only-testing:'yuedu appTests/RSSCookieAuthorizationTests' \
  -only-testing:'yuedu appTests/RSSImageServiceTests' \
  -only-testing:'yuedu appTests/RSSMediaResourceSessionTests'
```

最终证据：`/tmp/readerfork-s8-audio.8r9KFy/final/{iPhone,iPad}.xcresult`及同目录日志、summary、tests树。

原失败保留在上层：`audio-category-green.log`其实是进度断言失败，不能因文件名写作通过；`progress-capture-red.log`是纯本地三种退出复现；`progress-clock-snapshot.log`记录首版修复的seek回归；`verified/iPhone.log`记录旧阅读页观察点超时。其他开发失败包括目录白名单尚未适配实际首分类的动态参数/主机，以及测试表达式编译复杂度，均未隐藏或算作通过。

## 5. 剩余边界与回滚

S8仍待：原规则网页/iframe真实播放、真实视频/HLS与更多格式、真实受限登录、B122空结果、R146自己的图片TLS、iOS17和设备/发布门槛。#58/#64/#65独立，#73关闭。没有放宽TLS、自动验证、人为延迟或无限重试。

回滚仅撤回本轮RSS进度采样/seek保护、对应本地测试与R141受控验收、S8边界的显式HEAD/动态URL准入及文档片段；保留已有数据和之前各批次修改。不降级或清空RSSStore格式，不移除旧失败证据，不整体覆盖同文件中的#74/上一轮S8改动。
