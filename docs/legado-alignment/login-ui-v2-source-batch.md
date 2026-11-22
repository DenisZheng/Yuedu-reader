# LoginUiV2：书源和 RSS 动态登录

> 当前交付：2026-11-22 已合入并推送 `main`（业务合并 `81e89c91`）。下文保留独立开发与自动验收的历史范围；总体状态和限制见 [项目状态页](STATUS.md)。

以 Android `330e606c4d57e08adc056ff8ab7a4132c784da9a` 的 `LoginUiV2`、`BaseSource`、`SourceLoginV2Delegate`、`JsSourceConfig` 为准。既有旧表单和网页登录路径不改；本地阶段起点是已经自动验收的副文、只读段评工作区，未提交。不登录真实账号、不授予权限或运行私人源脚本。

## 可观察行为及边界

- `{"version":2}` 是标记，不是旧表单数组。mainJs 的 `loginUi` / `loginAction` 成对出现时在导入生成标记，不把 marker 当脚本。静态声明式书源和 RSS 从各自 loginUrl 取函数。宿主保持 `BookSourceSession` / `RSSRuntime`，不新建 JSContext、Keychain 存储或网络权限。
- `loginUi(state)` 首次 state 为 {}，返回 `rows`。支持 label、text、password、select、toggle、button，校验必要字段和重复 key/action。显式行值优先于本会话输入，再读已有凭据；只提交当前可见表单，不把临时输入自动写入凭据。
- `loginAction(action,state,form)` 接收动作标识而非独立脚本；支持 `state` 触发重绘、`error` 键级显示、`login` 写入既有凭据 owner、`close` 关闭。未知命令忽略，无效命令不执行原生保存。iOS 使用原生表单，不复制 Android Flex 布局；加载中防重复动作，成功动作可开始按钮冷却。
- 书源和 RSS 凭据命名空间继续隔离，凭据写入校验 revision；撤销、关闭、源失效后不能应用晚到结果。表单、状态与命令文档限 256 KiB，最多 256 行，按钮冷却最多 24 小时；不把表单、令牌、结果或私密异常原文写进诊断。
- 目前从来源配置入口打开，`book`、`chapter` 绑定为 null。不新增 V2 站点验证弹窗或权限；旧数组表单和网页登录路径继续保留。

## 自动验收

- `.artifacts/login-ui-v2/red-2.log`：旧导入拒绝有效的 mainJs 函数对，1 项因 `.invalidConfiguration` 失败。更早的编译错误不计 RED；实现后同一用例通过。
- `.artifacts/login-ui-v2/final-regressions.log`：90 项 Swift Testing／10 suites、2 项既有登录布局 XCTest、2 项隔离 UI 测试均零失败，`TEST SUCCEEDED`。新合同覆盖导入冲突、键级错误、重绘失败保留原表单、显式合成凭据保存、书源与 RSS 隔离、旧源／旧凭据修订拒绝、无效输入和上限。旧 RSS 登录页另用本机 HTTP 检验，未登录真实账号。
- 两项 UI 在同一独立 iPhone 18 Pro Max（iOS 27.2）上进入实际书源、RSS 登录页面，检查 SecureField、字段错误、重绘、冷却与关闭。首次未通过：探针点到系统开关整行的中心，AX 快照显示开关仍为 0；改点开关本体并等待值变化后两项合计 68.748 秒、零失败。截图与命令见 [验证记录](validation.md#loginuiv2-自动验收2026-11-22)。
- 未执行私人源脚本、真实账号登录或站点验证码，不代表 Android Flex 样式、真机、iPad、最低 iOS 17、VoiceOver 或真实源全量验收。验收时尚未提交或推送；回滚只撤本批 V2 差异，前两批的基线快照保存在 `.artifacts/readonly-review/checkpoint/sub-content-plus-review.patch`。
