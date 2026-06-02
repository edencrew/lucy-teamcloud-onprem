#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_SCRIPT_DIR="${DMZ_SCRIPT_DIR:-$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)}"
DMZ_RUNTIME=podman
SCRIPT_NAME="${SCRIPT_NAME:-load-compose-images.sh}"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=load-compose-images-common.sh
. "$SCRIPT_DIR/load-compose-images-common.sh"

load_compose_images_main "$@"
