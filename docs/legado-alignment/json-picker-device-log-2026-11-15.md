# 自签文件选择失败：设备日志定位

## 本次输入与采集

用户在当前全能签安装包中复现JSON点击后选择器不返回。没有改签名、删除数据、安装其他App或附加LLDB。

Apple原生`log collect`首次普通权限尝试退出77：`Must be root to collect logs from attached device`，未创建归档。停止后用户明确同意在Mac终端管理员授权，复现并生成本地归档；助手没有取得密码或自动提权。

用户执行的采集方案：

```bash
sudo /usr/bin/log collect \
  --device-name "DENIS PHONE" \
  --last 5m --size 20m \
  --predicate 'process == "YueduReader" OR subsystem CONTAINS[c] "fileprovider" OR subsystem CONTAINS[c] "documentmanager" OR eventMessage CONTAINS[c] "dev.denis.readerfork.dev"' \
  --output ".git/signed-picker-device-logs.akgbz7wm/repro.logarchive"
```

原始归档与脱敏分析仅保存在`.git/signed-picker-device-logs.akgbz7wm/`，不公开上传。用户终端命令的退出码未提供；不能声称助手运行的管理员采集退出0。

助手实际运行`/usr/bin/log show --archive <上述归档> --info --debug --style ndjson --predicate <相同相关条件>`，退出0；提取8072个JSON记录，其中8071条有事件时间，范围为2026-11-15 21:49:11.962669至21:53:49.910290（+0800）。其中App事件1610条。输出引用仅保留与故障相关的非个人信息错误，不公开文件名、路径、规则正文或原始书签。

## 直接证据

首次失败附近顺序：

| 时间（21:53） | 进程／阶段 | 安全摘要 |
| --- | --- | --- |
| 22.305449 | DocumentManager.Service | 收到用户点击动作 |
| 22.314036 | DocumentManager.Service | 已选中URL，准备交给delegate |
| 22.321639 | DocumentManager.Service | 扩展sandbox并取得bookmark |
| 22.322043 | YueduReader／DocumentManager | `_didPickItemBookmarks`，`usingBookmark == YES` |
| 22.322958 | YueduReader | `Could not resolve bookmark. Error: NSError: Cocoa 257` |
| 22.322982 | YueduReader／DocumentManager | `Failed to create a url from bookmarkableString (Error Domain=NSCocoaErrorDomain Code=257)` |
| 22.323054 | YueduReader／DocumentManager | 准备交给`documentBrowser:didPickDocumentURLs:`的数组为空，选中文件未能准备／物化 |

上述书签解析、URL创建失败、空数组三条分别出现48次。这是同一复现场景中的重复失败日志，不是48个独立测试通过／失败。

使用当前iOS SDK Foundation头文件核对：`FoundationErrors.h:20`明确`NSFileReadNoPermissionError = 257`。因此该错误表示读取权限拒绝，不是JSON语法错误。

## 可以和不能得出的结论

**可以确认：本次点击已被系统接收，但系统在向App交付有效文件URL时，授权书签解析被拒绝。** 尚无有效URL可供后续JSON解码／本地拷贝流程消费。

- 本次错误不是来自普通书籍导入的`BookFileProtection.copy`，也不是JSON解析器给出的错误。
- 把授权启动放到更早的业务Task、仅在后续Data／copy加NSFileCoordinator，不能直接修复已经发生在系统交付有效URL之前的此项失败。
- 不能凭空断言SwiftUI的`onCompletion`从未被调用：系统明确记录了空文件数组，但现包没有足够业务入口日志区分“未回调”和“收到空数组”。准确表述是未得到有效文件URL。
- 当前日志还出现LaunchServices数据库映射权限`-54`，以及`SecTaskLoadEntitlements`对另一个PID读取标志失败。App PID为14149，SecTask消息目标PID为14151，不能将它误读为App无法读取自身entitlements，不能据此指责get-task-allow=false或证书过期。
- 未取得当前安装IPA精确签入数据，不能把先前20:02包的App ID／Info差异不加核验地认定为本次唯一触发字段。

## 与源码对照的关系

[源码对照](json-picker-source-comparison.md)证明参考项目的书源JSON入口显式使用公开UIKit复制导入模式`asCopy: true`，而本Fork使用SwiftUI文件导入封装。现有日志将问题收敛到书签交付路径，使“以显式复制导入模式对照”比继续逐个关权限或修改普通书籍三个文件更有针对性。

这不等于已证明复制模式必然解决，也不等于全能签整套工具必然有问题。仍需比较可用App同输入的交付日志，或经用户确认用最小原生复制选择器对照包复验，并保持当前签名／数据条件。

当前完成的是日志采集与失败阶段定位，未修改Swift或重新编译；不标JSON自签兼容修复、不标S8通过。原始归档留作本地复查，回滚不涉及任何App／数据修改。
