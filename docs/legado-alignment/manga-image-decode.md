# 漫画横条图片还原修复（2026-11-16）

## 结果与范围

用户随后明确“禁漫天堂API”可复现。固定书源包 B013 的原始 `imageDecode` 规则在离线乱序图上确实失败：运行时不支持 `Packages.android.graphics.BitmapFactory.decodeByteArray`，规则捕获异常后返回原图。因此本次确认的是**图片横条没有还原**，不是解析器把整章多张 `<img>` 合并成一张图。

已在现有共享 JS 运行时补齐受控的位图接口，不改源包、阅读模式、图片身份、持久化格式、网络权限或播放器。修复后原始规则的固定像素回放通过；游客实源一章解析出 13 页，实际下载并还原前三张图片，独立 Pillow 像素对照三张均完全一致。iPhone / iPad Simulator 各 **48 项通过**（Swift Testing 47 项 + 原源规则 XCTest 1 项）。

此前[长图修复](book-source-media-fixes.md)针对单张超长图被整页缩小，有独立失败回归；不能把那项通过当作此次多图反馈已解决，也没有撤回它或把普通图片强制切片。

## 根因与共享实现

数据链仍为章节解析 → `MangaChapterParser` 的独立 `FixedPage` → `FixedPageImageLoader` → `FixedPageImageDecoder` / `BookSourceSession` → 原源 `imageDecode` → Nuke 解码 / 布局。图片还原发生在缩放、裁边和布局之前，不另建图片加载器或源专用分支。

改动：

- `LegadoGraphicsBridge.swift`：ImageIO 解码 / 编码、CoreGraphics 矩形裁剪绘制；正确转换 Android 左上原点与 CoreGraphics 左下绘制坐标，不把整张源图反复缩进每个横条。
- `LegadoJavaInteropRuntime+Graphics.swift`：有限的 `BitmapFactory.decodeByteArray`、`Bitmap.createBitmap` / 尺寸 / 回收 / 压缩、`Rect`、`Canvas.drawBitmap(Bitmap, Rect, Rect, Paint)`、`Paint` 过滤标志。
- 原 `LegadoJavaInteropRuntime` 注入同一 Context，原 `LegadoRuntimeCapabilityRegistry` 准入；不新增 JSContext、文件 / 网络接口或 Android Graphics 全量兼容声明。
- 字节区间合法性、单图最多 16 Mi 像素、边长最多 32,768、输入 / 编码输出最多 8 MiB；同时限制单 Context 与全部 Context 合计计费位图最多 32 Mi 像素。Native 回收 / GC 释放计费，不增加第二套图片缓存。
- 重活在原 JS 队列，新增主线程禁止断言；ImageIO 解码 / 编码记录 `SourcePerfTrace` 的线程和规模，不输出 URL、正文或签名。

未修改既有“规则返回空结果时显示原下载图”的 loader 合同；本源自己捕获异常并返回原字节，所以此前看似加载成功。回归必须比较正确像素，不能只断言返回了图片。

PNG 的无损像素路径已验证；JPEG 复用同一受控编码入口，但没有对 JPEG 有损质量建立逐像素验收。预算约束的是计费位图，不是 App 总内存保证；编码暂存、JS 字节数组和 ImageIO 内部资源仍有额外成本。

## 实源边界与结果

固定本地 `docs/Booksource.json`：253 项，SHA-256 `3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc`，保持原文件不动，不提交原始规则或图片。

B013 游客探测仅调用搜索、目录、章节和图片解码；不调用登录、收藏详情 init、发现或用户操作脚本。临时 session、隔离源变量、禁用 Cookie / credential storage / URLCache，检查既有 Cookie 为空；最多 8 个 GET 请求、单图最多 8 MiB、重定向禁止、并发 1。源配置自行生成的应用签名仅在内存校验并限于确切 API 域；图片 URL 单独逐项准入，不携带签名到 CDN。没有扩大生产准入或 S8 通用边界。

