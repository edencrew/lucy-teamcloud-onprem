#!/usr/bin/env bash

# Shared preflight helpers for Docker and Podman on-prem checks.

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '  \033[1;32mOK\033[0m   %s\n' "$*"
}

info_msg() {
  printf '  \033[1;34mINFO\033[0m %s\n' "$*"
}

warn() {
  printf '  \033[1;33mWARN\033[0m %s\n' "$*" >&2
}

fail_msg() {
  printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

die() {
  printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

script_dir() {
  if [ -n "${ONPREM_SCRIPT_DIR:-}" ]; then
    printf '%s' "$ONPREM_SCRIPT_DIR"
    return 0
  fi

  local src="${BASH_SOURCE[1]}"
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

resolve_project_root() {
  local sdir="$1"
  local root=""

  if [ -n "${PROJECT_ROOT:-}" ]; then
    root="$PROJECT_ROOT"
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

  (cd "$root" >/dev/null 2>&1 && pwd) || die "Project root not found or not accessible: $root"
}

resolve_path_from_root() {
  local path="$1"

  case "$path" in
    /*)
      printf '%s' "$path"
      ;;
    *)
      printf '%s/%s' "$ROOT_DIR" "$path"
      ;;
  esac
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

is_numeric_id() {
  case "$1" in
    ""|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

resolve_runtime_owner() {
  local env_uid env_gid current_uid current_gid
  local invalid_owner
  invalid_owner=0

  env_uid="$(get_env_value HOST_UID)"
  env_gid="$(get_env_value HOST_GID)"

  if [ -n "$env_uid" ] && ! is_numeric_id "$env_uid"; then
    fail_msg "HOST_UID must be numeric: $env_uid"
    invalid_owner=1
  fi

  if [ -n "$env_gid" ] && ! is_numeric_id "$env_gid"; then
    fail_msg "HOST_GID must be numeric: $env_gid"
    invalid_owner=1
  fi

  if [ "$invalid_owner" -eq 1 ]; then
    return 1
  fi

  if command -v id >/dev/null 2>&1; then
    current_uid="$(id -u)"
    current_gid="$(id -g)"
  else
    current_uid=""
    current_gid=""
  fi

  RUNTIME_UID="${env_uid:-$current_uid}"
  RUNTIME_GID="${env_gid:-$current_gid}"

  if [ -z "$RUNTIME_UID" ] || [ -z "$RUNTIME_GID" ]; then
    fail_msg "Could not resolve runtime UID/GID. Set HOST_UID and HOST_GID in .env."
    return 1
  fi

  if [ "$RUNTIME_UID" = "0" ]; then
    fail_msg "Runtime bind mount owner must not be root. Set HOST_UID/HOST_GID to the install user's id values."
    return 1
  fi

  if [ -z "$env_uid" ]; then
    warn "HOST_UID is not set. Using current UID for bind mount preparation: $RUNTIME_UID"
  else
    ok "HOST_UID is set: $env_uid"
  fi

  if [ -z "$env_gid" ]; then
    warn "HOST_GID is not set. Using current GID for bind mount preparation: $RUNTIME_GID"
  else
    ok "HOST_GID is set: $env_gid"
  fi

  ok "Runtime bind mount owner target: ${RUNTIME_UID}:${RUNTIME_GID}"
}

ensure_directory_exists() {
  local rel="$1"
  local full="$ROOT_DIR/$rel"

  if [ -e "$full" ] && [ ! -d "$full" ]; then
    fail_msg "Path exists but is not a directory: $rel"
    return 1
  fi

  if [ ! -d "$full" ]; then
    if mkdir -p "$full"; then
      ok "Directory created: $rel"
    else
      fail_msg "Could not create directory: $rel"
      warn "Suggested fix: mkdir -p $(shell_quote "$full")"
      return 1
    fi
  fi

  return 0
}

path_is_under_directory() {
  local path="$1"
  local dir="$2"

  case "$path" in
    "$dir"|"$dir"/*)
      return 0
      ;;
  esac

  return 1
}

path_is_root_owned() {
  local path="$1"
  local first

  first="$(find "$path" -prune -user 0 -group 0 -print -quit 2>/dev/null || true)"
  [ -n "$first" ]
}

path_is_allowed_root_owned_generated_path() {
  local path="$1"
  local rel full

  path_is_root_owned "$path" || return 1

  for rel in $ROOT_OWNED_GENERATED_FILES; do
    full="$ROOT_DIR/$rel"
    [ "$path" = "$full" ] && return 0
  done

  for rel in $ROOT_OWNED_GENERATED_DIRS; do
    full="$ROOT_DIR/$rel"
    path_is_under_directory "$path" "$full" && return 0
  done

  return 1
}

first_allowed_root_owned_mismatch() {
  local path="$1"
  local uid="$2"
  local gid="$3"
  local first

  first="$(find "$path" -user 0 -group 0 \( ! -user "$uid" -o ! -group "$gid" \) -print -quit 2>/dev/null || true)"
  printf '%s' "$first"
}

log_allowed_root_owned_generated_paths() {
  local dir="$1"
  local uid="$2"
  local gid="$3"
  local rel full mismatch

  for rel in $ROOT_OWNED_GENERATED_FILES; do
    full="$ROOT_DIR/$rel"
    [ -e "$full" ] || continue
    path_is_under_directory "$full" "$dir" || continue
    path_is_root_owned "$full" || continue

    mismatch="$(find "$full" -prune \( ! -user "$uid" -o ! -group "$gid" \) -print -quit 2>/dev/null || true)"
    if [ -n "$mismatch" ]; then
      info_msg "Allowed root-owned generated path: $rel"
    fi
  done

  for rel in $ROOT_OWNED_GENERATED_DIRS; do
    full="$ROOT_DIR/$rel"
    [ -e "$full" ] || continue
    path_is_under_directory "$full" "$dir" || continue

    mismatch="$(first_allowed_root_owned_mismatch "$full" "$uid" "$gid")"
    if [ -n "$mismatch" ]; then
      info_msg "Allowed root-owned generated path: $rel"
    fi
  done
}

first_disallowed_owner_mismatch() {
  local path="$1"
  local uid="$2"
  local gid="$3"
  local candidate

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if path_is_allowed_root_owned_generated_path "$candidate"; then
      continue
    fi
    printf '%s' "$candidate"
    return 0
  done <<EOF_OWNER_MISMATCH
$(find "$path" \( ! -user "$uid" -o ! -group "$gid" \) -print 2>/dev/null || true)
EOF_OWNER_MISMATCH

  return 0
}

first_root_owned_path() {
  local path="$1"
  local first

  first="$(find "$path" -user 0 -print -quit 2>/dev/null || true)"
  printf '%s' "$first"
}

print_root_owned_sample() {
  local path="$1"

  find "$path" -user 0 -print 2>/dev/null | sed -n '1,5p'
}

directory_is_empty() {
  local path="$1"
  local first

  first="$(find "$path" -mindepth 1 -print -quit 2>/dev/null || printf '%s' "__find_failed__")"
  [ -z "$first" ]
}

prepare_host_owned_directory() {
  local rel="$1"
  local full="$ROOT_DIR/$rel"
  local mismatch

  ensure_directory_exists "$rel" || return 0

  info_msg "Checking runtime directory ownership: $rel"
  log_allowed_root_owned_generated_paths "$full" "$RUNTIME_UID" "$RUNTIME_GID"
  mismatch="$(first_disallowed_owner_mismatch "$full" "$RUNTIME_UID" "$RUNTIME_GID")"
  if [ -n "$mismatch" ]; then
    info_msg "Preparing ownership: $rel -> ${RUNTIME_UID}:${RUNTIME_GID}"
    if chown -R "$RUNTIME_UID:$RUNTIME_GID" "$full" 2>/dev/null; then
      ok "Directory ownership prepared: $rel -> ${RUNTIME_UID}:${RUNTIME_GID}"
    else
      fail_msg "Directory ownership mismatch and automatic chown failed: $rel"
      warn "First mismatched path: $mismatch"
      warn "Suggested fix: sudo chown -R ${RUNTIME_UID}:${RUNTIME_GID} $(shell_quote "$full")"
      return 0
    fi
  fi

  if [ -w "$full" ]; then
    ok "Directory exists and is writable: $rel"
  else
    fail_msg "Directory exists but is not writable: $rel"
    warn "Suggested fix: sudo chown -R ${RUNTIME_UID}:${RUNTIME_GID} $(shell_quote "$full")"
  fi
}

prepare_service_owned_directory() {
  local rel="$1"
  local full="$ROOT_DIR/$rel"
  local root_owned

  ensure_directory_exists "$rel" || return 0

  info_msg "Checking service data directory ownership: $rel"
  root_owned="$(first_root_owned_path "$full")"
  if [ -n "$root_owned" ]; then
    if directory_is_empty "$full"; then
      if chown "$RUNTIME_UID:$RUNTIME_GID" "$full" 2>/dev/null; then
        ok "Empty service data directory ownership prepared: $rel -> ${RUNTIME_UID}:${RUNTIME_GID}"
      else
        fail_msg "Empty service data directory is root-owned and automatic chown failed: $rel"
        warn "Suggested fix: sudo chown ${RUNTIME_UID}:${RUNTIME_GID} $(shell_quote "$full")"
      fi
    else
      fail_msg "Service data directory contains root-owned entries: $rel"
      warn "Preflight does not recursively chown existing PostgreSQL data."
      warn "Root-owned sample:"
      print_root_owned_sample "$full" >&2
    fi
  else
    ok "Service data directory exists and is not root-owned: $rel"
  fi
}

array_contains() {
  local needle="$1"
  shift || true

  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

split_colon_list_to_lines() {
  local value="$1"
  printf '%s' "$value" | awk 'BEGIN { RS=":" } NF > 0 { print }'
}

add_compose_file_unique() {
  local file="$1"
  if ! array_contains "$file" "${COMPOSE_FILE_LIST[@]}"; then
    COMPOSE_FILE_LIST+=("$file")
  fi
}

compose_file_list_has_offline() {
  local file base

  for file in "${COMPOSE_FILE_LIST[@]}"; do
    base="$(basename "$file")"
    case "$base" in
      docker-compose.offline.yaml|docker-compose.offline.yml|compose.offline.yaml|compose.offline.yml)
        return 0
        ;;
    esac
  done

  return 1
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

url_authority() {
  local url="$1"
  local no_scheme authority

  no_scheme="$(printf '%s' "$url" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##')"
  authority="$(printf '%s' "$no_scheme" | sed 's|[/?#].*$||' | sed 's#^[^@]*@##')"
  printf '%s' "$authority"
}

url_authority_port() {
  local authority="$1"
  local candidate

  case "$authority" in
    \[*\]:*)
      candidate="$(printf '%s' "$authority" | sed -n 's#^\[[^]]*\]:\([^]]*\)$#\1#p')"
      ;;
    \[*\])
      candidate=""
      ;;
    *:*)
      candidate="${authority##*:}"
      ;;
    *)
      candidate=""
      ;;
  esac

  printf '%s' "$candidate"
}

external_url_gw_port_mapping() {
  local external_url scheme authority port target_port

  GW_PORT_MAPPING=""
  external_url="$(get_env_value EXTERNAL_URL)"
  [ -n "$external_url" ] || return 1

  scheme="$(url_scheme "$external_url")"
  authority="$(url_authority "$external_url")"
  port="$(url_authority_port "$authority")"

  case "$authority" in
    *:)
      port=":"
      ;;
  esac

  case "$scheme" in
    http)
      target_port=80
      [ -n "$port" ] || port=80
      ;;
    https)
      target_port=443
      [ -n "$port" ] || port=443
      ;;
    *)
      return 1
      ;;
  esac

  if ! is_tcp_port "$port"; then
    fail_msg "EXTERNAL_URL port must be a number between 1 and 65535: $external_url"
    return 1
  fi

  GW_PORT_MAPPING="$port:$target_port"
}

prepare_compose_port_override() {
  COMPOSE_PORT_OVERRIDE_REL="${COMPOSE_PORT_OVERRIDE_REL:-.install-state/compose-ports.override.yml}"
  COMPOSE_PORT_OVERRIDE_FILE="$ROOT_DIR/$COMPOSE_PORT_OVERRIDE_REL"

  if ! compose_file_list_has_offline; then
    return 0
  fi

  local mapping state_dir tmp_file
  if external_url_gw_port_mapping; then
    mapping="$GW_PORT_MAPPING"
  else
    mapping=""
  fi

  if [ -z "$mapping" ]; then
    rm -f "$COMPOSE_PORT_OVERRIDE_FILE" 2>/dev/null || true
    return 0
  fi

  state_dir="$(dirname "$COMPOSE_PORT_OVERRIDE_FILE")"
  mkdir -p "$state_dir" || die "Could not create install state directory: $state_dir"

  tmp_file="${COMPOSE_PORT_OVERRIDE_FILE}.tmp.$$"
  {
    printf '%s\n' "# Generated from .env EXTERNAL_URL by preflight/onprem scripts."
    printf '%s\n' "# Do not edit manually; update EXTERNAL_URL instead."
    printf '%s\n' "services:"
    printf '%s\n' "  gw:"
    printf '%s\n' "    ports: !override"
    printf '      - "%s"\n' "$mapping"
  } > "$tmp_file" || die "Could not write compose port override: $tmp_file"

  if [ -f "$COMPOSE_PORT_OVERRIDE_FILE" ] && cmp -s "$tmp_file" "$COMPOSE_PORT_OVERRIDE_FILE"; then
    rm -f "$tmp_file"
  else
    mv "$tmp_file" "$COMPOSE_PORT_OVERRIDE_FILE" || die "Could not save compose port override: $COMPOSE_PORT_OVERRIDE_FILE"
  fi
}

append_compose_port_override() {
  COMPOSE_PORT_OVERRIDE_REL="${COMPOSE_PORT_OVERRIDE_REL:-.install-state/compose-ports.override.yml}"
  COMPOSE_PORT_OVERRIDE_FILE="$ROOT_DIR/$COMPOSE_PORT_OVERRIDE_REL"

  if [ -f "$COMPOSE_PORT_OVERRIDE_FILE" ]; then
    add_compose_file_unique "$COMPOSE_PORT_OVERRIDE_FILE"
  fi
}

detect_base_compose_file() {
  local candidates="docker-compose.yaml docker-compose.yml compose.yaml compose.yml"
  local f

  for f in $candidates; do
    if [ -f "$ROOT_DIR/$f" ]; then
      printf '%s' "$ROOT_DIR/$f"
      return 0
    fi
  done

  return 1
}

detect_compose_files() {
  COMPOSE_FILE_LIST=()

  if [ -n "${COMPOSE_FILES:-}" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      f="$(resolve_path_from_root "$f")"
      [ -f "$f" ] || die "Compose file not found: $f"
      add_compose_file_unique "$f"
    done <<EOF_COMPOSE_FILES
$(split_colon_list_to_lines "$COMPOSE_FILES")
EOF_COMPOSE_FILES
    return 0
  fi

  local base
  base="$(detect_base_compose_file)" || die "No compose file found in project root: $ROOT_DIR"
  add_compose_file_unique "$base"

  local base_name
  base_name="$(basename "$base")"

  local runtime_flavor="${COMPOSE_RUNTIME_FLAVOR:-docker}"
  local f
  case "$base_name" in
    docker-compose.yaml|docker-compose.yml)
      for f in docker-compose.offline.yaml docker-compose.offline.yml; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      for f in "docker-compose.$runtime_flavor.yaml" "docker-compose.$runtime_flavor.yml"; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      for f in docker-compose.override.yaml docker-compose.override.yml; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      ;;
    compose.yaml|compose.yml)
      for f in compose.offline.yaml compose.offline.yml; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      for f in "compose.$runtime_flavor.yaml" "compose.$runtime_flavor.yml"; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      for f in compose.override.yaml compose.override.yml; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      ;;
  esac

  for f in override.yaml override.yml; do
    if [ -f "$ROOT_DIR/$f" ]; then
      add_compose_file_unique "$ROOT_DIR/$f"
    fi
  done

  if [ -n "${COMPOSE_OVERRIDE_FILES:-}" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      f="$(resolve_path_from_root "$f")"
      [ -f "$f" ] || die "Override file not found: $f"
      add_compose_file_unique "$f"
    done <<EOF_OVERRIDE_FILES
$(split_colon_list_to_lines "$COMPOSE_OVERRIDE_FILES")
EOF_OVERRIDE_FILES
  fi
}

build_compose_args() {
  COMPOSE_ARGS=()

  if [ "${COMPOSE_ARGS_INCLUDE_ENV_FILE:-0}" = "1" ] && [ -f "$ROOT_DIR/.env" ]; then
    COMPOSE_ARGS+=("--env-file" "$ROOT_DIR/.env")
  fi

  local f
  for f in "${COMPOSE_FILE_LIST[@]}"; do
    COMPOSE_ARGS+=("-f" "$f")
  done
}

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

join_by_space_quoted() {
  local out=""
  local item
  for item in "$@"; do
    out="$out '$item'"
  done
  printf '%s' "$out"
}

semver_normalize() {
  # Convert something like:
  #   2.20.1-desktop.1 -> 2 20 1
  #   Docker version 27.4.0 -> 27 4 0
  local v="$1"
  v="$(printf '%s' "$v" | sed 's/[^0-9.].*$//' | sed 's/^[^0-9]*//')"

  local major minor patch
  major="$(printf '%s' "$v" | awk -F. '{print $1}')"
  minor="$(printf '%s' "$v" | awk -F. '{print $2}')"
  patch="$(printf '%s' "$v" | awk -F. '{print $3}')"

  [ -n "$major" ] || major=0
  [ -n "$minor" ] || minor=0
  [ -n "$patch" ] || patch=0

  printf '%s %s %s' "$major" "$minor" "$patch"
}

version_ge() {
  local current="$1"
  local required="$2"

  local cmaj cmin cpat rmaj rmin rpat
  set -- $(semver_normalize "$current")
  cmaj="$1"; cmin="$2"; cpat="$3"

  set -- $(semver_normalize "$required")
  rmaj="$1"; rmin="$2"; rpat="$3"

  [ "$cmaj" -gt "$rmaj" ] && return 0
  [ "$cmaj" -lt "$rmaj" ] && return 1

  [ "$cmin" -gt "$rmin" ] && return 0
  [ "$cmin" -lt "$rmin" ] && return 1

  [ "$cpat" -ge "$rpat" ] && return 0
  return 1
}

get_env_value() {
  local key="$1"
  local file="$ROOT_DIR/.env"

  [ -f "$file" ] || return 0

  awk -v key="$key" '
    BEGIN { found = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      pos = index(line, "=")
      if (pos == 0) next
      k = substr(line, 1, pos - 1)
      v = substr(line, pos + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k != key) next

      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)

      if (v ~ /^".*"$/) {
        v = substr(v, 2, length(v) - 2)
      } else if (v ~ /^\047.*\047$/) {
        v = substr(v, 2, length(v) - 2)
      } else {
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/[[:space:]]+$/, "", v)
      }

      print v
      found = 1
      exit
    }
  ' "$file"
}

is_placeholder_value() {
  local value="$1"

  case "$value" in
    ""|\
    *your-domain.com*|\
    *your-company.com*|\
    *your-secure-password*|\
    *your-db-root-password*|\
    *your-db-password*|\
    *change-this*|\
    *changeme*|\
    *CHANGE_ME*|\
    *example.com*)
      return 0
      ;;
  esac

  return 1
}

