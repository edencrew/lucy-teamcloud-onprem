#!/usr/bin/env bash
set -Eeo pipefail

# Compatibility wrapper. Auto-selects Docker or Podman, like onprem-compose.sh.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"

case "${1:-}" in
  -h|--help|-v|--version)
    DMZ_RUNTIME=docker
    SCRIPT_NAME="dmz-compose.sh"
    # shellcheck source=dmz-compose-common.sh
    . "$SCRIPT_DIR/dmz-compose-common.sh"
    dmz_compose_main "$@"
    ;;
esac

case "${DMZ_RUNTIME:-$(detect_dmz_runtime)}" in
  podman)
    exec "$SCRIPT_DIR/dmz-compose-podman.sh" "$@"
    ;;
  docker)
    exec "$SCRIPT_DIR/dmz-compose-docker.sh" "$@"
    ;;
  *)
    die "Could not detect Docker or Podman runtime."
    ;;
esac
