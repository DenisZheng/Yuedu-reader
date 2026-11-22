# LegadoPro 3.0.2（7）发布记录

## 授权与固定范围

用户于 2026-11-22 明确选择：先提交并 Push 书架搜索 Bug 修复；清理所有旧 IPA；将 `3.0.1（6）` 升为 `3.0.2（7）`；重新使用 GitHub Actions 构建 Release 配置未签名 IPA，发布正式 GitHub Release 并标为 Latest。该授权不包括 Apple 签名、TestFlight / App Store、安装手机、删除用户书库或把 S8 未验收项改为通过。

修复提交 `b28a6955bdbb6f61f997190fde6e51b6d2a40578` 已正常 Push 到 `origin/main`，远端 SHA 相同，仅包含书架导航、双源 UI 回归、fixture 和验证记录 4 个文件。提交时曾遇到瞬时索引锁；只读检查及正常重试后提交成功，未删除锁、跳过 hooks 或强推。

## 旧 IPA 清理

明确只删 IPA / 同名 checksum 和包含旧 IPA 的 artifact，保留 archive、日志、源码、Git 历史、Tag 和 Release 记录。

- 本地共 9 份 IPA 和 9 份 checksum，包含 `.artifacts/` 中 3 份以及 `.git/` 历史下载 / 打包目录中 6 份；全部为未跟踪产物，不删除任何 Git 元数据。
- Actions 4 个旧 IPA artifact：run `45005372411`、`43771750049`、`43691532133`、`43683303939`；未删除这些 run 的记录或日志。
- 旧 `reader-fork-v3.0-rc.1` 的 IPA / checksum 两附件删除，旧 Tag 和 Release 记录保留。
- 删除前后的元数据、逐项清单与结果保存在 `.artifacts/release-3.0.2-fNkR5o/`；删除后实际查询：`local=0, Actions=0, old Release assets=0; release record preserved`。

## 版本与分发说明

只在共享的 `xcconfig/Yuedu-reader_version.xcconfig` 修改 `MARKETING_VERSION = 3.0.2`、`CURRENT_PROJECT_VERSION = 7`。修改前已备份为 `.artifacts/release-3.0.2-fNkR5o/version-before.xcconfig`。实际解析工程证明 App、Widget、ShareExtension 均继承该配置，没有目标级版本覆盖。签名、身份、权限、依赖与构建工作流不变。

发布 Tag 预定为 `legadopro-v3.0.2`，构建前核对不存在同名远端 Tag；以版本提交创建固定 Tag 后手动触发一次，不因慢归档重复触发。使用已有 `build-ios.yml`，`Reader-Fork-Dev` scheme、Release、iPhoneOS、关闭签名；不改工作流权限。

[发布说明](../release-notes/legadopro-3.0.2.md)明确未签名、重签限制、TLS 风险、真机和旧系统未验收及对应 Fork 源码地址。修正[打包指南](../manual-ipa-build.md)的 Release / Debug 身份说明；[许可说明](../../LICENSING.md)区分 Fork 与上游官方可执行版本的对应源码，不改许可证或历史许可边界。本次新增输入为自建 fixture，未复制 Android 源码或素材；现有独立第三方声明仍适用，以下许可文本检查不冒充完整法务审查。

## 已执行的准备检查

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
python3 -B -m unittest discover -s scripts/tests -p 'test_fork_configuration.py' -v
ruby scripts/tests/licensing_contract_test.rb \
  --name '/test_current_license_is_mpl|test_preserves_the_historical_mit_notice|test_documents_the_exact_license_transition_boundaries/'
git diff --check
```

实际结果：工作流 / 合成打包合同 24 项 `OK`；Fork 配置 9 项 `OK`；许可文本范围 3 项、18 assertions、0 failures / errors / skips。许可测试仅覆盖本轮相关的 MPL、历史 MIT 通知和转换边界，不执行已经不对应当前 Fork 关于页的旧上游 UI 断言。配置检查不能替代真实 archive、签名或启动。

书架搜索代码与环境未再改变，复用本次会话的 iOS 27.2 实际行为证据：UI 2 项、详情路由 3 项通过，详见[验证记录](validation.md)。不为升版重复 App build / clean / UI 测试。

## 云归档与发布状态

当前为准备记录：尚未把新产物或 GitHub Release 写成成功。实际版本提交 SHA、手动 run、工具链、归档结论、IPA 检查、发布 URL 与附件验证在对应操作完成后补入本节。

## 仍未验收与回滚

真机、iPad、iOS 17–26、全部实源、媒体 / WebDAV 和正式签名未由本轮发布操作验收；`stageAccepted=false` 保持。正式 GitHub Release / Latest 是用户的分发选择，不等于 App Store 或 S8 放行。

版本可通过后续明确授权的提交调整；不覆盖本次 Tag、不强推。旧 IPA 已按批准清理，不能声称可以从本地文件无损恢复；保留的 archive / source / run 日志可支持重新构建，但要另行授权。新 Release 若需撤回或删附件，同样需明确批准。
