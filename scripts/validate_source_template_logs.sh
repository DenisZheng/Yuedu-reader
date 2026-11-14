#!/usr/bin/env bash
# 真实执行AnalyzeUrl合成模板并检查xctest控制台；不连接外部站点，不只检查DiagnosticLog内存条目。
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME="${YUEDU_SCHEME:-Reader-Fork-RSS-PoC}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-template-logs.XXXXXX")}"
mkdir -p "$OUT"
bash scripts/xctest.sh -l "$OUT/tests.log" -- -resultBundlePath "$OUT/tests.xcresult" \
  -only-testing:'yuedu appTests/AnalyzeUrlLogSafetyTests'
python3 - "$OUT/tests.log" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
completed = text.count('SOURCE_TEMPLATE_LOG_PROBE_COMPLETED') == 2
leaked = any(value in text for value in ['fixtureTemplateExpressionSecret9281', 'fixtureTemplateResultSecret6742'])
print(f'template_probes_complete={completed}; expression_or_result_logged={leaked}')
if not completed or leaked:
    raise SystemExit(1)
PY
