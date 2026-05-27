#!/usr/bin/env bash
set -Eeo pipefail

# Compatibility wrapper. Prefer the explicit Docker/Podman scripts for new use.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"

case "$(detect_dmz_runtime)" in
  podman)
    exec "$SCRIPT_DIR/load-images-and-up-podman.sh" "$@"
    ;;
  docker)
    exec "$SCRIPT_DIR/load-images-and-up-docker.sh" "$@"
    ;;
  *)
    die "Could not detect Docker or Podman runtime."
    ;;
esac
