# 3.0 Actions归档与预发布记录

用户已授权提交Push、通过GitHub Actions构建未签名IPA，并交付GitHub预发布；后续不进行本地编译，不自动安装手机。构建工作流仍为`.github/workflows/build-ios.yml`，仅手动触发、contents只读；产物验收后由本次发布操作创建预发布，不修改工作流权限。

## 首次云归档：失败，没有IPA

准备改动已提交并Push：`ad96e15c2ceda45eaf73e55d6c81e81859d705ae`。实际执行：

```bash
gh workflow run build-ios.yml --ref main -R DenisZheng/Yuedu-reader
gh run watch 43681572831 -R DenisZheng/Yuedu-reader --interval 20 --compact --exit-status
```

[run 43681572831](https://github.com/DenisZheng/Yuedu-reader/actions/runs/43681572831)，attempt1，head与上述commit一致，最终`failure`。工具链Xcode26.6（17F113）、Swift6.3.3、iPhoneOS SDK26.5；工具链检查、17项工作流／打包合同及锁定依赖解析通过，`Archive unsigned device app`失败，IPA打包／上传均跳过，没有创建Release。

完整failure artifact：`reader-fork-build-failure-43681572831-1`，下载到本地`.git/release-30-cloud-failure-43681572831/`，不提交。完整archive日志5400行，唯一已报告编译错误：

```text
Modules/Core/BookSource/BookSourceCheckBackgroundTask.swift:126:67:
error: extra trailing closure passed in call
BGTaskScheduler.shared.submitTaskRequest(request) { error in
** ARCHIVE FAILED **
```

## 最小SDK兼容修正

本机只读取SDK27.2的`BGTaskScheduler.h`，没有编译：回调重载明确`API_AVAILABLE(ios(27.0))`；原错误发生于SDK26.5，运行时`#available`不能隐藏编译期不存在的重载。

- 给iOS27回调路径增加`#if compiler(>=6.4)`，采用现有工作流支持的Xcode26.x／Swift6.3与Xcode27.1+／Swift6.4组合。
- 新工具链在iOS27继续使用原异步回调，提交后直接返回；旧工具链／旧系统沿用原有`try BGTaskScheduler.shared.submit(request)`和错误处理。
- 不改执行线程、请求策略、任务注册／进度／结束行为，不抬高最低iOS、不改变Swift模式、优化、依赖、签名或云工具链。

新增`test_background_completion_api_is_compile_guarded`纯静态回归，先运行1项失败（缺少编译器保护），再修改生产代码。随后：

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
```

实际`Ran 18 tests`、`OK`，日志`.git/release-30-ipa-contract-bg-green.log`；red日志`.git/release-30-bg-guard-red.log`。这些是Python静态／合成合同，不冒充完整Swift编译或后台任务真机行为。实际修正必须由下一次Actions archive验证。

## 当前分发与验收边界

- 尚未生成本版IPA或创建预发布。只有新的固定commit云归档、打包、上传通过后，才下载核对版本3.0／构建号4、App与两扩展身份、iPhoneOS Mach-O、最低声明17.0、ZIP／权限、checksum和实际签名状态。
- 未签名IPA使用前仍需自行签名；App Group／iCloud取决于签名账号及授权。本次不自动配置签名或安装手机，不把模拟器Debug包装成真机包。
- 预发布不能代表S8人工／iOS17／真机媒体／真实云同步或所有实源已通过。范围见[准备记录](release-3.0-preparation.md)和[发布清单](s8-release-checklist.md)。
- 只用新版本专属的预发布标签，不覆盖已有tag／Release，不标Latest；源码对应标签commit，保留MPL及独立文件许可证。
- 回滚仅撤回本次后台调度编译保护及新增静态测试；不回滚用户图标或版本，不删除用户数据或历史失败证据。未完成云验收前不标归档阻碍已关闭。
