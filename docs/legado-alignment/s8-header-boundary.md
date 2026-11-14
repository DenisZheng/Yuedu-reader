# S8：请求前未知私有头阻断（2026-11-14）

## 结果与范围

**已复现并修正S8测试边界只枚举Cookie/Authorization而漏掉自定义私有头的问题。仅加强无凭据实源验收，不改变生产源的合法认证、CookieJar或头部传播合同。**

`S8RequestBoundary`原先只拒绝Cookie、Authorization、Proxy-Authorization；确切URL和预算符合时，`X-API-Key`仍可能送到服务端。因此此前`credentialHeadersSent=0`只能证明这三个已检查头未出现，不能单独证明任意自定义认证头都没有发出。

新边界只准入已审查的公共传输头名称，如User-Agent、Accept、Range、Referer和条件缓存头；未知头在系统HTTP分派前失败，不消耗成功准入预算。没有按token关键字猜测私有头、把未知头当普通头继续发送，或修改全App生产headers处理。

这个测试边界依然不是任意网页/脚本的通用安全代理：公共头值仍依赖固定源配置预审、空登录/私有header配置与请求上下文检查，URL/query仍独立精确准入。不能把名称名单理解成任意公共头值都不可能含私有数据。WebKit和系统DNS/TLS服务也不是此Session业务计数的全局拦截范围。

## 真实反馈与验证

在同一个自建loopback用例中添加X-API-Key和无认证语义提示的X-Private-Fixture：

- 修复前真实Session将第一个自定义头送到自建服务端，导致“服务端仍应无请求”失败；5项suite共3 issues。没有把fixture密钥发送到公网。
- 修复后两类头均在发出前拒绝；原正常GET仍200，后续超预算请求拒绝，重定向/HEAD合同不变。
- 先前尝试按无括号Swift Testing函数名定向时实际0项，wrapper已拒绝；随后使用整个suite得到真正红→绿。0项结果不计入证据。

证据：

- 0项：`/tmp/readerfork-s8-header-boundary-red.xcresult`（不能当作通过）。
- 真正失败：`/tmp/readerfork-s8-header-boundary-red-suite.xcresult`，5项/1 suite失败。
- 修复后：`/tmp/readerfork-s8-header-boundary-green.xcresult`，5项/1 suite通过。

将这5项加入[自动回归脚本](s8-regression-gate.md)的nonmedia模式后，新脚本双设备均完整退出0：**各21项/5 suites、零失败零跳过，显式排除真实MP3和R146 TLS**。完整full manifest仍为46项/12 suites，未实际整套运行；nonmedia相对full未执行25项（其中2项显式排除），`stageAccepted=false`。

最终新证据：`/tmp/readerfork-s8-header-gate-{iPhone,iPad}/`。实际公网子集证明公共请求仍可运行，但不证明已暂停的真实MP3当前能够运行；#77/#78不由这21项覆盖。

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/tests -p 'test_s8_regression_verdict.py' -v
YUEDU_EVIDENCE_DIR=/tmp/s8-public-headers bash scripts/validate_reader_fork_s8.sh nonmedia
```

10项verdict/shell单元同步通过；格式/文档链接/源包哈希检查保留。未装手机、commit/push、关闭设备、调整CA/路由或弱化TLS。

回滚限定为本次测试边界的公共头名单、两个loopback负例与nonmedia选择集/文档；不改生产认证行为、已有S8/#74修改或用户数据。不建议退回仅枚举三个凭据头并继续宣称“任意私有头都已阻止”。
