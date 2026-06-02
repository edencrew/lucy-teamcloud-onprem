#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_SCRIPT_DIR="${DMZ_SCRIPT_DIR:-$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)}"
DMZ_RUNTIME=podman
SCRIPT_NAME="${SCRIPT_NAME:-preflight-dmz.sh}"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=preflight-dmz-common.sh
. "$SCRIPT_DIR/preflight-dmz-common.sh"

preflight_dmz_main "$@"
