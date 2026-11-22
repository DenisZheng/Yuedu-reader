# LegadoPro 3.0.2（构建号 7）

这是基于 Yuedu Reader 的独立、非官方 iOS Fork，不代表上游官方版本或获得其背书。维护者选择将本版发布为正式 GitHub Release 并标为 Latest；这不表示 App Store 签名、S8 完整验收或所有真实书源已通过。

## 本版重点修复

- 修复从书架放大镜进入搜索后，点击结果无法打开详情、搜索内容被清空的问题；搜索进行中和暂停后均可打开已返回的结果，返回后保留搜索状态。书架工具栏与空书架搜索入口使用同一导航方式。
- 包含此前已合入的登录源快照及诊断隐私修复，避免读取已失效的源配置和输出源控制的未脱敏诊断内容。
- 修正书架 VoiceOver 重复动作，减少探索列表重复解析源变量，并修复自动阅读翻页的状态重置与遮挡问题。
- 版本统一升为 `3.0.2（7）`，主 App、Widget 和 ShareExtension 共享版本配置。

## 下载与安装

- 附件 `LegadoPro-unsigned.ipa` 为 **Release 配置、iPhoneOS 真机架构的未签名 IPA**，不是模拟器包。
- 正常 iOS 设备安装前必须自行签名。此包不含 Apple 证书或 provisioning profile，不是可直接安装的 App Store、Ad Hoc 或 TestFlight 包。
- 主 Bundle ID：`com.deniszheng.legadopro`；扩展为 `.widget`、`.shareextension`。重签时需正确处理主 App 与扩展身份及 App Group 授权。
- 本版继续暂停 iCloud，不申请 CloudKit 权限；保留本地能力、已有数据和 WebDAV。不保证所有侧载签名方式都可使用共享容器或扩展。
- 下载同名 `.sha256` 后，在下载目录验证：

```bash
shasum -a 256 -c LegadoPro-unsigned.ipa.sha256
```

## 验证范围

- 书架搜索修复在 iOS 27.2 模拟器采用可控双源实际点击回归：搜索进行中、暂停后打开详情并返回，共 2 项、0 失败；详情路由回归 3 项通过。
- 旧 SDK / CI 工具链的适用能力以本版实际 Actions 构建记录为准；较旧 SDK 不因此获得只在新 SDK 提供的 iOS 27 增强路径。
- 本版云归档与产物检查已完成，实际记录见下方；这些不替代真机运行或全部功能验收。

## 已知边界与安全提示

- 最低声明 iOS 17；本次没有完成真机、iPad、iOS 17–26、完整 VoiceOver 或真实大源包压力验收。导入成功不表示全部书源都能运行。
- 部分真实规则网页播放、登录、媒体格式或 DRM 仍有站点、签名或播放器限制；不宣称所有来源均兼容。
- App 可控制的连接接受无效服务器证书，仍有中间人读取或篡改内容、Cookie、AI / WebDAV 凭据的风险；请避免在不可信网络提交敏感配置。此政策不代表站点证书链已修复。
- 本地能力不收费，外部 AI 等服务仍需自己的服务配置；不使用原版 Google/Firebase 账号后台。

## 源码与许可

对应源码：[legadopro-v3.0.2](https://github.com/DenisZheng/Yuedu-reader/tree/legadopro-v3.0.2)，也可使用本 Release 的 Source code 附件。源码遵循仓库 MPL-2.0 和各文件、第三方组件的独立许可；保留原作者与许可声明。未签名或重新签名不豁免这些义务，也不授予上游品牌权利。

原始用户书源包、私有请求配置、凭据和本地诊断原始文件未作为本次提交或 Release 附件发布。旧 IPA 附件已按维护者要求清理，历史标签、Release 记录、日志及归档不删除。

## 本版实际构建与产物

- 构建 commit：`f9de39b85c9f043d663577544f87911939481b04`，包含书架搜索修复 `b28a6955`。
- 发布 Tag：`legadopro-v3.0.2`。
- GitHub Actions：[run 45018465876](https://github.com/DenisZheng/Yuedu-reader/actions/runs/45018465876)，最终 `completed / success`；Archive、Package、Upload 均成功，没有重新触发构建。
- App、Widget、ShareExtension 均为 **3.0.2（7）**；主 App 为 `com.deniszheng.legadopro`，两扩展使用 `.widget` / `.shareextension` 后缀。
- 三个可执行文件均为 **arm64 / iPhoneOS**，Mach-O 最低系统 **17.0**，SDK **26.5**；不是模拟器产物。
- 下载后实际检查 SHA-256、ZIP CRC、版本、身份、可执行权限通过；ZIP 中没有签名 Bundle 标记或 embedded provisioning profile。
- IPA 大小：**38460602 字节**。
- SHA-256：

```text
80e9d94621a954c1d80a211c6a9bdd668dd826041912baccd5b876f945e72a3a
```

这些是构建和产物检查结果，不是手机安装、正式签名或完整功能验收结论。
