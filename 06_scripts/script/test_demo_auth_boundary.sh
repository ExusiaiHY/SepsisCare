#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
AUTH_BOUNDARY_TEXT="演示界面门禁，不是生产认证"
REMOTE_TOKEN_TEXT="远端敏感接口仍以 Token 控制"
README_BOUNDARY_TEXT="client-side demo gate, not production authentication"

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq "$expected" "$path" || fail "$path is missing: $expected"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$path"; then
    fail "$path still contains: $unexpected"
  fi
}

check_web_file() {
  local path="$1"
  assert_contains "$path" 'const DEMO_PASSWORD = "123123";'
  assert_contains "$path" "$AUTH_BOUNDARY_TEXT"
  assert_contains "$path" "$REMOTE_TOKEN_TEXT"
  assert_contains "$path" '$("#password").value.trim() !== DEMO_PASSWORD'
  assert_not_contains "$path" '$("#password").value.trim() !== "123123"'
}

check_readme() {
  local path="$1"
  assert_contains "$path" "$README_BOUNDARY_TEXT"
  assert_contains "$path" "remote sensitive APIs still require a Bearer token"
}

check_web_file "$APPS_ROOT/sepsiscare-web-client/app.js"
check_web_file "$APPS_ROOT/SepsisCare-Windows/renderer/web/app.js"
check_web_file "$APPS_ROOT/SepsisCare-iOS/Resources/Web/app.js"
check_web_file "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web/app.js"

check_readme "$APPS_ROOT/sepsiscare-web-client/README.md"
check_readme "$APPS_ROOT/SepsisCare-Windows/renderer/web/README.md"
check_readme "$APPS_ROOT/SepsisCare-iOS/Resources/Web/README.md"
check_readme "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web/README.md"

for prefix in "$PRIMARY_MACOS_ROOT" "$MIRROR_MACOS_ROOT"; do
  assert_contains "$prefix/Sources/App/ViewModels/AppViewModel.swift" 'static let demoPassword = "123123"'
  assert_contains "$prefix/Sources/App/ViewModels/AppViewModel.swift" "演示界面门禁，不是生产认证"
  assert_contains "$prefix/Sources/App/Views/LoginView.swift" "AppViewModel.demoAuthBoundaryNotice"
  assert_not_contains "$prefix/Sources/App/ViewModels/AppViewModel.swift" 'password == "123123"'
done

echo "demo auth boundary checks passed"
