#!/bin/bash
# S4共享执行链及S2/S3回归。不包含未审查的个人源包脚本或媒体平台验收。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s4-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
suites=(
  RSSRuntimeIntegrationTests RSSSharedBridgeTests RSSForegroundRuntimeTests RSSArticleScriptObjectTests
  LegadoRhinoNormalizerTests LegadoConnectionResponseTests LegadoJavaInteropRuntimeTests
  UnsupportedLegadoAPITests LegadoParserBridgeContractTests
  BookSourceSessionQueueTests StageLoginCheckTests SourceVariableOverlayTests
  AjaxAllWorkerJSTests AjaxAllSourceHeadersTests RuntimeFetchDecodingTests
  SourceBrowserJavaBridgeTests
  DiagnosticLogTests DiagnosticRedactorTests
  RSSIdentityStateTests RSSWebDAVBackupTests RSSImportServiceTests RSSSourceFidelityTests
  RSSRealPackImportTests LegadoRSSCompatTests RSSStoreTests RSSBackgroundRefreshTests
  RSSExportTests RSSPageDecodingTests RSSArticleLinkResolutionTests
  SubscriptionArticlesSectionTests RSSFlowFixtureTests RSSLinkRouteTests RSSAlignmentFixtureTests
)
args=()
for suite in "${suites[@]}"; do
  args+=("-only-testing:yuedu appTests/$suite")
done
# 同文件的liveShushanComments需要外部服务和个人API key，不属于S4固定输入门槛。
cases=(
  'SourceBrowserAuthenticationTests/authenticatedFirstLoad()'
  'SourceBrowserAuthenticationTests/currentCredentialsAndIsolation()'
  'SourceBrowserAuthenticationTests/nativeMarkerAuthentication()'
  'RSSUnreadCountTests/countsMatchListedArticles()'
)
for case in "${cases[@]}"; do args+=("-only-testing:yuedu appTests/$case"); done
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/tests.json"
python3 - "$EVIDENCE/summary.json" "$EVIDENCE/tests.json" "${suites[@]}" "${cases[@]}" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary["result"]=="Passed",summary["result"]
assert summary["totalTestCount"]>=180,summary["totalTestCount"]
assert summary["failedTests"]==0 and summary["skippedTests"]==0,summary
tree=json.load(open(sys.argv[2]))
executed={}
case_results={}
def walk(node):
    if isinstance(node,dict):
        if node.get("nodeType")=="Test Case":
            identifier=node.get("nodeIdentifier","")
            if identifier:
                suite=identifier.split("/",1)[0]
                executed.setdefault(suite,[]).append(node.get("result"))
                case_results[identifier]=node.get("result")
        for child in node.get("children",[]):walk(child)
    elif isinstance(node,list):
        for child in node:walk(child)
walk(tree["testNodes"])
for selector in sys.argv[3:]:
    if "/" in selector:
        assert case_results.get(selector)=="Passed",(selector,case_results.get(selector))
    else:
        assert executed.get(selector),f"未执行选定suite: {selector}"
        assert all(result=="Passed" for result in executed[selector]),(selector,executed[selector])
print("S4所有选定合同通过：",summary["totalTestCount"],"项；全部suite/指定用例均实际执行")
PY
ruby scripts/check_localizations.rb
git diff --check
