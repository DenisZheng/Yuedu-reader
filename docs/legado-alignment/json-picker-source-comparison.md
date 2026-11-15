# 自签JSON选择器：真实入口与可用项目源码对照

## 范围与结论

用户报告同一类自签默认配置下`Aminark/legado-ios`能选择JSON，而本Fork单独移除iCloud、最小权限后仍不返回。该证据要求重新核验文件选择代码，不能把之前签名静态差异当作唯一根因。

本次固定参考提交`5f033e4d00ff0ac7055aec7020c536ab800c8cbc`，只读取得代码。参考LICENSE为GPLv3，完整源码仅保存在本地`.git/aminark-file-picker-reference/`，没有复制进产品或执行其脚本。

**确定的源码差异不等于已证实的设备故障因果。** 本次没有改Swift、重新打包／安装或宣称自签故障已经消失。

## 真正的书源入口

本Fork：

- `Modules/Features/BookSource/BookSourceAddFlow.swift:317`、`:461`使用SwiftUI `.fileImporter`，分别属于父页面与导入sheet，不是同一View上重复两个importer。
- `:155`的`handleImportFile`在回调中立即调用`startAccessingSecurityScopedResource`；所以“书源必须等Task启动才授权”与源码不符。
- 同步调用`BookSourceStore.importData(contentsOf:)`和`parseForImport`。同步`nonisolated`函数从MainActor调用仍在当前线程执行，并不会自动后台化。
- `BookSourceStore.swift:748`直接读取资源属性和`Data(contentsOf:options:)`，没有NSFileCoordinator。
- `BookSourceAddFlow.swift:249`为普通导入sheet／网络sheet等待关闭，但未单独等待文件选择器的真实关闭；文件回调可能直接请求下一确认sheet。当前不能断言这个边界已产生设备竞态。

参考项目书源：

- [SourceManagementView.swift:270–303](https://github.com/Aminark/legado-ios/blob/5f033e4d00ff0ac7055aec7020c536ab800c8cbc/App/Features/Sources/SourceManagementView.swift#L270-L303)使用原生`UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)`，多选并提供系统明确确认动作。不能把SwiftUI的内部实现模式凭空断言为asCopy=false；能确认的是我们未显式设置复制模式，而参考设置了。
- 同文件`:237–267`等待“已取得文件”和“选择器实际关闭”两个事件后，才开始预览，兼容两个回调的不同顺序。
- [SourceLibraryModel.swift:7–34](https://github.com/Aminark/legado-ios/blob/5f033e4d00ff0ac7055aec7020c536ab800c8cbc/App/Features/Sources/SourceLibraryModel.swift#L7-L34)在delegate阶段构造文件持有对象，直到后台读取完毕才释放scope；读取使用NSFileCoordinator提供的readableURL。
- 同文件`:205–229`的预览通过后台任务执行实际读取／规范化，不在选择器回调里同步读大文件。

这是与用户“选中文件不返回”更接近的可验证差异：文件交付方式、选择器关闭时序和外部文件读取边界，而不只是证书勾选数量。

## RSS不能与书源混为一条路径

本Fork：`RSSListView.swift:297–301`使用`.fileImporter`；`:643–650`将URL立刻交给确认sheet；`RSSImportService.swift:125–134`在后续异步load中才开启scope、检查属性并直接读Data，没有协调器。

参考RSS：`RSSViews.swift:44–46`同样使用SwiftUI `.fileImporter`，先启动Task；`RSSLibraryModel.swift:63–74`才开启scope并直接读Data，没有采用该项目书源的原生复制选择器或协调器。因此，如果用户验证的是参考RSS，仍需确认其实际使用入口／版本；不能仅用参考书源实现给所有入口定因。

## 对其他Agent意见的核验

1. `AddBookView.swift`→`LocalBookImportService.swift`是普通书籍文件入口，虽支持JSON文本书，并不是书源／RSS规则包入口。其修改不能自动覆盖本次两个故障入口。
2. 普通书籍确实先启动Task，再在批量服务中开启scope。外部文件访问生命周期应明确持有到读取／复制完成，但Apple示例在回调中开启不等于“任何异步后开启都必然失效”的证据。
3. 当前三条实际外部读取路径都缺少协调读取；Apple要求协调读取／写入打开的外部文档，不能假定iCloud／第三方提供器就是普通本地文件。
4. 不应把所有`startAccessing… == false`一律改成失败：安全作用域URL须正确授权，但内部已可访问URL／复制后的沙盒文件不一定需要额外scope。参考持有对象也未把false当作统一硬失败。应该明确输入来源、记录授权结果并让真实访问错误正常上报。
5. `BookFileProtection.copy`同时用于保护书库文件的锁屏可读性，不能为了外部文件协调把全部内部拷贝／保护类处理重写。协调更适合放在外部文件进入App的边界。

## 验证边界与建议

现有描述尚不能区分：选择器没发回调、回调内读文件阻塞，或回调之后下一sheet的呈现失败。失败自签不允许LLDB附加时不能绕过权限；单元测试内部普通文件也不能冒充File Provider实际回调通过。

下一步建议经用户确认建立一份小范围本地Debug对照：只在真正书源／RSS JSON入口使用显式原生复制选择器，区分选中／取消／真实关闭／开始读／读完阶段，不记录路径、文件内容或凭据；沿原解析／确认／存储流程执行。同一自签配置和同一JSON验证，之后再针对失败阶段修正授权持有和协调读取。不要先一口气修改普通书籍三个文件，或再继续随机切换权限。

如采用原生适配，使用公开UIKit API自行实现，不复制GPL产品代码，不引入新依赖、并行parser／store或sleep等定时等待。当前尚未获新对照包操作确认，也没有运行自签行为回归；S8不标通过。

## 官方API依据

通过Context7核对：

- [SwiftUI fileImporter](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:))：完成前设置isPresented=false，取消不一定触发onCompletion；返回安全作用域URL，需要平衡访问的获取与释放。
- [UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)：打开外部文档须正确处理安全作用域和协调读写。
- [文件系统性能与稳定性](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)：使用协调器与后台队列，避免主线程等待远程文件。
