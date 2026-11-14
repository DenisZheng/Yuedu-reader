# S8补充：真实图片资源与受限Cookie（2026-11-13）

## 结论与范围

**本轮补齐一个RSS真实图片链，以及受限Cookie的合成跨层闭环；S8仍未完成。**

iPhone / iPad各23项、6 suites通过，零失败零跳过。其中XCTest代表源7项、Swift Testing合同16项；CookieJar参数用例的false/true两种情况都实际执行。没有安装物理设备、修改源包、提交或推送，也没有执行真实登录、验证码、支付、写入或媒体脚本。

- 当前基线为`64149fd1`加工作区改动；此前独立网页返回（#74）保持原样，本轮不改生产代码。
- 设备由`scripts/sim.sh`选择：iPhone 18 Pro Max、iPad Pro 13-inch (M5)，均为iOS27.2 (24B8117)模拟器；Xcode SDK为27.2。
- 真实请求改用已有`Reader-Fork-RSS-PoC`宿主，避免普通App主页的后台请求干扰。S8测试会拒绝非隔离宿主，不能用它替代正常App/UI或发布验收。
- 原始253/307项包仍只读，哈希不变，未加入测试资源或提交。

## 1. 修正实源验收的重定向约束

原`S8RequestMeter`在Session delegate中返回nil，**不能阻止生产请求自己的task delegate跟随重定向**。因此历史`redirectsBlocked=0`不代表没有跳转；历史R146的301事务仍是有效观察，但不能按“Session已禁止跳转”解释。

新增`S8RequestBoundary`只装到这些测试的隔离URLSession：

- 在系统HTTP协议分派前拒绝非GET、body、URL内凭据、Cookie/Authorization、未准入的确切URL和超预算请求。
- 允许的请求直接由系统协议处理；没有代理/复制网络栈，不重写响应，也不使用URLProtocol拦截WebKit子资源。
- 下一页、选中正文和单张图片经预审后才显式准入。R146只额外允许已审查canonical URL的完整SHA-256匹配，不开放整站路径或任意重定向。
- `URLProtocol.canInit`可能被系统重复询问，预算计的是协议准入次数，重复询问只会提前耗尽预算。R146上限5次准入，最终HTTP事务断言仍为至多4；其他实源用例上限为1或2。
- URLProtocol类方法没有Session实例，注册表使用锁保护的单个弱引用，重叠创建直接失败。此实现仅适合这些串行验收，不是生产请求权限系统。

4项loopback合同实际证明：

1. 不加边界的对照中，Session拒绝回调为0，但生产task delegate已让目标收到请求。
2. 加边界后，同样的未准入目标收到0次请求。
3. 已准入哈希的301目标可由生产重定向路径正常读取。
4. POST、Cookie、Authorization、未知路径和超预算请求在发出前失败。

R146首次受保护复跑确实拦住了一个未准入canonical路径。随后两次无Cookie、禁跟随的单GET预审确认其301 Location为HTTPS同源、无query/内嵌凭据；没有访问该Location。最终只准入此确切URL的哈希，再运行生产流程。没有通过增加整站白名单或关闭TLS来让测试变绿。

## 2. R014：列表到真实CDN图片

先以单次GET预审R014第一页：HTTP200、20个图片候选；目标为公开HTTPS、无query/fragment/内嵌凭据。CDN主机用固定SHA-256校验，任何变更均先拒绝。R181首轮预审的10个Feed条目没有图片，未伪造图片输入或强行改用其他链接。

实际生产调用链：

```text
RSSFeedSession → RSSStore条目
  → 预审首条目的imageURL
  → RSSImageService.load（相同隔离URLSession）
  → inspect / displayImage
  → 已读、收藏落盘 → RSSStore重建
```

| 观察 | iPhone | iPad |
| --- | ---: | ---: |
| HTTP GET / 状态 | 2 / 200、200 | 2 / 200、200 |
| 凭据请求 / 边界拒绝 | 0 / 0 | 0 / 0 |
| JPEG字节 | 75,292 | 75,292 |
| 解码尺寸 | 640×440 | 640×440 |
| 条目图片地址、已读和收藏重载 | 通过 | 通过 |

