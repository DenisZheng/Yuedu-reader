#!/bin/bash
# 在 macOS 宿主测试 RSS 授权用例，不调用真实系统授权、不注册 APNs。
# 不替代 iOS App/UI 测试；测试通过依赖注入断言实际请求次数和结果。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash "$ROOT/scripts/sim.sh" xcode)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/readerfork-rss-authorization.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/yuedu_app" "$WORK/Tests/AuthorizationTests"
printf '%s\n' \
  '// swift-tools-version: 5.9' \
  'import PackageDescription' \
  'let package = Package(name: "RSSAuthorizationProbe", platforms: [.macOS(.v13)], targets: [' \
  '    .target(name: "yuedu_app"),' \
  '    .testTarget(name: "AuthorizationTests", dependencies: ["yuedu_app"])' \
  '], swiftLanguageVersions: [.v5])' > "$WORK/Package.swift"
ln -s "$ROOT/Modules/Services/RSS/RSSNotificationAuthorization.swift" "$WORK/Sources/yuedu_app/RSSNotificationAuthorization.swift"
ln -s "$ROOT/Tests/iOS/yuedu appTests/RSSNotificationAuthorizationTests.swift" "$WORK/Tests/AuthorizationTests/RSSNotificationAuthorizationTests.swift"
xcrun swift test --no-parallel --package-path "$WORK" --filter RSSNotificationAuthorizationTests 2>&1 | tee "$WORK/tests.log"
# Swift Testing 的实际最终结论必须包含至少一个测试；0项不能放行。
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$WORK/tests.log"; then
  echo "No nonzero successful test verdict" >&2
  exit 1
fi
