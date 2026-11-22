"""锁住已清理的源脚本调试旁路；只检查源码合同，不替代Swift行为回归。"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = "Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift"
ENGINE = "Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift"
JAVA = "Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift"
LOGIN = "Modules/Features/BookSource/BookSourceFormLoginView.swift"


class SourceDebugLoggingPrivacyTests(unittest.TestCase):
    def test_parser_bridge_has_no_raw_console_diagnostic_bypass(self):
        source = (ROOT / BRIDGE).read_text()
        self.assertFalse(re.search(r"\b(?:NSLog|print)\s*\(", source),
                         "共享规则bridge仍存在绕过诊断入口的原始输出")
        for marker in ("❖SHUSHAN TRACE❖", "❖DISC TRACE❖", "[企點診斷]"):
            self.assertFalse(marker in source, "已清理的源级调试输出不能恢复")
        self.assertTrue("SourceAPIErrorLog.shared.record(" in source)
        self.assertTrue("engine.errorHandler =" in source)

    def test_javascript_engine_does_not_print_arbitrary_source_values(self):
        source = (ROOT / ENGINE).read_text()
        self.assertFalse(re.search(r"\bprint\s*\(", source),
                         "JS执行器仍向控制台输出未经处理的脚本内容")
        self.assertTrue('forKeyedSubscript: "print"' in source,
                        "保留脚本print入口，避免兼容性回归")
        self.assertTrue("self.errorHandler?(msg," in source,
                        "真实异常仍必须进入已有错误回调")

    def test_login_scripts_freeze_source_before_background_work(self):
        source = (ROOT / LOGIN).read_text()
        for name in ("runLoginJS", "runButtonJS"):
            body = source.split(f"func {name}(", 1)[1].split("Task.detached", 1)[0]
            self.assertTrue("let source = source" in body,
                            f"{name}必须在离开主线程前读取源快照")

    def test_login_menu_keeps_errors_without_raw_diagnostic_evaluations(self):
        source = (ROOT / LOGIN).read_text()
        self.assertFalse(re.search(r"\bNSLog\s*\(", source),
                         "登录菜单仍存在原文控制台旁路")
        self.assertFalse("❖SHUSHAN TRACE❖" in source)
        self.assertFalse("java.get('yunpara')" in source,
                         "菜单不能为诊断额外求值并覆盖真实脚本错误")
        self.assertTrue("Self.evaluateDynamicLabels(" in source)
        self.assertTrue("SourceAPIErrorLog.shared.last(" in source)
        self.assertTrue("來源配置腳本錯誤" in source)

    def test_toast_and_log_type_no_longer_duplicate_raw_console_output(self):
        source = (ROOT / JAVA).read_text()
        self.assertFalse("[JSBridge toast]" in source)
        self.assertFalse("[JSBridge logType]" in source)
        self.assertTrue("DispatchQueue.main.async { handler?(msg) }" in source,
                        "提示仍交给主线程用户界面回调")
        self.assertTrue('AppLogger.parse("⟐ source log"' in source,
                        "保留源作者的已有诊断通道，不整包删日志")


if __name__ == "__main__":
    unittest.main()