url_scheme() {
  local url="$1"
  printf '%s' "$url" | sed -n 's#^\([A-Za-z][A-Za-z0-9+.-]*\)://.*#\1#p'
}

url_host() {
  local url="$1"
  local no_scheme host
  no_scheme="$(printf '%s' "$url" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##')"
  host="$(printf '%s' "$no_scheme" | sed 's#^[^@]*@##' | sed 's#/.*##' | sed 's/:.*//')"
  printf '%s' "$host"
}

is_localhost_host() {
  local host="$1"

  case "$host" in
    localhost|\
    127.*|\
    0.0.0.0|\
    ::1|\
    "[::1]")
      return 0
      ;;
  esac

  return 1
}

validate_required_env() {
  log "Checking .env required values..."

  local env_file="$ROOT_DIR/.env"

  if [ ! -f "$env_file" ]; then
    fail_msg ".env file not found: $env_file"
    if [ -f "$ROOT_DIR/.env.example" ]; then
      warn "Create it first: cp .env.example .env"
    fi
    return 0
  fi

  ok ".env exists"

  local required_keys="EXTERNAL_URL BROKER_WS_URL LUCY_ADMIN_EMAIL LUCY_ADMIN_PASSWORD LUCY_ADMIN_NAME DB_ROOT_PASSWORD DB_USERNAME DB_PASSWORD TZ"
  local key value

  for key in $required_keys; do
    value="$(get_env_value "$key")"

    if [ -z "$value" ]; then
      fail_msg "$key is missing or empty in .env"
      continue
    fi

    if is_placeholder_value "$value"; then
      fail_msg "$key still looks like a placeholder: $value"
      continue
    fi

    ok "$key is set"
  done
}

