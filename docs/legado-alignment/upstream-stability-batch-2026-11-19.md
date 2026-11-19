# 上游第一批三项稳定性修复（2026-11-19）

## 结果与范围

用户批准按[上游评估](upstream-78199517-assessment.md)小批合入。在 `8f699695` 当前工作区移植 `75381a89`、`2a66e1e2`、`82177e65`，保留先前 RSS 网页 UA、Release Bundle ID 与其他工作区改动。采用精选补丁，不整包 merge，不切分支，不 commit／push；因此 Git 共同祖先仍为 `dbd25567`，不能声称已整合上游至 `78199517`。

本批只改 6 个既有 Swift 文件并新增 1 个测试文件，没有依赖、构建配置、权限、版本、源配置或持久格式改动。

## 来源与必要适配

上游作者 CHANG-JUI-LIN，沿仓库 MPL-2.0／NOTICE 保留来源；没有复制 Android 代码、站点脚本或素材。

| 来源 | 文件与实际变更 |
| --- | --- |
| `75381a89` | `ChapterDocument.swift` 提取原来的容量 8 为共享默认值；`CoreTextPaginator.swift` 将原无界字典改成最多 8 份完整排版的 LRU，仍是一条缓存路径；`CoreTextPageEngine.swift` 内存警告同步清空分页器缓存 |
| `2a66e1e2` | `ReaderView.swift` 在现有 `ReaderWindowReference.withWindow` 的真实绑定事件后补入底部安全区；不加延时，不查询其他 key window，不覆盖用户自定义页脚距离 |
| `82177e65` | `HomeModelTests.swift`、`SourceCategoryCardsTests.swift` 的封面请求头期望改为书源的默认 Legado UA；不改书源请求行为，不使用 RSS 手机 UA |
| 改编自 `75381a89` | 新增 `CoreTextPaginatorRetentionTests.swift`：使用相同自建正文和生产引擎，补非空／章节就绪断言；隔离进度目录在后台创建、flush 和清理，清理失败报告错误，不照搬上游 `try?` |

## RED：先复现再改行为

先只加入测试、缓存数量只读探针、默认容量常量（仍为 8），不加 LRU、内存警告清空或页脚修复，封面期望亦保持原样。

使用 `scripts/xctest.sh` 选择新增缓存 3 项和封面 2 项，最终 `** TEST FAILED **`；xcresult 为 5 项、1 通过／4 失败、0 跳过。失败是实际行为而非编译错误：

- 三十章前后遍历后 `cachedLayoutCount = 52`，期望不超过 8。
- 内存警告后仍保留 4 份完整排版，期望 0。
- 两个封面已有默认 Legado UA，但测试仍期望空头。
- 相同修订命中同一排版的控制项在修复前即通过。

当次内存观测增长 40.8 MB；这是单次模拟器观察，不是实机峰值承诺。页脚的原始实机／窗口位置未在本轮复现，不把缓存 RED 代替页脚视觉证据。

## GREEN：实际回归

环境：Xcode 27.2、iOS 27.2 iPhone 18 Pro Max 模拟器，工具链和 destination 由 `scripts/sim.sh` 解析。使用 `Reader-Fork-Dev`、原 DerivedData、串行测试；不 clean、不删模拟器或用户数据。测试构建提供 Debug 编译证据，不重复单独 build。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
export YUEDU_SCHEME=Reader-Fork-Dev
result_dir="$(mktemp -d -t upstream-stability)"
bash scripts/xctest.sh -l "$result_dir/green.log" -- -resultBundlePath "$result_dir/green.xcresult" \
  -only-testing:'yuedu appTests/CoreTextPaginatorRetentionTests' \
  -only-testing:'yuedu appTests/BookSourceProviderTests/categoryRow()' \
  -only-testing:'yuedu appTests/SourceCategoryCardsTests/cards()' \
  -only-testing:'yuedu appTests/CoreTextLongChapterPaginationTests' \
  -only-testing:'yuedu appTests/ContentRevisionPaginationTests' \
  -only-testing:'yuedu appTests/ReaderChapterSupplyTests' \
  -only-testing:'yuedu appTests/ChapterDocumentStoreTests' \
  -only-testing:'yuedu appTests/ReaderBarEdgeDistanceTests' \
  -only-testing:'yuedu appTests/ReaderViewportFollowsWindowTests'
```

最终 `Test run with 47 tests in 9 suites passed`、`** TEST SUCCEEDED **`、退出 0；xcresult 47／47、0 失败／跳过／预期失败。相同三十章输入下保留数量为 8，内存警告清到 0，相同修订仍命中；当次内存观测增长 9.1 MB。47 项还覆盖长章取消、首屏／完整分页修订、真实关闭后旧请求不复活、文档存储、默认／自定义页脚距离和窗口视口。

日志与 xcresult 在未跟踪 `.artifacts/upstream-stability-20261119-FHNDd2/`。`ruby scripts/check_localizations.rb` 输出五语 4288 键和 2975 个调用键齐全；`git diff --check` 通过。原两个源包 SHA-256 与方案记录一致，未更改原包。暂存区与分支／标签／远端引用保持不变。

## c51b91a0 的影响

本批不合入 `c51b91a0`。只扫描用户包的接口名称，不执行源脚本、不输出私有源内容：253 个书源、307 个 RSS 中，`readBookConfig`、`getReadBookConfigMap`、`setWebCookie` 的引用数均为 0；YCK 1330／1331／1329 包本机缺失，未统计。当前样本没有使用这些接口，不代表所有 Legado 源都不需要；上游记录的 YCK 哔哩哔哩源通过 `typeof java.readBookConfig` 判断运行环境，缺少时会要求用户更换阅读 App，故对那类源可成为阻断问题。

`readBookConfig` 部分是阅读颜色配置／环境探测，不直接解决 Cloudflare；`setWebCookie` 是另一条浏览器 Cookie 写入能力。Fork 的 `LegadoCookieBridge` 已有撤销检查，而上游新方法未接入它，并将 Cookie 异步写到默认持久 WebKit store；RSS 网页使用非持久 store。因此需先适配撤销、域授权与 store 归属，不能为补一个探测属性就原样扩大 Cookie 能力。

## 限制与回滚

未验证 iOS 17、iPad、物理设备、实际页脚与 Home 指示条位置、VoiceOver 或真实站点。既有页脚距离与窗口视口测试不替代实际 ReaderView 进入窗口后的视觉验收。

回滚仅按上述 6 个文件和新增测试反向恢复本批差异，可与本地 `before/` 备份对照；不恢复整个工作区、不撤销先前 RSS／包名改动、不清数据。新源码不自动更新先前已交付的 IPA；新版归档另记实际证据。
