#!/usr/bin/env bash
set -Eeo pipefail

# DMZ standalone restart helper.
# Validates the new DMZ .env/compose configuration before taking down the
# running stack, then recreates containers so env changes are applied.

SCRIPT_VERSION="2.0.0"

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"

show_help() {
  cat <<'EOF'
restart-after-env-change.sh

DESCRIPTION
  Apply DMZ .env changes by recreating the standalone DMZ compose stack.

  This script validates the new DMZ env/compose configuration before stopping
  the running stack. It is fully self-contained under dmz/ and does not call
  parent on-premise scripts.

USAGE
  ./scripts/restart-after-env-change.sh [OPTIONS]

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
    ./scripts/restart-after-env-change.sh

EOF
}

main() {
  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      echo "restart-after-env-change.sh $SCRIPT_VERSION"
      exit 0
      ;;
    "")
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac

  init_dmz_context require-env
  require_docker_daemon
  require_dmz_runtime_env

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"

  log "Validating DMZ compose config before restart..."
  dmz_compose config --quiet

  log "Stopping DMZ proxy while preserving files..."
  dmz_compose down

  log "Starting DMZ proxy with updated env..."
  dmz_compose up -d --pull never --no-build
}

main "$@"
