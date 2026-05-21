#!/usr/bin/env bash
set -Eeo pipefail

# export-compose-images.sh
#
# Recommended location:
#   <project-root>/scripts/export-compose-images.sh
#
# Purpose:
#   Export all Docker images required by a Docker Compose project into a single
#   tar.gz archive for offline / air-gapped server installation.
#
# Compatibility:
#   - Bash 3+ compatible. Works with macOS default /bin/bash 3.2.
#   - Requires Docker CLI with Docker Compose plugin: docker compose version
#
# Default target platform:
#   linux/amd64
#
# Why not `set -u`?
#   macOS ships Bash 3.2. With `set -u`, empty arrays like "${ARRAY[@]}"
#   can fail with "unbound variable". This script intentionally avoids
#   nounset for portability and validates required values explicitly.

SCRIPT_VERSION="1.4.0"

show_help() {
  cat <<'EOF'
export-compose-images.sh

DESCRIPTION
  Export all Docker images required by a Docker Compose project into a single
  tar.gz archive for offline / air-gapped server installation.

  Recommended location:
    <project-root>/scripts/export-compose-images.sh

  The script automatically treats the parent directory of ./scripts as the
  project root. Compose files are detected from the project root, not from
  the scripts directory.

  Because this script is used to create an offline package,
  docker-compose.offline.yml is automatically included when it exists.

WHAT IT DOES
  1. Checks Docker installation and Docker daemon status.
  2. Checks Docker Compose plugin availability.
  3. Detects compose files from the project root.
  4. Merges base compose, offline compose, and override compose files.
  5. Reads image versions from the final merged compose config.
  6. Detects services that use build:.
  7. Pulls only registry images.
     - If a service has both image: and build:, its image is built locally,
       not pulled from a registry.
  8. Builds services that use build:.
  9. Saves pulled and built images into <project-root>/images/*.tar.gz.
  10. Creates checksum and image-list files.

USAGE
  ./scripts/export-compose-images.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

ENVIRONMENT VARIABLES
  PROJECT_ROOT
      Explicit project root path.
      Default:
        If script is inside ./scripts, parent directory of ./scripts.
        Otherwise, the directory containing this script.

      Example:
        PROJECT_ROOT=/path/to/project ./scripts/export-compose-images.sh

  TARGET_PLATFORM
      Target image platform.
      Default: linux/amd64

      Examples:
        TARGET_PLATFORM=linux/amd64
        TARGET_PLATFORM=linux/arm64

  PLATFORM
      Backward-compatible alias for TARGET_PLATFORM when TARGET_PLATFORM is unset.

  OUTPUT_DIR
      Directory where the tar.gz file will be written.
      Default: <project-root>/images

      Example:
        OUTPUT_DIR=./dist

  OUTPUT_NAME
      Output tar.gz file name.
      Default: <compose-project-name>-images-<platform>.tar.gz

      Example:
        OUTPUT_NAME=onprem-images.tar.gz

  COMPOSE_FILES
      Explicit compose files to use, separated by colon (:).
      Paths are resolved relative to PROJECT_ROOT unless absolute.
      Later files override earlier files.

      Example:
        COMPOSE_FILES="docker-compose.yaml:docker-compose.prod.yaml"

  COMPOSE_OVERRIDE_FILES
      Extra override files to append after auto-detected compose files,
      separated by colon (:).
      Paths are resolved relative to PROJECT_ROOT unless absolute.

      Example:
        COMPOSE_OVERRIDE_FILES="docker-compose.local.yaml:docker-compose.customer.yaml"

AUTO-DETECTED COMPOSE FILES
  Base compose file, first match in PROJECT_ROOT:
    docker-compose.yaml
    docker-compose.yml
    compose.yaml
    compose.yml

  Offline files, appended after base if they exist in PROJECT_ROOT:
    docker-compose.offline.yaml
    docker-compose.offline.yml
    compose.offline.yaml
    compose.offline.yml

  Override files, appended after offline files if they exist in PROJECT_ROOT:
    docker-compose.override.yaml
    docker-compose.override.yml
    compose.override.yaml
    compose.override.yml
    override.yaml
    override.yml

  Override priority follows Docker Compose behavior:
    later -f files override earlier -f files.

EXAMPLES
  Basic usage from project root:
    chmod +x ./scripts/export-compose-images.sh
    ./scripts/export-compose-images.sh

  Export for x86_64 Linux server:
    PLATFORM=linux/amd64 ./scripts/export-compose-images.sh

  Export for ARM64 Linux server:
    PLATFORM=linux/arm64 ./scripts/export-compose-images.sh

  Use explicit compose files:
    COMPOSE_FILES="docker-compose.yml:docker-compose.prod.yml" ./scripts/export-compose-images.sh

  Use extra override files:
    COMPOSE_OVERRIDE_FILES="docker-compose.customer.yml" ./scripts/export-compose-images.sh

  Change output file:
    OUTPUT_NAME=lucy-onprem-images.tar.gz ./scripts/export-compose-images.sh

  Run from anywhere:
    PROJECT_ROOT=/path/to/project /path/to/project/scripts/export-compose-images.sh

OUTPUT FILES
  By default, files are created under <project-root>/images:

    <project-name>-images-linux-amd64.tar.gz
    <project-name>-images-linux-amd64.tar.gz.sha256
    <project-name>-images-linux-amd64.images.txt
    <project-name>-images-linux-amd64.explicit-images.txt
    <project-name>-images-linux-amd64.services.txt

OFFLINE SERVER USAGE
  Copy the tar.gz file to the offline server, then run:

    docker load -i <project-name>-images-linux-amd64.tar.gz
    docker compose up -d --pull never

NOTES
  - This script reads images from:
      docker compose config --images

  - That means image versions are taken from the final merged compose config.
    If an override file changes an image tag, the override tag is used.

  - Services using build: are built locally by:
      docker compose build <service...>

  - If a service has both image: and build:, the image is NOT pulled.
    It is built locally and saved with that image tag.

  - If you run this on Apple Silicon Mac while exporting linux/amd64 images,
    Docker Desktop must support cross-platform pull/build/save.

  - If docker save fails with a missing content digest error, try:
      docker image rm -f <image>
      docker pull --platform linux/amd64 <image>

    Or run this script on an amd64 Linux machine.

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
        # Backward compatible fallback:
        # if someone still places the script next to docker-compose.yml,
        # use the script directory as project root.
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

join_by_space_quoted() {
  local out=""
  local item
  for item in "$@"; do
    out="$out '$item'"
  done
  printf '%s' "$out"
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

supports_docker_save_platform() {
  docker save --help 2>/dev/null | grep -q -- '--platform'
}

supports_docker_build_platform() {
  docker build --help 2>/dev/null | grep -q -- '--platform'
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
  base="$(detect_base_compose_file)" || die "No compose file found in project root: $ROOT_DIR. Expected one of: docker-compose.yaml, docker-compose.yml, compose.yaml, compose.yml"
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
  local f
  for f in "${COMPOSE_FILE_LIST[@]}"; do
    COMPOSE_ARGS+=("-f" "$f")
  done
}

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

get_project_name() {
  local name=""

  name="$(compose config --project-name 2>/dev/null | head -n 1 || true)"

  if [ -z "$name" ]; then
    name="$(compose config 2>/dev/null | sed -n 's/^name:[[:space:]]*//p' | head -n 1 | tr -d '"' | tr -d "'" || true)"
  fi

  if [ -z "$name" ]; then
    name="$(basename "$ROOT_DIR")"
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"
  fi

  printf '%s' "$name"
}

