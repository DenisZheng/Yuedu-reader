# mainJs 主脚本书源：实现与验收合同

## 范围

用户于2026-11-21确认：先交付已验收`8bcad47b`的Release IPA，然后下一独立分支先做mainJs。本批基于该提交；固定Android为`330e606c4d57e08adc056ff8ab7a4132c784da9a`。

完成单文件JS／JSON中mainJs的导入保真，以及搜索、发现、详情、目录、单章正文闭环。批量正文／副文、通用段评、LoginUiV2和迁移仍是后置项；保留相关脚本与字段不等于实现其功能。没有新增JS引擎、网络执行器、缓存、播放器或依赖的许可。代码在独立工作区实现，用户回退后的main及未提交文件原处保留。用户于2026-11-21在人工验收通过后明确指示“可以合入，并Push了”，授权本批功能提交及合入远端main；发布、打包和原工作区还原仍未获授权。

## 原生合同

- `BookSource.isJsSource()`只看mainJs是否非空；jsLib不触发主脚本模式。JSON中的原文保持往返，更新保持本地身份与不变不写。
- 单文件JS读取顶层`config`，兼容旧版`source`；必须有bookSourceUrl/bookSourceName，原始key不做URL归一化。剥离声明式rule*及自引用mainJs，保留其他配置；exploreUrl/loginUi数组转为对应JSON字符串。普通源必需search/getChapters/getContent，文件型源必需search/getBookInfo；exploreUrl非空须配explore。错误、不支持的协议和合法空结果分开。
- 导入只求值元数据，不授予java请求、登录、文件、Cookie或cache写入；导入／脚本／JSON重活不在主线程，且有大小与时间预算。实际主函数走同一BookSourceSession／SourceScriptHost／JSCoreEngine，共享现有请求、Cookie、限流、日志与源状态能力。
- 每次函数调用拥有新脚本scope，复用宿主JSContext与jsLib；函数内局部变量不串调用，源变量显式持久化。同源book/chapter上下文按完整turn隔离，不串书、不在await后引用旧上下文。活动宿主仅登记弱引用用于失效通知，不拥有第二份配置、脚本或缓存；即使被32项缓存驱逐，仍在执行的请求也不能因删除／配置变更逃过失效检查。
- `search(key,page)`／`explore(url,page)`返回数组或数组JSON字符串，null／undefined为空列表；非法顶层类型报错。缺name/bookUrl或非对象的条目按Android丢弃。结果source身份由宿主赋值。
- `getBookInfo(book)`可缺失或无返回，保留已有搜索字段；按canReName及缺字段规则合并，tocUrl缺省用bookUrl。文件型必须有有效downloadUrls，沿既有文件导入链，不伪造目录。
- `getChapters(book)`返回章节数组；标题／URL、索引、卷/VIP/购买标记、nextChapterUrl和book变量保持，空目录报错。沿现有TOC owner与合并缓存，不建第二份目录。
- `getContent(chapter,book,nextChapterUrl)`返回正文或媒体结果，不附加声明式分页／替换。卷占位不抓正文；非卷空正文报错。沿既有ChapterPackage、媒体处理和写回失效保护提交，不直接写阅读器或另建缓存。
- 字符串原样返回；JS对象／数组在同一执行预算内用JSON.stringify归一化，覆盖toJSON/getter。循环引用、缺必需函数、JS异常、超时、取消和过期源明确拒绝，不fallback到声明式抓取。

## 完成标准

1. 先以固定自建输入复现无searchUrl主脚本被拒、单文件JS无法导入，再改生产路径；不是增加字段后检查存在。
2. 隔离测试覆盖config／legacy、JSON往返、五阶段真实调用、对象与JSON返回、上下文变量、并发／取消／源修订、文件型详情、错误／空值／超时和元数据阶段权限拒绝。
3. 主流程从生产BookSourceFetcher调用，至少有本机fixture证明java请求复用既有请求上下文，返回目录／正文进入现有owner。
4. 运行最小关联回归、五语言检查、文档链接与git diff --check，结果写入[validation](validation.md)。不执行原包公网脚本、个人登录或授予系统权限。
5. 用户人工确认前不标整批验收完成，不自动合入或push。真机、iPad、最低iOS17、全部站点与其他后置协议未实际执行时明确未验证。