validate_urls() {
  log "Checking URL settings..."

  local external_url broker_ws_url ext_scheme broker_scheme ext_host broker_host
  external_url="$(get_env_value EXTERNAL_URL)"
  broker_ws_url="$(get_env_value BROKER_WS_URL)"

  if [ -z "$external_url" ]; then
    fail_msg "EXTERNAL_URL is empty"
    return 0
  fi

  ext_scheme="$(url_scheme "$external_url")"
  ext_host="$(url_host "$external_url")"

  case "$ext_scheme" in
    http|https)
      ok "EXTERNAL_URL scheme is $ext_scheme"
      ;;
    *)
      fail_msg "EXTERNAL_URL must start with http:// or https://: $external_url"
      ;;
  esac

  if [ -z "$ext_host" ]; then
    fail_msg "EXTERNAL_URL hostname could not be parsed: $external_url"
  elif is_localhost_host "$ext_host"; then
    fail_msg "EXTERNAL_URL must not use localhost / loopback / 0.0.0.0: $external_url"
  else
    ok "EXTERNAL_URL hostname is $ext_host"
  fi

  if [ -z "$broker_ws_url" ]; then
    fail_msg "BROKER_WS_URL is empty"
    return 0
  fi

  broker_scheme="$(url_scheme "$broker_ws_url")"
  broker_host="$(url_host "$broker_ws_url")"

  case "$broker_scheme" in
    ws|wss)
      ok "BROKER_WS_URL scheme is $broker_scheme"
      ;;
    *)
      fail_msg "BROKER_WS_URL must start with ws:// or wss://: $broker_ws_url"
      ;;
  esac

  if [ "$ext_scheme" = "https" ] && [ "$broker_scheme" != "wss" ]; then
    fail_msg "BROKER_WS_URL must use wss:// when EXTERNAL_URL uses https://"
  elif [ "$ext_scheme" = "http" ] && [ "$broker_scheme" != "ws" ]; then
    fail_msg "BROKER_WS_URL should use ws:// when EXTERNAL_URL uses http://"
  else
    ok "BROKER_WS_URL scheme matches EXTERNAL_URL"
  fi

  case "$broker_ws_url" in
    */mqtt|*/mqtt/)
      ok "BROKER_WS_URL path looks like /mqtt"
      ;;
    *)
      warn "BROKER_WS_URL usually ends with /mqtt: $broker_ws_url"
      ;;
  esac

  if [ -n "$broker_host" ] && is_localhost_host "$broker_host"; then
    fail_msg "BROKER_WS_URL must not use localhost / loopback / 0.0.0.0: $broker_ws_url"
  fi
}

