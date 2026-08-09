#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NAVIS_DESKTOP_LAYOUT_DIAGNOSTICS=1
exec "$PROJECT_DIR/tool/presentation_diagnostics.sh" clone / desktop-layout
