import Foundation
import Testing
@testable import yuedu_app

/// scripts/validate_source_template_logs.sh还会检查实际xctest控制台，不能只证明内存日志已脱敏。
@Suite("AnalyzeUrl template log safety", .serialized)
struct AnalyzeUrlLogSafetyTests {
    @Test("限制/普通上下文都保留模板求值而不记录表达式或结果", arguments: [false, true])
    func templateEvaluationPreservesRequest(restricted: Bool) throws {
        try SourceDiagnosticContext.$restrictedTask.withValue(restricted) {
            let expression = "fixtureTemplateExpressionSecret9281()"
            let result = "fixtureTemplateResultSecret6742"
            let parsed = AnalyzeUrl(ruleUrl: "https://template-fixture.invalid/page?q={{" + expression + "}}",
                                    jsEvaluator: { code, _ in code == expression ? result : nil })
            let components = try #require(URLComponents(string: parsed.evaluatedRuleUrl))
            #expect(components.host == "template-fixture.invalid")
            #expect(components.queryItems?.first?.name == "q")
            #expect(components.queryItems?.first?.value == result)
            print("SOURCE_TEMPLATE_LOG_PROBE_COMPLETED")
        }
    }
}