| 输入 | 实际结果 | 限制 |
| --- | --- | --- |
| B013 禁漫天堂API | 游客搜索 80 条，目录 1 章，正文 13 张图；前三张均 960×1342，还原后生产页面各 400×559；8 次准入、0 次拒绝 | 仅一个游客样本章、前三图；不代表全部章节或用户的具体阅读设置 |
| B018 再漫画（先前对照） | 搜索 / 目录 / 首章成功；19 个 img → 19 页，前三张 822×1200，生产页面各 400×583 | 该路径未复现挤屏；最初包含它的三源批次整体失败，不能把批次写为通过 |
| B104 | 调整确切请求白名单后，章节响应明确要求登录 | 不登录、不绕过认证，未取得章节图片 |
| B135 | 调整首段边界后，搜索 / 228 章目录成功；章节目标仍被边界拦截 | 未完成图片验证；用户随后指定 B013，不为这项扩大白名单或重复网络试探 |

B013 实图独立检查使用 Pillow 从原 JPEG 行像素构造预期排列，不复用 Swift 的裁剪实现：

| 图片索引 | 横条数 | 还原尺寸 | 最大通道差异 | 完整像素一致 |
| --- | --- | --- | --- | --- |
| 0 | 14 | 960×1342 | 0 | True |
| 1 | 12 | 960×1342 | 0 | True |
| 2 | 4 | 960×1342 | 0 | True |

原图、还原图、预览、条数 JSON 及临时探测代码仅保存在未跟踪的 `.artifacts/manga-multipage/`。临时网络测试已移出默认测试目录；正式回归完全使用自建输入，不复制私有签名常量或成人素材。

## 实际执行证据

环境由 `bash scripts/sim.sh doctor` / `xcode` / `dest` 动态解析：Xcode 与 iOS Simulator SDK 27.2，iPhone 18 Pro Max / iPad Pro 13-inch (M5)，均为 iOS 27.2 Simulator。复用 `Reader-Fork-RSS-PoC`、`scripts/xctest.sh` 与既有 DerivedData 串行测试；测试构建提供 App 编译证据，没有另做 build / clean。

### 修复前

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-RSS-PoC bash scripts/xctest.sh \
  -l .artifacts/manga-multipage/bitmap-red.log -- \
  -only-testing:'yuedu appTests/MangaBitmapDecodeTests' \
  -only-testing:'yuedu appTests/MangaRealSourceProbeTests/testJmOriginalImageRuleOnFixedPixels'
```

决定性输出：`MANGA_JM_ORIGINAL_RULE returnedOriginal=true restoredPixels=false graphicsMissing=true`；合成横条像素断言失败；`** TEST FAILED **`。原规则来自上述固定包，只在未提交诊断中执行。

### 修复后双设备

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-RSS-PoC bash scripts/xctest.sh \
  -l .artifacts/manga-multipage/iphone-accepted.log -- \
  -only-testing:'yuedu appTests/MangaBitmapDecodeTests' \
  -only-testing:'yuedu appTests/FixedPageImageDecodeTests' \
  -only-testing:'yuedu appTests/MangaChapterParserTests' \
  -only-testing:'yuedu appTests/LegadoJavaInteropRuntimeTests' \
  -only-testing:'yuedu appTests/LegadoJavaIOInteropTests' \
  -only-testing:'yuedu appTests/RSSPageDecodingTests' \
  -only-testing:'yuedu appTests/MangaRealSourceProbeTests/testJmOriginalImageRuleOnFixedPixels'
```

iPad 同一选择，只将 destination 改为 `$(bash scripts/sim.sh dest iPad)`，日志为 `ipad-accepted.log`。这条命令记录当时仍在临时测试目录的原源规则回放；现在只保留前六个正式类即可运行 47 项自建回归。

两端决定性输出均为：

- `MANGA_JM_ORIGINAL_RULE returnedOriginal=false restoredPixels=true graphicsMissing=false`
- `Executed 1 test, with 0 failures`
- `Test run with 47 tests in 6 suites passed`
- `** TEST SUCCEEDED **`