## 当前状态

本批约定范围的实现、自动门槛与用户人工验收已通过。2026-11-21用户明确反馈“验收OK，通过”，据此补齐本次提供流程的人工确认；不是把助手的界面测试当作用户操作。人工验收采用用户批准的系统Files根层文件位置绕行，原文件夹导航问题仍未修复。实现分支`feature/legado-mainjs-1022e1`，功能提交`d942f722`；用户随后另行明确指示合入并push。合并提交`c4a1d703`无冲突，已正常推送并核对远端main一致；合并树与已验收功能树完全相同，整合最小回归55项／7 suites实际通过。为保留root回退后的未提交文件，合入在干净工作区`../Yuedu-reader-mainjs-integrated-c50fb6c2`执行，不还原root。完整提交／回归／远端结果见[validation](validation.md)末节。此前自动验证的实际记录如下：

- 有效RED：`.artifacts/main-js/red-behavior.log`，2项／1 suite，单文件被当JSON、主脚本搜索返回空，3个issues／`TEST FAILED`。首次目录缺失和测试隔离编译报错不算行为RED。
- 关联GREEN：`.artifacts/main-js/final-regressions-3.log`，`Test run with 124 tests in 15 suites passed after 5.872 seconds`／`TEST SUCCEEDED`。包含主脚本16项以及scope、宿主队列、jsLib重入、变量、聚合搜索、详情合并、RSS、配置保真、不变不写、文件源、诊断与媒体类型回归。
- 活性检查新RED：`.artifacts/main-js/checker-red.log`，1项／3 issues，主脚本被错误跳过搜索并标空规则；修正后与真正离线fixture一起执行`.artifacts/main-js/checker-and-demo.log`，5项／2 suites，`Test run with 5 tests in 2 suites passed after 0.246 seconds`／`TEST SUCCEEDED`。这5项与上一批没有重复测试，累计129项／16个不同suite。
- 五语言及源码日志隐私gate、文档格式／链接和git diff --check结果见[validation](validation.md)。未跑全部测试，不新增实源可用率或真机媒体验收结论。

### 支持边界与未验证项

1. 主脚本预算8 MiB，元数据归一化1 MiB／2秒，运行返回归一化16 MiB；主函数沿原宿主30秒预算。取消拒绝返回与落盘，不保证立刻终止已经同步运行的JS或系统请求。
2. 复用现有LegadoRuleScope与RhinoNormalizer；原scope对strict、动态eval／Function、全局属性与jsLib可变闭包的已知差异没有被本批消除。不新建JSContext或备用规则引擎。
3. 单文件元数据是仅JS语言环境；没有注册请求、Cookie、cache或任意文件桥，也不自动下载jsLib。依赖原生能力或Android默认CryptoJS来计算顶层配置的脚本会明确失败，不假报完整兼容。
4. 本mainJs交付当时getContentBatch／maxBatchSize只保留，不执行批量回存；后续独立[批量正文批次](content-batch-source-batch.md)已接通并通过自动固定输入、两站实站适配和用户人工确认，已另行授权合入main并Push，不能混作本页原验收范围。通用段评及LoginUiV2仍后置；动态loginUi函数明确拒绝。旧loginUi数据校验login配对，但本批不新增主脚本登录函数调用入口。
5. 单一合法书籍位标记按自身域映射到现有阅读／媒体路径；混合多媒体标记、非文件型源临时返回文件类型、全部媒体格式／DRM未增加独立验收。不以字段推导当作播放通过。
6. JSON中mainJs仍按Android由非空判断模式，不在解码／保存时执行脚本；语法错、缺函数和非法返回在执行时明确报错。主脚本不再fallback到声明式网页抓取。
7. 实源公网、私人登录、iPad、最低iOS17、VoiceOver专项及真机尚未新增验证。主脚本配置变更／删除／用户源变量修改使已登记宿主失效；已被调用方复制的旧配置不是重新授权，不承诺任意离线快照都能代表当前store。

