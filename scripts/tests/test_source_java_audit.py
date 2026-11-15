import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("audit_java", Path(__file__).parents[1] / "audit_source_java_calls.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class SourceJavaAuditTests(unittest.TestCase):
    def test_counts_mentions_and_sources_separately(self):
        # 只统计函数名，不把参数里的合成凭据输出为统计内容。
        mentions, sources = audit.summarize([
            {"jsLib": "java.get('synthetic'); java.get('synthetic'); java.ajax('synthetic')"},
            {"rule": {"content": "java.get('synthetic')"}},
            {"name": "no call"},
        ])
        self.assertEqual(mentions, {"get": 3, "ajax": 1})
        self.assertEqual(sources, {"get": 2, "ajax": 1})

    def test_properties_and_other_objects_are_not_function_calls(self):
        self.assertEqual(list(audit.calls("java.foo; source.ajax(); java.getWebViewUA()")), ["getWebViewUA"])

    def test_export_properties_do_not_truncate_protocol(self):
        exports = audit.direct_exports("""
        @objc protocol LegadoJSBridgeExport: JSExport {
            var title: String { get set }
            func ajax(_ url: String) -> String
        }
        class Helper { func privateOnly() {} }
        """)
        self.assertEqual(exports, {"ajax"})

    def test_invalid_input_fails_instead_of_empty_success(self):
        with self.assertRaises(ValueError): audit.summarize({})
        with self.assertRaises(ValueError): audit.direct_exports("class NoExports {}")


if __name__ == "__main__":
    unittest.main()
