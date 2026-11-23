# LegadoPro 3.0.3（构建号 8）

独立、非官方 iOS Fork。本版主要修复 `3.0.2（7）` 的书架开书回退；旧版 GitHub Release 已改回草稿下架，原 Tag 和历史附件保留，不推荐继续使用旧 IPA。

## 修复

- 已读书从书架点击封面后，不再出现打开动作后自动退回书架的问题。
- 封面阅读器由原生 UIKit 容器拥有 push/pop；原 SwiftUI 栈保留书架内页和搜索值导航，避免两者争用同一导航栈。
- 仍复用原阅读器、动画、进度和状态，不通过禁用封面动画、延迟开书或取消搜索来规避故障。
- 保留此前修复的书架搜索结果点击：搜索进行中或暂停后均可打开已返回的书。
- App、Widget 和 ShareExtension 的共享版本递增为 `3.0.3（8）`，身份、签名、权限及依赖不变。

## 当前验证与构建边界

- iOS 27.2 iPhone 模拟器：列表/网格开书、探索继续阅读、退出后重复开书和搜索导航，共 4 项、0 失败。
- iOS 27.2 iPad 模拟器：原模态阅读器的列表/网格开书、探索及搜索入口返回，共 2 项、0 失败。
- 使用隔离 TXT / 本地双源测试，未运行真实书源或使用个人账号；上述检查不代表所有格式、真机或 iOS 17 均已验收。
- 新 Release 真机归档采用既有 GitHub Actions 工作流，只手动触发一次；按维护者要求不监视 CI。完成通知后另行核对固定提交、IPA 版本、身份、架构、ZIP 和 checksum，未完成前不把新产物写成成功。

## 安装与风险

预期附件仍为 `LegadoPro-unsigned.ipa` 和同名 `.sha256`，属于 Release 配置、iPhoneOS 架构的**未签名 IPA**。正常 iOS 安装前需要自行签名，不是 App Store / Ad Hoc / TestFlight 成品。App Group 及两扩展依赖重签授权；本版继续暂停 iCloud，保留本地能力与 WebDAV。

主身份 `com.deniszheng.legadopro`；扩展为 `.widget`、`.shareextension`。App 可控制的连接仍接受无效服务器证书，有中间人读取或篡改内容和凭据的风险；不在不可信网络提交敏感配置。媒体 / DRM、真实在线书、完整无障碍及最低 iOS 17 未由本轮发布流程验收。

对应源码：[legadopro-v3.0.3](https://github.com/DenisZheng/Yuedu-reader/tree/legadopro-v3.0.3)。遵守仓库 MPL-2.0 及独立文件/第三方许可，保留作者与声明，不代表上游官方版本或品牌背书。原始私有源包和诊断原始文件不作为 Release 附件上传。
