# LegadoPro 3.0.2（7）发布记录

> 2026-11-23 后续状态：用户报告书架封面开书自动退回后，已按授权把本 Release 改回草稿下架；`isDraft=true`、`isLatest=false`，原 Tag 和两个附件保持不变。下文是当时成功构建/发布的历史记录，不代表该版仍可公开安装或覆盖当前修复。[故障与修复证据](bookshelf-reader-return-2026-11-23.md)。

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

版本提交 `f9de39b85c9f043d663577544f87911939481b04` 已 Push；固定发布 Tag `legadopro-v3.0.2` 指向同一 commit，包含修复 `b28a6955`。构建前核对同名 Tag / run 不存在，随后只手动触发一次；用户要求不监看时已停止本地轮询，没有取消或重触发 CI。使用已有 `build-ios.yml`，`Reader-Fork-Dev` scheme、Release、iPhoneOS、关闭签名，不改工作流权限。

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

[run 45018465876](https://github.com/DenisZheng/Yuedu-reader/actions/runs/45018465876) 已完成；`gh run view` 返回 `completed / success`，Tag、head SHA 与上述固定版本一致，Archive、Package、Upload 均成功。实际归档约 29 分钟；三个 Mach-O 的 SDK 记录为 26.5，本节不借用旧 run 的 Xcode / Swift 版本充作本次证据。

下载 artifact `legadopro-unsigned-ipa-45018465876-1` 后，实际 Python 检查 SHA-256、ZIP CRC、App / 两扩展版本与身份、可执行权限、Mach-O 平台及最低系统：

- 主 App `com.deniszheng.legadopro`，Widget / ShareExtension 为对应后缀；全部 `3.0.2（7）`。
- 三个可执行文件均 `arm64 / iPhoneOS / minOS 17.0`，不是模拟器产物。
- ZIP 中没有 `_CodeSignature` 或 `embedded.mobileprovision`；本包仍需用户自行签名，不是已签名安装包。
- IPA 38,460,602 字节，SHA-256：`80e9d94621a954c1d80a211c6a9bdd668dd826041912baccd5b876f945e72a3a`。
- 输出：`Release IPA verification OK: SHA-256, ZIP, App/extensions 3.0.2 (7), arm64 iPhoneOS, minOS17, unsigned bundle markers`。

已按用户选择正式发布 [LegadoPro 3.0.2（7）](https://github.com/DenisZheng/Yuedu-reader/releases/tag/legadopro-v3.0.2)，发布时间 `2026-11-22T12:26:37Z`。先创建草稿并上传 IPA / checksum，核对两个附件的 GitHub SHA-256 与本地一致，再公开并设 Latest。实际查询确认 `isDraft=false`、`isPrerelease=false`、`isLatest=true`，两个附件均 `uploaded`，Tag 没有移动。

```bash
gh run view 45018465876 --repo DenisZheng/Yuedu-reader \
  --json status,conclusion,headSha,headBranch,url,jobs
gh run download 45018465876 --repo DenisZheng/Yuedu-reader \
  --pattern 'legadopro-unsigned-ipa-45018465876-*' --dir "$download_dir"
python3 -I .artifacts/release-3.0.2-fNkR5o/verify_ipa.py "$ipa"
gh release edit legadopro-v3.0.2 --repo DenisZheng/Yuedu-reader \
  --draft=false --prerelease=false --latest --verify-tag
gh release list --repo DenisZheng/Yuedu-reader \
  --json tagName,isLatest,isDraft,isPrerelease
gh release download legadopro-v3.0.2 --repo DenisZheng/Yuedu-reader \
  --pattern 'LegadoPro-unsigned.ipa*' --dir "$public_download_dir"
# 在下载目录核对实际公开附件：
shasum -a 256 -c LegadoPro-unsigned.ipa.sha256
```

`download_dir` / `ipa` / `public_download_dir` 对应本次新的产物目录，实际路径与详细结果保存于 `.artifacts/release-3.0.2-fNkR5o/` 的 `download-dir.txt`、`verification.json`、`public-download-verification.json`。上述为实际执行命令的关键参数摘要，不重复构建。

公开发布后通过 `gh release download` 重新下载，两附件与已校验的 CI 产物字节一致；最终 `shasum` 输出 `LegadoPro-unsigned.ipa: OK`。直接下载：[IPA](https://github.com/DenisZheng/Yuedu-reader/releases/download/legadopro-v3.0.2/LegadoPro-unsigned.ipa)、[checksum](https://github.com/DenisZheng/Yuedu-reader/releases/download/legadopro-v3.0.2/LegadoPro-unsigned.ipa.sha256)。对应源码由固定 Tag / Source code 附件提供；私有源包和原始诊断未上传。后续发布记录提交不改变该产物或固定 Tag。

## 仍未验收与回滚

真机、iPad、iOS 17–26、全部实源、媒体 / WebDAV 和正式签名未由本轮发布操作验收；`stageAccepted=false` 保持。正式 GitHub Release / Latest 是用户的分发选择，不等于 App Store 或 S8 放行。

版本可通过后续明确授权的提交调整；不覆盖本次 Tag、不强推。旧 IPA 已按批准清理，不能声称可以从本地文件无损恢复；保留的 archive / source / run 日志可支持重新构建，但要另行授权。新 Release 若需撤回或删附件，同样需明确批准。