validate_admin_name() {
  log "Checking admin account constraints..."

  local name
  name="$(get_env_value LUCY_ADMIN_NAME)"

  if [ "$name" = "admin" ]; then
    ok "LUCY_ADMIN_NAME is admin"
  else
    fail_msg "LUCY_ADMIN_NAME must be admin. Current value: ${name:-<empty>}"
  fi
}

validate_resources() {
  if [ "$SKIP_RESOURCE_CHECK" = "1" ]; then
    log "Skipping resource checks by request."
    return 0
  fi

  log "Checking system resources..."

  local ram_mb=""
  if command -v free >/dev/null 2>&1; then
    ram_mb="$(free -m | awk '/^Mem:/ { print $2 }')"
  elif command -v sysctl >/dev/null 2>&1; then
    ram_mb="$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d", $1 / 1024 / 1024 }' || true)"
  fi

  if [ -n "$ram_mb" ]; then
    if [ "$ram_mb" -lt "$MIN_RAM_MB" ]; then
      fail_msg "RAM is ${ram_mb}MB. Minimum required: ${MIN_RAM_MB}MB"
    else
      ok "RAM is ${ram_mb}MB"
    fi
  else
    warn "Could not detect RAM size"
  fi

  local disk_mb=""
  disk_mb="$(df -Pk "$ROOT_DIR" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 }' || true)"

  if [ -n "$disk_mb" ]; then
    if [ "$disk_mb" -lt "$MIN_DISK_MB" ]; then
      fail_msg "Available disk is ${disk_mb}MB. Minimum required: ${MIN_DISK_MB}MB"
    else
      ok "Available disk is ${disk_mb}MB"
    fi
  else
    warn "Could not detect available disk space"
  fi
}

