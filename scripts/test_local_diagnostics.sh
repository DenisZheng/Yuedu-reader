#!/bin/bash
# 编译真实的诊断源码并运行同一份回归测试，不解析 App 的第三方依赖。
# 这是 macOS 子集验证，不能替代 scripts/xctest.sh 的 iOS App/RSS 验收。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash "$ROOT/scripts/sim.sh" xcode)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/readerfork-diagnostics.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/yuedu_app" "$WORK/Tests/DiagnosticsTests"
# 新建临时 manifest；不添加外部依赖、不改变 App 的语言模式或 DerivedData。
printf '%s\n' \
  '// swift-tools-version: 5.9' \
  'import PackageDescription' \
  'let package = Package(name: "LocalDiagnosticsProbe", platforms: [.macOS(.v13)], targets: [' \
  '    .target(name: "yuedu_app"),' \
  '    .testTarget(name: "DiagnosticsTests", dependencies: ["yuedu_app"])' \
  '], swiftLanguageVersions: [.v5])' > "$WORK/Package.swift"
for name in CrashContext DiagnosticEntry DiagnosticLog DiagnosticReportBundle MetricKitCallStack; do
  ln -s "$ROOT/Modules/Services/Diagnostics/$name.swift" "$WORK/Sources/yuedu_app/$name.swift"
done
ln -s "$ROOT/Tests/HostDiagnostics/HostSupport.swift" "$WORK/Sources/yuedu_app/HostSupport.swift"
for name in LocalDiagnosticContextTests DiagnosticRedactorTests MetricKitCallStackTests; do
  ln -s "$ROOT/Tests/iOS/yuedu appTests/$name.swift" "$WORK/Tests/DiagnosticsTests/$name.swift"
done
xcrun swift test --no-parallel --package-path "$WORK" --filter 'LocalDiagnosticContextTests|DiagnosticRedactorTests|MetricKitCallStackTests' 2>&1 | tee "$WORK/tests.log"
# Swift Testing 的实际最终结论必须包含至少一个测试；0项不能放行。
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$WORK/tests.log"; then
  echo "No nonzero successful test verdict" >&2
  exit 1
fi
