# S8 开发收口与人工／发布验收清单

## 当前判断（2026-11-14）

当前代码与Release验证基线：`fdd60bd48714c1d38f78013731f120748348c921`（保留其前的`64149fd1`）；此后的验收文档提交不改变代码。**所列自动回归已通过，可以继续独立开发和发布准备；S8整体及发布验收未完成。** 推送供CodeReview不等于阶段验收或发布放行。

用户已明确选择：**保留现有iframe/JS支持，把R265/R267真实播放转入#58人工验收。** 这是验收方式调整，不是缩减产品能力：不关闭iframe、不改源规则或JS开关，不把真实播放写成通过，也不再为自动验收引入全站代理或逐请求拦截系统。生产行为仍以[规则网页合同](rss-source.md)为准。

#77为未定位的间歇风险、转监控；#78的客户端调查关闭，R146图片为外部证书链前置条件。记录和重开条件分别见[音频诊断](s8-audio-clock-diagnostics.md)、[R146 TLS](s8-r146-tls.md)。两者不阻塞无依赖开发，但历史失败和未验收状态保留。

## S1–S8 CodeReview范围

- **仅S1–S8增量**：以独立Fork/S0基线`bd6b0076`为排除端，与审查时固定的HEAD比较；包含后续S1–S8及相关兼容性、入口、诊断和构建修正，不因阶段名称过滤commit。
- **包含S0的完整Fork改动**：以项目原始iOS基线`f821dc9a7f35b375ea043c07fd1b95e15465e267`为排除端。Android行为对照仍固定`../legado`的`330e606c4d57e08adc056ff8ab7a4132c784da9a`，不更新基准。
- 先读[执行计划](implementation-plan.md)、[实际验证记录](validation.md)与下表。检查代码是否满足合同、测试是否实际覆盖行为；不要把“full47项通过”当成S1–S8全部功能／发布通过。
- 原始253/307项包、xcresult与私有原始日志不提交。离线合成合同可用于公共代码审查；需要固定实源包的测试在缺包时不能执行，不得用自造配置替代后声称实源成功。需要重跑时由操作员在本地提供原路径／已记录SHA-256匹配的输入，并继续遵守网络预审与预算。
- 对#77保留历史故障及重开条件；#78和人工项是未验收边界，不是已修复／已通过。审查不自动授权push、云构建、手机安装、第三方iframe加载或账号操作。

## 验收矩阵

| 项目 | 当前证据 | 后续动作／归属 |
| --- | --- | --- |
| S8 full自动回归 | 双端47项／12 suites通过，R146图片在结果中单列外部前置条件、不计通过 | 代码／测试合同不变时复用；变更时按影响范围重跑 |
| RSS网页返回与工具栏 | 当前提交前正常Dev宿主双端各12项（7合同＋5UI）通过 | 保留与容器Back／Close分开的网页历史Back |
| iframe/HLS本地能力与边界 | 双端7项规则网页／iframe-HLS合成合同及3项WebKit边界探针分别通过 | 只能证明固定fixture，不能代替真实R265/R267 |
| R265/R267真实iframe播放 | **未验证，转#58人工**；R265只读首页100项，R267仅离线配置审阅 | 另行确认精确目标和人工测试环境，执行下述记录卡；不阻塞其他开发 |
| 真实受限登录／Cookie | 合成CookieJar／路径隔离合同通过，真实站点未验证 | #58；先确认测试站点及无个人凭据方案，不自动登录或处理验证码 |
| 当前Release模拟器编译 | `fdd60bd4`构建通过，主App与两个扩展为iOS Simulator、最低声明17.0，无DEBUG条件 | 只证明当前工具链Release编译；不代表iOS17实际运行或真机归档 |
| 最低iOS17运行 | **未验证**；当前doctor只列出26.2／27.2，没有17.x runtime | #58；取得可用受支持环境后另验，不自动下载runtime或抬高最低系统 |
| 当前提交的物理设备媒体／VoiceOver／交互 | **未验证**；旧稳定`15a29143`真机S6通过是历史证据 | #58；保持不将当前主工作区安装到手机，另行授权后才做 |
| 真实WebDAV、正式iCloud／App Group与签名 | **未验证**；本地fixture不能替代服务／签名能力 | #58；先确认Fork自有环境、身份与授权，不修改现有个人账号或容器 |
| 当前iPhoneOS archive／IPA、品牌和分发许可 | **未验证**；旧云产物不覆盖`fdd60bd4` | #58；单独确认云构建／签名／发布，不自动push、触发CI、打包或发布 |
| 书源漫画翻页、视频反复弹出 | 独立故障 | #64／#65，不混入RSS验收 |

