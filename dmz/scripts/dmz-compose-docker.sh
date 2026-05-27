#!/usr/bin/env bash
set -Eeo pipefail

# Operational wrapper around Docker Compose for the standalone DMZ stack.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_RUNTIME=docker
SCRIPT_NAME="dmz-compose-docker.sh"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=dmz-compose-common.sh
. "$SCRIPT_DIR/dmz-compose-common.sh"

dmz_compose_main "$@"
