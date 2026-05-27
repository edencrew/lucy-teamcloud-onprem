#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_RUNTIME=docker
SCRIPT_NAME="down-docker.sh"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=down-common.sh
. "$SCRIPT_DIR/down-common.sh"

down_main "$@"
