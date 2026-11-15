# 自签IPA静态审计：App身份、权限模板与文件浏览声明

## 输入与范围

用户提供下载目录`LegadoPro_3.0_20261115_200253.ipa`，症状为App与选择器能打开，但点击JSON后不返回；“文件访问”开关已开启。本次只读解包和核验，不安装、不重签、不改原文件，不输出证书身份、设备标识或私有配置。

对照原本地SDK27.2 Debug未签包，原包SHA-256为`399292252d5a26a5cbad061d7dd4992ca5b3d74ac88aa004fa3df317669409b7`。审计元数据、实际entitlements与profile仅保存在本地`.git/selfsigned-ipa-audit.z26_xl_9/`；公开记录不含其App ID前缀或签名服务商固定标识。

## 已执行的检查

- 用户包ZIP CRC通过；审计前后用户IPA SHA-256相同，未修改原文件。
- `codesign --display --xml --entitlements -`读取三个Bundle实际签入权限；`security cms -D`读取嵌入profile，均成功。
- `codesign --verify --deep --strict --verbose=2`完整嵌套验证退出码0。这证明代码签名／资源完整性，不等于所有实际权限类型、App身份和系统文档行为都正确。
- 三个可执行文件的`__TEXT.__text`／`__TEXT.__cstring`哈希及Mach-O UUID与原包一致；没有新增动态库。实际Mach-O仍为SDK27.2、minos17.0。
- 首次代码段脚本假定存在独立Debug dylib，遇文件不存在停止；检查原包与签后包都无该文件后，只对实际三个可执行文件重跑并通过，未用缺失文件充当验证成功。

## 确定的签名后差异

### 1. Bundle身份与实际App ID不一致

| Bundle ID | CodeDirectory Identifier | 实际application-identifier |
| --- | --- | --- |
| `dev.denis.readerfork.dev` | 与Bundle ID相同 | 固定的其他App ID，后缀不匹配 |
| `dev.denis.readerfork.dev.widget` | 与Bundle ID相同 | 与主App相同的固定App ID，后缀不匹配 |
| `dev.denis.readerfork.dev.shareextension` | 与Bundle ID相同 | 与主App相同的固定App ID，后缀不匹配 |

三个Bundle使用同一个profile，profile的App ID是固定值，不是通配符。签入的App ID确实被该profile授权，但不是这些Bundle ID；签名Team与profile一致。不能仅把签入App ID改成`dev.denis.readerfork.dev`来修复，因为当前固定profile不授权它，应先取得匹配的profile或明确调整整套应用身份。

### 2. 将profile授权模板整份当作实际权限

三个Bundle签入的entitlements均与profile的Entitlements字典完全相同，包含大量本App未申请的能力。特别是：

- `com.apple.developer.icloud-services`实际为字符串`"*"`，而Apple公开定义是字符串数组；它是授权模板中的通配形式，不能据此认为App正确申请了iCloud服务。
- 实际App Group有5项，但不包含Fork所需`group.dev.denis.readerfork.dev`；这不证明普通JSON选择必须依赖App Group，但共享扩展／Widget不能因此视为授权正确。
- profile记录未过期并包含目标手机。`get-task-allow=false`与profile一致，是非开发签名的正常调试限制，不能把它作为JSON选择失败原因，也不建议强改为true。

### 3. 改写原有Info.plist语义

| 字段 | 原未签包 | 用户签后包 |
| --- | --- | --- |
| `UISupportsDocumentBrowser` | 未声明 | true |
| `UIFileSharingEnabled` | true | true |
| `LSSupportsOpeningDocumentsInPlace` | true | true |
| `MinimumOSVersion` | 17.0 | 10.0 |
| `UIRequiredDeviceCapabilities` | 原包声明 | 被移除 |

原包已经具备普通App的文件共享／原地打开声明；`UISupportsDocumentBrowser`是文档型App标记，不是一般文件读取开关。该新增声明会改变系统文件提供器／文档处理语义，是与“同步至iCloud／点击不返回”现象值得优先核对的线索，但尚未通过只恢复该字段的同签名复验锁定因果。

最低版本仅Info被改成10.0，代码minos仍17.0，不能宣称支持iOS10；也不能把这一个变化直接认定为当前iOS27.2.1选择失败根因。

## 正常开发签名与失败自签的直接权限对比

直接读取已正常真机导入的SDK26.5开发签名Release与用户提供的20:02失败自签包；同SDK27.2正常Debug的当时实际签入权限快照与正常Release字典完全相同。没有要求额外新包或从当前未签归档推断原Debug签名。

| 对照项 | 正常开发签名包 | 所提供的失败自签包 |
| --- | --- | --- |
| App实际签入项数 | 3 | 44 |
| profile授权项数 | 5 | 44 |
| 是否整份复制profile许可模板 | 否，仅声明所需子集 | 是，原样复制整个字典 |
| App ID | 每个组件匹配各自Bundle ID | 三组件同一个固定其他App ID |
| Team | 匹配自己的profile | 也匹配自己的profile；Team不同本身不是错误 |
| get-task-allow | true | false，发布签名正常值，不作文件选择根因 |
| iCloud服务 | 不声明 | 字符串`*`，不符合公开的数组类型 |
| App Group | 不声明 | 5项，不含Fork组 |
| 钥匙串共享组 | 不声明 | 2项 |

正常包的三项为`application-identifier`、`com.apple.developer.team-identifier`、`get-task-allow`；普通JSON导入在本次无App Group／钥匙串共享／iCloud能力下也能工作。三项是本轮个人开发签名的实际对照，不是正式App永远只能申请三项：Widget／分享共享另需匹配且获授权的App Group。

用户后来仅取消iCloud服务仍失败，此新包尚未取得，因此本表明确使用先前20:02样本，不据此断言后一次取消未生效。不再将iCloud视为唯一原因；即使移除一个多余项目，固定App ID不匹配及Info文档浏览器注入仍不会自动消失。

## 判断与下一步

已有[真机开发签名对照](json-import-device-diagnosis.md)证明同SDK26.5原Release和SDK27.2 Debug均能导入。本次又证明用户签后执行代码未改变，但签名身份／权限类型与Info被改写。因此先处理签名包配置，不换SDK、不猜测修改解析器。

建议以原未签包Info为准，避免额外文档浏览器标记和降低最低版本；实际签名权限按App需要、且在profile许可内生成，不把整份授权模板原样写入。固定App ID不匹配的问题应向签名服务商核对匹配profile，不能伪造profile或单独硬改application-identifier越过授权。

具体哪个签名选项造成模板复制／文档浏览器注入，需要用户提供真实签名设置截图，或由服务商修正后提供新的签后IPA作只读复查与手机行为复验。当前没有实际纠正重签／安装，不能宣称已经消除文件选择故障；不索取私钥／密码，不自动改Bundle ID、移除扩展或删除数据。

## 官方合同

- [TN3125：代码签名与provisioning profile](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)：App ID由前缀与Bundle ID构成，App实际声明由profile的许可清单授权。
- [iCloud Services Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services)：类型为array of strings，值为CloudKit／CloudDocuments等。
- [File Provider](https://developer.apple.com/documentation/fileprovider)：文档浏览器App使用UISupportsDocumentBrowser，其他App使用UIFileSharingEnabled与LSSupportsOpeningDocumentsInPlace。

V2EX链接读取被网络安全检查拦截，未获得正文；没有绕路读取或更改安全白名单，本文不把论坛内容当成已取得的证据。
