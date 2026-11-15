# YCK205网页一键RSS导入修复（2026-11-15）

## 原始入口与复现

用户确认的按钮页：<https://www.yckceo.com/yuedu/rsss/content/id/205.html>。
对应源JSON：<https://www.yckceo.com/yuedu/rsss/json/id/205.json>，不是按钮页。

有限只读捕获确认按钮文字为`3.x一键导入`，href为`legado://import/rssSource?src=.../json/id/205.json`。JSON请求200，92660字节、36项RSS数组；捕获只在`.git/review-yck205/`，没有提交真实规则或请求配置，也没有执行导入源脚本。

## 根因与修复

网页有两个宿主，之前未共享完整导入管线：

1. 通用`BrowserState`允许WebKit继续导航自定义scheme，没有进入App的RSS分流确认。
2. `JsBridgeBrowserView`自行用无上限dataTask下载并只走BookSource解析/列表，不遵循已修复的系统深链RSS分类合同。

现在两个宿主都转给`BookSourceBrowserImportHost`，仅负责UIKit呈现；`BookSourceDeepLinkHandler`拥有确认→限额下载→分类→书源或RSS预览。关闭/消失取消工作，不预览即写库，不执行源规则，不调用系统争用的legado scheme。移除浏览器中重复的无上限请求与BookSource专用确认管线。

普通网页仍使用原来的WKWebpagePreferences和TLS策略。模块深链保留模块导入器；导入动作需要显式确认，不开放任意文件或网页桥系统权限。

## 实际行为验收

新增`ReviewYCK205ImportUITests`从资源库的合成书源分类进入**真实按钮页**，点击实际WebView链接，确认原生导入弹窗，等待RSS比较预览；不点击保存、不刷新源。

旧代码测试失败：`.git/review-yck205-ui-red.log`，`网页一键导入未进入有内容的RSS比较预览`。
修复后零失败：`.git/review-yck205-ui-accepted.log`、`.git/review-yck205-ui-accepted.xcresult`。

决定性输出：

```text
YCK205_IMPORT_PREVIEW 新增 36、更新 0、跳過 0、錯誤 0 saved=false refreshed=false
Executed 1 test, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

环境：由`scripts/sim.sh`解析的Xcode，Swift6/严格并发complete、iOS17部署目标；实际运行iPhone18ProMax/iOS27.2。不是iOS17/真机验证。

公网用例在scheme TestAction中的`YUEDU_RUN_YCK205_IMPORT`默认关闭。经授权单独运行时临时开启该条环境项，再运行：

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
YUEDU_SCHEME=Reader-Fork-Dev bash scripts/xctest.sh -l .git/review-yck205-ui-accepted.log -- \
  -resultBundlePath .git/review-yck205-ui-accepted.xcresult \
  -only-testing:'yuedu appUITests/ReviewYCK205ImportUITests'
```

之后恢复环境项关闭。本轮曾仅向xcodebuild shell传环境变量，测试runner没有继承，导致1项跳过；那次不算通过。上述最终证据为显式TestAction环境配置后实际执行的1项、无跳过。

最小合成/状态回归`.git/review-final-focused-green.log`68 tests/11 suites通过，涵盖导入分类、空书源、限额/嵌套URL/取消、图片与布局、源修订、TLS、WebDAV及iCloud同步逻辑；没有用这些合成通过代替上述网页入口验收。

## 剩余范围与回滚

36个源可进入预览不代表其规则、登录、音视频或站点全可用。没有自动批量保存/联网刷新这些源。S8人工门禁、R146新TLS政策实图和正式签名不因本修复被标通过。

回滚撤回两浏览器到统一宿主的接线与新增宿主/测试；保留系统深链导入分流、有界下载和已有RSS数据。旧浏览器管线存在已知缺陷，不建议单独恢复它。没有清空模拟器或用户书库。
