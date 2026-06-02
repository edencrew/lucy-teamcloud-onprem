#!/usr/bin/env bash

# Shared implementation for Docker/Podman DMZ image loading scripts.

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-load-compose-images.sh}"

SKIP_CHECKSUM=0
SKIP_GZIP_TEST=0
SKIP_IMAGE_VERIFY=0

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Verify and load a DMZ image archive on an offline / air-gapped server.

  This script is fully self-contained under dmz/. It does not call the parent
  on-premise scripts.

USAGE
  ./scripts/$SCRIPT_NAME [OPTIONS] [ARCHIVE_PATH]

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
      Skip post-load image existence verification using *.images.txt.

ENVIRONMENT VARIABLES
  DMZ_ROOT
      Explicit DMZ root path. Defaults to the parent directory of dmz/scripts.

  DMZ_ENV_FILE
      Explicit env file. Defaults to dmz/.env, or dmz/.env.example when .env
      does not exist because image loading only needs DMZ root context.

  IMAGES_DIR
      Directory to search when ARCHIVE_PATH is omitted. Default:
        <dmz-root>/images

EXAMPLES
  Load the only archive under ./images:
    ./scripts/$SCRIPT_NAME

  Load a specific archive:
    ./scripts/$SCRIPT_NAME ./images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz

  Skip checksum verification:
    ./scripts/$SCRIPT_NAME --skip-checksum ./images/dmz-images.tar.gz

EOF
}

parse_args() {
  ARCHIVE_PATH_ARG=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        echo "$SCRIPT_NAME $SCRIPT_VERSION"
        exit 0
        ;;
      --skip-checksum)
        SKIP_CHECKSUM=1
        ;;
      --skip-gzip-test)
        SKIP_GZIP_TEST=1
        ;;
      --skip-image-verify)
        SKIP_IMAGE_VERIFY=1
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [ -n "$ARCHIVE_PATH_ARG" ]; then
          die "Only one archive path may be provided."
        fi
        ARCHIVE_PATH_ARG="$1"
        ;;
    esac
    shift
  done
}

find_single_archive() {
  local dir="$1"
  local matches=""
  local count=0
  local f

  [ -d "$dir" ] || die "Images directory not found: $dir"

  for f in "$dir"/*.tar.gz "$dir"/*.tgz "$dir"/*.tar; do
    [ -f "$f" ] || continue
    matches="${matches}${f}
"
    count=$((count + 1))
  done

  if [ "$count" -eq 0 ]; then
    die "No image archive found in: $dir"
  fi

  if [ "$count" -gt 1 ]; then
    printf '%s\n' "$matches" >&2
    die "Multiple image archives found. Pass one explicitly."
  fi

  printf '%s' "$matches" | sed '/^[[:space:]]*$/d' | head -n 1
}

resolve_archive_path() {
  if [ -n "$ARCHIVE_PATH_ARG" ]; then
    ARCHIVE_PATH="$(resolve_path_from_dmz_root "$ARCHIVE_PATH_ARG")"
  else
    local images_dir
    images_dir="${IMAGES_DIR:-$DMZ_ROOT_DIR/images}"
    images_dir="$(resolve_path_from_dmz_root "$images_dir")"
    ARCHIVE_PATH="$(find_single_archive "$images_dir")"
  fi

  [ -f "$ARCHIVE_PATH" ] || die "Archive not found: $ARCHIVE_PATH"
}

verify_checksum() {
  local archive="$1"
  local checksum_file="$archive.sha256"
  local dir base

  if [ "$SKIP_CHECKSUM" = "1" ]; then
    warn "Skipping checksum verification by request."
    return 0
  fi

  if [ ! -f "$checksum_file" ]; then
    warn "Checksum file not found, skipping: $checksum_file"
    return 0
  fi

  log "Verifying checksum: $checksum_file"
  dir="$(dirname "$archive")"
  base="$(basename "$archive")"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$base.sha256")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$dir" && shasum -a 256 -c "$base.sha256")
  else
    die "Neither sha256sum nor shasum is available."
  fi
}

verify_gzip() {
  local archive="$1"

  if [ "$SKIP_GZIP_TEST" = "1" ]; then
    warn "Skipping gzip integrity verification by request."
    return 0
  fi

  case "$archive" in
    *.tar.gz|*.tgz)
      require_cmd gzip
      log "Verifying gzip integrity..."
      gzip -t "$archive"
      ;;
    *)
      warn "Archive is not gzip-compressed, skipping gzip test: $archive"
      ;;
  esac
}

verify_loaded_images() {
  local archive="$1"
  local base image_list_file img

  if [ "$SKIP_IMAGE_VERIFY" = "1" ]; then
    warn "Skipping image verification by request."
    return 0
  fi

  base="$(archive_basename_without_extensions "$archive")"
  image_list_file="$(dirname "$archive")/$base.images.txt"
  [ -f "$image_list_file" ] || die "Image list file not found: $image_list_file"

  log "Verifying loaded images from: $image_list_file"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || die "Loaded image not found locally: $img"
    printf '  OK   %s\n' "$img"
  done < "$image_list_file"
}

load_compose_images_main() {
  parse_args "$@"
  init_dmz_context allow-example
  require_dmz_selected_runtime
  resolve_archive_path

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"
  log "Image archive: $ARCHIVE_PATH"

  verify_checksum "$ARCHIVE_PATH"
  verify_gzip "$ARCHIVE_PATH"

  log "Loading image archive..."
  docker load -i "$ARCHIVE_PATH"
  verify_loaded_images "$ARCHIVE_PATH"

  log "DMZ image load complete."

  cat <<EOF

Next step:
  cd "$DMZ_ROOT_DIR"
  ./scripts/preflight-dmz.sh --compose-up

Or run:
  ./scripts/dmz-compose.sh up

EOF
}
