# 批量正文：本批实施与验收合同

## 范围与基线

用户确认按建议开始下一批，只补批量正文；副文、段评、LoginUiV2、迁移、跨端同步、Web/MCP、UMD、视频快进和发布均不混入。本批分支`feature/legado-batch-content`，base`fe4d28be`。人工确认后用户另行明确要求提交并Push，且选择“合入main并推送”，授权本批功能提交和正常合入；发布、打包及删除环境不在授权内。

Android固定`330e606c4d57e08adc056ff8ab7a4132c784da9a`。合同以`BatchContentContext.kt`、`BookContent.analyzeContentBatch`、`JsSourceBook.getContentBatchAwait`、`CacheBook.runBatch/downloadBatchAwait`与`BookSource.supportContentBatch/contentBatchSize`为准。只读对照，不修改Android仓库，不复制原始源包或运行私人脚本。

## 必须兑现的行为

- 声明式源需要非空contentBatch与大于1的maxBatchSize；mainJs源需要批量函数配对，导入保留并回填数量。最多50章，未启用则走单章。
- 普通阅读保留单章路径；现有下载／预读链可共用一个在途批量请求，不能建立另一份正文缓存。
- JS源调用getContentBatch(chapters,book)，声明式规则以result提供本批数组，并兼容裸JS、@js:与连续纯<js>片段。批量结果以java.cacheContent(chapter,content)逐章回存，不用函数返回值猜内容。
- 身份使用本批chapter.index；对象可以区分同URL多章，URL字符串仅唯一命中才可接受，数字不作为数组下标或章节号猜测。未知／歧义标识明确报错。
- 空回传不记完成；正文替换沿现有规则引擎，章节变量不能串值。副文和额外媒体能力留下一批。
- 缺可选函数或未回存章节交给既有单章流程。脚本先回存部分再失败时保留已完成部分，明确记录失败，只回退未完成章节；取消／失效不是普通失败，不自动重试。
- 同一书／配置／批量窗口合并在途请求；一个等待者取消不应取消仍有下载者共享的批量。清理书缓存、单章新写及源删除／修订拒绝旧批量写回；不复活已删数据。
- ChapterCacheRepository继续拥有所有正文文件，增加在途写入票据用于实际竞态保护，不创建平行持久层。内容与资源相同不推进savedAt或重写文件；合计16 MiB批量回传预算，沿既有源宿主／请求预算和限流。

## 反馈与验收

先以既有API固定输入复现：ContentRule仅保留未知字段而不可执行，以及生产主脚本宿主缺cacheContent。实际RED为2项／1 suite／3 issues，TEST FAILED（`.artifacts/content-batch/red.log`），不是编译／启动错误冒充行为差异。

后续需要真实三章回存、两种源、对象／唯一URL／重复URL、变量隔离、部分回存／异常、单章回退、不变不写、50章和字节预算、取消／删除／缓存清理及共享下载保护测试。用动态Xcode／目标和既有scripts/xctest.sh串行回归，不clean或新建DerivedData绕过错误。

自动通过后再准备自建离线源和直接人工步骤；用户确认前不标整批完成或合入。iPad、真机、最低iOS17、VoiceOver专项、原文件夹导航及真实公网源未验状态保留。旧8bc Release IPA不包含本批实现。

本批自动门槛、用户批准的两站实站适配验证与用户人工验收均已通过。用户于2026-11-21明确反馈“验证OK”，按本次提供流程补齐人工确认；人工通过不自动授权提交／合入；用户随后另行明确指示“合入main并推送”，现进入保存功能提交和正常合入交付流程，最终结果以validation末节为准。结果写入[validation](validation.md)。回滚只撤回本批代码／文档，保留原私有源包、备份、App与模拟器数据，不reset main、不清理工作区或force push。

## 实施结果与证据

