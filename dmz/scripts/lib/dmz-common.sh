#!/usr/bin/env bash

# Shared helpers for the standalone DMZ compose stack.
# This file is sourced by scripts under dmz/scripts and intentionally does not
# depend on the parent on-premise project scripts.

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

script_dir() {
  if [ -n "${DMZ_SCRIPT_DIR:-}" ]; then
    printf '%s' "$DMZ_SCRIPT_DIR"
    return 0
  fi

  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  local dir
  dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  case "$(basename "$dir")" in
    lib)
      cd -P "$dir/.." >/dev/null 2>&1 && pwd
      ;;
    *)
      printf '%s' "$dir"
      ;;
  esac
}

resolve_dmz_root() {
  local sdir="$1"
  local root=""

  if [ -n "${DMZ_ROOT:-}" ]; then
    root="$DMZ_ROOT"
  else
    case "$(basename "$sdir")" in
      scripts)
        root="$(dirname "$sdir")"
        ;;
      *)
        root="$sdir"
        ;;
    esac
  fi

  (cd "$root" >/dev/null 2>&1 && pwd) || die "DMZ root not found or not accessible: $root"
}

resolve_path_from_dmz_root() {
  local path="$1"

  case "$path" in
    /*)
      printf '%s' "$path"
      ;;
    *)
      printf '%s/%s' "$DMZ_ROOT_DIR" "$path"
      ;;
  esac
}

select_env_file() {
  local mode="$1"

  if [ -n "${DMZ_ENV_FILE:-}" ]; then
    DMZ_ENV_FILE_RESOLVED="$(resolve_path_from_dmz_root "$DMZ_ENV_FILE")"
    [ -f "$DMZ_ENV_FILE_RESOLVED" ] || die "DMZ env file not found: $DMZ_ENV_FILE_RESOLVED"
    return 0
  fi

  if [ -f "$DMZ_ROOT_DIR/.env" ]; then
    DMZ_ENV_FILE_RESOLVED="$DMZ_ROOT_DIR/.env"
    return 0
  fi

  if [ "$mode" = "allow-example" ] && [ -f "$DMZ_ROOT_DIR/.env.example" ]; then
    DMZ_ENV_FILE_RESOLVED="$DMZ_ROOT_DIR/.env.example"
    return 0
  fi

  die "DMZ .env not found. Create it first: cd '$DMZ_ROOT_DIR' && cp .env.example .env"
}

env_file_value() {
  local key="$1"
  local file="$2"
  local value

  value="$(
    awk -v key="$key" '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      {
        line = $0
        sub(/^[[:space:]]*export[[:space:]]+/, "", line)
        if (index(line, key "=") == 1) {
          print substr(line, length(key) + 2)
          exit
        }
      }
    ' "$file"
  )"

  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

dmz_env_value() {
  local key="$1"
  local value=""

  eval "value=\"\${$key:-}\""
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  env_file_value "$key" "$DMZ_ENV_FILE_RESOLVED"
}

dmz_tls_enabled() {
  local enabled
  enabled="$(dmz_env_value DMZ_ENABLE_TLS)"
  [ -n "$enabled" ] || enabled="1"
  [ "$enabled" != "0" ]
}

dmz_proxy_mode() {
  local mode
  mode="$(dmz_env_value DMZ_PROXY_MODE)"
  [ -n "$mode" ] || mode="mqtt"
  printf '%s' "$mode"
}

dmz_teamcloud_upstream() {
  local upstream
  upstream="$(dmz_env_value INTERNAL_TEAMCLOUD_UPSTREAM)"
  if [ -z "$upstream" ]; then
    upstream="$(dmz_env_value INTERNAL_MQTT_UPSTREAM)"
  fi
  printf '%s' "$upstream"
}

is_tcp_port() {
  local port="$1"
  case "$port" in
    ""|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

dmz_https_port() {
  local port
  port="$(dmz_env_value DMZ_HTTPS_PORT)"
  [ -n "$port" ] || port="443"
  printf '%s' "$port"
}

validate_dmz_server_name() {
  local server_name="$1"
  case "$server_name" in
    *://*|*/*|*:*)
      die "DMZ_SERVER_NAME must be a host or IP only, without scheme, path, or port: $server_name"
      ;;
  esac
}

join_by_space_quoted() {
  local out=""
  local item

  for item in "$@"; do
    if [ -z "$out" ]; then
      out="'$item'"
    else
      out="$out '$item'"
    fi
  done

  printf '%s' "$out"
}

