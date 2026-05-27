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
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
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

  [ -f "$DMZ_ROOT_DIR/docker-compose.yml" ] || die "DMZ compose file not found: $DMZ_ROOT_DIR/docker-compose.yml"

  select_env_file "$env_mode"

  DMZ_COMPOSE_FILES=("$DMZ_ROOT_DIR/docker-compose.yml")
  if ! dmz_tls_enabled; then
    [ -f "$DMZ_ROOT_DIR/docker-compose.ws.yml" ] || die "DMZ plain WS override not found: $DMZ_ROOT_DIR/docker-compose.ws.yml"
    DMZ_COMPOSE_FILES+=("$DMZ_ROOT_DIR/docker-compose.ws.yml")
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
  docker info >/dev/null 2>&1 || die "Docker daemon is not running or current user cannot access Docker."
}

dmz_compose() {
  (cd "$DMZ_ROOT_DIR" && docker compose --env-file "$DMZ_ENV_FILE_RESOLVED" "${DMZ_COMPOSE_ARGS[@]}" "$@")
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
  local server_name upstream
  server_name="$(dmz_env_value DMZ_SERVER_NAME)"
  upstream="$(dmz_env_value INTERNAL_MQTT_UPSTREAM)"

  [ -n "$server_name" ] || die "DMZ_SERVER_NAME is not set in: $DMZ_ENV_FILE_RESOLVED"
  [ -n "$upstream" ] || die "INTERNAL_MQTT_UPSTREAM is not set in: $DMZ_ENV_FILE_RESOLVED"

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
