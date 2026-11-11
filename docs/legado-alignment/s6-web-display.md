# S6：独立网页缩放、越界弹层与当前基线复验

## 结果与范围

以用户确认的 `0f31f857` 为基线独立实现，没有恢复回退前的提交。独立网页新增用户主动缩放与始终可用的原生关闭；分类/Feed 404 缓存修复及音频诊断一并完成当前双设备自动回归。**本地自动门槛通过，不等于真实站点或发布验收通过。** 真机仍暂停。

这不是广告拦截器：不删除 DOM 弹层、脚本或 iframe，不改源配置。原始 R062/R306 没有联网复测；任意负坐标、无限生成弹层或主动覆盖 viewport 的站点仍可能需要用原生关闭退出。

## 实现决策

- `RSSSourcePageScreen` 使用原生 Menu/Picker 提供 10%、25%、50%、75%、100%、150%、200%；当前倍率纳入 VoiceOver 标签。关闭和缩放控件保留至少44pt点击区，推入/模态标题仍为 inline。
- `RSSWebViewport` 只在独立网页、用户选择时调整主文档 viewport；默认100%不改作者属性。缩放不重新请求、不重载、不重新执行源规则，也不启用被 `enableJs=false` 禁止的页面脚本。规则文章和登录调用方默认不参与。
- 通过 WebKit 的 `callAsyncJavaScript` 和 `.defaultClient` 隔离世界保存 viewport 原属性；DOM变化可见，但快照与控制变量不暴露给网页。100%恢复全部原始 content 属性，包括没有 content、多重/大小写不同的 viewport；原来没有 viewport 时移除本次创建的节点。
- 最多保存32个节点；超过预算先失败、不部分改写。Swift与JS两侧检查修订号，迟到选择不覆盖新选择；导航、撤销和拆除取消显示任务。错误显示固定本地化文案，不包含网页异常原文。
- 仅独立网页设置 `WKWebViewConfiguration.ignoresViewportScaleLimits`，允许用户缩放；没有使用私有 API、URLProtocol 接管、通用代理或新增依赖。WebKit自行处理后续布局与旋转。
- 首文档仍沿 `RSSOpenTarget` / `RSSSourcePageWebView` 的既有请求、Cookie、权限和失效流程。分类/Feed 404修复见 [S6缓存复查](s6-rule-web.md#用户反馈复查404缓存与分类切换)，没有增加第二套缓存。

官方接口依据：[callAsyncJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:))、[WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld)。`ignoresViewportScaleLimits` 的最低版本同时核对当前 SDK 公共头文件为 iOS10；不能误用 iOS26 的新 WebPage API 可用性来判断 WKWebViewConfiguration。

## RED → GREEN

所有输入均自建、无敏感内容；UI宿主只提供HTML，不读取用户RSSStore、不连接原始源或账号。

| 证据目录 | 结果 |
| --- | --- |
| `/tmp/readerfork-current-viewport-red.SXDvv2/` | 生产首文档、标准HTML超大固定弹层：脚本开/关两个输入都失败，缩小请求没有让关闭按钮进入视口。 |
| `/tmp/readerfork-current-viewport-green.icUTJp/` | 实现显示控制后，同一测试的两个输入通过；请求次数不增加、脚本开关不变、100%还原。 |
| `/tmp/readerfork-current-viewport-ui.7hucAH/` | 首轮扩展测试失败：元数据测试在空文档阶段过早采样；UI把系统Menu不提供的AX value当成当前倍率。实际缩放后的按钮已经位于网页中。修正为等待生产loading完成，并将当前倍率写入可读标签，未增加等待时长或移除行为断言。 |
| `/tmp/readerfork-current-viewport-ui-retry.rom6ex/` | 3项单元（含参数输入）+3项UI全部通过，实际点击两层DOM关闭并保留页面状态。 |
| `/tmp/readerfork-current-s6-viewport.SsfuYj/iPad/s5/` | 首轮iPad完整前置失败：既有 `RSSOpeningViewTests/remoteSearchAction` 的查询作用域没有在原8秒截止内出现。该批不计通过，未修改搜索实现或测试时限。 |
| `/tmp/readerfork-current-ipad-opening-control.uKIZfJ/` | 原条件下单独运行opening/toolbar的16项全部通过，随后再完整复验。 |

## 最终双设备门槛

正常 `Reader-Fork-Dev`，Xcode/目标动态解析；实际iOS27.2 (24B8117)，两设备串行，沿用既有DerivedData。没有单独build/clean、清模拟器或自动重试脚本。

| 设备/最终证据 | S5前置 | S6单元/集成 | 网页UI |
| --- | --- | --- | --- |
| iPhone：`/tmp/readerfork-current-s6-viewport.SsfuYj/iPhone/` | 270项/38 suites | 101项/20 suites | 3项/1 suite |
| iPad：`/tmp/readerfork-current-s6-ipad-recheck.AU0Pd7/` | 270项/38 suites | 101项/20 suites | 3项/1 suite |

最终两批零失败、零跳过，阶段脚本逐suite检查；UI额外检查三个具体用例全部实际执行。数量变化来自当前基线新增的分类/Feed重试、首文档重试与视口用例，不能与回退前其他分支的数量直接等同。不同集合存在重叠，不相加为独立覆盖数。

UI实际覆盖：两层DOM关闭→原页面脚本操作→100%恢复仍保留状态；关闭/重开默认100%；原始超大弹层与缩小状态下的原生退出；横屏、深色及AX5。最终 `screens/` 导出附件已检查，深色原生工具栏清楚，HTML保留作者白色背景，不把网页颜色强改为深色。AX5自动操作不替代真人VoiceOver。

命令（分别选择iPhone/iPad；每次使用新证据目录）：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)" YUEDU_SCHEME=Reader-Fork-Dev
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)"
EVIDENCE="$(mktemp -d /tmp/readerfork-s6-current.XXXXXX)"
YUEDU_EVIDENCE_DIR="$EVIDENCE" bash scripts/validate_reader_fork_s6.sh
```

脚本保留完整音频/MP4/HLS及实际时钟断言，并纳入 `RSSWebViewportTests` 和 `RSSWebDisplayUITests`，不以旧子集通过替代本轮新增行为。

## 音频诊断和剩余限制

用户确认Mac主机音频正常；此前 `afplay` 单命令失败不代表主机整体故障，也不是App验收前置。仅为本地/HTTP测试增加会话激活、item状态、seek、播放边界和拆除时间线，保留原暂停/拆除→恢复会话顺序和ready10秒/时钟8秒断言；没有修改生产播放器或声称唯一定位旧间歇问题。

正常Dev媒体前置两端各36项通过，证据 `/tmp/readerfork-current-baseline-media.7Z21AR/`；正常→隔离→正常宿主的本地对照在 `/tmp/readerfork-audio-host-controls.G3Ilua/`。隔离对照仅用于定位，不代替生产宿主。最新完整S6两端也实际执行音频并通过。

仍未验证：R062/R306当前实站、iOS17、真人登录/VoiceOver、DRM、真实WebDAV、正式iCloud/App Group签名。S7恢复中断/后台重载与入口边界仍按当前Todo推进；本轮不记S7或S8完成。

## 回滚

可撤回本轮显示控制、fixture/测试、诊断及脚本增量；不涉及持久格式，不删除源、文章、用户设置或模拟器数据。回滚默认请求session会重新引入隐式404缓存风险，必须单独披露。原始源包保持不变，未Push或触发云归档。
