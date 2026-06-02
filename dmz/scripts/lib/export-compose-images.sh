#!/usr/bin/env bash
set -Eeo pipefail

# DMZ standalone image package exporter.
# Pulls images from the effective DMZ compose config and writes an offline
# archive under dmz/images by default.

SCRIPT_VERSION="2.0.0"

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DMZ_SCRIPT_DIR="${DMZ_SCRIPT_DIR:-$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)}"
# shellcheck source=dmz-common.sh
. "$SCRIPT_DIR/dmz-common.sh"

TMP_DIR=""
TMP_TAR=""

cleanup() {
  if [ -n "$TMP_TAR" ] && [ -f "$TMP_TAR" ]; then
    rm -f "$TMP_TAR"
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

show_help() {
  cat <<'EOF'
export-compose-images.sh

DESCRIPTION
  Export Docker images for the standalone DMZ MQTT WebSocket proxy into an
  offline archive.

  This script is fully self-contained under dmz/. It does not call the parent
  on-premise scripts.

USAGE
  ./scripts/export-compose-images.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

ENVIRONMENT VARIABLES
  DMZ_ROOT
      Explicit DMZ root path. Defaults to the parent directory of dmz/scripts.

  DMZ_ENV_FILE
      Explicit env file. Defaults to dmz/.env, or dmz/.env.example when .env
      does not exist because image packaging only needs compose image metadata.

  TARGET_PLATFORM
      Target image platform. Default: linux/amd64.

  PLATFORM
      Backward-compatible alias for TARGET_PLATFORM when TARGET_PLATFORM is
      unset.

  OUTPUT_DIR
      Output directory. Default: <dmz-root>/images.

  OUTPUT_NAME
      Output archive file name. Default:
        lucy-teamcloud-dmz-images-<platform>.tar.gz

EXAMPLES
  Package the DMZ nginx image:
    ./scripts/export-compose-images.sh

  Package for ARM64:
    TARGET_PLATFORM=linux/arm64 ./scripts/export-compose-images.sh

  Write to a custom output path:
    OUTPUT_DIR=/tmp/dmz-images ./scripts/export-compose-images.sh

OUTPUT FILES
  <base>.tar.gz
  <base>.tar.gz.sha256
  <base>.images.txt
  <base>.archive-images.txt
  <base>.explicit-images.txt
  <base>.services.txt

EOF
}

write_checksum() {
  local file="$1"
  local dir base
  dir="$(dirname "$file")"
  base="$(basename "$file")"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum "$base" > "$base.sha256")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$dir" && shasum -a 256 "$base" > "$base.sha256")
  else
    die "Neither sha256sum nor shasum is available."
  fi
}

supports_docker_save_platform() {
  docker save --help 2>/dev/null | grep -q -- '--platform'
}

docker_save_images() {
  local output_tar="$1"
  shift

  if supports_docker_save_platform; then
    docker save --platform "$TARGET_PLATFORM_RESOLVED" -o "$output_tar" "$@"
  else
    warn "This Docker version does not support 'docker save --platform'. Saving without platform filter."
    docker save -o "$output_tar" "$@"
  fi
}

refresh_images_after_save_failure() {
  local img

  warn "Docker save failed because local image content appears incomplete."
  warn "Refreshing selected images with docker image rm + docker pull, then retrying once."

  for img in "${SAVE_IMAGES[@]}"; do
    warn "Refreshing image: $img"
    docker image rm -f "$img" >/dev/null 2>&1 || true
    docker pull --platform "$TARGET_PLATFORM_RESOLVED" "$img"
  done
}

save_images_with_retry() {
  local output_tar="$1"
  local err_file="$TMP_DIR/docker-save.err"

  rm -f "$err_file"

  if docker_save_images "$output_tar" "${SAVE_IMAGES[@]}" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi

  cat "$err_file" >&2 || true

  if grep -Eq 'content digest .*not found|unable to create manifests file' "$err_file"; then
    refresh_images_after_save_failure
    rm -f "$err_file"
    docker_save_images "$output_tar" "${SAVE_IMAGES[@]}"
    return $?
  fi

  return 1
}

main() {
  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      echo "export-compose-images.sh $SCRIPT_VERSION"
      exit 0
      ;;
    "")
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac

  init_dmz_context allow-example
  require_docker_daemon

  TARGET_PLATFORM_RESOLVED="${TARGET_PLATFORM:-${PLATFORM:-linux/amd64}}"
  export TARGET_PLATFORM="$TARGET_PLATFORM_RESOLVED"
  export PLATFORM="$TARGET_PLATFORM_RESOLVED"

  OUTPUT_DIR="${OUTPUT_DIR:-$DMZ_ROOT_DIR/images}"
  OUTPUT_DIR="$(resolve_path_from_dmz_root "$OUTPUT_DIR")"
  OUTPUT_NAME="${OUTPUT_NAME:-lucy-teamcloud-dmz-images-${TARGET_PLATFORM_RESOLVED//\//-}.tar.gz}"
  OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"
  OUTPUT_BASE="$(archive_basename_without_extensions "$OUTPUT_PATH")"

  mkdir -p "$OUTPUT_DIR" || die "Could not create output directory: $OUTPUT_DIR"

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"
  log "Target platform: $TARGET_PLATFORM_RESOLVED"
  log "Output archive: $OUTPUT_PATH"

  log "Validating DMZ compose config..."
  dmz_compose config --quiet

  TMP_DIR="$(mktemp -d)"
  local images_file services_file archive_images_file explicit_images_file
  images_file="$TMP_DIR/images"
  services_file="$OUTPUT_DIR/$OUTPUT_BASE.services.txt"
  archive_images_file="$OUTPUT_DIR/$OUTPUT_BASE.archive-images.txt"
  explicit_images_file="$OUTPUT_DIR/$OUTPUT_BASE.explicit-images.txt"

  dmz_compose_images > "$images_file"
  [ -s "$images_file" ] || die "No images found in DMZ compose config."

  dmz_compose_services_with_images > "$services_file"
  cp "$images_file" "$OUTPUT_DIR/$OUTPUT_BASE.images.txt"
  cp "$images_file" "$archive_images_file"
  cp "$images_file" "$explicit_images_file"

  log "Images to pull and package:"
  sed 's/^/  /' "$images_file"

  local img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    log "Pulling image: $img"
    docker pull --platform "$TARGET_PLATFORM_RESOLVED" "$img"
  done < "$images_file"

  TMP_TAR="$OUTPUT_DIR/$OUTPUT_BASE.tmp.tar"
  log "Saving Docker images..."
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    SAVE_IMAGES+=("$img")
  done < "$images_file"

  save_images_with_retry "$TMP_TAR"
  gzip -c "$TMP_TAR" > "$OUTPUT_PATH"
  rm -f "$TMP_TAR"
  TMP_TAR=""

  write_checksum "$OUTPUT_PATH"

  log "DMZ image archive created:"
  ls -lh "$OUTPUT_PATH" "$OUTPUT_PATH.sha256" "$OUTPUT_DIR/$OUTPUT_BASE.images.txt" "$archive_images_file" "$explicit_images_file" "$services_file" 2>/dev/null || true
}

SAVE_IMAGES=()
main "$@"
