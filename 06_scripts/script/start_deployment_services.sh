#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"

echo "Starting SepsisCare deployment services in managed background mode."
echo "Use './script/sepsiscare_services.sh status|smoke|logs|stop' for operations."
exec "$SCRIPT_ROOT/sepsiscare_services.sh" start
