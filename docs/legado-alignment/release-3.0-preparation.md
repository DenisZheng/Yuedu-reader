# 3.0 未签名Release IPA准备记录

以下记录基于`main`的`cd159098`之后的本地准备：按用户确认修正过期断言、采用最终提供的单张图标并把版本设为`3.0`。准备时尚未提交Push、触发工作流或生成IPA，不能把这些检查写成正式Release／签名／S8通过。

用户随后明确要求**后续编译全部使用GitHub Actions，不再本地构建**，并授权提交Push后交付GitHub预发布。保留现有仅手动触发、contents只读的构建工作流；下载并核验云端产物后，再通过本次发布操作创建预发布，不给每次构建增加Release写权限。手机安装不在本次自动操作中：已有本地新产物是模拟器Debug，不是可安装的iPhoneOS包。

## 改动

- `scripts/tests/test_manual_ipa_workflow.py`：移除要求源码直接写出`ReservedRegion`类型名的过期断言，仍检查真实`.reservedRegions`调用和运行时版本保护，并确认全部调用都在编译器保护块内。生产Swift与IPA工作流不变，没有删除整项检查或增加假字符串。
- `xcconfig/Yuedu-reader_version.xcconfig`：`MARKETING_VERSION=3.0`，`CURRENT_PROJECT_VERSION=4`保留。App与两个扩展继续从同一项目级配置继承；没有改变Bundle ID、签名、共享容器、部署目标或模块格式。
- 用户最终提供`閱讀 Pro Logo.png`（下载目录，1254×1254、无透明PNG）；不再使用原ZIP。只缩放，不裁切、不重画：默认／深色图标共用原构图，着色图标使用系统ColorSync生成的灰度副本。
- 替换`AppIcon.appiconset`的3张1024×1024图片；同步替换`YueduAppIcon.imageset`的浅／深色192×192（2x）和288×288（3x）图片，共7张PNG。资源名称与Contents.json保持不变，系统和现有引导页继续使用同一套入口。
- 原图前后SHA-256一致，没有改动用户文件。图标与版本配置备份保存在`.git/release-30-artifacts.LVjoU3/before/`。临时处理产物、编译文件及日志不提交。

## 实际验证

### 过期断言先失败，再修正

```bash
python3 -B -m unittest scripts.tests.test_manual_ipa_workflow.ManualIPAWorkflowTests.test_new_viewport_api_is_compile_guarded -v
```

修正前实际1项失败：`AssertionError: 'ReservedRegion' not found`，`FAILED (failures=1)`。

修正后执行：

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
```

实际`Ran 17 tests`、`OK`，日志`.git/release-30-ipa-contract.log`。这验证工作流／合成archive打包合同，不是真实iPhoneOS archive。

### 原生图标编译

Xcode由`scripts/sim.sh xcode`动态解析。候选目录复制当前两份资源清单，并放入7张新图片，执行：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
xcrun actool "$artifact/Assets.xcassets" \
  --compile "$artifact/compiled" --platform iphoneos \
  --minimum-deployment-target 17.0 --target-device iphone --target-device ipad \
  --app-icon AppIcon --output-partial-info-plist "$artifact/icons-info.plist" \
  --warnings --errors --notices --output-format human-readable-text
```

实际`artifact=.git/release-30-artifacts.LVjoU3`，退出0，输出`com.apple.actool.compilation-results`及`Assets.car`。生成plist中iPhone／iPad的`CFBundlePrimaryIcon.CFBundleIconName`均为`AppIcon`。没有警告或错误。

随后核对7张PNG的尺寸、无alpha、着色图为Gray及全部PNG chunk CRC，再替换项目中的相同路径；替换后资源与这次已编译的候选资源逐字节一致。默认／深色为RGB，着色图为Gray；应用内3x图片实际读取检查了构图。本轮未安装真机查看最终系统图标。

### Release版本与资源配置

```bash
xcodebuild -project Yuedu-Reader.xcodeproj -alltargets -configuration Release \
  -sdk iphoneos -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile -showBuildSettings -json
```

实际退出0，白名单字段核对：

| target | Bundle ID | 版本／构建号 | 平台／最低系统 |
| --- | --- | --- | --- |
| yuedu app | `dev.denis.readerfork.dev` | `3.0 / 4` | `iphoneos / 17.0` |
| Yuedu-Reader Widget | `dev.denis.readerfork.dev.widget` | `3.0 / 4` | `iphoneos / 17.0` |
| Yuedu-Reader ShareExtension | `dev.denis.readerfork.dev.shareextension` | `3.0 / 4` | `iphoneos / 17.0` |

主App的`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`。设置输出仅本地保存，`.git/release-30-build-settings.json`；没有将全量build settings输出到报告。

### 版本调整后的模块回归

六个内置JSON插件最低版本均为`3.0`，需要确认版本改动不会把这些资源排除。执行：

```bash
bash scripts/sim.sh doctor
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh \
  -l .git/release-30-module-version.log -- \
  -resultBundlePath .git/release-30-module-version.xcresult \
  -only-testing:'yuedu appTests/OfficialRuleModulesTests' \
  -only-testing:'yuedu appTests/ForkBuiltinModulesDefaultsTests'
```

正常Dev宿主实际7项／2 suites通过，`** TEST SUCCEEDED **`。包含运行中App版本验证六个Bundle插件、默认停用及手动启用／重启保持；不连接插件网站。测试构建为Debug，不冒充完整Release App编译。没有clean、新DerivedData或清除模拟器数据。

模块最低版本检查仍使用真实App版本；声明需要高于`3.0`的用户模块会按既有门禁拒绝，本轮不放宽门禁或宣称支持3.0.1／3.0.2新格式。

## 边界与回滚

- `Reader Fork Dev`显示名和开发身份保留；用户本轮只确认图标及版本，没有要求更改正式品牌／签名。图标来自用户提供，本轮处理不是素材／字体许可审查，也不豁免其他分发内容的许可要求。
- 过期合同阻塞已解除，但本次没有完整Release iPhoneOS archive、真实IPA／checksum、签名安装、App Group／iCloud或S8人工验收。后续应在用户确认后的固定提交上归档并验产物，不沿用旧云IPA的通过结论。
- 新资源可回滚为上述本地备份中的两份图标目录，版本配置可恢复备份；过期断言修正单独撤回。回滚不删除用户原图、设备数据、源包或其他未跟踪资料。