init_dmz_context() {
  local env_mode="$1"
  local sdir

  sdir="$(script_dir)"
  DMZ_SCRIPT_DIR="$sdir"
  DMZ_ROOT_DIR="$(resolve_dmz_root "$sdir")"
  DMZ_RUNTIME_RESOLVED="${DMZ_RUNTIME:-docker}"

  case "$DMZ_RUNTIME_RESOLVED" in
    docker|podman)
      ;;
    *)
      die "Unsupported DMZ runtime: $DMZ_RUNTIME_RESOLVED"
      ;;
  esac

  [ -f "$DMZ_ROOT_DIR/docker-compose.yml" ] || die "DMZ compose file not found: $DMZ_ROOT_DIR/docker-compose.yml"

  select_env_file "$env_mode"

  DMZ_COMPOSE_FILES=("$DMZ_ROOT_DIR/docker-compose.yml")
  if [ "$DMZ_RUNTIME_RESOLVED" = "podman" ]; then
    [ -f "$DMZ_ROOT_DIR/docker-compose.podman.yml" ] || die "DMZ Podman override not found: $DMZ_ROOT_DIR/docker-compose.podman.yml"
    DMZ_COMPOSE_FILES+=("$DMZ_ROOT_DIR/docker-compose.podman.yml")

    if ! dmz_tls_enabled; then
      [ -f "$DMZ_ROOT_DIR/docker-compose.podman.ws.yml" ] || die "DMZ Podman plain WS override not found: $DMZ_ROOT_DIR/docker-compose.podman.ws.yml"
      DMZ_COMPOSE_FILES+=("$DMZ_ROOT_DIR/docker-compose.podman.ws.yml")
    fi
  else
    if ! dmz_tls_enabled; then
      [ -f "$DMZ_ROOT_DIR/docker-compose.ws.yml" ] || die "DMZ plain WS override not found: $DMZ_ROOT_DIR/docker-compose.ws.yml"
      DMZ_COMPOSE_FILES+=("$DMZ_ROOT_DIR/docker-compose.ws.yml")
    fi
  fi

  DMZ_COMPOSE_ARGS=()
  local f
  for f in "${DMZ_COMPOSE_FILES[@]}"; do
    DMZ_COMPOSE_ARGS+=("-f" "$f")
  done
}

require_docker_compose() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available. Check: docker compose version"
}

require_docker_daemon() {
  require_docker_compose
  docker info >/dev/null 2>&1 || die "Container runtime is not running or current user cannot access it."
}

detect_dmz_runtime() {
  require_cmd docker

  local output
  output="$(
    docker compose version 2>&1 || true
    docker version 2>&1 || true
  )"

  case "$output" in
    *Podman*|*podman*|*libpod*|*Libpod*)
      printf '%s' "podman"
      ;;
    *)
      printf '%s' "docker"
      ;;
  esac
}

require_docker_runtime() {
  require_docker_daemon

  if [ "$(detect_dmz_runtime)" = "podman" ]; then
    die "docker compose appears to target Podman. Use the matching Podman DMZ script."
  fi
}

require_podman_runtime() {
  require_docker_daemon

  if [ "$(detect_dmz_runtime)" != "podman" ]; then
    die "docker compose does not appear to target Podman. Use Docker scripts or configure Docker CLI emulation for Podman."
  fi
}

require_dmz_selected_runtime() {
  case "${DMZ_RUNTIME_RESOLVED:-${DMZ_RUNTIME:-docker}}" in
    docker)
      require_docker_runtime
      ;;
    podman)
      require_podman_runtime
      ;;
    *)
      die "Unsupported DMZ runtime: ${DMZ_RUNTIME_RESOLVED:-${DMZ_RUNTIME:-}}"
      ;;
  esac
}

dmz_compose() {
  (cd "$DMZ_ROOT_DIR" && docker compose --env-file "$DMZ_ENV_FILE_RESOLVED" "${DMZ_COMPOSE_ARGS[@]}" "$@")
}

dmz_compose_up() {
  if [ "${DMZ_RUNTIME_RESOLVED:-docker}" = "podman" ]; then
    dmz_compose up -d --no-build "$@"
  else
    dmz_compose up -d --pull never --no-build "$@"
  fi
}

