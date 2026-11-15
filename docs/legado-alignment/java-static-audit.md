# 真实源包 java.* 静态引用统计

命令：`python3 scripts/audit_source_java_calls.py --output docs/legado-alignment/java-static-audit.md`。

本统计不执行脚本，不展开网络请求，不输出规则、URL、源名、请求头或账号数据。词法匹配也会包含字符串/注释中的提及，遗漏动态属性调用；它不是运行时覆盖率或所有源可用的证明。

“直接导出”仅表示名字出现在 `LegadoJSBridgeExport` 的函数声明中，未验证参数、权限或RSS上下文。未命中者还需要核查JS shim、别名与固定Android基准，不能直接判为不支持。

## rssSources-valid.json（307项）

词法函数名：37；提及次数：495；含引用的源：66。

| java函数 | 涉及源数 | 提及次数 | 直接导出 |
| --- | ---: | ---: | --- |
| `addBook` | 2 | 2 | 待核查 |
| `ajax` | 26 | 46 | 是 |
| `ajaxAll` | 1 | 1 | 是 |
| `androidId` | 1 | 2 | 是 |
| `base64Decode` | 6 | 14 | 是 |
| `base64DecodeToByteArray` | 2 | 4 | 是 |
| `base64Encode` | 7 | 9 | 是 |
| `bytesToStr` | 2 | 2 | 是 |
| `createSymmetricCrypto` | 5 | 5 | 待核查 |
| `deviceID` | 1 | 1 | 是 |
| `digestHex` | 1 | 1 | 是 |
| `encodeURI` | 2 | 2 | 是 |
| `get` | 20 | 38 | 是 |
| `getElement` | 1 | 1 | 待核查 |
| `getElements` | 13 | 17 | 是 |
| `getString` | 29 | 141 | 是 |
| `getStringList` | 1 | 2 | 是 |
| `getThemeConfig` | 2 | 2 | 是 |
| `getVerificationCode` | 6 | 7 | 是 |
| `getWebViewUA` | 3 | 3 | 是 |
| `head` | 1 | 1 | 是 |
| `log` | 17 | 35 | 是 |
| `longToast` | 10 | 25 | 是 |
| `md5Encode16` | 1 | 1 | 是 |
| `open` | 2 | 3 | 是 |
| `put` | 19 | 31 | 是 |
| `searchBook` | 13 | 13 | 是 |
| `setContent` | 10 | 17 | 是 |
| `startBrowser` | 6 | 7 | 是 |
| `startBrowserAwait` | 2 | 6 | 是 |
| `strToBytes` | 2 | 2 | 是 |
| `timeFormat` | 3 | 7 | 是 |
| `timeFormatUTC` | 2 | 2 | 是 |
| `toURL` | 7 | 7 | 待核查 |
| `toast` | 6 | 30 | 是 |
| `webView` | 2 | 7 | 是 |
| `webViewGetOverrideUrl` | 1 | 1 | 是 |

## Booksource.json（253项）

词法函数名：43；提及次数：749；含引用的源：95。

| java函数 | 涉及源数 | 提及次数 | 直接导出 |
| --- | ---: | ---: | --- |
| `aesBase64DecodeToString` | 3 | 5 | 待核查 |
| `ajax` | 31 | 70 | 是 |
| `ajaxAll` | 3 | 4 | 是 |
| `androidId` | 1 | 1 | 是 |
| `base64Decode` | 9 | 15 | 是 |
| `base64DecodeToByteArray` | 1 | 1 | 是 |
| `base64Encode` | 2 | 2 | 是 |
| `connect` | 6 | 7 | 是 |
| `createSymmetricCrypto` | 1 | 8 | 待核查 |
| `downloadFile` | 1 | 1 | 是 |
| `encodeURI` | 2 | 3 | 是 |
| `get` | 16 | 38 | 是 |
| `getElements` | 4 | 6 | 是 |
| `getString` | 21 | 87 | 是 |
| `getVerificationCode` | 2 | 2 | 是 |
| `getWebViewUA` | 3 | 3 | 是 |
| `hexDecodeToByteArray` | 1 | 1 | 是 |
| `hexDecodeToString` | 2 | 2 | 是 |
| `htmlFormat` | 1 | 1 | 是 |
| `log` | 26 | 48 | 是 |
| `longToast` | 8 | 35 | 是 |
| `md5Encode` | 14 | 201 | 是 |
| `open` | 1 | 1 | 是 |
| `openBook` | 1 | 2 | 待核查 |
| `openUrl` | 3 | 4 | 是 |
| `openWeb` | 1 | 1 | 待核查 |
| `post` | 3 | 3 | 是 |
| `put` | 17 | 27 | 是 |
| `reLoginView` | 1 | 1 | 是 |
| `readTxtFile` | 1 | 1 | 是 |
| `refreshExplore` | 10 | 36 | 是 |
| `searchBook` | 4 | 4 | 是 |
| `setContent` | 1 | 1 | 是 |
| `startBrowser` | 7 | 8 | 是 |
| `startBrowserAwait` | 4 | 5 | 是 |
| `strToBytes` | 1 | 1 | 是 |
| `t2s` | 7 | 33 | 是 |
| `timeFormat` | 13 | 20 | 是 |
| `timeFormatUTC` | 1 | 4 | 是 |
| `toNumChapter` | 5 | 10 | 是 |
| `toast` | 16 | 41 | 是 |
| `upLoginData` | 3 | 3 | 是 |
| `webView` | 2 | 2 | 是 |

## RSS未直接导出项的复核

- `createSymmetricCrypto`、`toURL`已有`LegadoJavaInteropRuntime`的JS shim；`toURL`返回URL组成对象，不表示开放任意文件/系统连接。
- `getElement`由`JSCoreEngine.installJavaElementAccessors`转接`getElementValue`，直接函数名扫描不能识别该别名。
- `addBook`在RSS包中有2项词法提及，当前桥未提供此名称；本次不盲目新增自动书架写入。需按具体交互确认与权限合同单独评估，不能宣称这些源全功能可用。

## 范围判断

先处理RSS包的“待核查”函数，并逐个查证真实调用所需能力；书源包单列，不据此扩大首期RSS范围。Dict、AutoTask/Cron、任意文件或系统能力仍不开放。

新增压缩/字体能力前仍需实际需求、隔离fixture、许可和安全审查；不得按函数数量盲目补实现。