validate_license() {
  log "Checking license file..."

  local license="$ROOT_DIR/license/license.json"

  if [ ! -f "$license" ]; then
    fail_msg "License file not found: $license"
    return 0
  fi

  if [ ! -s "$license" ]; then
    fail_msg "License file is empty: $license"
    return 0
  fi

  ok "License file exists"

  if command -v jq >/dev/null 2>&1; then
    if jq empty "$license" >/dev/null 2>&1; then
      ok "License file is valid JSON according to jq"
    else
      fail_msg "License file is not valid JSON according to jq"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "$license" >/dev/null 2>&1; then
      ok "License file is valid JSON according to python3"
    else
      fail_msg "License file is not valid JSON according to python3"
    fi
  elif command -v python >/dev/null 2>&1; then
    if python -m json.tool "$license" >/dev/null 2>&1; then
      ok "License file is valid JSON according to python"
    else
      fail_msg "License file is not valid JSON according to python"
    fi
  else
    warn "jq/python not found. Checked only existence and non-empty license file."
  fi
}

validate_certificates() {
  log "Checking SSL certificate files..."

  local cert="$ROOT_DIR/nginx/certs/server.crt"
  local key="$ROOT_DIR/nginx/certs/server.key"
  local external_url host

  external_url="$(get_env_value EXTERNAL_URL)"
  host="$(url_host "$external_url")"

  if [ ! -f "$cert" ] && [ ! -f "$key" ]; then
    ok "No nginx certificate files found. init-secrets is expected to generate self-signed certs on first boot."
    return 0
  fi

  if [ -f "$cert" ] && [ ! -f "$key" ]; then
    fail_msg "server.crt exists but server.key is missing"
    return 0
  fi

  if [ ! -f "$cert" ] && [ -f "$key" ]; then
    fail_msg "server.key exists but server.crt is missing"
    return 0
  fi

  ok "Certificate and key both exist"

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found. Skipping certificate details check."
    return 0
  fi

  if openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
    ok "server.crt is parseable by openssl"
  else
    fail_msg "server.crt is not parseable by openssl"
    return 0
  fi

  if openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
    ok "server.crt is not expired"
  else
    fail_msg "server.crt is expired"
  fi

  if [ -n "$host" ]; then
    local cert_text
    cert_text="$(openssl x509 -in "$cert" -noout -subject -ext subjectAltName 2>/dev/null || true)"

    if printf '%s\n' "$cert_text" | grep -F "$host" >/dev/null 2>&1; then
      ok "server.crt appears to include EXTERNAL_URL hostname: $host"
    else
      if [ "$ALLOW_CERT_HOST_MISMATCH" = "1" ]; then
        warn "server.crt does not appear to include EXTERNAL_URL hostname, but allowed: $host"
      else
        fail_msg "server.crt does not appear to include EXTERNAL_URL hostname: $host"
      fi
    fi
  fi
}

get_compose_service_meta() {
  # Output:
  #   service<TAB>image<TAB>has_build
  #
  # Use normalized compose config YAML as the single metadata source so the
  # script works with both Docker Compose and podman-compose providers.
  compose config 2>/dev/null | awk '
    function flush() {
      if (svc != "") {
        print svc "\t" img "\t" build
        svc = ""
        img = ""
        build = 0
      }
    }

    BEGIN {
      in_services = 0
      svc = ""
      img = ""
      build = 0
    }

    /^services:[[:space:]]*$/ {
      in_services = 1
      next
    }

    in_services && /^[^[:space:]]/ {
      flush()
      in_services = 0
      exit
    }

    in_services && /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
      flush()
      line = $0
      sub(/^  /, "", line)
      sub(/:.*/, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      svc = line
      img = ""
      build = 0
      next
    }

    in_services && svc != "" && /^    image:[[:space:]]*/ {
      line = $0
      sub(/^    image:[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      img = line
      next
    }

    in_services && svc != "" && /^    build:/ {
      build = 1
      next
    }

    END {
      if (in_services) {
        flush()
      }
    }
  '
}

get_compose_images() {
  get_compose_service_meta | awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' | sort -u
}

validate_onprem_image_mode() {
  ONPREM_IMAGE_MODE_RESOLVED="${ONPREM_IMAGE_MODE:-offline}"

  case "$ONPREM_IMAGE_MODE_RESOLVED" in
    offline|online)
      ok "Image mode: $ONPREM_IMAGE_MODE_RESOLVED"
      ;;
    *)
      fail_msg "ONPREM_IMAGE_MODE must be offline or online: $ONPREM_IMAGE_MODE_RESOLVED"
      return 1
      ;;
  esac
}

