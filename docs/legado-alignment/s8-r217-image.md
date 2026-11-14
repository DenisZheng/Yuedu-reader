# S8：R217公开RSS图片资源闭环（2026-11-14）

## 判断

**R217新增一条双设备通过的公开图片闭环。** 在固定307项包的SHA-256保护下，经无凭据只读首列表预审，只允许其第一条精确列表URL；生产`RSSFeedSession`解析18条，各有图片引用、17个唯一目标。所有目标均为HTTPS、无query/fragment/内嵌凭据，目标host集合仅含预审hash `0336c9b73661988775e65e74fb5b8a891afe86e13bbf4b226c25b51e440860b1`，扩展名只有PNG/WebP。双端列表的计数和目标host形状一致，首个目标URL仅记录SHA-256 `a8dfb32af7f036c216fc9d3222840cf2ee9a078675b6ff5e7c98f35ac02c5aef`；从未写出完整URL或query值。

第二步生产管线只准入该首图的**确切**HTTPS URL（第一步指纹匹配后显式加入隔离请求边界），调用`RSSImageService.load`，原生检查WebP并由`displayImage`解码，随后标已读/收藏、落盘，重建`RSSStore`验证状态和图片目标重载。iPhone与iPad均两项HTTP事务：列表GET 200 + 单图GET 200，唯一跨origin事务是明确预审的该图；0凭据头、0重定向、0额外图片请求。解码为12,838 B、480×300。它只证明R217这一页的一张图片，不等于所有17图、其他分类、正文/iframe或受限登录通过。

## 独立候选的停止结果

另一个离线通过静态筛选的候选R128，双设备各只取预审首列表1次GET/200，生产解析20条；当时20条均无`imageURL`，未发出图片请求，测试冻结这个观察为**无图即停止**，不再重试该源或自动打开下一页。它不是生产解析器失败，也不计图片成功。

## 请求、状态与证据

- R217最终双设备结果：`/tmp/readerfork-s8-r217-image-cookie-audit-{iPhone,iPad}.xcresult`，对应日志`/tmp/readerfork-s8-r217-image-cookie-audit-{iPhone,iPad}.log`。每端核对1个测试、0失败、0跳过，控制台仅含计数、MIME、字节/解码尺寸、host及URL哈希等白名单元数据。
- 独立R217首页预审（每端1 GET、0图）及确切首图指纹的重复预审见`/tmp/readerfork-s8-r217-image-target-fingerprint-{iPhone,iPad}.xcresult`；生产闭环执行仍独立重新审查页面并要求固定图URL哈希相等，任何目标变化都会在图片请求前失败。
- R128 no-image形状：`/tmp/readerfork-s8-r128-image-preflight-final-{iPhone,iPad}.xcresult`，每端1项通过。
- 最终精确集同时断言R217的18条/17图、唯一host、无query/fragment/凭据、PNG/WebP目标，以及首张WebP的整URL SHA-256；隔离session最多2次准入，不跳页、不重试。资源请求不携带持久Cookie；并在图片URL请求前核验目标Cookie存储为空，响应后再次确认未向任一Cookie存储落值。请求/HTML解析错误输出固定类别，不输出URL、响应正文、请求头或任意异常文本。

## 过程中的失败与纠正

过程失败均发生在网络请求前或测试条件断言处，不隐藏为通过：最初候选测试误用RSS模型不存在的`type`属性（模型域字段为`contentType`）；R128第一版把“存在image rule”误作“当前首页必有图片”并失败，后改成冻结实际的20条、0图观察。R217首版将`sortUrl`分类数误数为8，随后又把分类URL错判为跨源；检查生产`LegadoSortURLParser`的`name::url`边界及Swift `URL`解析后证实是同源HTTPS的7项分类，失败用例在`RSSFeedSession`发请求前已停止。最终测试先只做列表与目标指纹，再单独将精确首图纳入两请求预算并通过；这些旧失败result bundle保留，不替代最终结果。

## S8边界与回滚

此图片闭环不能覆盖R146的系统TLS失败（`-1202` / `-9814`），不变更CA/网络/时间/校验。R265/R267真实iframe继续未验：WebKit第三方子资源不受这个URLSession测试边界统一控制，见[iframe预审](s8-iframe-preflight.md)。#77历史音频停滞根因仍未定，不因R217通过而关闭。R146图片后来改列外部前置条件，full manifest为47项/12 suites并已在双设备整套通过（见[自动回归记录](s8-regression-gate.md)）；真实R217图片和R141 MP3只在full范围，nonmedia为22项/5 suites；`stageAccepted=false`仍是阶段状态。

回滚仅撤下本次R128/R217隔离实源用例及对应门槛/文档；不改生产RSS图片、Cookie/TLS/请求逻辑，不改原包、不触碰用户数据。无真机安装、提交或推送。