这证明真实图片字节经过生产检查和原生解码/显示准备，不是HTTP200或静态图片字段检查。没有加载整篇文章、其他图片、iframe或视频；没有进行屏幕视觉/VoiceOver验收。R146此前外部图片的`NSURLErrorDomain -1202`仍未解决，R014成功不代表R146或其他CDN通过。

## 3. 合成Cookie跨层闭环

`S8RestrictedCookieFlowTests`使用唯一临时Cookie、自建loopback页面和1×1 PNG，分别运行CookieJar=false/true：

```text
RSSFeedSession列表 → type=1条目 → RSSTypedArticleModel.ruleContent
  → RSSImageService实际读取private图片和public对照图片
  → RSSStore已读/收藏/类型重载
```

每种情况恰好4次请求。断言：

- 显式Cookie正常传播；关闭自动Jar不禁止已保存Cookie。
- 已保存的`Path=/private` Cookie只出现在private请求，不能出现在public对照图片。
- 列表Set-Cookie只有在Jar开启时才保存并到达后续private正文/图片。
- 图片不是HTML伪响应：生产PNG检查和原生解码得到1×1；状态重载保持图片型条目身份。

所有Cookie值都是合成数据，仅删除本用例唯一命名的Cookie。没有私人账号，**不计为真实受限站点或真实登录通过**。

## 4. 其他代表项复跑

新增边界下，两设备均再次得到：R181 XML 10条、R265列表100个iframe标记、R014两页20→40条、B002文本搜索3项、B122离线匹配DOM1条、R146两页20条/正文987字符/状态重载。

- R146实际4个事务：301、200、200、200；全部同源、GET、无凭据。301不是最终成功状态。
- B122仍只有离线fixture通过；此前真实HTTP200零结果没有被重新判定为成功。
- R265没有加载iframe、媒体内容或播放器，仍只验证列表标记。
- B002仅为兼容性对照：测试副本使用独立缓存修订和中性日志名称，不清理原始源的已有搜索缓存；不修改真实请求与解析规则。

## 5. 命令、证据与失败记录

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export YUEDU_DEST="$(bash scripts/sim.sh dest iPhone)" # iPad同样串行运行
bash scripts/xctest.sh -- \
  -only-testing:'yuedu appTests/S8RepresentativeSourceTests' \
  -only-testing:'yuedu appTests/S8RequestBoundaryTests' \
  -only-testing:'yuedu appTests/S8RestrictedCookieFlowTests' \
  -only-testing:'yuedu appTests/RSSCookieAuthorizationTests' \
  -only-testing:'yuedu appTests/RSSImageServiceTests' \
  -only-testing:'yuedu appTests/RSSMediaResourceSessionTests'
```

最终证据：`/tmp/readerfork-s8-resources.22G9AG/final/`的两设备日志、xcresult、summary和完整tests树；核对23项及6个suite实际存在，未采用中途框架结果。开发过程的失败日志仍保存在上层目录。

本轮开发失败保留，不算通过：测试初版漏UIKit import；测试在主线程调用CookieStore写入触发既有`notOnQueue(.main)`断言，现改为共享执行器；隔离宿主中的书源搜索未显式初始化GlobalSettings快照而触发precondition，现补齐测试初始化；初版相对搜索URL白名单、R146未准入canonical路径及过紧协议准入预算造成的失败也保留。均未靠清空数据、换DerivedData、sleep、禁TLS或吞错处理。重启后出现0项的框架行不代表这些失败已通过。

## 6. 剩余门槛与回滚

S8继续保持进行中：真实音视频/iframe播放器、实际受限Cookie/登录场景、B122定性、R146图片TLS，以及iOS17和物理设备/发布抽查仍待验；性能沿用此前同口径观察，不凭本轮增加性能结论。#58、#64、#65独立，#73已关闭。

回滚仅撤回本轮S8测试、测试边界及对应文档片段；不覆盖之前#74网页返回改动，不删除原始包、Cookie库、用户数据或既有诊断证据。生产代码本轮未改。