- 使用既有SourceScriptHost／BookSourceSession，批量java桥只在当前调用期间安装，完成／失败撤销；主脚本与声明式直接JS调用均挂上原规则读者，不注册另一套解析器。
- 批量替换切换到当前章节和变量，再恢复原读者；新增固定输入曾实际发现index／变量未切换，以及直接JS未挂规则读者、把数组误作解析文档导致java.getString空值。修复以单测输出为准，不修改测试期望。
- ChapterCacheRepository增加在途写入票据与互斥，清理、另一单章写入或新票据使旧写失效；不变时跳过全套文件重写。票据完结释放，只跟踪在途操作，不成为第二份正文store。
- ChapterFetchManager在下载／预读调用中合并本书配置窗口的批量，只回退未回存章；共享等待者按明确完成／取消事件退出。普通immediate／jump仍单章，取消读者不取消仍在等待的下载者。
- 新锁可能与主线程上的旧清理入口相遇，因此只把阅读器刷新和详情清缓存改成后台清理实际完成后更新UI；标题、布局、入口不变，没有sleep或延时稳定状态。
- 批量配置的非法数量不能被旧宽容解码吞成空ruleContent；保留双重编码、未知字段和旧普通源，6个新增错误key同步五语言。

实际自动结果：主回归79项／8 suites／9.318秒／TEST SUCCEEDED；另1项离线交付fixture读取→导入→搜索→详情→目录→批量三章及变量，0.171秒／TEST SUCCEEDED。15个本批测试均实际运行，两个非重叠批次共80项。五语言Localization OK，源码日志隐私3项／OK，文档与diff检查见validation。

## 人工环境

本次新建设备`Legado 批量正文验收 1121-2035-da64`，UDID`A780DBD1-9AB4-4681-8B89-05CFB5B2B15E`，iPhone 18 Pro Max／iOS27.2，安装当前Debug并预置1个自建源、无旧书架／账号。下载目录`批量正文人工验收-1121-2045-40cd`包含指南、3样本和已执行验证的重开command。系统Files“我的iPhone”根层直接选文件，不进入文件夹；原导航问题未修。

操作概要：探索搜索“批量正文验收书”→加入书架／阅读→下载三章→逐章检查变量和批量标记→重开；部分失败样本检验已成功保留和剩余单章回退。阅读器可能先加载单章或预读邻章，因此不为演示删除已有缓存，单章与批量标记并存允许，不能凭下载完成字样代替正文验证。完整步骤在下载目录指南。

环境安装、源码测试和重开命令不等于用户人工确认。完整媒体／DRM、iPad／真机／最低iOS17／VoiceOver专项仍未新增验收；副文、段评、LoginUiV2仍后置。没有发布、打包或清理旧环境，现有8bc IPA不含本批实现。

## 用户授权的实站适配验证

用户要求助手先验证实书源，通过后才交人工。只读原253项包后确认其中无mainJs/contentBatch/maxBatchSize；公开检索的相关例子均为框架fixture，没有据此宣称不存在任何原生批量源。用户在集中询问后明确选择“实站适配验证”：原样普通源回归，再临时添加批量规则；原包不动，不把适配副本叫作作者原生批量源。

2026-11-21实际验证B236（0-based index235，quduwx.net）与B250（index249，yetianlian.la／已核对重定向xyetianlian.com）：原样搜索→详情→目录→三章单章正文通过；隔离副本使用原正文提取／替换规则逐章cacheContent，三章均已回存且与原单章内容去空白后逐章一致，没有串章。各9／10请求，加上两个搜索空结果候选各1，共21个Swift受控请求；四个只读站点预审GET另计，不算功能通过。

两个未进入正文的候选只记录固定词搜索空结果，不说站点故障或程序已修，不计通过。实站限定GET/HEAD、固定公共域名、不请求个人Cookie/Authorization、最多16请求/源、每响应2 MiB、传输超时、隔离runtime/authenticationKey/cache、限制诊断。没有登录、购买、发帖、脚本文件写入或更改系统权限。

命令为scripts/xctest.sh选择临时RealSourceBatchValidationTests；真实1项／20.412秒／TEST SUCCEEDED，决定性输出REAL_BATCH index=235 original=PASS adapted=PASS chapters=3 requests=9和index=249同样PASS／requests=10。临时测试已移至.artifacts/content-batch/real/diagnostic-source，常规test target不留自动公网探针；报告validation.json和脱敏live-3.log保留在该目录，不公开原包、源规则／登录配置／正文。

实站适配门槛通过后，用户在提供的人工环境中明确反馈“验证OK”，本批人工门槛据此通过；不是用助手的自动输出代替用户操作。此结论仅本次流程、两代表实站及隔离适配规则，不代表作者原生批量包或全部书源可用。没有逐项截图、真机／iPad／最低iOS17或VoiceOver专项的新结论。用户已在人工确认后另行明确授权保存功能提交、合入main并正常push；完成状态以validation末节实际Git结果为准，不把授权写作已完成发布。