image_registry() {
  local image="$1"
  local first="${image%%/*}"

  if [ "$first" = "$image" ]; then
    printf '%s' "docker.io"
    return 0
  fi

  case "$first" in
    *.*|*:*|localhost)
      printf '%s' "$first"
      ;;
    *)
      printf '%s' "docker.io"
      ;;
  esac
}

ecr_region_from_registry() {
  local registry="$1"

  printf '%s\n' "$registry" | awk -F '.' '
    {
      for (i = 1; i <= NF - 3; i++) {
        if ($(i + 1) == "dkr" && $(i + 2) == "ecr") {
          print $(i + 3)
          exit
        }
      }
    }
  '
}

print_pull_error() {
  local image="$1"
  local registry region

  registry="$(image_registry "$image")"
  region="$(ecr_region_from_registry "$registry")"

  cat >&2 <<EOF_PULL_ERROR

Failed to pull image:
  $image

Registry:
  $registry

EOF_PULL_ERROR

  case "$registry" in
    public.ecr.aws)
      cat >&2 <<EOF_PUBLIC_ECR
Most likely causes for public ECR:
  - The tag is not published in public ECR.
  - docker-compose.yml points to public.ecr.aws, but the image exists only in private ECR.
  - The tag exists, but does not support platform: $TARGET_PLATFORM_RESOLVED

Checks:
  docker buildx imagetools inspect $image

If the image is private, change the compose image or add an override that points
to the private ECR repository, for example:
  <account-id>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>

EOF_PUBLIC_ECR
      ;;
    *.dkr.ecr.*.amazonaws.com|*.dkr.ecr.*.amazonaws.com.cn)
      [ -n "$region" ] || region="<region>"
      cat >&2 <<EOF_PRIVATE_ECR
Possible causes for AWS Private ECR:
  - You are not logged in to this registry.
  - The repository or tag does not exist in this private ECR registry.
  - The tag does not support platform: $TARGET_PLATFORM_RESOLVED

Login example:
  aws ecr get-login-password --region $region \\
    | docker login --username AWS --password-stdin $registry

Check:
  docker buildx imagetools inspect $image

EOF_PRIVATE_ECR
      ;;
    *)
      cat >&2 <<EOF_GENERIC_REGISTRY
Possible causes:
  - The repository or tag does not exist in the registry.
  - You are not logged in to a private registry.
  - The tag does not support platform: $TARGET_PLATFORM_RESOLVED
  - The image is intended to be built locally, not pulled.

Checks:
  docker buildx imagetools inspect $image
  docker pull --platform $TARGET_PLATFORM_RESOLVED $image

EOF_GENERIC_REGISTRY
      ;;
  esac
}

canonical_image_for_localhost_alias() {
  local image="$1"

  case "$image" in
    localhost/nginx:1.26-alpine)
      printf '%s' "nginx:1.26-alpine"
      ;;
    localhost/postgres:17)
      printf '%s' "postgres:17"
      ;;
    localhost/eclipse-mosquitto:2.0.22)
      printf '%s' "eclipse-mosquitto:2.0.22"
      ;;
    *)
      printf '%s' "$image"
      ;;
  esac
}

prepare_online_build_service_image() {
  local service="$1"
  local image="$2"

  log "Building compose service image for online mode: $service -> $image"
  if compose build "$service"; then
    ok "Built image: $image"
  else
    fail_msg "Failed to build image for service: $service ($image)"
  fi
}

