#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_VERSION="2.0.0"
RUNTIME="docker"

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

show_help() {
  cat <<'EOF'
load-compose-images-docker.sh

DESCRIPTION
  Verify and load a Docker image archive into Docker.

USAGE
  ./scripts/load-compose-images-docker.sh [OPTIONS] [ARCHIVE_PATH]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --skip-checksum
      Skip SHA256 checksum verification.

  --skip-gzip-test
      Skip gzip integrity verification.

  --skip-image-verify
      Skip post-load image existence verification.

ENVIRONMENT
  PROJECT_ROOT
      Project root. Defaults to the parent of ./scripts.

  IMAGES_DIR
      Directory containing one image archive. Defaults to <project-root>/images.

  ARCHIVE_PATH
      Explicit archive path. Same as positional ARCHIVE_PATH.

EXAMPLES
  ./scripts/load-compose-images-docker.sh
  ./scripts/load-compose-images-docker.sh ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
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

find_single_archive() {
  local dir="$1"
  local matches=()
  local f

  [ -d "$dir" ] || die "Images directory not found: $dir"

  for f in "$dir"/*.tar.gz "$dir"/*.tgz "$dir"/*.tar; do
    [ -f "$f" ] || continue
    matches+=("$f")
  done

  if [ "${#matches[@]}" -eq 0 ]; then
    die "No image archive found in: $dir"
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    printf '%s\n' "${matches[@]}" >&2
    die "Multiple archives found. Pass one explicitly."
  fi

  printf '%s\n' "${matches[0]}"
}

archive_stem() {
  local base
  base="$(basename "$1")"
  case "$base" in
    *.tar.gz) base="${base%.tar.gz}" ;;
    *.tgz) base="${base%.tgz}" ;;
    *.tar) base="${base%.tar}" ;;
    *) base="${base%.*}" ;;
  esac
  printf '%s\n' "$base"
}

validate_image_list() {
  local image_list="$1"

  [ -f "$image_list" ] || die "Image list file not found: $image_list"

  grep -Fxq "lucy-teamcloud-onprem-init-secrets:offline" "$image_list" \
    || die "This is not a Docker archive image list: missing lucy-teamcloud-onprem-init-secrets:offline"

  if grep -Fxq "localhost/lucy-teamcloud-onprem-init-secrets:offline" "$image_list"; then
    die "This looks like a Podman archive. Use ./scripts/load-compose-images-podman.sh instead."
  fi
}

SKIP_CHECKSUM=0
SKIP_GZIP=0
SKIP_IMAGE_VERIFY=0
ARCHIVE_ARG="${ARCHIVE_PATH:-}"

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
    --skip-checksum)
      SKIP_CHECKSUM=1
      shift
      ;;
    --skip-gzip-test)
      SKIP_GZIP=1
      shift
      ;;
    --skip-image-verify)
      SKIP_IMAGE_VERIFY=1
      shift
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [ -z "$ARCHIVE_ARG" ] || die "Only one archive path may be provided"
      ARCHIVE_ARG="$1"
      shift
      ;;
  esac
done

require_cmd "$RUNTIME"

SCRIPT_DIR="$(script_dir)"
ROOT_DIR="$(resolve_root "$SCRIPT_DIR")"
IMAGES_DIR="${IMAGES_DIR:-$ROOT_DIR/images}"

if [ -n "$ARCHIVE_ARG" ]; then
  case "$ARCHIVE_ARG" in
    /*) ARCHIVE="$ARCHIVE_ARG" ;;
    *) ARCHIVE="$ROOT_DIR/$ARCHIVE_ARG" ;;
  esac
else
  ARCHIVE="$(find_single_archive "$IMAGES_DIR")"
fi

[ -f "$ARCHIVE" ] || die "Archive not found: $ARCHIVE"

STEM="$(archive_stem "$ARCHIVE")"
ARCHIVE_DIR="$(cd "$(dirname "$ARCHIVE")" >/dev/null 2>&1 && pwd)"
CHECKSUM_FILE="${CHECKSUM_FILE:-$ARCHIVE.sha256}"
IMAGE_LIST_FILE="${IMAGE_LIST_FILE:-$ARCHIVE_DIR/$STEM.images.txt}"

log "Runtime: $RUNTIME"
log "Archive: $ARCHIVE"

if [ "$SKIP_CHECKSUM" -eq 0 ] && [ -f "$CHECKSUM_FILE" ]; then
  log "Checking SHA256: $CHECKSUM_FILE"
  (
    cd "$ARCHIVE_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c "$(basename "$CHECKSUM_FILE")"
    else
      shasum -a 256 -c "$(basename "$CHECKSUM_FILE")"
    fi
  )
else
  warn "Skipping checksum verification"
fi

case "$ARCHIVE" in
  *.tar.gz|*.tgz)
    if [ "$SKIP_GZIP" -eq 0 ]; then
      log "Checking gzip integrity"
      gzip -t "$ARCHIVE"
    else
      warn "Skipping gzip integrity check"
    fi
    ;;
esac

if [ "$SKIP_IMAGE_VERIFY" -eq 0 ]; then
  validate_image_list "$IMAGE_LIST_FILE"
fi

log "Loading images"
"$RUNTIME" load -i "$ARCHIVE"

if [ "$SKIP_IMAGE_VERIFY" -eq 0 ]; then
  log "Verifying loaded images: $IMAGE_LIST_FILE"
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    "$RUNTIME" image inspect "$image" >/dev/null 2>&1 || die "Image not found after load: $image"
    printf '  \033[1;32mOK\033[0m   %s\n' "$image"
  done < "$IMAGE_LIST_FILE"
else
  warn "Skipping post-load image verification"
fi

log "Load complete."
