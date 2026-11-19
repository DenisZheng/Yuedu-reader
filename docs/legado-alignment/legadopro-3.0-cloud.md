# LegadoPro 3.0（5）云归档与侧载复验交付

## 历史产物与当前发布门槛（2026-11-17补充）

本文的build 5固定对应`5ac9b1b9`，不是后续`40065b99`或[首批上游修复](upstream-small-batch-2026-11-17.md)的产物。后续JSON复制导入、漫画、视频退出、订阅管理及本批上游修复不在此IPA中；必须对实际发布提交重新归档、核对产物并完成其自签／设备验收，不能用本文旧产物结论发布新代码。

远端`reader-fork-v3.0-rc.1`固定指向`23b7d7de`，用户曾在该版本年度自签安装后遇到CloudKit启动崩溃，见[ADR-0006](../adr/0006-pause-icloud-for-current-release.md)。**该历史版本不推荐安装**；保留tag的原始身份，不强制移动或删除，不自动创建Release。新RC采用新的固定标签和匹配产物。

以下为当时执行快照；后续开发签名启动／导入成功见[设备诊断](json-import-device-diagnosis.md)，不等同年度自签或当前提交验收。

## 固定产物

- 代码提交：`5ac9b1b972141f12930c68fde0a2300c46c72bec`，已Push主线。
- [Actions run 43691532133](https://github.com/DenisZheng/Yuedu-reader/actions/runs/43691532133)，attempt 1，最终`completed/success`，ipa作业耗时43分6秒。
- [Artifact下载页面](https://github.com/DenisZheng/Yuedu-reader/actions/runs/43691532133/artifacts/14153233279)，名称`legadopro-unsigned-ipa-43691532133-1`，需登录GitHub，保留14天。包含`LegadoPro-unsigned.ipa`及同名`.sha256`。
- IPA大小：37,580,655字节。
- SHA-256：`cb28a56e39e6792420f8dfb27d08adc2c3c17974b643de75178cd4bcdd3ebf22`。
- 主程序UUID：`F1B97B1E-4852-3807-AD51-6A8AF71DAD50`，内部可执行文件名仍为YueduReader。
- App显示名LegadoPro，Widget为LegadoPro Widget，分享扩展为LegadoPro：匯入連結。三个Bundle均为3.0（5）、iPhoneOS、最低声明iOS17.0；Bundle ID和共享数据身份未改变。

## 本次执行与决定性输出

没有本地build或模拟器运行。显式指定Fork仓库触发并监测：

```bash
gh workflow run build-ios.yml --ref main -R DenisZheng/Yuedu-reader
gh run watch 43691532133 -R DenisZheng/Yuedu-reader --exit-status
# ✓ ipa in 43m6s
# Archive unsigned device app: success
# Package IPA and checksum: success
# Upload unsigned IPA: success
```

实际工具链：Xcode26.6（17F113）、Swift6.3.3、iPhoneOS SDK26.5。云端脚本合同为`Ran 19 tests / OK`及`Ran 9 tests / OK`；归档成功不等于Swift测试运行或真实手机启动。

首次未指定`-R`的gh命令错误解析为上游CHANG-JUI-LIN/Yuedu-reader并返回workflow 404，未创建作业。确认Fork本提交作业数0后仅触发上述一次构建，不改全局gh默认仓库，不重复触发或强制推送。

下载后实际核验ZIP CRC、SHA-256、三个Bundle身份／版本、五种语言主App显示名、可执行权限，以及无`embedded.mobileprovision`／`_CodeSignature`。Mach-O检查：

```bash
xcrun vtool -show-build <下载后主程序>
# platform IOS / minos 17.0 / sdk 26.5
xcrun dwarfdump --uuid <下载后主程序>
# UUID: F1B97B1E-4852-3807-AD51-6A8AF71DAD50 (arm64)
codesign -dv <下载后主程序>
# code object is not signed at all
```

本地新副本为用户下载目录的`LegadoPro-3.0-build5-unsigned.ipa`与同名`.sha256`，创建前检查不存在同名文件，复制后SHA-256再次匹配；未覆盖旧IPA或用户数据。诊断JSON和日志留在本地`.git/`，不分发用户IPS。

## 已完成与尚未完成

按[ADR-0006](../adr/0006-pause-icloud-for-current-release.md)停用本版iCloud入口、自动调用与CloudKit申请，保留WebDAV、本地能力及历史数据，显示名按用户最终拼写LegadoPro。实现与静态RED/GREEN见[准备记录](legadopro-3.0-rc2-preparation.md)。

**仍需用户用新包自行签名并启动复验。** 没有替用户重签、安装、授予权限或删除旧数据，没有新发布／覆盖RC1。不能宣称原闪退已消除；新增Swift运行时回归未执行，最低iOS17、真机媒体、VoiceOver、App Group和S8人工验收仍按原未验证范围保留。构建日志仅有Node20弃用强制Node24及arm64 runner容量提示，本轮不扩大范围升级Actions依赖。

回滚仅涉及本轮相关代码／配置提交，数据身份与格式不变，无需清库。恢复iCloud必须重新验签名／容器授权及无权限启动行为，不因构建成功恢复该功能。
