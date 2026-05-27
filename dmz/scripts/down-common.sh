#!/usr/bin/env bash

# Shared implementation for Docker/Podman DMZ shutdown scripts.

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-down.sh}"

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Stop and remove the standalone DMZ compose stack while preserving files.

USAGE
  ./scripts/$SCRIPT_NAME [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

ENVIRONMENT VARIABLES
  DMZ_ROOT
      Explicit DMZ root path. Defaults to the parent directory of dmz/scripts.

  DMZ_ENV_FILE
      Explicit env file. Defaults to dmz/.env. Runtime commands require .env.

EXAMPLES
  Stop DMZ:
    ./scripts/$SCRIPT_NAME

EOF
}

down_main() {
  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      echo "$SCRIPT_NAME $SCRIPT_VERSION"
      exit 0
      ;;
    "")
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac

  init_dmz_context require-env
  require_dmz_selected_runtime

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"

  log "Stopping DMZ proxy while preserving files..."
  dmz_compose down
}
