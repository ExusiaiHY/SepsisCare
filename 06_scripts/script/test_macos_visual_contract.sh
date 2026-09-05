#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
PRIMARY_APP="$PRIMARY_MACOS_ROOT"
MIRROR_APP="$MIRROR_MACOS_ROOT"
WORKSPACE="$PRIMARY_APP/Sources/App/Views/WorkspaceViews.swift"
BRAND="$PRIMARY_APP/Sources/App/AppBrand.swift"
TESTS="$PRIMARY_APP/Tests/AppTests/AppTests.swift"

require_text() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "missing '$needle' in $file" >&2
    exit 1
  fi
}

cmp -s "$PRIMARY_APP/Sources/App/Views/WorkspaceViews.swift" "$MIRROR_APP/Sources/App/Views/WorkspaceViews.swift" || {
  echo "WorkspaceViews.swift differs between primary and apps mirror" >&2
  exit 1
}

cmp -s "$PRIMARY_APP/Sources/App/AppBrand.swift" "$MIRROR_APP/Sources/App/AppBrand.swift" || {
  echo "AppBrand.swift differs between primary and apps mirror" >&2
  exit 1
}

cmp -s "$PRIMARY_APP/Tests/AppTests/AppTests.swift" "$MIRROR_APP/Tests/AppTests/AppTests.swift" || {
  echo "AppTests.swift differs between primary and apps mirror" >&2
  exit 1
}

require_text "$BRAND" "struct AppBrandColorRole"
require_text "$BRAND" "static let colorRoles"
require_text "$WORKSPACE" "static let overviewProductionSignalCount = 4"
require_text "$WORKSPACE" "static let riskVisualizationFamilies = [\"triageStack\", \"phenotypeBars\", \"wardMatrix\"]"
require_text "$WORKSPACE" "ProductionReadinessStripView("
require_text "$WORKSPACE" "RiskAcuityStackChart("
require_text "$WORKSPACE" "WardRiskMatrixView("
require_text "$WORKSPACE" "RoleVisualIdentityGrid("
require_text "$TESTS" "testVisualProductionContractConstants"
require_text "$TESTS" "testBrandColorRolesCoverClinicalVisualizationSemantics"

echo "macOS visual contract OK"
