#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export DMZ_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=dmz/scripts/lib/dmz-common.sh
. "$SCRIPT_DIR/lib/dmz-common.sh"

case "${1:-}" in
  -h|--help|-v|--version)
    DMZ_RUNTIME=docker
    SCRIPT_NAME="preflight-dmz.sh"
    # shellcheck source=dmz/scripts/lib/preflight-dmz-common.sh
    . "$SCRIPT_DIR/lib/preflight-dmz-common.sh"
    preflight_dmz_main "$@"
    ;;
esac

case "${DMZ_RUNTIME:-$(detect_dmz_runtime)}" in
  podman)
    exec "$SCRIPT_DIR/lib/preflight-dmz-podman.sh" "$@"
    ;;
  docker)
    exec "$SCRIPT_DIR/lib/preflight-dmz-docker.sh" "$@"
    ;;
  *)
    die "Could not detect Docker or Podman runtime."
    ;;
esac
