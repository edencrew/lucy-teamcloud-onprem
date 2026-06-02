#!/usr/bin/env bash
set -Eeo pipefail

# onprem-compose-docker.sh
#
# Operational wrapper for Lucy TeamCloud On-Premise Docker Compose commands.
# It preserves data by default and delegates readiness checks to preflight.

SCRIPT_VERSION="1.1.1"
IMAGE_OVERRIDE_REL=".install-state/compose-image-tags.override.yml"
COMPOSE_PORT_OVERRIDE_REL=".install-state/compose-ports.override.yml"

cleanup_tmp_files() {
  if [ -n "${TMP_IMAGE_OVERRIDE_DIR:-}" ] && [ -d "$TMP_IMAGE_OVERRIDE_DIR" ]; then
    rm -rf "$TMP_IMAGE_OVERRIDE_DIR"
  fi
}

trap cleanup_tmp_files EXIT

show_help() {
  cat <<'EOF'
onprem-compose.sh (Docker runtime)

DESCRIPTION
  Safe operational wrapper around Docker Compose for Lucy TeamCloud On-Premise.

  The script auto-detects the same compose files as preflight-onprem.sh in Docker mode:
    1. Base compose file
    2. docker-compose.offline.yml / docker-compose.offline.yaml if present
    3. docker-compose.docker.yml / docker-compose.docker.yaml if present
    4. docker-compose.override.yml / docker-compose.override.yaml if present
    5. .install-state/compose-image-tags.override.yml if present
    6. .install-state/compose-ports.override.yml if generated from EXTERNAL_URL

  Data is preserved by default. This script never runs docker compose down -v.

USAGE
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh <COMMAND> [PREFLIGHT_OPTIONS...] [ARGS...]

COMMANDS
  check
      Run scripts/preflight-onprem.sh in Docker mode.

  up [SERVICE...]
      Run preflight, then:
        docker compose up -d --pull never --no-build [SERVICE...]

  down
      Stop and remove compose containers while preserving bind mount data and
      compose volumes:
        docker compose down

  restart [SERVICE...]
      Run preflight, then:
        docker compose restart [SERVICE...]

  recreate [SERVICE...]
      Run preflight, then force-recreate containers without pulling/building:
        docker compose up -d --pull never --no-build --force-recreate [SERVICE...]

  restart-stack
      Run docker compose down, then preflight, then compose up.

  replace-images ARCHIVE [SERVICE...]
      Verify ARCHIVE's sibling *.images.txt and *.services.txt, generate a
      persistent image-tag override, load the archive through
      load-compose-images.sh, run preflight, then force-recreate all services
      or the specified SERVICE list.

  ps
      Show compose service status.

  logs [SERVICE...]
      Show recent compose logs. Additional docker compose logs options may be
      passed before SERVICE names.

  config
      Print the merged Docker Compose config.

  images
      Print the image tags from the merged Docker Compose config.

  image-override
      Print the generated image-tag override file path and contents.

  clear-image-override
      Remove the generated image-tag override file only. Service data and
      compose volumes are not touched.

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

PREFLIGHT OPTIONS
  The following options are forwarded only to preflight-onprem.sh for commands
  that run preflight: check, up, restart, recreate, restart-stack,
  replace-images.

    --skip-resource-check
    --skip-port-check
    --skip-image-check
    --skip-arch-check
    --allow-cert-host-mismatch
    --allow-immutable-change

ENVIRONMENT VARIABLES
  PROJECT_ROOT
      Explicit project root path.

  COMPOSE_FILES
      Explicit compose files to use, separated by colon (:).

  COMPOSE_OVERRIDE_FILES
      Extra override files to append after auto-detected compose files,
      separated by colon (:).

EXAMPLES
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh check
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh check --skip-resource-check
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh up
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh restart broker
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh recreate broker
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh recreate --skip-resource-check broker
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh restart-stack --skip-resource-check
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh image-override
  ONPREM_RUNTIME=docker ./scripts/onprem-compose.sh down

EOF
}

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
  if [ -n "${ONPREM_SCRIPT_DIR:-}" ]; then
    printf '%s' "$ONPREM_SCRIPT_DIR"
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

