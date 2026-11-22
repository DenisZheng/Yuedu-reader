# 副文：声明式获取、分型回存与原生查看

> 当前交付：2026-11-22 已合入并推送 `main`（业务合并 `81e89c91`）。下文保留独立开发与自动验收的历史范围；总体状态和限制见 [项目状态页](STATUS.md)。

## 本批范围与授权

基线为main `7be2c8c1`，开发分支`feature/legado-sub-content`，Android固定`330e606c4d57e08adc056ff8ab7a4132c784da9a`。用户授权按建议自动开发、测试和助手验收，且人不在屏幕前、不提问汇报；不再把用户人工确认作为本批继续开发的条件。助手自动操作与用户人工反馈分开，未自动commit、合入、push、发布、修改账号或删除已有环境。

本批先接副文获取／保存／查看，不重写播放器。依据固定Android `BookContent.kt:131–165`：文本副文直接按当前页面规则取值，追加在正文替换前；文本结果即使是URL也不额外下载。音频歌词、视频弹幕单独保存，结果为HTTP地址时再请求；图片不当成文本副文。固定`BatchContentContext`不自动执行subContent，因此批量仅保存源脚本主动通过`chapter.putLyric/putDanmaku`写出的内容，不重复调用规则。

## 实现与身份

- `ContentRule.subContent`进入执行模型，未知字段保真仍保留。共享SourceScriptHost与BookSourceSession完成规则和网络，未创建另一JS引擎、请求解析器或歌词缓存。
- 文本在原页面／章节变量上下文追加后执行原replaceRegex；媒体内容仍是可播放地址，不混入歌词／弹幕。分页副文按当前章更新，正文继续按页合并。
- 远程副文复用AnalyzeUrl及SourceRequestExecutor，响应含charset/bodyJs／登录检查；同源等待期间恢复本章快照，不能读到交错请求的chapter。WebView型副文不扩大为通用网页代理，明确请求失败。
- 只对副文新增最大1 MiB资源限制，最多10,000条显示数据；源私有头按原站／当前内容页范围继承，跨域不盲传，目标显式URL options头仍属于该请求；重定向继续受原请求边界约束。
- `ChapterSubContent`保存在唯一ChapterPackageArtifact，可选字段向后兼容旧缓存；按bookID／chapterIndex与正文共同保存。主脚本与批量源都支持明确的chapter歌词／弹幕桥，预算超限报错，章节不串值。
- 单章所有保存路径使用原缓存写入票据。取消、清缓存、删源／改配置使晚到结果失效；副文改变不是无变更，正文与副文／资源都相同才不重写。
- 副文规则／请求／字节失败保留主内容，并记录固定失败分类，不存私人异常／请求地址；合法空结果与失败分开。用户重新刷新章节／清缓存后可重新获取，未创建静默无限重试。

## 显示边界

在线书架有声书菜单提供“歌词”，不依赖eventListener／自订按钮；视频播放器有“弹幕”入口。两者使用原生List和inline模态标题，显示LRC或XML时间文本，点击时间行调用既有播放器定位。空／加载／错误／关闭状态与Preview已补，9个新key同步五语言。

本批是有限的原生副文列表／时间定位，不宣称复刻Android的滚动弹幕引擎、全部歌词格式或实时高亮。LRC与常用XML弹幕有固定输入；JSON等未映射格式明确报受限，XML不允许DOCTYPE／外部实体。没有新增播放器依赖或系统权限。

## 实际反馈与自动验收

- 原始缺口：2项／1 suite真实RED，文本副文缺失和ContentRule不承载subContent，日志`.artifacts/sub-content/red-2.log`。第一次60秒工具超时没有行为结论。
- 原生chapter歌词桥缺失也已实际复现，11项中的1项.javascript失败，`media-bridge-red.log`，不是编译错误冒充行为失败。
- 最终相关回归：88项／7 suites／4.516秒／TEST SUCCEEDED，`final-regressions.log`。包含副文、批量、mainJs、cache写入／旧缓存和阅读路径／分页。
- 主体测试覆盖真实生产下载及artifact重载、缓存不额外请求、文本URL／图片隔离、副文503／字节上限／脚本异常、同源请求交错、两种批量主动副文、清缓存／取消／源失效和不变不写。
- 助手自动UI：新隔离设备`Legado副文自动验收-bb6f66`／iPhone 18 Pro Max／iOS27.2，UDID `BEC54913-3551-4004-AC0B-5B2A130F55B0`。5本自建资料，媒体仅本机静音WAV／既有自建视频，不使用个人源或账号。
- UI首次真实发现“歌词入口错误依赖事件监听”的问题；修正普通在线书入口后2项／96.768秒／零失败／TEST SUCCEEDED（`ui-2.log`）。实际打开歌词、点击第二条时间、关闭／重启；打开空／请求失败状态；视频弹幕列表／时间行／关闭。截图保存在该次xcresult，不把它叫用户人工验收或真实站点播放证明。
- 临时UI及导出探针已移出常规Tests到`.artifacts/sub-content/probes`，避免以后自动运行依赖本机fixture／媒体服务。隔离设备和数据保留，只关闭本次有64请求上限的本机媒体服务。

期间出现过测试启动握手等待：App sample停在XCTest `_prepareTestConfigurationAndIDESession`，未到业务测试。保留日志／sample，只停止当次测试进程，未擦除模拟器或新建DerivedData；后续实际88项及UI完整结论有效。另一次发现fixture固定sourceKey的历史计数污染，测试分配随机sourceKey隔离，不改源期待或生产变量语义。

五语言、源码隐私3项及文档／diff检查见[validation](validation.md)。仅此范围自动验收通过：没有用户新的逐项人工反馈，未验证真机／iPad／最低iOS17／VoiceOver专项、全部实源／格式／DRM、真实账号。后续继续独立段评与LoginUiV2开发，不把这些后置协议写成本批完成。