prepare_online_registry_image() {
  local image="$1"
  local source

  source="$(canonical_image_for_localhost_alias "$image")"

  if [ "$source" = "$image" ]; then
    case "$image" in
      localhost/*)
        fail_msg "Online image mode does not know how to create localhost image: $image"
        warn "Add an explicit alias mapping or use offline image archive loading."
        return 1
        ;;
    esac
  fi

  log "Pulling image for online mode: $source"
  if docker pull --platform "$TARGET_PLATFORM_RESOLVED" "$source"; then
    ok "Pulled image: $source"
  else
    print_pull_error "$source"
    fail_msg "Failed to pull image: $source"
    return 1
  fi

  if [ "$source" != "$image" ]; then
    if docker tag "$source" "$image"; then
      ok "Tagged image alias: $image <- $source"
    else
      fail_msg "Failed to tag image alias: $image <- $source"
      return 1
    fi
  fi
}

prepare_online_images() {
  validate_onprem_image_mode || return 0

  if [ "$ONPREM_IMAGE_MODE_RESOLVED" != "online" ]; then
    return 0
  fi

  TARGET_PLATFORM_RESOLVED="$(detect_target_platform)"

  log "Preparing compose images from registries for online mode..."
  ok "Target image platform: $TARGET_PLATFORM_RESOLVED"

  local service image build
  while IFS="$(printf '\t')" read -r service image build; do
    [ -n "$service" ] || continue
    [ -n "$image" ] || continue

    if [ "$build" = "1" ]; then
      prepare_online_build_service_image "$service" "$image"
    else
      if ! prepare_online_registry_image "$image"; then
        :
      fi
    fi
  done <<EOF_ONLINE_IMAGES
$(get_compose_service_meta)
EOF_ONLINE_IMAGES
}

validate_local_images() {
  if [ "$SKIP_IMAGE_CHECK" = "1" ]; then
    log "Skipping local image checks by request."
    return 0
  fi

  log "Checking that compose images exist locally..."

  local img count
  count=0

  while IFS= read -r img; do
    [ -n "$img" ] || continue
    count=$((count + 1))

    if docker image inspect "$img" >/dev/null 2>&1; then
      ok "Local image exists: $img"
    else
      fail_msg "Local image missing: $img"
    fi
  done <<EOF_IMAGES
$(get_compose_images)
EOF_IMAGES

  if [ "$count" -eq 0 ]; then
    warn "No images found in compose service metadata"
  fi
}

detect_target_platform() {
  if [ -n "${TARGET_PLATFORM:-}" ]; then
    printf '%s' "$TARGET_PLATFORM"
    return 0
  fi

  if [ -n "${PLATFORM:-}" ]; then
    printf '%s' "$PLATFORM"
    return 0
  fi

  local arch
  arch="$(uname -m 2>/dev/null || true)"

  case "$arch" in
    x86_64|amd64)
      printf '%s' "linux/amd64"
      ;;
    aarch64|arm64)
      printf '%s' "linux/arm64"
      ;;
    armv7l)
      printf '%s' "linux/arm/v7"
      ;;
    *)
      printf '%s' "linux/$arch"
      ;;
  esac
}

image_platforms() {
  local image="$1"
  local direct=""
  local manifests=""

  direct="$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)"

  if [ -n "$direct" ] && [ "$direct" != "/" ]; then
    printf '%s\n' "$direct"
    return 0
  fi

  # Docker Desktop / containerd image store may keep image index metadata.
  manifests="$(docker image inspect "$image" --format '{{range .Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}}{{"\n"}}{{end}}' 2>/dev/null || true)"

  if [ -n "$manifests" ]; then
    printf '%s\n' "$manifests" | awk 'NF > 0'
    return 0
  fi

  # Fallback when Go template cannot access manifests.
  # If jq is available, try parsing the raw JSON.
  if command -v jq >/dev/null 2>&1; then
    docker image inspect "$image" 2>/dev/null \
      | jq -r '.[0] as $i
          | if ($i.Os // "") != "" and ($i.Architecture // "") != "" then
              "\($i.Os)/\($i.Architecture)"
            elif ($i.Manifests // [] | length) > 0 then
              $i.Manifests[] | "\(.Platform.OS)/\(.Platform.Architecture)"
            else
              empty
            end' 2>/dev/null \
      | awk 'NF > 0'
  fi
}

can_save_image_for_platform() {
  local image="$1"
  local platform="$2"
  local tmp_dir tmp_file

  if ! docker save --help 2>/dev/null | grep -q -- '--platform'; then
    return 2
  fi

  tmp_dir="$(mktemp -d)"
  tmp_file="$tmp_dir/test.tar"

  if docker save --platform "$platform" "$image" -o "$tmp_file" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    return 0
  fi

  rm -rf "$tmp_dir"
  return 1
}

validate_image_architectures() {
  if [ "$SKIP_ARCH_CHECK" = "1" ]; then
    log "Skipping image architecture checks by request."
    return 0
  fi

  TARGET_PLATFORM_RESOLVED="$(detect_target_platform)"

  log "Checking Docker image architectures..."
  ok "Expected image platform: $TARGET_PLATFORM_RESOLVED"

  local img platforms matched p count save_status
  count=0

  while IFS= read -r img; do
    [ -n "$img" ] || continue
    count=$((count + 1))

    if ! docker image inspect "$img" >/dev/null 2>&1; then
      fail_msg "Cannot check architecture because image is missing: $img"
      continue
    fi

    platforms="$(image_platforms "$img" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

    if [ -z "$platforms" ]; then
      # Many multi-arch index images show empty .Os/.Architecture in Docker Desktop.
      # In that case, the most reliable local check is whether docker can save
      # the requested platform variant from the local image store.
      can_save_image_for_platform "$img" "$TARGET_PLATFORM_RESOLVED"
      save_status="$?"

      if [ "$save_status" -eq 0 ]; then
        ok "Image can be saved for target platform: $img [$TARGET_PLATFORM_RESOLVED]"
      elif [ "$save_status" -eq 2 ]; then
        warn "Could not determine image architecture for $img, and docker save --platform is unavailable."
      else
        fail_msg "Image cannot be saved for target platform: $img, expected $TARGET_PLATFORM_RESOLVED"
      fi

      continue
    fi

    matched=0
    for p in $platforms; do
      if [ "$p" = "$TARGET_PLATFORM_RESOLVED" ]; then
        matched=1
      fi
    done

    if [ "$matched" -eq 1 ]; then
      ok "Image platform matches: $img [$platforms]"
    else
      # Some images are inspected as an index even though the requested platform
      # exists locally. Confirm with docker save --platform before failing.
      can_save_image_for_platform "$img" "$TARGET_PLATFORM_RESOLVED"
      save_status="$?"

      if [ "$save_status" -eq 0 ]; then
        ok "Image can be saved for target platform: $img [$TARGET_PLATFORM_RESOLVED; inspect=$platforms]"
      else
        fail_msg "Image platform mismatch: $img [$platforms], expected $TARGET_PLATFORM_RESOLVED"
      fi
    fi
  done <<EOF_ARCH_IMAGES
$(get_compose_images)
EOF_ARCH_IMAGES

  if [ "$count" -eq 0 ]; then
    warn "No images found in compose service metadata"
  fi
}

validate_compose_config() {
  local label="${COMPOSE_CONFIG_LABEL:-Docker Compose}"

  log "Checking $label config..."

  if compose config --quiet; then
    ok "docker compose config --quiet succeeded"
  else
    fail_msg "docker compose config --quiet failed"
  fi
}

get_published_ports() {
  # Parses normalized compose config long-form ports and podman-compose
  # short-form ports.
  compose config 2>/dev/null | awk '
    function emit_port(value) {
      gsub(/"/, "", value)
      gsub(/\047/, "", value)
      gsub(/[[:space:]]/, "", value)
      sub(/\/.*$/, "", value)
      if (value ~ /^[0-9]+$/) print value
    }

    /^    ports:[[:space:]]*$/ {
      in_ports = 1
      next
    }

    in_ports && /^    [^[:space:]-][^:]*:/ {
      in_ports = 0
    }

    !in_ports {
      next
    }

    /published:[[:space:]]*/ {
      line = $0
      sub(/^.*published:[[:space:]]*/, "", line)
      emit_port(line)
      next
    }

    /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      gsub(/[[:space:]]/, "", line)
      sub(/\/.*$/, "", line)
      n = split(line, parts, ":")
      if (n == 2) {
        emit_port(parts[1])
      } else if (n >= 3) {
        emit_port(parts[n - 1])
      }
    }
  ' | sort -n | uniq
}

is_port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
    return $?
  fi

  return 2
}

container_id_matches() {
  local needle="$1"
  local candidate="$2"

  [ -n "$needle" ] || return 1
  [ -n "$candidate" ] || return 1

  case "$needle" in
    "$candidate"|"$candidate"*)
      return 0
      ;;
  esac

  case "$candidate" in
    "$needle"|"$needle"*)
      return 0
      ;;
  esac

  return 1
}

