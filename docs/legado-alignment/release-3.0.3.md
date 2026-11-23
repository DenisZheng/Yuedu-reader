# LegadoPro 3.0.3（8）构建交接（2026-11-23）

## 已完成

- 修复提交 `ead78adbc9e34a031addd55de29dd47fdfc904cd` 已 Push 到 `origin/main` 并核对远端。最终复用原阅读器与封面转场，由 `BookshelfNavigationHost` 的 UIKit 栈持有封面阅读器，原 SwiftUI 栈保留书架内页/搜索；详情见[故障与验证记录](bookshelf-reader-return-2026-11-23.md)。
- iPhone iOS27.2 4 项真实 UI、iPad iOS27.2 2 项真实 UI 均 0 失败、`** TEST SUCCEEDED **`；原回退 RED 和所有无效对照保留，不靠禁用搜索/动画或定时等待修复。
- 有问题的 `legadopro-v3.0.2` Release 已按用户授权改回草稿下架。`gh release view` 确认 `isDraft=true`，`gh release list` 确认 `isLatest=false`；两个附件的名称/摘要与原值一致，Tag 不删除或移动。
- 共享 `xcconfig/Yuedu-reader_version.xcconfig` 递增为 `3.0.3（8）`，修改前备份 `.artifacts/release-3.0.3-6NbeZt/version-before.xcconfig`。工作流、签名、身份、依赖和源包不变。

## 本轮升版检查

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_*ipa*.py' -v
python3 -B -m unittest discover -s scripts/tests -p 'test_fork_configuration.py' -v
git diff --check
```

实际工作流/合成打包 24 项、Fork配置9项均 `OK`。本地化、设计规范两份同步、Markdown本地链接/围栏、UTF-8/LF 等检查见修复记录。配置/打包检查不冒充新的 Release 归档或手机运行。

## 构建与交接约定

发布 Tag 为 `legadopro-v3.0.3`，必须指向包含修复和本次升版的固定 commit。触发前检查该 Tag / workflow run 不存在；随后只调用一次：

```bash
gh workflow run build-ios.yml --ref legadopro-v3.0.3 --repo DenisZheng/Yuedu-reader
```

使用既有 `workflow_dispatch`、`Reader-Fork-Dev` scheme、Release 真机归档、关闭 Apple 签名；不添加自动触发或新签名配置。按用户明确要求，**触发后不 watch、不轮询、不重触发 CI**。请求返回的 URL / 固定提交写入 `.artifacts/release-3.0.3-6NbeZt/handoff.json`，构建本身不写通过。

待用户通知完成后，只检查现有 run 的最终结论和 head SHA，下载该 run 的 IPA / checksum，核对 App与两个扩展的 `3.0.3（8）`、Release身份、arm64/iPhoneOS、ZIP、hash 和签名包状态，再决定正式Release/Latest交付。此时没有创建或发布 `3.0.3` Release，不称旧IPA含本修复。

## 边界

未验证真机、最低 iOS17、全部格式/实源和完整人工无障碍。新的 IPA 仍需自行签名；用户没有授权 Apple签名、安装手机、删除书库、覆盖Tag或改变S8未验收状态。旧3.0.2公开入口已下架，但用户下载目录中的旧文件没有擅自删除。重新公开旧Release或删除其附件仍需明确批准。