array_contains() {
  local needle="$1"
  shift || true

  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

is_preflight_option() {
  case "$1" in
    --skip-resource-check|--skip-port-check|--skip-image-check|--skip-arch-check|--allow-cert-host-mismatch|--allow-immutable-change)
      return 0
      ;;
  esac

  return 1
}

split_preflight_args() {
  PREFLIGHT_ARGS=()
  COMMAND_ARGS=()

  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift

    if [ "$arg" = "--" ]; then
      while [ "$#" -gt 0 ]; do
        COMMAND_ARGS+=("$1")
        shift
      done
      break
    fi

    if is_preflight_option "$arg"; then
      PREFLIGHT_ARGS+=("$arg")
    else
      COMMAND_ARGS+=("$arg")
    fi
  done
}

split_colon_list_to_lines() {
  local value="$1"
  printf '%s' "$value" | awk 'BEGIN { RS=":" } NF > 0 { print }'
}

join_by_colon() {
  local out=""
  local item

  for item in "$@"; do
    if [ -z "$out" ]; then
      out="$item"
    else
      out="$out:$item"
    fi
  done

  printf '%s' "$out"
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

get_env_value() {
  local key="$1"
  local file="$ROOT_DIR/.env"

  [ -f "$file" ] || return 0

  awk -v key="$key" '
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
      exit
    }
  ' "$file"
}

url_scheme() {
  local url="$1"
  printf '%s' "$url" | sed -n 's#^\([A-Za-z][A-Za-z0-9+.-]*\)://.*#\1#p'
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

is_tcp_port() {
  local port="$1"

  case "$port" in
    ""|*[!0-9]*)
      return 1
      ;;
  esac

  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
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

  is_tcp_port "$port" || die "EXTERNAL_URL port must be a number between 1 and 65535: $external_url"
  GW_PORT_MAPPING="$port:$target_port"
}

prepare_compose_port_override() {
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

  local f
  case "$base_name" in
    docker-compose.yaml|docker-compose.yml)
      for f in docker-compose.offline.yaml docker-compose.offline.yml; do
        if [ -f "$ROOT_DIR/$f" ]; then
          add_compose_file_unique "$ROOT_DIR/$f"
        fi
      done
      for f in docker-compose.docker.yaml docker-compose.docker.yml; do
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
      for f in compose.docker.yaml compose.docker.yml; do
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

append_installed_image_override() {
  IMAGE_OVERRIDE_FILE="$ROOT_DIR/$IMAGE_OVERRIDE_REL"
  if [ -f "$IMAGE_OVERRIDE_FILE" ]; then
    add_compose_file_unique "$IMAGE_OVERRIDE_FILE"
  fi
}

build_compose_args() {
  COMPOSE_ARGS=()
  local f
  for f in "${COMPOSE_FILE_LIST[@]}"; do
    COMPOSE_ARGS+=("-f" "$f")
  done
}

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

compose_with_extra_override() {
  local override_file="$1"
  shift
  docker compose "${COMPOSE_ARGS[@]}" -f "$override_file" "$@"
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

require_compose_cli() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available. Check: docker compose version"
}

require_docker_daemon() {
  require_compose_cli
  docker info >/dev/null 2>&1 || die "Docker daemon is not running or current user cannot access Docker."
}

run_preflight() {
  local preflight="$ROOT_DIR/scripts/lib/preflight-docker.sh"
  local compose_files
  [ -x "$preflight" ] || die "preflight script not found or not executable: $preflight"
  log "Running preflight..."
  compose_files="$(join_by_colon "${COMPOSE_FILE_LIST[@]}")"
  ONPREM_SCRIPT_DIR="$ROOT_DIR/scripts" PROJECT_ROOT="$ROOT_DIR" COMPOSE_FILES="$compose_files" "$preflight" "${PREFLIGHT_ARGS[@]}"
}

