#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_RUNTIME=podman
SCRIPT_NAME="load-images-and-up-podman.sh"

# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"
# shellcheck source=load-images-and-up-common.sh
. "$SCRIPT_DIR/load-images-and-up-common.sh"

load_images_and_up_main "$@"