get_explicit_images() {
  compose config --images 2>/dev/null | awk 'NF > 0' | sort -u
}

get_services() {
  compose config --services 2>/dev/null | awk 'NF > 0'
}

get_service_meta() {
  # Output:
  #   service<TAB>image<TAB>has_build
  #
  # This parses normalized `docker compose config` YAML.
  # It is intentionally simple and targets Compose's normalized indentation.
  compose config 2>/dev/null | awk '
    function flush() {
      if (svc != "") {
        print svc "\t" img "\t" build
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
      exit
    }

    in_services && /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
      flush()
      line = $0
      sub(/^  /, "", line)
      sub(/:.*/, "", line)
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

image_platform() {
  local image="$1"
  docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true
}

image_exists() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1
}

check_image_save() {
  local image="$1"
  local tmp_file="$2"

  if supports_docker_save_platform; then
    docker save --platform "$TARGET_PLATFORM_RESOLVED" "$image" -o "$tmp_file"
  else
    warn "This Docker version does not support 'docker save --platform'. Falling back to plain docker save."
    docker save "$image" -o "$tmp_file"
  fi
}

sha256_file() {
  local file="$1"

  if command -v shasum >/dev/null 2>&1; then
    (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")" > "$(basename "$file").sha256")
  elif command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
  else
    warn "Neither shasum nor sha256sum found. Skipping checksum."
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        echo "export-compose-images.sh $SCRIPT_VERSION"
        exit 0
        ;;
      *)
        die "Unknown argument: $1

Run './scripts/export-compose-images.sh --help' for usage."
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd awk
  require_cmd sed
  require_cmd sort
  require_cmd gzip

  docker info >/dev/null 2>&1 || die "Docker daemon is not running or current user cannot access Docker."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available. Check: docker compose version"

  TARGET_PLATFORM_RESOLVED="${TARGET_PLATFORM:-${PLATFORM:-linux/amd64}}"
  export TARGET_PLATFORM="$TARGET_PLATFORM_RESOLVED"
  export PLATFORM="$TARGET_PLATFORM_RESOLVED"

  local sdir
  sdir="$(script_dir)"

  ROOT_DIR="$(resolve_project_root "$sdir")"
  cd "$ROOT_DIR"

  detect_compose_files
  build_compose_args

  log "Script directory: $sdir"
  log "Project root: $ROOT_DIR"
  log "Compose files, in merge order:$(join_by_space_quoted "${COMPOSE_FILE_LIST[@]}")"
  log "Target platform: $TARGET_PLATFORM_RESOLVED"

  log "Validating merged compose config..."
  compose config --quiet

  local project_name
  project_name="$(get_project_name)"
  log "Compose project name: $project_name"

  OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/images}"
  OUTPUT_DIR="$(resolve_path_from_root "$OUTPUT_DIR")"
  OUTPUT_NAME="${OUTPUT_NAME:-${project_name}-images-${TARGET_PLATFORM_RESOLVED//\//-}.tar.gz}"
  OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"

  mkdir -p "$OUTPUT_DIR"

  log "Reading service metadata from merged compose config..."
  SERVICE_META_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.services.txt"
  get_service_meta > "$SERVICE_META_FILE"

  BUILD_SERVICES=()
  BUILD_IMAGES=()

  local svc meta_img has_build
  while IFS="$(printf '\t')" read -r svc meta_img has_build; do
    [ -n "$svc" ] || continue
    if [ "$has_build" = "1" ]; then
      BUILD_SERVICES+=("$svc")
      if [ -n "$meta_img" ]; then
        BUILD_IMAGES+=("$meta_img")
      fi
    fi
  done < "$SERVICE_META_FILE"

  if [ "${#BUILD_SERVICES[@]}" -gt 0 ]; then
    log "Build services detected:"
    local i
    for i in "${BUILD_SERVICES[@]}"; do
      printf '  %s\n' "$i"
    done

    if [ "${#BUILD_IMAGES[@]}" -gt 0 ]; then
      log "Images produced by build services. These will not be pulled:"
      for i in "${BUILD_IMAGES[@]}"; do
        printf '  %s\n' "$i"
      done
    fi
  else
    log "No build services detected."
  fi

  log "Reading image list from merged compose config..."
  EXPLICIT_IMAGES=()
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    EXPLICIT_IMAGES+=("$img")
  done <<EOF_EXPLICIT_IMAGES
