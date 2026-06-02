#!/usr/bin/env bash

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-preflight-dmz.sh}"

COMPOSE_UP=0
SKIP_IMAGE_CHECK=0

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Verify the standalone DMZ MQTT WebSocket proxy before running compose up.

USAGE
  ./scripts/$SCRIPT_NAME [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --compose-up
      Start the DMZ stack after all checks pass.

  --skip-image-check
      Skip local image existence checks.

ENVIRONMENT VARIABLES
  DMZ_ROOT
      Explicit DMZ root path. Defaults to the parent directory of dmz/scripts.

  DMZ_ENV_FILE
      Explicit env file. Defaults to dmz/.env. Runtime checks require .env.

  DMZ_RUNTIME
      Force runtime selection. Supported values: docker, podman.

EXAMPLES
  Basic check:
    ./scripts/$SCRIPT_NAME

  Check and start DMZ:
    ./scripts/$SCRIPT_NAME --compose-up

  Force Podman:
    DMZ_RUNTIME=podman ./scripts/$SCRIPT_NAME --compose-up

EOF
}

parse_preflight_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        echo "$SCRIPT_NAME $SCRIPT_VERSION"
        exit 0
        ;;
      --compose-up)
        COMPOSE_UP=1
        ;;
      --skip-image-check)
        SKIP_IMAGE_CHECK=1
        ;;
      *)
        die "Unknown option: $1

Run './scripts/$SCRIPT_NAME --help' for usage."
        ;;
    esac
    shift
  done
}

check_local_images() {
  if [ "$SKIP_IMAGE_CHECK" = "1" ]; then
    warn "Skipping local image checks by request."
    return 0
  fi

  local images img missing=0
  images="$(dmz_compose_images)"
  [ -n "$images" ] || die "No image entries found in DMZ compose config."

  log "Checking that DMZ compose images exist locally..."
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      printf '  OK   %s\n' "$img"
    else
      printf '  MISS %s\n' "$img" >&2
      missing=$((missing + 1))
    fi
  done <<EOF_IMAGES
$images
EOF_IMAGES

  if [ "$missing" -gt 0 ]; then
    die "$missing DMZ image(s) are missing locally. Run ./scripts/load-compose-images.sh first."
  fi
}

preflight_dmz_main() {
  parse_preflight_args "$@"

  init_dmz_context require-env
  require_dmz_selected_runtime

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"

  require_dmz_runtime_env

  log "Validating DMZ compose config..."
  dmz_compose config --quiet

  check_local_images

  log "DMZ preflight passed."

  if [ "$COMPOSE_UP" = "1" ]; then
    log "Starting DMZ proxy..."
    dmz_compose_up
  else
    cat <<EOF

Next step:
  cd "$DMZ_ROOT_DIR"
  ./scripts/dmz-compose.sh up

Or run:
  ./scripts/preflight-dmz.sh --compose-up

EOF
  fi
}