is_current_compose_container_id() {
  local container_id="$1"
  local current_id

  while IFS= read -r current_id; do
    [ -n "$current_id" ] || continue
    if container_id_matches "$container_id" "$current_id"; then
      return 0
    fi
  done <<EOF_COMPOSE_CONTAINER_IDS
$(compose ps -q 2>/dev/null || true)
EOF_COMPOSE_CONTAINER_IDS

  return 1
}

is_port_used_by_current_compose_project() {
  local port="$1"
  local owner_id
  local owner_count=0

  while IFS= read -r owner_id; do
    [ -n "$owner_id" ] || continue
    owner_count=$((owner_count + 1))

    if ! is_current_compose_container_id "$owner_id"; then
      return 1
    fi
  done <<EOF_PORT_OWNER_IDS
$(docker ps --filter "publish=$port" -q 2>/dev/null || true)
EOF_PORT_OWNER_IDS

  [ "$owner_count" -gt 0 ]
}

validate_ports() {
  if [ "$SKIP_PORT_CHECK" = "1" ]; then
    log "Skipping port checks by request."
    return 0
  fi

  log "Checking host port conflicts..."

  local ports=""
  ports="$(get_published_ports || true)"

  if [ -z "$ports" ]; then
    warn "No published ports detected from compose config"
    return 0
  fi

  local port status unprivileged_start
  unprivileged_start="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || printf '%s' "1024")"

  for port in $ports; do
    case "$port" in
      ""|*[!0-9]*)
        warn "Skipping non-numeric published port: $port"
        continue
        ;;
    esac

    if [ "${CHECK_ROOTLESS_PRIVILEGED_PORTS:-0}" = "1" ] && [ "$(id -u)" != "0" ] && [ "$port" -lt "$unprivileged_start" ]; then
      fail_msg "Rootless Podman cannot publish host privileged port $port (ip_unprivileged_port_start=$unprivileged_start)"
      warn "Use Docker/rootful Podman, or allow low ports on the host, for example: sudo sysctl net.ipv4.ip_unprivileged_port_start=$port"
    fi

    if is_port_in_use "$port"; then
      if is_port_used_by_current_compose_project "$port"; then
        ok "Host port is already used by this compose project: $port"
      else
        fail_msg "Host port is already in use: $port"
      fi
    else
      status=$?
      if [ "$status" -eq 2 ]; then
        warn "Could not check port $port because ss/lsof/netstat is unavailable"
      else
        ok "Host port is available: $port"
      fi
    fi
  done
}

prepare_bind_mount_directories() {
  local host_owned_dirs="$1"
  local service_data_dirs="$2"
  local d

  log "Preparing runtime bind mount directories..."

  resolve_runtime_owner || return 0

  for d in $host_owned_dirs; do
    prepare_host_owned_directory "$d"
  done

  for d in $service_data_dirs; do
    prepare_service_owned_directory "$d"
  done
}

hash_command() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "shasum -a 256"
  else
    printf '%s' ""
  fi
}

calculate_immutable_hash() {
  local tmp
  tmp="$(mktemp)"

  local key value
  for key in $IMMUTABLE_KEYS; do
    value="$(get_env_value "$key")"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  done

  local cmd
  cmd="$(hash_command)"

  if [ -z "$cmd" ]; then
    rm -f "$tmp"
    return 1
  fi

  # shellcheck disable=SC2086
  $cmd "$tmp" | awk '{ print $1 }'
  rm -f "$tmp"
}

is_install_initialized() {
  # If any persisted runtime data exists, assume this installation has been initialized.
  [ -f "$ROOT_DIR/secrets/secrets.env" ] && return 0
  [ -d "$ROOT_DIR/postgres/data" ] && [ "$(find "$ROOT_DIR/postgres/data" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" != "" ] && return 0
  [ -d "$ROOT_DIR/git/data" ] && [ "$(find "$ROOT_DIR/git/data" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" != "" ] && return 0
  return 1
}

validate_immutable_env_lock() {
  log "Checking immutable .env lock..."

  local state_dir="$ROOT_DIR/.install-state"
  local lock_file="$state_dir/immutable.env.sha256"

  local current_hash
  current_hash="$(calculate_immutable_hash || true)"

  if [ -z "$current_hash" ]; then
    warn "sha256sum/shasum not found. Skipping immutable .env lock."
    return 0
  fi

  if [ ! -f "$lock_file" ]; then
    ok "No immutable .env lock yet. It will be created only after all preflight checks pass."
    return 0
  fi

  local locked_hash
  locked_hash="$(cat "$lock_file" | head -n 1 | tr -d '[:space:]')"

  if [ "$current_hash" = "$locked_hash" ]; then
    ok "Immutable .env values match existing lock"
  else
    if [ "$ALLOW_IMMUTABLE_CHANGE" = "1" ]; then
      warn "Immutable .env values changed, but allowed by --allow-immutable-change"
    elif ! is_install_initialized; then
      warn "Immutable .env lock exists but installation data is not initialized yet. The lock will be refreshed after successful preflight."
    else
      fail_msg "Immutable .env values changed after installation initialization. Affected keys: $IMMUTABLE_KEYS"
    fi
  fi
}

write_immutable_env_lock_after_success() {
  local state_dir="$ROOT_DIR/.install-state"
  local lock_file="$state_dir/immutable.env.sha256"

  local current_hash
  current_hash="$(calculate_immutable_hash || true)"

  if [ -z "$current_hash" ]; then
    return 0
  fi

  mkdir -p "$state_dir"

  if [ ! -f "$lock_file" ]; then
    printf '%s\n' "$current_hash" > "$lock_file"
    ok "Immutable .env lock created: .install-state/immutable.env.sha256"
    return 0
  fi

  local locked_hash
  locked_hash="$(cat "$lock_file" | head -n 1 | tr -d '[:space:]')"

  if [ "$current_hash" != "$locked_hash" ] && ! is_install_initialized; then
    printf '%s\n' "$current_hash" > "$lock_file"
    ok "Immutable .env lock refreshed before first initialization"
  fi
}
