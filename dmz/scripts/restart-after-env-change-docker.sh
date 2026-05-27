#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_RUNTIME=docker
SCRIPT_NAME="restart-after-env-change-docker.sh"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=restart-after-env-change-common.sh
. "$SCRIPT_DIR/restart-after-env-change-common.sh"

restart_after_env_change_main "$@"
