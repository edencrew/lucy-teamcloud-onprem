#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ONPREM_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=scripts/lib/onprem-common.sh
. "$SCRIPT_DIR/lib/onprem-common.sh"

target="${ONPREM_RUNTIME:-$(onprem_detect_target)}"
case "$target" in
  docker|podman)
    onprem_exec_target_script "$target" "preflight" "$@"
    ;;
  *)
    printf '\033[1;31m[ERROR]\033[0m unsupported ONPREM_RUNTIME: %s\n' "$target" >&2
    exit 1
    ;;
esac
