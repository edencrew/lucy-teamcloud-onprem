#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ONPREM_SCRIPT_DIR="$SCRIPT_DIR"
export ONPREM_SCRIPT_DIR

if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
  export PROJECT_ROOT
fi

exec "$SCRIPT_DIR/lib/export-compose-images.sh" "$@"