新 `MangaBitmapDecodeTests` 覆盖整除 / 非整除横条的完整像素、带前后杂字节的区间解码、真正的 Rect 裁剪、非法区间 / 格式 / 像素拒绝、回收后不可使用、同一源连续 40 图、跨 Context 合计预算与回收再分配，以及三张乱序下载图经过**生产 Nuke → 翻页控制器**后保持 0/1/2 三个独立页、正常页宽且像素正确。等待的是实际加载 Task 完成，不用 sleep 稳定状态。

游客实源命令为临时 `MangaRealSourceProbeTests/testJmGuestChapterImages`，日志 `jm-guest-real-final.log`：`MANGA_JM_REAL_RESULT pages=13 restoredImages=3 approvals=8 rejections=0`，该 XCTest 1 项通过。但同次误选了隔离宿主不会注册的 `RSSBackgroundRefreshTests`，其启动注册断言失败，因此**这份日志整体是 TEST FAILED，不是整套通过**。没有修改该业务断言；最终双端回归不把它包含在隔离宿主集合里。

独立 Pillow 命令输出三行 `JM_REAL_PIXEL_CHECK … maxChannelDifference 0 matches True`；计算为按记录的横条数将原图行区间移回目标行，逐字节比较预期 RGB 与还原 PNG。没有把 PNG 字节不相等当作像素正确证据。

### 测试编译阻碍与最终目录状态

增量编译重新检查测试辅助代码，SDK 27.2 的 `OSAllocatedUnfairLock.withLock` 要求 Sendable 的捕获 / 返回，而 Foundation 的 `URLProtocol` 一致性 unavailable：

1. 原 `RSSPageFixtureProtocol.Fixture` 缺少一致性；尝试 checked Sendable 后，实际 `pending` URLProtocol 字段仍被拒绝。
2. 受 `state` / `lifecycle` 两层锁保护的快照改为明确的 `@unchecked Sendable`；读取本机 `os.swiftinterface` 后，仅将携带 URLProtocol 的入队 / 取队操作改为 SDK 提供的 `withLockUnchecked`。不改锁行为、超时、语言模式或编译开关。
3. Graphics 的私有计费对象本身只在锁内访问，补明确的 unchecked Sendable 以符合全局锁闭包合同。

临时网络测试移出默认目录后，再运行 `ReviewSourceRevisionTests`：`final-fixture-release.log` 中 `Test run with 1 test in 1 suite passed` / `** TEST SUCCEEDED **`，实际覆盖固定 held 响应入队、release、解析完成和不相关修订不取消请求，同时证明最终目录仍可编译。

收尾格式 / 相对链接 / 隐私检查输出 `FORMAT_LINK_PRIVACY_OK files=10 sourceEntries=253 sourceHashUnchanged=true temporaryNetworkTestsExcluded=true`，确认十个提交候选为 UTF-8 / LF、文档链接存在、原始包哈希不变且没有复制源签名常量。`git diff --check` 无输出、退出 0；本次未修改用户界面文案或本地化资源。

## 未验证与回滚

- 未验证用户指定的具体书 / 章节、个人源变量、登录后图片、所有章节 / 全部源包、iOS 17 runtime、真机视觉 / 性能、VoiceOver、Release / IPA 或正式签名安装。
- 没有为 B104 登录或为 B135 放宽边界；没有自动操作手机、重装数据、推送或触发 / 监控 Actions。
- 不是 Android Graphics 完整实现，不支持任意绘图、其他 Canvas 重载或所有 Bitmap.Config，不新增文件输出权限。极端输入会按预算明确失败，而不是无限制分配。
- 共享 Nuke pipeline 没有第二份持久化的已处理图片缓存；本次不需要删除书籍、重新导入源或清空用户数据。
- 本次桥接与合成 fixture 为独立实现，只使用 API 名称和矩形行排列合同，不复制 / 提交源脚本、签名常量、Android 源码或实图。

回滚仅由操作员对本次提交执行 `git revert`，撤回四个生产文件、合成回归、必要测试锁及本次文档。没有数据迁移，不做整库 reset、清缓存或擦除模拟器。
