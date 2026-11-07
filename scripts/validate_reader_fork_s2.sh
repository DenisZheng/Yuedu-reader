#!/bin/bash
# S2只验收导入/配置/保存与显式刷新，不代表S3–S8运行时或媒体闭环。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s2-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
args=()
for suite in RSSImportServiceTests RSSSourceFidelityTests RSSRealPackImportTests LegadoRSSCompatTests RSSStoreTests RSSBackgroundRefreshTests RSSExportTests RSSPageDecodingTests SharedImportQueueDrainerTests WorkIndexServiceTests; do
  args+=("-only-testing:yuedu appTests/$suite")
done
args+=("-only-testing:yuedu appTests/RSSToolbarVoiceOverTests/legadoJSONImport()")
# 私有AX开关的宿主测试不能与XCUITest复用同一次automation会话；先独立跑真实UI。
bash scripts/xctest.sh -l "$EVIDENCE/ui.log" -- -resultBundlePath "$EVIDENCE/ui.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  "-only-testing:yuedu appUITests/RSSImportUITests"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/ui.xcresult" --format json > "$EVIDENCE/ui-summary.json"
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
python3 - "$EVIDENCE/summary.json" "$EVIDENCE/ui-summary.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
for path,minimum in zip(sys.argv[1:],[99,2]):
 result=json.load(open(path))
 assert result["result"]=="Passed",result["result"]
 assert result["totalTestCount"]>=minimum,result["totalTestCount"]
 assert result["failedTests"]==0 and result["skippedTests"]==0, result
assert hashlib.sha256(Path("docs/rssSources-valid.json").read_bytes()).hexdigest()=="0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45"
print("S2选定行为合同与实际UI全部通过；原始307项源包哈希不变")
PY
ruby scripts/check_localizations.rb
git diff --check