## iframe人工验收记录卡（尚未执行）

这份清单**不是公网／账号／手机操作授权**。操作员先另行批准一个精确入口及其测试环境；WebKit子资源由页面驱动，不能承诺“整页只发N次请求”，也不能把host哈希当作后续所有资源的白名单。

准备：

1. 固定App commit、构建配置、设备与系统、源包SHA-256、源编号R265或R267；源与状态使用独立测试空间，不把整包导入真实用户库。
2. 私下审阅单个被选条目的完整入口和参数，不把原始包、URL、query、headers、Cookie或正文写入工单／仓库。确认无个人账号、登录依赖、支付、下载／安装、发帖或其他写入操作。
3. 记录通过标准与停止条件。需要外部App／系统权限、登录／验证码、证书异常、非预期跳转或不可接受的副作用时立即停止，不绕过、不重复刷过。

每个批准目标只做一次人工流程：

- 从生产订阅列表打开该文章，保持原`enableJs`、`loadWithBaseUrl`和规则配置；不能换成提取后的直链播放器再宣称网页通过。
- 用真实用户手势启动网页播放器；记录可见画面、实际播放时间推进和可听声音。只出现iframe、HTTP200或页面完成都不是播放成功。
- 检查原生Close与网页Back可达；若有网页导航，Back回网页、Close退出容器。退出／切后台后观察媒体停止，不因一次无声就声称全部子资源连接均被取消。
- 重开同一入口确认没有旧容器残留。规则网页滚动位置与原生附件播放进度是不同合同，不要求不存在的跨源网页媒体进度回写。
- 记录成功、网站／权限前置条件、格式受限、取消或可复现客户端缺陷中的一种；失败时保存脱敏状态和原始本地证据，不自动重试。可复现客户端问题建立新缺陷，只有同类audio-only停钟证据才重开#77。

结果模板：

```text
commit / scheme / configuration：
设备 / 系统 / 执行时间：
源编号 / 固定源包SHA-256：
人工批准目标：仅本地私有记录；工单使用脱敏标签
生产网页打开 / 真实手势播放 / 画面 / 时间推进 / 可听声音：
网页Back / 原生Close / 后台与重开：
结果分类与停止原因：
本地证据路径（分享前脱敏）：
尚未验证的分支：
```

## 已执行的Release准备

命令在仓库根目录运行；Xcode和目标由既有脚本解析，没有新建DerivedData、clean、安装或启动App：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)"
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev \
  -configuration Release -destination "$YUEDU_DEST" \
  CODE_SIGNING_ALLOWED=NO build
```

本次实际增加`-resultBundlePath`保留构建证据：`/tmp/readerfork-s8-release-preflight.gAUsSt/`，含`commit.txt`、`sim-doctor.txt`、`build-settings.json`、`build.log`、`build.xcresult`、`build-exit.txt`与`summary.json`。

- Release构建退出0，Xcode／Simulator SDK27.2，无`DEBUG` compilation condition；原工程实际Swift语言模式为6.0，未修改设置。
- 主App和`.shareextension`／`.widget`扩展的Bundle ID均为Fork开发命名空间；三者平台为`iphonesimulator`，最低声明17.0。Mach-O build version为`IOSSIMULATOR`／minos17.0；主二进制符号未发现DEBUG-only `RSSAudioHostComparison`。
- 这些是编译及产物检查，不是Release运行、真机签名、iOS17或可听声音验收。没有archive／IPA产物、云构建或发布。

## 回滚与阶段状态

本轮只有验收说明／记录调整，生产代码和自动门槛manifest不变。撤回本清单和同步说明即可回滚人工分流决定；不删除历史证据或源包，不恢复已泄露日志、不重开已转监控的#77。完成上述人工／设备／发布门槛前，`stageAccepted=false`保持不变。