$(get_explicit_images)
EOF_EXPLICIT_IMAGES

  if [ "${#EXPLICIT_IMAGES[@]}" -eq 0 ]; then
    warn "No explicit image: entries found in compose config."
  else
    printf '%s\n' "${EXPLICIT_IMAGES[@]}" > "$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.explicit-images.txt"
    log "Explicit image list:"
    printf '  %s\n' "${EXPLICIT_IMAGES[@]}"
  fi

  log "Pulling registry images..."
  local img
  for img in "${EXPLICIT_IMAGES[@]}"; do
    if array_contains "$img" "${BUILD_IMAGES[@]}"; then
      log "Skipping pull for build image: $img"
      continue
    fi

    log "Pulling: $img"
    if ! docker pull --platform "$TARGET_PLATFORM_RESOLVED" "$img"; then
      cat >&2 <<EOF_PULL_ERROR

Failed to pull image:
  $img

Possible causes:
  - You are not logged in to a private registry.
  - The tag does not support platform: $TARGET_PLATFORM_RESOLVED
  - The image is intended to be built locally, not pulled.

For AWS Private ECR, login example:
  aws ecr get-login-password --region ap-northeast-2 \\
    | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-northeast-2.amazonaws.com

EOF_PULL_ERROR
      exit 1
    fi
  done

  if [ "${#BUILD_SERVICES[@]}" -gt 0 ]; then
    log "Building compose services that have build: definitions..."
    if supports_docker_build_platform; then
      DOCKER_DEFAULT_PLATFORM="$TARGET_PLATFORM_RESOLVED" compose build "${BUILD_SERVICES[@]}"
    else
      warn "docker build --platform is not supported by this Docker version. Build may use native platform."
      compose build "${BUILD_SERVICES[@]}"
    fi
  else
    log "Skipping compose build. No build services found."
  fi

  log "Collecting images to save..."
  SAVE_IMAGES=()

  for img in "${EXPLICIT_IMAGES[@]}"; do
    if ! array_contains "$img" "${SAVE_IMAGES[@]}"; then
      SAVE_IMAGES+=("$img")
    fi
  done

  SERVICES=()
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    SERVICES+=("$svc")
  done <<EOF_SERVICES
