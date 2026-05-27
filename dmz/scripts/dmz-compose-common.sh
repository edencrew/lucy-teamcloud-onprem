#!/usr/bin/env bash

# Shared implementation for Docker/Podman DMZ compose operation wrappers.

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-dmz-compose.sh}"

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Operational wrapper around the standalone DMZ compose stack.

  This follows the same command style as the parent on-premise
  scripts/onprem-compose.sh wrapper. Data and local files are preserved by
  default. This script never runs docker compose down -v.

USAGE
  ./scripts/$SCRIPT_NAME <COMMAND> [ARGS...]

COMMANDS
  check
      Validate the DMZ env and merged compose config.

  up [SERVICE...]
      Validate, then start the DMZ stack:
        docker compose up -d --no-build [SERVICE...]

  down
      Stop and remove DMZ compose containers while preserving files:
        docker compose down

  restart [SERVICE...]
      Validate, then restart running DMZ containers:
        docker compose restart [SERVICE...]

  recreate [SERVICE...]
      Validate, then force-recreate DMZ containers without pulling/building:
        docker compose up -d --no-build --force-recreate [SERVICE...]

  restart-stack
      Validate, run docker compose down, then start the stack again.

  ps
      Show DMZ compose service status.

  logs [SERVICE...]
      Show recent DMZ compose logs. Additional docker compose logs options may
      be passed before SERVICE names.

  config
      Print the merged DMZ Docker Compose config.

  images
      Print the image tags from the merged DMZ Docker Compose config.

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
  ./scripts/$SCRIPT_NAME check
  ./scripts/$SCRIPT_NAME up
  ./scripts/$SCRIPT_NAME ps
  ./scripts/$SCRIPT_NAME logs
  ./scripts/$SCRIPT_NAME restart dmz-mqtt-proxy
  ./scripts/$SCRIPT_NAME recreate
  ./scripts/$SCRIPT_NAME restart-stack
  ./scripts/$SCRIPT_NAME down

EOF
}

dmz_compose_init() {
  init_dmz_context require-env
  require_docker_compose
}

dmz_compose_require_runtime() {
  require_dmz_selected_runtime
}

dmz_compose_log_context() {
  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"
}

dmz_compose_validate() {
  require_dmz_runtime_env
  log "Validating DMZ compose config..."
  dmz_compose config --quiet
}

cmd_check() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  dmz_compose_validate
  log "DMZ check passed."
}

cmd_up() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  dmz_compose_validate
  log "Starting DMZ proxy..."
  dmz_compose_up "$@"
}

cmd_down() {
  if [ "$#" -gt 0 ]; then
    die "down does not accept service arguments."
  fi

  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  log "Stopping DMZ proxy while preserving files..."
  dmz_compose down
}

cmd_restart() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  dmz_compose_validate
  log "Restarting DMZ proxy..."
  dmz_compose restart "$@"
}

cmd_recreate() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  dmz_compose_validate
  log "Recreating DMZ proxy..."
  dmz_compose_recreate "$@"
}

cmd_restart_stack() {
  if [ "$#" -gt 0 ]; then
    die "restart-stack does not accept service arguments."
  fi

  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose_log_context
  dmz_compose_validate
  log "Stopping DMZ proxy while preserving files..."
  dmz_compose down
  log "Starting DMZ proxy..."
  dmz_compose_up
}

cmd_ps() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose ps "$@"
}

cmd_logs() {
  dmz_compose_init
  dmz_compose_require_runtime
  dmz_compose logs --tail=200 "$@"
}

cmd_config() {
  dmz_compose_init
  dmz_compose config "$@"
}

cmd_images() {
  dmz_compose_init
  dmz_compose_images
}

dmz_compose_main() {
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
      show_help
      exit 1
      ;;
  esac

  local cmd="$1"
  shift

  case "$cmd" in
    check)
      if [ "$#" -gt 0 ]; then
        die "check does not accept arguments."
      fi
      cmd_check
      ;;
    up)
      cmd_up "$@"
      ;;
    down)
      cmd_down "$@"
      ;;
    restart)
      cmd_restart "$@"
      ;;
    recreate)
      cmd_recreate "$@"
      ;;
    restart-stack)
      cmd_restart_stack "$@"
      ;;
    ps)
      cmd_ps "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    config)
      cmd_config "$@"
      ;;
    images)
      if [ "$#" -gt 0 ]; then
        die "images does not accept arguments."
      fi
      cmd_images
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}
