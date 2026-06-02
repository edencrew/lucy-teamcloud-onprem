#!/usr/bin/env bash
set -Eeo pipefail

# User-facing wrapper. Auto-selects Docker or Podman.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export DMZ_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=dmz/scripts/lib/dmz-common.sh
. "$SCRIPT_DIR/lib/dmz-common.sh"

case "${1:-}" in
  -h|--help|-v|--version)
    DMZ_RUNTIME=docker
    SCRIPT_NAME="load-compose-images.sh"
    # shellcheck source=dmz/scripts/lib/load-compose-images-common.sh
    . "$SCRIPT_DIR/lib/load-compose-images-common.sh"
    load_compose_images_main "$@"
    ;;
esac

case "$(detect_dmz_runtime)" in
  podman)
    exec "$SCRIPT_DIR/lib/load-compose-images-podman.sh" "$@"
    ;;
  docker)
    exec "$SCRIPT_DIR/lib/load-compose-images-docker.sh" "$@"
    ;;
  *)
    die "Could not detect Docker or Podman runtime."
    ;;
esac