$(get_services)
EOF_SERVICES

  local candidate
  for svc in "${SERVICES[@]}"; do
    for candidate in \
      "${project_name}-${svc}" \
      "${project_name}-${svc}:latest" \
      "${project_name}_${svc}" \
      "${project_name}_${svc}:latest"
    do
      if image_exists "$candidate"; then
        if ! array_contains "$candidate" "${SAVE_IMAGES[@]}"; then
          SAVE_IMAGES+=("$candidate")
        fi
      fi
    done
  done

  if [ "${#SAVE_IMAGES[@]}" -eq 0 ]; then
    die "No images found to save."
  fi

  printf '%s\n' "${SAVE_IMAGES[@]}" > "$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.images.txt"

  log "Final image list to save:"
  local arch
  for img in "${SAVE_IMAGES[@]}"; do
    arch="$(image_platform "$img")"
    if [ -n "$arch" ] && [ "$arch" != "/" ]; then
      printf '  %-80s %s\n' "$img" "$arch"
      if [ "$arch" != "$TARGET_PLATFORM_RESOLVED" ]; then
        warn "Platform mismatch: $img is $arch, expected $TARGET_PLATFORM_RESOLVED"
      fi
    else
      printf '  %-80s %s\n' "$img" "platform-index"
    fi
  done

  log "Testing docker save image by image..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  for img in "${SAVE_IMAGES[@]}"; do
    log "Testing save: $img"
    check_image_save "$img" "$tmp_dir/test.tar"
    rm -f "$tmp_dir/test.tar"
  done

  rm -f "$OUTPUT_PATH" "$OUTPUT_PATH.sha256"

  log "Saving all images to: $OUTPUT_PATH"
  if supports_docker_save_platform; then
    docker save --platform "$TARGET_PLATFORM_RESOLVED" "${SAVE_IMAGES[@]}" | gzip > "$OUTPUT_PATH"
  else
    warn "This Docker version does not support 'docker save --platform'. Saving without platform filter."
    docker save "${SAVE_IMAGES[@]}" | gzip > "$OUTPUT_PATH"
  fi

  sha256_file "$OUTPUT_PATH"

  log "Export complete."
  ls -lh "$OUTPUT_PATH" "$OUTPUT_PATH.sha256" "$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.images.txt" "$SERVICE_META_FILE" 2>/dev/null || true

  cat <<EOF_DONE

Offline server usage:
  docker load -i $OUTPUT_NAME
  docker compose up -d --pull never

Files created:
  $OUTPUT_PATH
  $OUTPUT_PATH.sha256
  $OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.images.txt
  $SERVICE_META_FILE

EOF_DONE
}

main "$@"
