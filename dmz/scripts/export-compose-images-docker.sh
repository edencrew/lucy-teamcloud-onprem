#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_VERSION="2.0.0"
COMPOSE_FILE_NAME="compose.docker.yml"
ARCHIVE_PREFIX="lucy-teamcloud-dmz-docker-images"

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

die() {
  printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
export-compose-images-docker.sh

DESCRIPTION
  Export images required by the default dmz/compose.docker.yml plain WS compose
  into a tar.gz archive.

USAGE
  ./scripts/export-compose-images-docker.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

ENVIRONMENT
  DMZ_ROOT
      DMZ root. Defaults to the parent of ./scripts.

  TARGET_PLATFORM
      Target platform. Defaults to linux/amd64.

  OUTPUT_DIR
      Output directory. Defaults to <dmz-root>/images.

  OUTPUT_NAME
      Output archive name. Defaults to
      lucy-teamcloud-dmz-docker-images-<platform>.tar.gz.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_docker_save_platform() {
  docker save --help 2>&1 | grep -q -- '--platform' || die "Docker CLI does not support 'docker save --platform'. Install or update to a recent Docker Desktop or Docker Engine version."
}

script_dir() {
  cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

resolve_root() {
  local sdir="$1"
  if [ -n "${DMZ_ROOT:-}" ]; then
    cd "$DMZ_ROOT" >/dev/null 2>&1 && pwd
  else
    cd "$sdir/.." >/dev/null 2>&1 && pwd
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required: docker compose version"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
require_docker_save_platform

SCRIPT_DIR="$(script_dir)"
ROOT_DIR="$(resolve_root "$SCRIPT_DIR")"
TARGET_PLATFORM="${TARGET_PLATFORM:-${PLATFORM:-linux/amd64}}"
PLATFORM_SAFE="$(printf '%s' "$TARGET_PLATFORM" | tr '/:' '--')"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/images}"
OUTPUT_NAME="${OUTPUT_NAME:-$ARCHIVE_PREFIX-$PLATFORM_SAFE.tar.gz}"
ARCHIVE_PATH="$OUTPUT_DIR/$OUTPUT_NAME"
COMPOSE_ARGS=(--env-file "$ROOT_DIR/.env.example" -f "$ROOT_DIR/$COMPOSE_FILE_NAME")

mkdir -p "$OUTPUT_DIR"

log "DMZ root: $ROOT_DIR"
log "Compose file: $COMPOSE_FILE_NAME"
log "Target platform: $TARGET_PLATFORM"

log "Validating compose config..."
docker compose "${COMPOSE_ARGS[@]}" config --quiet

TMP_IMAGES="$(mktemp "${TMPDIR:-/tmp}/lucy-dmz-images.XXXXXX")"
trap 'rm -f "$TMP_IMAGES"' EXIT

docker compose "${COMPOSE_ARGS[@]}" config --images | sort -u > "$TMP_IMAGES"
[ -s "$TMP_IMAGES" ] || die "No images found in compose config"

log "Pulling registry images..."
while IFS= read -r image; do
  [ -n "$image" ] || continue
  docker pull --platform "$TARGET_PLATFORM" "$image"
done < "$TMP_IMAGES"

IMAGES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.images.txt"
ARCHIVE_IMAGES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.archive-images.txt"
SERVICES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.services.txt"
CHECKSUM_FILE="$ARCHIVE_PATH.sha256"

log "Collecting image list..."
cp "$TMP_IMAGES" "$IMAGES_FILE"
cp "$IMAGES_FILE" "$ARCHIVE_IMAGES_FILE"
docker compose "${COMPOSE_ARGS[@]}" config --services | sort -u > "$SERVICES_FILE"
chmod 644 "$IMAGES_FILE" "$ARCHIVE_IMAGES_FILE" "$SERVICES_FILE"

log "Testing docker save image by image..."
while IFS= read -r image; do
  [ -n "$image" ] || continue
  docker save --platform "$TARGET_PLATFORM" "$image" >/dev/null || die "docker save failed: $image"
done < "$IMAGES_FILE"

log "Saving images to: $ARCHIVE_PATH"
docker save --platform "$TARGET_PLATFORM" $(cat "$IMAGES_FILE") | gzip -c > "$ARCHIVE_PATH"

log "Writing checksum..."
(
  cd "$OUTPUT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$OUTPUT_NAME"
  else
    shasum -a 256 "$OUTPUT_NAME"
  fi
) > "$CHECKSUM_FILE"
chmod 644 "$CHECKSUM_FILE"

log "Export complete."
ls -lh "$ARCHIVE_PATH" "$CHECKSUM_FILE" "$IMAGES_FILE" "$ARCHIVE_IMAGES_FILE" "$SERVICES_FILE"
