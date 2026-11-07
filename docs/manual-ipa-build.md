# 手动构建未签名 IPA

工作流：`.github/workflows/build-ios.yml`（**Build unsigned iOS IPA**）。

仅支持 `workflow_dispatch`，不会因PR、Push、Tag或定时任务自动构建。现有 `Localization` 轻量检查不受影响。同一分支重复点击会取消旧构建，避免重复耗时；单次作业最多60分钟。

## 使用

1. 工作流及配套脚本合入默认分支后，打开仓库 **Actions → Build unsigned iOS IPA → Run workflow**。
2. 选择要构建的分支或Tag；该版本必须包含工作流及打包脚本。
3. 成功后下载 `reader-fork-dev-unsigned-ipa-<run_id>-<attempt>` artifact，内含：
   - `Reader-Fork-Dev-unsigned.ipa`
   - `Reader-Fork-Dev-unsigned.ipa.sha256`
4. 在下载目录运行 `shasum -a 256 -c Reader-Fork-Dev-unsigned.ipa.sha256` 检查完整性。

IPA保留14天；失败时仅上传本次依赖解析/归档日志和xcresult，保留7天。不自动发布GitHub Release、不上传TestFlight，不自动触发第二次构建。

## 工具链与耗时

- 使用稳定的 `macos-26` runner，自行读取其 `xcode-select` 所选Xcode，不硬编码本机安装路径或要求Xcode27。
- 核查时官方镜像默认Xcode26.6、iPhoneOS SDK26.5。镜像会更新，实际版本记录在 **Check selected toolchain**。
- 本地LNPopupUI/LNPopupController包声明 `swift-tools-version: 6.2`，因此工具链至少需要Swift6.2；App的Swift6语言模式、并发设置、最低iOS17部署目标不变。
- 已给 `ReaderViewportReporting.swift` 的 `ReservedRegion` 加编译器保护。26.x工具链保留既有窗口safe-area逻辑；用新SDK构建且运行于iOS27.1+时，仍可读取遮挡/折叠区域。较旧SDK构建不会获得这项新SDK能力，不能称为完全相同的iOS27体验。
- 单独的27.0 SDK不含该27.1 API，而其编译器会进入新分支，因此预检明确拒绝27.0；可用26.x稳定工具链或27.1+，不是强制升级到本机版本。
- SwiftPM按锁文件解析；缓存只包含依赖源码/下载产物，并区分Xcode build与架构。不缓存App的DerivedData，不更新依赖版本，不通过新DerivedData绕过错误。
- 此任务只做Release真机归档和打包，不启动模拟器、不跑全量测试或RSS实源。因此成功仅说明这次构建/包装成功，不替代S0–S8行为验收。

**验证边界：** 本机只有Xcode27.2，尚未实际执行26.x云端archive。已完成工具链预检、包装合同及本机窗口回归；26.x完整编译结果必须以首次手动CI运行的最终结论为准，不能用预检模拟或本机27.x编译冒充。

## 签名与身份

采用 `Reader-Fork-Dev` scheme，`Release`、`generic/platform=iOS`，关闭代码签名后archive，再将App放入IPA的 `Payload/`。

打包器会拒绝模拟器产物、原版Bundle ID、缺失可执行文件，以及缺失/身份不符的Widget或ShareExtension；不会静默生成缺扩展的IPA。保留可执行权限和符号链接，不删除原archive，不覆盖已有IPA。

- 这是**未签名IPA**，不是可直接安装的App Store/Ad Hoc包，安装前需要自行签名。
- 不需要向本工作流提供Apple证书、provisioning profile或原版Google配置。
- iCloud/App Group等能力仍需要自己的签名、容器和授权；生成IPA不表示这些能力已经可用。
- 当前是临时Fork身份，不是正式发布品牌。公开分发前仍须完成签名、品牌、许可证与真机验收。

## 本地验证与打包

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
python3 -B scripts/package_unsigned_ipa.py \
  --archive /path/to/ReaderFork.xcarchive \
  --output /path/to/new-output-directory
```

包装测试使用合成archive，验证Payload结构、扩展、平台、权限、符号链接、SHA-256及失败分支；它不伪装成真实IPA编译测试。

## 参考与取舍

- 用户参考：[legado-ios build-ios.yml](https://github.com/DenisZheng/legado-ios/blob/d55585c52776359906c754b6eef0e06d471105da/.github/workflows/build-ios.yml)。该版本位于 `feature/rss-navigation-compat`，默认分支当时没有此文件。借鉴未签名archive→Payload→artifact流程，不复制它的Push触发、固定模拟器或大套UI回归。
- [GitHub手动触发说明](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)：工作流需在默认分支上，才能提供手动入口。
- [macos-26镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)：使用稳定镜像，而非Xcode27预览runner。