dmz_compose_recreate() {
  if [ "${DMZ_RUNTIME_RESOLVED:-docker}" = "podman" ]; then
    dmz_compose up -d --no-build --force-recreate "$@"
  else
    dmz_compose up -d --pull never --no-build --force-recreate "$@"
  fi
}

dmz_compose_images() {
  dmz_compose_services_with_images | awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' | sort -u
}

dmz_compose_services_with_images() {
  dmz_compose config | awk '
    /^services:/ {
      in_services = 1
      next
    }
    in_services && /^[^[:space:]]/ {
      in_services = 0
    }
    in_services && /^  [^[:space:]#][^:]*:/ {
      service = $0
      sub(/^  /, "", service)
      sub(/:.*/, "", service)
      gsub(/"/, "", service)
      gsub(/\047/, "", service)
      next
    }
    in_services && service != "" && /^    image:/ {
      image = $0
      sub(/^    image:[[:space:]]*/, "", image)
      gsub(/"/, "", image)
      gsub(/\047/, "", image)
      print service "\t" image "\t0"
      service = ""
    }
  ' | sort -k1,1
}

require_dmz_runtime_env() {
  local mode server_name upstream https_port
  mode="$(dmz_proxy_mode)"
  server_name="$(dmz_env_value DMZ_SERVER_NAME)"

  [ -n "$server_name" ] || die "DMZ_SERVER_NAME is not set in: $DMZ_ENV_FILE_RESOLVED"
  validate_dmz_server_name "$server_name"

  if dmz_tls_enabled; then
    https_port="$(dmz_https_port)"
    is_tcp_port "$https_port" || die "DMZ_HTTPS_PORT must be a number between 1 and 65535: $https_port"
  fi

  case "$mode" in
    mqtt)
      upstream="$(dmz_env_value INTERNAL_MQTT_UPSTREAM)"
      [ -n "$upstream" ] || die "INTERNAL_MQTT_UPSTREAM is not set in: $DMZ_ENV_FILE_RESOLVED"
      ;;
    teamcloud)
      upstream="$(dmz_teamcloud_upstream)"
      [ -n "$upstream" ] || die "INTERNAL_TEAMCLOUD_UPSTREAM is not set in: $DMZ_ENV_FILE_RESOLVED"
      if [ -z "$(dmz_env_value INTERNAL_TEAMCLOUD_UPSTREAM)" ]; then
        warn "INTERNAL_TEAMCLOUD_UPSTREAM is not set; falling back to INTERNAL_MQTT_UPSTREAM for teamcloud mode."
      fi
      warn "teamcloud mode requires onprem EXTERNAL_URL, BROKER_WS_URL, and PUBLIC_BROKER_WS_URL to use the same external canonical URL. If the onprem immutable env lock exists, rerun onprem preflight with --allow-immutable-change after updating .env."
      ;;
    *)
      die "DMZ_PROXY_MODE must be mqtt or teamcloud: $mode"
      ;;
  esac

  if dmz_tls_enabled; then
    local cert key cert_host key_host
    cert="$(dmz_env_value DMZ_TLS_CERTIFICATE)"
    key="$(dmz_env_value DMZ_TLS_CERTIFICATE_KEY)"
    [ -n "$cert" ] || cert="/etc/nginx/certs/server.crt"
    [ -n "$key" ] || key="/etc/nginx/certs/server.key"

    case "$cert" in
      /etc/nginx/certs/*)
        cert_host="$DMZ_ROOT_DIR/certs/${cert#/etc/nginx/certs/}"
        [ -f "$cert_host" ] || die "DMZ TLS certificate not found: $cert_host"
        ;;
      *)
        warn "Could not verify custom container certificate path: $cert"
        ;;
    esac

    case "$key" in
      /etc/nginx/certs/*)
        key_host="$DMZ_ROOT_DIR/certs/${key#/etc/nginx/certs/}"
        [ -f "$key_host" ] || die "DMZ TLS private key not found: $key_host"
        ;;
      *)
        warn "Could not verify custom container certificate key path: $key"
        ;;
    esac
  fi
}

archive_basename_without_extensions() {
  local file="$1"
  local base
  base="$(basename "$file")"

  case "$base" in
    *.tar.gz)
      base="${base%.tar.gz}"
      ;;
    *.tgz)
      base="${base%.tgz}"
      ;;
    *.tar)
      base="${base%.tar}"
      ;;
    *)
      base="${base%.*}"
      ;;
  esac

  printf '%s' "$base"
}
