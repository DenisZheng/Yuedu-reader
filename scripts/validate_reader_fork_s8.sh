#!/usr/bin/env bash
# S8可重复自动回归：full包含媒体门槛；nonmedia只验证明确子集；外部前置条件用例两种模式都不运行。永不表示阶段完成。
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-full}"
case "$MODE" in full|nonmedia) ;; *) echo "用法：$0 [full|nonmedia]" >&2; exit 2 ;; esac
if [[ -n "${YUEDU_PACKAGE_DIR:-}" || -n "${YUEDU_WORKSPACE:-}" ]]; then
  echo "S8仅验证当前工程；拒绝隐式package/workspace覆盖" >&2
  exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s8-regression.XXXXXX")}"
mkdir -p "$EVIDENCE"
if [[ -e "$EVIDENCE/s8.xcresult" ]]; then echo "拒绝覆盖已有结果包" >&2; exit 2; fi
xcrun simctl list devices --json > "$EVIDENCE/simulators.json"
DEVICE_ID="$(python3 scripts/verify_reader_fork_s8.py destination "$YUEDU_DEST" "$EVIDENCE/simulators.json")"
python3 - <<'PY'
from pathlib import Path
import hashlib
inputs = {
    'docs/Booksource.json': '3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc',
    'docs/rssSources-valid.json': '0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45',
}
for name, expected in inputs.items():
    if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected:
        raise SystemExit('固定预审输入缺失或哈希变化；未执行实源请求')
PY
python3 - "$MODE" > "$EVIDENCE/suites.txt" <<'PY'
import sys
sys.path.insert(0, 'scripts')
from verify_reader_fork_s8 import selected_cases
print('\n'.join(sorted({identifier.split('/')[0] for identifier in selected_cases(sys.argv[1])})))
PY
args=()
while IFS= read -r suite; do
  [[ -n "$suite" ]] || { echo "拒绝空suite选择，避免退回全量测试" >&2; exit 1; }
  args+=("-only-testing:yuedu appTests/$suite")
done < "$EVIDENCE/suites.txt"
(( ${#args[@]} > 0 )) || { echo "没有选择任何S8 suite" >&2; exit 1; }
# R146图片是外部证书链前置条件（-1202/-9814）：任何模式都不运行、不计通过，verifier单列。
args+=("-skip-testing:yuedu appTests/S8RepresentativeSourceTests/testReviewedR146ImageRequiresSystemTrustAndNativeDecode")
if [[ "$MODE" == nonmedia ]]; then
  args+=("-skip-testing:yuedu appTests/S8RepresentativeSourceTests/testPreScreenedRSSAudioResourceAdvancesAndProgressReloads")
  args+=("-skip-testing:yuedu appTests/S8RepresentativeSourceTests/testPreScreenedPublicRSSImageCandidateListHasBoundedTargets")
fi
status=0
bash scripts/xctest.sh -l "$EVIDENCE/s8.log" -- -resultBundlePath "$EVIDENCE/s8.xcresult" "${args[@]}" || status=$?
# 失败同样导出最终结果；没有xcresult或只有框架中途结论时不回退为成功。
xcrun xcresulttool get test-results summary --path "$EVIDENCE/s8.xcresult" --format json > "$EVIDENCE/s8-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/s8.xcresult" --format json > "$EVIDENCE/s8-tests.json"
python3 scripts/verify_reader_fork_s8.py verify "$MODE" "$EVIDENCE/s8-summary.json" \
  "$EVIDENCE/s8-tests.json" "$EVIDENCE/s8.log" "$status" "$DEVICE_ID"
echo "证据：${EVIDENCE}（模式=${MODE}；S8仍需人工与剩余门槛）"
