# 小浣熊阅读专题复核：净化规则、云备份、RSS 入口与音视频书源

补充[全项目对比](LegadoIOSFeatureComparison.md)；实施顺序、接入函数和验收见[吸收方案](../docs/legado-alignment/legado-ios-adoption-plan.md)。L = 小浣熊阅读 `2ea3814`；Y = LegadoPro `5f2bea2d`。**优先修净化导入的范围丢失，再改善恢复前预览；不建议移植播放器或更换备份格式。** 以下分别标明源码结论和离线实测，未安装对方 App、连接 WebDAV 或试播真实媒体。

## 1. 净化：先保证“不该替换的书不被替换”

这里比较的是**读者自己配置的替换规则**，不是书源提取正文时的 `replaceRegex`，也不是 TXT 分章正则。

| 问题 | 小浣熊阅读 | LegadoPro 的现状与取舍 |
| --- | --- | --- |
| 对哪本书、哪个部位生效？ | [编辑页](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Rules/ReplaceRuleEditorView.swift#L101-L119)独立选择章标题、正文，可限定或排除书名／书源。[运行时](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ContentSanitizer.swift#L238-L259)先排除再限定，用“范围字符串包含书名或来源”判断，并非精确身份匹配。 | Y 的[运行时](../Modules/Core/Replace/ReplaceRuleStore.swift#L105-L124)接受全局或按分隔符列举的源地址；[本地模型](../Modules/Core/Replace/ReplaceRule.swift)没有独立标题开关、排除范围或每条超时字段。优先保住输入语义；不要把对方的子串匹配照搬成规范，尤其是短书名。 |
| 用户如何知道规则改了什么？ | [处理管线](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ContentSanitizer.swift#L157-L235)按顺序处理标题、首段重复标题、分段及正文替换，返回实际改变文本的规则 ID 和诊断。[试跑](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/ReplaceRuleTester.swift)使用当前草稿，刻意关掉自动去重标题和分段，便于看清**这条规则本身**的效果。 | Y [已有首部重复标题处理](../Modules/Core/ReaderCore/ReaderHTMLUtilities.swift#L2390-L2410)和[保留富文本属性的替换路径](../Modules/Core/Replace/ReplaceRuleEngine.swift#L117-L204)，不需要重建。建议预览分开显示标题／正文、未命中／不在范围／无效正则，并保留原文；完整阅读效果与单规则试跑要明确区分。 |
| 如何维护大量规则？ | [管理页](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Rules/ReplaceRuleManagementView.swift#L14-L83)可按组筛选、按名称或模式搜索、复制一条再试跑；过滤列表时禁用拖动，避免弄乱全局顺序。正则可用每条超时与 JS 替换，执行出错时保留输入并返回诊断。 | Y [手动导入器](../Modules/Core/Replace/ReplaceRuleStore.swift#L379-L425)把组名并入显示名，不是可独立筛选的字段。值得借的是结构化分组、复制试跑和错误反馈。JS 替换是额外的脚本执行能力，不是普通字符串替换；没有独立需求和执行预算，不建议随预览一起引入。 |

**同一包的实测差异。** 自建两条规则：T 只改标题；B 改正文，但排除《保留本》。送入 Y 的手动导入解析器，只返回 B，且 B 变成 `global`、编码后无排除字段。L 的模型和生产范围判断在普通书选择 T、B，在《保留本》只选择 T。这里测的是**导入结果与适用范围**，没有用真实书测试渲染。另一方面，Y 的[规则包订阅](../Modules/Services/RuleSubscriptions/RuleSubscriptionUpdateService.swift#L139-L163)遇到这些字段会拒绝整包，并不静默降级；[手动文件导入](../Modules/Features/Settings/ReplaceRuleListView.swift#L253-L271)走的是不同入口。

**建议顺序：** 先统一能力判断，让手动导入逐条告诉用户“仅标题／排除范围暂不支持”，不把受限规则当成功，不扩大应用范围；再补章标题、排除条件与草稿试跑。如果以后支持标题替换，只改显示，不用净化后的标题重算书签、章节身份或换源进度。验收用同一包走手动导入和订阅，另验证导出再导入、关闭规则恢复原文。

## 2. 云端备份：对方是“整包合并”，我们是“按类回到某个版本”

这里的“云”是用户自己的 **WebDAV**，不是账号后台、iCloud，也不是两台机器实时同步。差别最大的不是怎么上传，而是**取回来时谁覆盖谁**。

| | 小浣熊阅读 | LegadoPro |
| --- | --- | --- |
| 备份单位 | 本机导出和 WebDAV 共用一个 `.legadobackup`；[快照](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibrarySnapshot.swift#L14-L36)含书架、进度、分组、目录、书签、阅读统计、搜索词、书源、替换规则、RSS 源／收藏／阅读记录、TTS 配置等。可选带本地 TXT／EPUB；[取消携带时会连本地书架条目一起排除，文件缺失也会列为跳过](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibraryBackupArchive.swift#L232-L281)。这不是网络章节正文全量备份。 | [版本化 WebDAV](../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L185-L210)按书源、书架元数据、替换规则、RSS 分文件保存，书架类别不是本地原书；[RSS 备份提示](../Modules/Features/Settings/WebDAVSyncView.swift#L127-L136)明确不含正文或媒体。 |
| 上传和检查 | [整包](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibraryBackupArchive.swift#L30-L75)含清单、附件大小和 SHA-256，文件流式写入；WebDAV [PUT 单文件](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Sync/WebDAVClient.swift#L409-L430)。**校验不等于加密**，此封装不为书库内容提供端到端加密，源配置本身也可能含私密内容。 | [分类文件先传、manifest 最后提交](../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L419-L470)；缺少有效清单的残缺版本不列为可恢复。恢复时校验所选类别的内容和大小；[本地恢复日志](../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L293-L345)保护已有数据。应保留这套中断保护。 |
| 遇到已有记录 | [合并函数](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibrarySnapshot.swift#L138-L207)对同 ID 书比较阅读时间戳，时间相同再比章号和位置；已有书源、净化规则、书签、RSS 源优先用本机。同名同作者不同 ID 不一定新增；同设备同书的累计时长[取最大值而非相加](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibrarySnapshot.swift#L211-L231)。导入附件时[尽量复用已有可读文件](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Persistence/LibraryBackupArchive.swift#L296-L370)。 | [恢复页](../Modules/Features/Settings/WebDAVSyncView.swift#L289-L336)已有版本、类别、大小、选择和二次确认；[应用版本](../Modules/Services/WebDAV/WebDAVVersionedBackup.swift#L275-L329)是恢复所选类别，不是逐书挑较新进度。两种操作不能共用一个含糊的“恢复”说明。 |
| 何时自动、如何保留历史 | [自动策略](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Sync/WebDAVBackupPolicy.swift#L18-L93)默认关闭、默认间隔 24 小时、默认保留 10 份。启用后在[启动流程](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/LegadoApp.swift#L65-L84)检查到期，失败后至少 30 分钟再考虑。不是后台常驻定时器。[上传后清理](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Settings/WebDAVBackupModel.swift#L314-L355)会保住刚上传的一份，并删除超限旧包。 | Y 有[手动创建版本和查看历史](../Modules/Features/Settings/WebDAVSyncView.swift#L69-L100)；列表最多考察最近 50 个名称，**不是只保留 50 份或自动删除**。本版仍执行[暂停 iCloud 的决策](../docs/adr/0006-pause-icloud-for-current-release.md)。 |

**最合算的借法：先改预览，不动格式。** 在现有类别和字节数上补“本版本有多少本书／条规则”“不含哪些原文件”“所选类别将替换本机内容”。例如手机今天改了规则，备份来自昨天，确认前就应知道本地修改会怎样。以后如需“导入另一台设备并保留本机修改”，应作为与“回到旧版本”不同的操作；先用同书不同版、两侧都改过、重复导入、中途失败四种输入定合同。含原书、自动上传、自动删旧版均另行决定，不能以方便为由默认打开。

## 3. RSS：有模块，但普通用户为什么找不到？

- **代码确实在 App 内。** [Xcode App 编译列表](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Legado.xcodeproj/project.pbxproj#L918-L922)包含 `RSSViews.swift`；[RSS 首页](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/RSS/RSSViews.swift#L7-L48)有订阅、收藏、记录、导入和编辑；[App 启动时加载 RSS 数据](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/LegadoApp.swift#L65-L74)。不是只有数据模型或 README。
- **本提交没找到正常浏览入口。** [根 Tab](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/RootTabView.swift#L80-L111)是书架、发现、统计、我的。对 App 目录搜索 `RSSHomeView`，除定义外只有[书架的演示分支](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/RootTabView.swift#L53-L66)创建它；[参数读取](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/RootTabView.swift#L158-L164)要求 `-uiDemoTab rss`。这说明演示页面能被构造，不代表普通安装点得到。
- **“我的 → 规则订阅”不是 RSS 阅读。** [该页](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Rules/RuleSubscriptionView.swift#L5-L18)过滤掉类型 1；[新建器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Rules/RuleSubscriptionView.swift#L38-L63)只给书源、净化规则。备份中出现 RSS 源数也不是入口。Y 的[五个默认 Tab](../Targets/Yuedu/SharedApp/RootTabCustomization.swift#L16-L23)则明确包含“订阅”。所以“看不到 RSS”与“仓库有 RSS”可以同时为真；未核验其他发行版的界面。

## 4. 音视频：朗读、网页视频、媒体书源是三条链

| 要回答的问题 | 对方实际把什么交给谁？ | 我们该借什么？ |
| --- | --- | --- |
| 能否用音频书源听原声？ | L [编辑器](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Sources/SourceEditorView.swift#L130-L136)能选音频、视频。对音频型书源直接给章节地址、没有正文规则的情况，[取章函数](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/Book/NetworkBookService.swift#L565-L576)明确返回 `content.media_unsupported`。能找到的 [AVAudioPlayer／AVPlayer 调用](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/ReaderSpeechController.swift#L684-L752)拿的是按文字合成的 **TTS 音频**，不是书源的原声章节。 | Y [音频和视频详情分开](../Modules/Features/BookDetail/OnlineBookDetailDestination.swift#L75-L97)，从[书架打开](../Modules/Features/Reader/BookReaderView.swift#L80-L97)也有专属路由；[有声书播放器](../Modules/Core/TTS/AudiobookPlayer.swift#L86-L113)可解析章节、预载下一章、续播、跳转、倍速。L 对不支持输入给出具体原因值得借，不宜替换现有播放链。 |
| 能否按剧集播视频书源？ | L 的 [RSS 文章详情](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/RSS/RSSViews.swift#L337-L346)使用 WebKit；[RSS 视频分支](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/RSS/RSSWebReaderView.swift#L144-L162)生成带原生网页控件的 HTML `video`。但[网络书详情](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Books/BookDetailView.swift#L384-L396)进入通用 Reader，[阅读表面](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/ReaderView.swift#L706-L741)按图片或文本分流。本提交未追到 `bookSourceType=4 → 剧集流 → 专属播放器 → 按集写回进度`，不能用 RSS 条目类型或网页可播举证。 | Y 的[视频书播放器](../Modules/Features/Reader/Video/VideoPlaybackController.swift#L283-L329)由书和章号取流，再交给 AVPlayer；[进度写回](../Modules/Features/Reader/Video/VideoPlaybackController.swift#L548-L586)区分书和 RSS 条目。未发现 L 在**视频书源播放**上有值得搬的实现。普通网页继续用适合网页的控件，不据此承诺受限格式可播。 |
| 对方的媒体处理有哪一点真值得借？ | L 把“该不该自动恢复”做成[独立的朗读状态判断](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/Sources/LegadoCore/TTS/SpeechInterruptionCoordinator.swift#L53-L99)，而且[系统路由变化会实际通知它](https://github.com/Aminark/legado-ios/blob/2ea381463ed2230decdf2f7d3b4ef533636e05c6/App/Features/Reader/ReaderSpeechController.swift#L438-L460)。来电暂停后，即使系统随后允许恢复，只要中途拔掉耳机，就不应从扬声器继续。 | Y 的[有声书中断处理](../Modules/Core/TTS/AudiobookPlayer.swift#L1584-L1630)会记住恢复意图，但拔耳机分支先检查“当前是否正在播放”。**借这个事件顺序做回归，而不是借播放器**：中断时拔耳机／手动停止后不能外放；未拔且系统允许时可恢复。源码提示有边界值得测，未证明真机一定会错误外放。 |

## 5. 本次实际核验

以两仓固定提交取出原函数，在主机用 `swift -` 和合成输入执行；以下不是 UI、联网备份或播放测试。第三行假设自动备份已开启、已配置、没有最近一次成功；第四行是 L 的**朗读**状态机，不是 Y 播放器结果。

```text
Y manual: ["B"] scope: global keeps exclusion: false
L allowed: ["T", "B"] excluded: ["T"]
L due at 29/30 min: false true
L speech: pause none
```

<details>
<summary>复现上面四行（在 Y 仓库根目录运行；不发请求、不访问个人书库）</summary>

```bash
python3 - <<'PY'
import subprocess as sp
def src(repo, revision, path):
    return sp.check_output(['git','-C',repo,'show',revision+':'+path],text=True)
def run(*parts):
    sp.run(['swift','-'],input='\n'.join(parts),text=True,check=True)
L=lambda p: src('../legado-ios','2ea3814','Sources/LegadoCore/'+p)
Y=lambda p: src('.','5f2bea2d','Modules/Core/Replace/'+p)
rules='let input = Data(#"[{"id":1,"name":"T","pattern":"标题","scopeTitle":true,"scopeContent":false},{"id":2,"name":"B","pattern":"广告","excludeScope":"保留本"}]"#.utf8)'
ys=Y('ReplaceRuleStore.swift')
run(Y('ReplaceRule.swift'), 'func localized(_ s:String)->String{s}',ys[ys.index('enum ReplaceRuleImportError:'):], rules, '''
let ys = try ReplaceRuleImportParser.parse(data: input)
let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ys)) as! [[String:Any]]
print("Y manual:", ys.map { $0.name }, "scope:", ys[0].scope, "keeps exclusion:", rows[0]["excludeScope"] != nil)
''')
model=L('Domain/LibraryModels.swift')
san=L('Book/ContentSanitizer.swift')
test=san[san.index('    private static func ruleApplies'):san.index('    private func apply(')]
run('import Foundation',model[model.index('public struct ReplaceRule:'):],rules,
    'struct Book { let name:String; let origin:String }; enum Filter {',test,
    'static func names(_ rs:[ReplaceRule],_ b:Book)->[String] {rs.filter{ruleApplies($0,to:b)}.map{$0.name}} }', '''
let ls = try JSONDecoder().decode([ReplaceRule].self, from: input)
print("L allowed:", Filter.names(ls, Book(name:"普通本",origin:"source")), "excluded:", Filter.names(ls, Book(name:"保留本",origin:"source")))
''')
client=L('Sync/WebDAVClient.swift')
run(client[client.index('public struct WebDAVRemoteBackup:'):client.index('public enum WebDAVError:')],
    L('Sync/WebDAVBackupPolicy.swift'), L('TTS/SpeechInterruptionCoordinator.swift'), '''
let t = Date(timeIntervalSince1970: 200000)
var s = WebDAVBackupSettings(serverURL:"https://fixture.invalid", username:"fixture", autoBackupEnabled:true)
s.lastFailureAt=t
func due(_ n:Double)->Bool { WebDAVAutoBackupPolicy.shouldRunAutomaticBackup(settings:s,hasPassword:true,now:t.addingTimeInterval(n)) }
print("L due at 29/30 min:", due(1740), due(1800))
var audio = SpeechInterruptionCoordinator()
audio.didStartPlaying()
let a = audio.handleInterruptionBegan(ignoresAudioFocus:false,pausesForPhoneCalls:true)
_ = audio.handleRouteDisconnected()
let b = audio.handleInterruptionEnded(shouldResume:true,ignoresAudioFocus:false,pausesForPhoneCalls:true)
print("L speech:",a,b)
''')
PY
```

</details>