### 人工验收步骤

2026-11-21已按用户指示准备专用环境：`Legado mainJs 验收 1121-1542-2f9b`，UDID `A27135D7-0275-4227-9405-D4F4E8794FA1`，iPhone 18 Pro Max／iOS27.2。下载目录的`mainJs人工验收-1121-1550-58e3`含重开App／打开本机导入验收页两个command、5份自建样本和操作指南；已预置一个离线源，无书籍或私人账号。App中文主界面及本机Safari验收页实际已打开，下列为本次提供的人工流程；用户后续明确确认通过。预置文件、安装或启动本身不等于功能人工通过。

仅使用本分支新编译的Debug App，不能用刚交付的8bc Release IPA验收未合入功能。自建输入为[offline-demo.js](../../Tests/Fixtures/main-js/offline-demo.js)，函数不请求公网、不登录、不读其他文件、不改设置；自动测试已实际用该文件完成导入→搜索→详情→目录→正文缓存。

1. 通过「设置→来源配置管理→本地导入→从文件选择 .json／.js→浏览→我的 iPhone」直接选择`01-正常单文件.js`，不要进入文件夹。2026-11-21实际复现当前模拟器系统Files及App选择器都无法进入目录，重启未解决；用户批准把样本复制到系统Files根层，仍走真实文件选择和JS解析，不将绕行写成原目录已修。确认页显示“已有”时默认未勾选，勾选此源后保存；不会新增第二个同名源。
2. 在书架／探索搜索任意词，打开`主脚本测试书`；简介应含本次搜索词，不能只是导入成功。
3. 目录应有卷一和两章，卷一只作标题；第一章应显示`第一章变量`、目录总数3和第二章URL；第二章应显示其自己的变量。退出再进入仍可读。
4. 在源详情应显示`主脚本书源`，不是把空声明式规则误标成缺功能；主动活性检查应实际运行搜索轨道，且不附加“搜索链接规则为空”分组。
5. 确認取消导入不出现晚到确认页，检查最大字号／VoiceOver基本操作；按实际设备范围反馈，不据此声明全部源可用。

本次样本位置恢复的界面测试已实际通过：正常JS和legacy JS进入正确名称的确认页，缺getContent文件显示明确错误；测试取消两个确认，存储源文件SHA未变化。这不是用户人工确认，也不证明原文件夹导航已修复。日志见`.artifacts/main-js-manual/local-root-files-import.log`，1项UI test／`TEST SUCCEEDED`，临时测试源码保存在diagnostic-source，不纳入业务提交。

### 用户人工确认

2026-11-21用户在上述专用模拟器验收环境中反馈“验收OK，通过”。此前文件夹循环导航受阻，经用户批准改为“我的iPhone”根层直接选文件后确认；本批人工门槛按此次提供流程通过。没有逐项截图、书籍操作报告或VoiceOver专项结论，不把该反馈扩大为全部源、媒体格式、真机、iPad或最低iOS17都通过，也不声称原文件夹问题已修复。

人工验收与提交授权分开；用户随后已明确批准本批commit、合入和push，现已正常推送合并结果。为保留root回退后的5份未提交修改，整合在干净工作区基于远端main执行，不还原或覆盖root，也不将本批标为S8发布完成。现有下载目录8bc Release IPA不包含这批mainJs实现，本次授权不包含重新打包或发布。回滚只反向撤回本工作区这批代码／文档，保留首次Release IPA、原始包、所有用户数据和root工作区；不自动reset、删工作区或force push。
