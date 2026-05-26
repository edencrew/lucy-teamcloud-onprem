#!/usr/bin/env bash
set -Eeo pipefail

# onprem-compose-podman.sh
#
# Operational wrapper for Lucy TeamCloud On-Premise Docker Compose commands.
# It preserves data by default and delegates readiness checks to preflight.

SCRIPT_VERSION="1.0.0"
IMAGE_OVERRIDE_REL=".install-state/compose-image-tags.override.yml"

cleanup_tmp_files() {
  if [ -n "${TMP_IMAGE_OVERRIDE_DIR:-}" ] && [ -d "$TMP_IMAGE_OVERRIDE_DIR" ]; then
    rm -rf "$TMP_IMAGE_OVERRIDE_DIR"
  fi
}

trap cleanup_tmp_files EXIT

show_help() {
  cat <<'EOF'
onprem-compose-podman.sh

DESCRIPTION
  Safe operational wrapper around Podman Compose for Lucy TeamCloud On-Premise.

  The script auto-detects Podman compose files:
    1. Base compose file
    2. docker-compose.offline.yml / docker-compose.offline.yaml if present
    3. docker-compose.podman.yml / docker-compose.podman.yaml if present
    4. docker-compose.override.yml / docker-compose.override.yaml if present
    5. .install-state/compose-image-tags.override.yml if present

  Data is preserved by default. This script never runs docker compose down -v.

USAGE
  ./scripts/onprem-compose-podman.sh <COMMAND> [PREFLIGHT_OPTIONS...] [ARGS...]

COMMANDS
  check
      Run scripts/preflight-podman.sh.

  up [SERVICE...]
      Run preflight, run init-secrets once, then:
        docker compose up -d --no-build [SERVICE...]

  down
      Stop and remove compose containers while preserving bind mount data and
      compose volumes:
        docker compose down

  restart [SERVICE...]
      Run preflight, then:
        docker compose restart [SERVICE...]

  recreate [SERVICE...]
      Run preflight, run init-secrets once, then force-recreate containers without pulling/building:
        docker compose up -d --no-build --force-recreate [SERVICE...]

  restart-stack
      Run docker compose down, then preflight, init-secrets, and compose up.

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
  The following options are forwarded only to preflight-podman.sh for commands
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
  ./scripts/onprem-compose-podman.sh check
  ./scripts/onprem-compose-podman.sh check --skip-resource-check
  ./scripts/onprem-compose-podman.sh up
  ./scripts/onprem-compose-podman.sh restart broker
  ./scripts/onprem-compose-podman.sh recreate broker
  ./scripts/onprem-compose-podman.sh recreate --skip-resource-check broker
  ./scripts/onprem-compose-podman.sh restart-stack --skip-resource-check
  ./scripts/onprem-compose-podman.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
  ./scripts/onprem-compose-podman.sh image-override
  ./scripts/onprem-compose-podman.sh down

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
      for f in docker-compose.podman.yaml docker-compose.podman.yml; do
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
      for f in compose.podman.yaml compose.podman.yml; do
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

compose_up_prerequisites() {
  log "Starting init-secrets one-shot service..."
  compose up --no-build init-secrets

  log "Starting database service..."
  compose up -d --no-build db
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
  require_cmd podman
  docker compose version >/dev/null 2>&1 || die "podman-compose provider is not available. Check: docker compose version"
}

require_docker_daemon() {
  require_compose_cli
  docker info >/dev/null 2>&1 || die "Podman is not running or current user cannot access it through docker CLI."
}

run_preflight() {
  local preflight="$ROOT_DIR/scripts/preflight-podman.sh"
  local compose_files
  [ -x "$preflight" ] || die "preflight script not found or not executable: $preflight"
  log "Running preflight..."
  compose_files="$(join_by_colon "${COMPOSE_FILE_LIST[@]}")"
  PROJECT_ROOT="$ROOT_DIR" COMPOSE_FILES="$compose_files" "$preflight" "${PREFLIGHT_ARGS[@]}"
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
    printf '# Generated by scripts/onprem-compose-podman.sh replace-images.\n'
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
  compose_up_prerequisites
  log "Starting services..."
  compose up -d --no-build "$@"
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
  compose_up_prerequisites
  log "Recreating services..."
  compose up -d --no-build --force-recreate "$@"
}

cmd_restart_stack() {
  log "Stopping stack while preserving data..."
  compose down
  run_preflight
  compose_up_prerequisites
  log "Starting stack..."
  compose up -d --no-build
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
  compose_up_prerequisites
  log "Recreating services with loaded images..."
  compose up -d --no-build --force-recreate "$@"
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
      echo "onprem-compose-podman.sh $SCRIPT_VERSION"
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
