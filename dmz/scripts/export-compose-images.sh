#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export DMZ_SCRIPT_DIR="$SCRIPT_DIR"

exec "$SCRIPT_DIR/lib/export-compose-images.sh" "$@"
