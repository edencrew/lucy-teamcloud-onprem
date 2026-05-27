#!/usr/bin/env bash

# Shared implementation for Docker/Podman DMZ restart scripts.

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-restart-after-env-change.sh}"

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Apply DMZ .env changes by recreating the standalone DMZ compose stack.

  This script validates the new DMZ env/compose configuration before stopping
  the running stack. It is fully self-contained under dmz/ and does not call
  parent on-premise scripts.

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
  Apply DMZ .env changes:
    ./scripts/$SCRIPT_NAME

EOF
}

restart_after_env_change_main() {
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
  require_dmz_runtime_env

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"

  log "Validating DMZ compose config before restart..."
  dmz_compose config --quiet

  log "Stopping DMZ proxy while preserving files..."
  dmz_compose down

  log "Starting DMZ proxy with updated env..."
  dmz_compose_up
}
