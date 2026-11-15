# LegadoPro 3.0（5）：暂停iCloud与侧载启动复验准备

## 用户决定与现有故障证据

- 2026-11-15用户最终确认显示名为`LegadoPro`，覆盖先前`LegdoPro`拼写；版本仍为3.0，构建号递增5。
- 3.0（4）经轻松签安装后首屏前退出。用户IPS中的主程序UUID与公开RC1 IPA一致，主线程`EXC_CRASH/SIGABRT`，异常栈进入CloudKit及SwiftUI StateObject初始化；未显示CODESIGNING/DYLD终止。没有具体异常reason，未取得签名后entitlements，也未完成函数级符号化，因此不能断言具体哪项权限缺失。
- 按[ADR-0006](../adr/0006-pause-icloud-for-current-release.md)，本版暂时停用iCloud，不以一年有效期推断证书具备CloudKit授权。

## 实际变更

- `ICloudSyncManager.isConfigured`设为false，默认初始化不构造云容器；启动绑定、前台及后台自动同步增加配置门禁，自动章节检查保留。
- 备份页移除iCloud入口和状态请求，保留WebDAV；主App不申请CloudKit entitlements。保留实现、历史同步模型和现有数据，不访问或删除远端数据。
- App及分享扩展五种语言的显示名统一LegadoPro，Widget默认名为LegadoPro Widget。Bundle ID、App Group、URL scheme和内部项目／可执行文件名不变，以免改变数据身份。
- 当前未签名产物名为`LegadoPro-unsigned.ipa`，打包器新增主App显示名校验；Actions同步输出路径并执行Fork配置合同。不改变编译器、隔离设置、依赖或本地scheme。

## 本轮已执行的检查

仅运行Python/Ruby/工作流静态检查，没有本地Swift编译、build或模拟器测试：

```bash
python3 -B -m unittest scripts.tests.test_fork_configuration -v
# Ran 9 tests / OK
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
# Ran 19 tests / OK
ruby scripts/check_localizations.rb
# Localization OK: Resources/*.lproj/InfoPlist.strings (5 files, 17 keys)
# Localization OK: ShareExtension/*.lproj/InfoPlist.strings (5 files, 1 key)
git diff --check
# 无输出，退出码0
```

新增暂停iCloud的静态回归在修改前为`Ran 1 test / FAILED (failures=1)`，修改后通过。actionlint v1.7.12使用官方Darwin arm64归档及官方checksums文件核验后的临时二进制，执行`actionlint .github/workflows/build-ios.yml`退出码0。

新增Swift运行时测试`pausedCloudKitKeepsLocalStartupAvailable`尚未执行；静态检查不能替代它或手机启动证明。后续仅通过Actions对新的固定提交归档，核对新IPA的版本、显示名、身份、权限与checksum，然后交由用户自签启动复验。不得覆盖RC1 tag/资产，不宣称手机闪退已经消除、S8人工通过或正式稳定版。

## 回滚

只回滚本轮相关代码／配置提交即可恢复先前入口和CloudKit申请；无需删除本地库、修改Bundle ID或清理手机数据。高风险配置的修改前副本保存在本地`.git/legadopro-config-backup.KUmEA4/`，不随提交分发。恢复iCloud需重新做签名、容器授权和无权限启动回归，不能盲目启用。