parse_compose_service_meta() {
  awk '
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

compose_service_meta() {
  compose config 2>/dev/null | parse_compose_service_meta
}

compose_service_meta_with_override() {
  local override_file="$1"
  compose_with_extra_override "$override_file" config 2>/dev/null | parse_compose_service_meta
}

sorted_compose_images() {
  compose_service_meta | awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' | sort -u
}

sorted_compose_images_with_override() {
  local override_file="$1"
  compose_service_meta_with_override "$override_file" | awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' | sort -u
}

sorted_compose_services() {
  compose_service_meta | awk -F '\t' 'NF >= 1 && $1 != "" { print $1 }' | sort -u
}

sorted_image_file() {
  local image_file="$1"
  awk 'NF > 0' "$image_file" | sort -u
}

show_image_mismatch() {
  local archive_sorted="$1"
  local compose_sorted="$2"

  if command -v diff >/dev/null 2>&1; then
    diff -u "$archive_sorted" "$compose_sorted" >&2 || true
  else
    warn "Archive image list:"
    sed 's/^/  /' "$archive_sorted" >&2
    warn "Compose image list:"
    sed 's/^/  /' "$compose_sorted" >&2
  fi
}

normalize_service_manifest() {
  local service_list_file="$1"
  local output_file="$2"

  awk '
    NF == 0 { next }
    NF < 2 {
      printf "Invalid services.txt line %d: expected SERVICE IMAGE [HAS_BUILD]\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    {
      service = $1
      image = $2
      if (service in image_by_service && image_by_service[service] != image) {
        printf "Conflicting image for service %s: %s vs %s\n", service, image_by_service[service], image > "/dev/stderr"
        bad = 1
        next
      }
      image_by_service[service] = image
    }
    END {
      for (service in image_by_service) {
        print service "\t" image_by_service[service]
      }
      exit bad
    }
  ' "$service_list_file" | sort -k1,1 > "$output_file"
}

validate_manifest_services_against_compose() {
  local normalized_services="$1"
  local compose_services_file="$2"

  sorted_compose_services > "$compose_services_file"
  [ -s "$compose_services_file" ] || die "No services found in current Docker Compose config."

  awk -F '\t' '
    NR == FNR {
      service_exists[$1] = 1
      next
    }
    !($1 in service_exists) {
      printf "Service from services.txt is not present in compose config: %s\n", $1 > "/dev/stderr"
      bad = 1
    }
    END { exit bad }
  ' "$compose_services_file" "$normalized_services"
}

validate_manifest_images_against_archive() {
  local normalized_services="$1"
  local archive_sorted="$2"

  awk -F '\t' '
    NR == FNR {
      image_exists[$0] = 1
      next
    }
    !($2 in image_exists) {
      printf "Image from services.txt is not present in images.txt: %s (%s)\n", $2, $1 > "/dev/stderr"
      bad = 1
    }
    END { exit bad }
  ' "$archive_sorted" "$normalized_services"
}

write_image_override_from_manifest() {
  local normalized_services="$1"
  local output_file="$2"

  {
    printf '# Generated by scripts/onprem-compose.sh replace-images (Docker runtime).\n'
    printf '# Regenerate with replace-images or remove with clear-image-override.\n'
    printf 'services:\n'
    awk -F '\t' '
      function yquote(value) {
        gsub(/\047/, "\047\047", value)
        return "\047" value "\047"
      }
      {
        print "  " yquote($1) ":"
        print "    image: " yquote($2)
      }
    ' "$normalized_services"
  } > "$output_file"
}

verify_archive_image_tags_match_generated_override() {
  local archive="$1"
  local base_name image_list_file service_list_file tmp_dir
  local normalized_services archive_sorted compose_sorted compose_services_file override_file

  archive="$(resolve_path_from_root "$archive")"
  [ -f "$archive" ] || die "Archive file not found: $archive"

  base_name="$(archive_basename_without_extensions "$archive")"
  image_list_file="$(dirname "$archive")/$base_name.images.txt"
  service_list_file="$(dirname "$archive")/$base_name.services.txt"
  [ -f "$image_list_file" ] || die "Required image list file not found: $image_list_file"
  [ -f "$service_list_file" ] || die "Required service metadata file not found: $service_list_file"

  tmp_dir="$(mktemp -d)"
  TMP_IMAGE_OVERRIDE_DIR="$tmp_dir"
  normalized_services="$tmp_dir/services.normalized"
  archive_sorted="$tmp_dir/archive.images"
  compose_sorted="$tmp_dir/compose.images"
  compose_services_file="$tmp_dir/compose.services"
  override_file="$tmp_dir/compose-image-tags.override.yml"

  sorted_image_file "$image_list_file" > "$archive_sorted"
  normalize_service_manifest "$service_list_file" "$normalized_services"

  if [ ! -s "$normalized_services" ]; then
    die "No service image mappings found in service metadata file: $service_list_file"
  fi

  validate_manifest_services_against_compose "$normalized_services" "$compose_services_file"
  validate_manifest_images_against_archive "$normalized_services" "$archive_sorted"
  write_image_override_from_manifest "$normalized_services" "$override_file"
  sorted_compose_images_with_override "$override_file" > "$compose_sorted"

  if [ ! -s "$compose_sorted" ]; then
    die "No images found in Docker Compose config with generated image override."
  fi

  if cmp -s "$archive_sorted" "$compose_sorted"; then
    VERIFIED_ARCHIVE="$archive"
    VERIFIED_IMAGE_OVERRIDE_FILE="$override_file"
    VERIFIED_IMAGE_LIST_FILE="$image_list_file"
    VERIFIED_SERVICE_LIST_FILE="$service_list_file"
    log "Archive image tags match compose config with generated image override."
    return 0
  fi

  warn "Archive image tags do not match compose config with generated image override."
  warn "Archive image list: $image_list_file"
  warn "Service metadata file: $service_list_file"
  show_image_mismatch "$archive_sorted" "$compose_sorted"
  die "Refusing image replacement because image tags differ."
}

persist_verified_image_override() {
  local source_file="$1"
  local state_dir tmp_dir

  [ -n "$source_file" ] || die "Internal error: generated image override file is empty."
  [ -f "$source_file" ] || die "Internal error: generated image override file not found: $source_file"

  state_dir="$(dirname "$IMAGE_OVERRIDE_FILE")"
  tmp_dir="${TMP_IMAGE_OVERRIDE_DIR:-}"
  mkdir -p "$state_dir" || die "Could not create install state directory: $state_dir"
  mv "$source_file" "$IMAGE_OVERRIDE_FILE" || die "Could not save image override file: $IMAGE_OVERRIDE_FILE"

  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  TMP_IMAGE_OVERRIDE_DIR=""
  add_compose_file_unique "$IMAGE_OVERRIDE_FILE"
  build_compose_args
  log "Saved image tag override: $IMAGE_OVERRIDE_REL"
}

load_archive() {
  local archive="$1"
  local loader="$ROOT_DIR/scripts/load-compose-images.sh"
  [ -x "$loader" ] || die "image loader script not found or not executable: $loader"
  log "Loading image archive..."
  "$loader" "$archive"
}

cmd_check() {
  run_preflight
}

cmd_up() {
  run_preflight
  log "Starting services..."
  compose up -d --pull never --no-build "$@"
}

cmd_down() {
  log "Stopping services while preserving data..."
  compose down
}

cmd_restart() {
  run_preflight
  log "Restarting services..."
  compose restart "$@"
}

cmd_recreate() {
  run_preflight
  log "Recreating services..."
  compose up -d --pull never --no-build --force-recreate "$@"
}

cmd_restart_stack() {
  log "Stopping stack while preserving data..."
  compose down
  run_preflight
  log "Starting stack..."
  compose up -d --pull never --no-build
}

cmd_replace_images() {
  local archive

  [ "$#" -gt 0 ] || die "replace-images requires ARCHIVE path."
  archive="$1"
  shift

  VERIFIED_ARCHIVE=""
  VERIFIED_IMAGE_OVERRIDE_FILE=""
  VERIFIED_IMAGE_LIST_FILE=""
  VERIFIED_SERVICE_LIST_FILE=""
  verify_archive_image_tags_match_generated_override "$archive"
  require_docker_daemon
  load_archive "$VERIFIED_ARCHIVE"
  persist_verified_image_override "$VERIFIED_IMAGE_OVERRIDE_FILE"
  run_preflight
  log "Recreating services with loaded images..."
  compose up -d --pull never --no-build --force-recreate "$@"
}

cmd_ps() {
  compose ps "$@"
}

cmd_logs() {
  compose logs --tail=200 "$@"
}

cmd_config() {
  compose config "$@"
}

cmd_images() {
  sorted_compose_images
}

init_root_context() {
  local sdir
  sdir="$(script_dir)"

  ROOT_DIR="$(resolve_project_root "$sdir")"
  cd "$ROOT_DIR"

  IMAGE_OVERRIDE_FILE="$ROOT_DIR/$IMAGE_OVERRIDE_REL"
}

init_context() {
  require_compose_cli
  init_root_context

  detect_compose_files
  append_installed_image_override
  prepare_compose_port_override
  append_compose_port_override
  build_compose_args
}

cmd_image_override() {
  if [ -f "$IMAGE_OVERRIDE_FILE" ]; then
    printf 'Image override file: %s\n\n' "$IMAGE_OVERRIDE_FILE"
    sed -n '1,200p' "$IMAGE_OVERRIDE_FILE"
  else
    printf 'No image override file found: %s\n' "$IMAGE_OVERRIDE_FILE"
  fi
}

cmd_clear_image_override() {
  if [ -f "$IMAGE_OVERRIDE_FILE" ]; then
    rm -f "$IMAGE_OVERRIDE_FILE" || die "Could not remove image override file: $IMAGE_OVERRIDE_FILE"
    log "Removed image override file: $IMAGE_OVERRIDE_REL"
  else
    log "No image override file to remove: $IMAGE_OVERRIDE_REL"
  fi
}

main() {
  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      echo "onprem-compose-docker.sh $SCRIPT_VERSION"
      exit 0
      ;;
    "")
      show_help
      exit 1
      ;;
  esac

  local command="$1"
  shift

  case "$command" in
    image-override|clear-image-override)
      init_root_context
      ;;
    *)
      init_context
      ;;
  esac

  case "$command" in
    check|up|restart|recreate|restart-stack|replace-images)
      split_preflight_args "$@"
      set -- "${COMMAND_ARGS[@]}"
      ;;
    *)
      PREFLIGHT_ARGS=()
      ;;
  esac

  case "$command" in
    check)
      cmd_check "$@"
      ;;
    up)
      require_docker_daemon
      cmd_up "$@"
      ;;
    down)
      if [ "$#" -gt 0 ]; then
        die "down does not accept service arguments. Use restart/recreate for service-scoped operations."
      fi
      require_docker_daemon
      cmd_down
      ;;
    restart)
      require_docker_daemon
      cmd_restart "$@"
      ;;
    recreate)
      require_docker_daemon
      cmd_recreate "$@"
      ;;
    restart-stack)
      if [ "$#" -gt 0 ]; then
        die "restart-stack does not accept service arguments."
      fi
      require_docker_daemon
      cmd_restart_stack
      ;;
    replace-images)
      cmd_replace_images "$@"
      ;;
    ps)
      require_docker_daemon
      cmd_ps "$@"
      ;;
    logs)
      require_docker_daemon
      cmd_logs "$@"
      ;;
    config)
      cmd_config "$@"
      ;;
    images)
      cmd_images "$@"
      ;;
    image-override)
      if [ "$#" -gt 0 ]; then
        die "image-override does not accept arguments."
      fi
      cmd_image_override
      ;;
    clear-image-override)
      if [ "$#" -gt 0 ]; then
        die "clear-image-override does not accept arguments."
      fi
      cmd_clear_image_override
      ;;
    *)
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
