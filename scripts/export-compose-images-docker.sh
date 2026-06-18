#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_VERSION="2.0.0"
BUILD_IMAGE="lucy-teamcloud-onprem-init-secrets:offline"

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
  Export images required by compose.docker.yml into a tar.gz archive.

USAGE
  ./scripts/export-compose-images-docker.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --skip-remote-digest-check
      Accepted for compatibility. Remote digest verification is not performed.

ENVIRONMENT
  PROJECT_ROOT
      Project root. Defaults to the parent of ./scripts.

  TARGET_PLATFORM
      Target platform. Defaults to linux/amd64.

  OUTPUT_DIR
      Output directory. Defaults to <project-root>/images.

  OUTPUT_NAME
      Output archive name. Defaults to
      lucy-teamcloud-onprem-docker-images-<platform>.tar.gz.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

script_dir() {
  cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

resolve_root() {
  local sdir="$1"
  if [ -n "${PROJECT_ROOT:-}" ]; then
    cd "$PROJECT_ROOT" >/dev/null 2>&1 && pwd
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
    --skip-remote-digest-check)
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required: docker compose version"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

SCRIPT_DIR="$(script_dir)"
ROOT_DIR="$(resolve_root "$SCRIPT_DIR")"
TARGET_PLATFORM="${TARGET_PLATFORM:-${PLATFORM:-linux/amd64}}"
PLATFORM_SAFE="$(printf '%s' "$TARGET_PLATFORM" | tr '/:' '--')"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/images}"
OUTPUT_NAME="${OUTPUT_NAME:-lucy-teamcloud-onprem-docker-images-$PLATFORM_SAFE.tar.gz}"
ARCHIVE_PATH="$OUTPUT_DIR/$OUTPUT_NAME"
COMPOSE_ARGS=(--env-file "$ROOT_DIR/.env.example" -f "$ROOT_DIR/compose.docker.yml")

mkdir -p "$OUTPUT_DIR"

log "Project root: $ROOT_DIR"
log "Compose file: compose.docker.yml"
log "Target platform: $TARGET_PLATFORM"

log "Validating compose config..."
docker compose "${COMPOSE_ARGS[@]}" config --quiet

TMP_IMAGES="$(mktemp "${TMPDIR:-/tmp}/lucy-compose-images.XXXXXX")"
trap 'rm -f "$TMP_IMAGES"' EXIT

docker compose "${COMPOSE_ARGS[@]}" config --images | sort -u > "$TMP_IMAGES"

log "Pulling registry images..."
while IFS= read -r image; do
  [ -n "$image" ] || continue
  if [ "$image" = "$BUILD_IMAGE" ]; then
    printf '  \033[1;34mSKIP\033[0m build image: %s\n' "$image"
  else
    docker pull --platform "$TARGET_PLATFORM" "$image"
  fi
done < "$TMP_IMAGES"

log "Building local images..."
docker compose "${COMPOSE_ARGS[@]}" build

IMAGES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.images.txt"
ARCHIVE_IMAGES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.archive-images.txt"
SERVICES_FILE="$OUTPUT_DIR/${OUTPUT_NAME%.tar.gz}.services.txt"
CHECKSUM_FILE="$ARCHIVE_PATH.sha256"

log "Collecting image list..."
cp "$TMP_IMAGES" "$IMAGES_FILE"
cp "$IMAGES_FILE" "$ARCHIVE_IMAGES_FILE"
docker compose "${COMPOSE_ARGS[@]}" config --services | sort -u > "$SERVICES_FILE"
chmod 644 "$IMAGES_FILE" "$ARCHIVE_IMAGES_FILE" "$SERVICES_FILE"

[ -s "$IMAGES_FILE" ] || die "No images found in compose config"

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
