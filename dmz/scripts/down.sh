#!/usr/bin/env bash
set -Eeo pipefail

# Compatibility wrapper. Prefer the explicit Docker/Podman scripts for new use.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"

case "${1:-}" in
  -h|--help|-v|--version)
    DMZ_RUNTIME=docker
    SCRIPT_NAME="down.sh"
    # shellcheck source=down-common.sh
    . "$SCRIPT_DIR/down-common.sh"
    down_main "$@"
    ;;
esac

case "$(detect_dmz_runtime)" in
  podman)
    exec "$SCRIPT_DIR/down-podman.sh" "$@"
    ;;
  docker)
    exec "$SCRIPT_DIR/down-docker.sh" "$@"
    ;;
  *)
    die "Could not detect Docker or Podman runtime."
    ;;
esac
