# S8：R146图片的系统TLS时效失败（2026-11-14）

## 当前状态：外部前置条件，客户端调查关闭（2026-11-14）

按用户决定，#78不再持续阻塞S8。代码审阅确认`RSSImageService` → `SourceRequestExecutor` → 系统URLSession路径没有server trust/challenge放行，失败发生在HTTP响应之前，没有可修复的客户端缺陷。该图片用例已从full/nonmedia门槛的通过集中剔除并由verifier单列为`externalPreconditionsNotRun`，**状态是未验收，不是通过**；图片代表链由R014、R217承担。证书链恢复可信后用同一请求与解码断言重验，再移回门槛。仍然不安装CA、不改时间/网络、不关闭校验、不重复公网重试。

## 判断

**当前R146首图仍未通过，已收敛到系统证书链时效校验失败：`NSURLErrorDomain -1202`，底层SSL `-9814 / errSSLCertExpired`。不能用R014图片成功替代，也不应修改iOS图片解析器或绕过TLS。**

当前SDK `Security.framework/Headers/SecBase.h`将`-9814`定义为`errSSLCertExpired`，注释是“chain had an expired cert”。这能说明本次系统看到的链存在过期证书，但不能唯一确定哪一张、源站/CDN、代理或本地信任环境的责任；没有据此更换VPN、安装CA或修改系统时间。

## 分离正文与资源边界

1. 生产列表两页与正文、已读/收藏/阅读位置和内容重载继续通过：4个事务为301、200、200、200，无凭据/跨origin transaction。
2. 先仅从实际正文读取首图准入元数据，不请求图片。该目标为HTTPS、无query/fragment/内嵌凭据、图片扩展；已记录确切URL哈希，不公开URL。
3. 后续独立图片测试只准入该**确切URL**，新的隔离Session最多1个GET任务；列表/正文边界在结束后退出，图片边界不能准入任何其他路径或跟随跳转。全流程最多4个HTTP事务+1个图片连接事务。
4. 图片仍经过生产`RSSImageService`及系统TLS。没有SSL challenge放行、重试、另写请求/解码器、关闭ATS或改原始源配置。预算/metrics只覆盖本轮隔离Session业务请求，不把系统DNS/TLS服务流量误称为已经捕获或计数；诊断辅助不额外发起证书链请求。

| 观察 | iPhone | iPad |
| --- | --- | --- |
| 列表/正文事务 | 301、200、200、200 | 301、200、200、200 |
| 正文/状态重载 | 987字符，通过 | 987字符，通过 |
| 图片URLSession事务 | 1 | 1 |
| 图片HTTP状态 | 无 | 无 |
| 图片凭据 / 边界拒绝 | 0 / 0 | 0 / 0 |
| 系统失败 | -1202，原始SSL元数据-9814 | -1202，安全诊断SSL码-9814 |
| 原生图片解码 | 未证明到达/未通过 | 未证明到达/未通过 |

图片阶段有1个配置为GET的任务/连接事务，**不能据此声称HTTP GET已发出或服务器返回了HTTP错误**；TLS在HTTP响应之前失败。原失败不是“合法空图片”或图片解码成功。

## 可重复反馈与证据

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad串行独立对照
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/S8RepresentativeSourceTests/testReviewedR146ImageRequiresSystemTrustAndNativeDecode'
```

- 元数据预审：`/tmp/readerfork-s8-r146-target.xcresult`，只有列表/正文，图片未请求。
- iPhone失败：`/tmp/readerfork-s8-r146-trust.xcresult`，1项失败。已有本地控制台中`_kCFStreamErrorCodeKey=-9814`，只提取该数值，不对外输出原错误字典。
- iPad失败：`/tmp/readerfork-s8-r146-trust-iPad.xcresult`。原生链输出`sslCode=-9814`；同轮3项合成诊断通过不覆盖这1项图片失败。
- 系统自己的原始错误字段可能含URL/证书信息，xcresult与原始控制台只留本地，未经脱敏不可原样外发/提交。测试自己的输出只保留准入哈希、状态/数量和白名单错误码。

`S8TLSFailureMetadata`仅查询已经存在的NSError根及两层underlying，提取白名单整数SSL码，不重新求值trust、不主动抓取AIA/OCSP/证书链。合成测试覆盖嵌套过期码、未知字符串/字典/数值/非整数/NaN拒绝，以及过深错误链截断。

## 非媒体回归与门槛

日志安全、共享桥、B122搜索和TLS元数据等非媒体子集，两端各16项/4 suites、零失败零跳过，精确用例集合已核对。证据`/tmp/readerfork-s8-nonmedia-final/`。

此处两端16项是当时的历史非媒体子集，随后安全边界加入5项变为21项/5 suites（见[自动回归记录](s8-regression-gate.md)）。子集**显式排除**真实MP3和本次R146图片TLS两项，不把框架“零跳过”解释成二者通过；命令需同时包含：

```bash
-skip-testing:'yuedu appTests/S8RepresentativeSourceTests/testPreScreenedRSSAudioResourceAdvancesAndProgressReloads'
-skip-testing:'yuedu appTests/S8RepresentativeSourceTests/testReviewedR146ImageRequiresSystemTrustAndNativeDecode'
```

#78保留当前图片TLS门槛；#77的旧本地音频间歇失败后来经双端同文件隔离App/XCTest对照、原用例/PCM/R141复查均未复现，但根因仍未定，见[音频记录](s8-audio-clock-diagnostics.md)。已通过的B122搜索对照、R014图片和R146正文不撤销，也不外推为整个媒体闭环通过。S8仍进行中，#58/#64/#65独立。

回滚仅撤去本次独立图片集成用例、安全TLS元数据辅助与对应文档/测试重用调整；保留旧TLS失败、列表/正文测试、其他S8/#74修改和用户数据。无手机安装、commit/push、新依赖、权限或证书配置变更。
