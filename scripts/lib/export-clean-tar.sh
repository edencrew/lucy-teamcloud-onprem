#!/usr/bin/env bash
set -Eeo pipefail

SCRIPT_VERSION="1.0.0"

SKIP_IMAGE_EXPORT=0
VERIFY_ARCHIVE=1
CLEAN_TAR_OUTPUT_DIR="${CLEAN_TAR_OUTPUT_DIR:-}"

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '  \033[1;32mOK\033[0m   %s\n' "$*"
}

warn() {
  printf '  \033[1;33mWARN\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Create a Windows/Linux-clean tar.gz archive for the whole Lucy TeamCloud onprem directory.

USAGE
  ./scripts/export-clean-tar.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --skip-image-export
  --no-image-export
  --skip-export-images
  --no-export-images
      Do not run ./scripts/export-compose-images.sh before creating the clean tar.
      By default, image export always runs first.

  --skip-verify
      Skip archive verification. Not recommended.

ENVIRONMENT VARIABLES
  PROJECT_ROOT
      Explicit project root path.
      Default: parent directory of ./scripts.

  CLEAN_TAR_OUTPUT_DIR
      Directory where the clean tar.gz file is written.
      Default: parent directory of PROJECT_ROOT.

  TARGET_PLATFORM, PLATFORM, COMPOSE_FILES, COMPOSE_OVERRIDE_FILES
      Passed through to ./scripts/export-compose-images.sh when image export runs.

OUTPUT NAME
  <project-name>_YYYY_MM_DD.tar.gz

  If that file already exists:
    <project-name>_YYYY_MM_DD_HHMMSS.tar.gz

  If that also exists, a numeric suffix is appended.

EXAMPLES
  ./scripts/export-clean-tar.sh
  ./scripts/export-clean-tar.sh --skip-image-export
  CLEAN_TAR_OUTPUT_DIR=/tmp ./scripts/export-clean-tar.sh
EOF
}

resolve_project_root() {
  local sdir="$1"
  local root

  if [ -n "${PROJECT_ROOT:-}" ]; then
    root="$PROJECT_ROOT"
  else
    root="$(cd "$sdir/.." >/dev/null 2>&1 && pwd)"
  fi

  (cd "$root" >/dev/null 2>&1 && pwd)
}

sha256_file() {
  local file="$1"
  local checksum_file="$file.sha256"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$file")" && sha256sum "$(basename "$file")") > "$checksum_file"
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")") > "$checksum_file"
  else
    die "sha256sum or shasum is required to write checksum files"
  fi
}

tar_supports_no_xattrs() {
  local probe
  probe="$(mktemp)"
  if tar --no-xattrs -cf "$probe" -T /dev/null >/dev/null 2>&1; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

pick_output_path() {
  local output_dir="$1"
  local project_name="$2"
  local day_stamp time_stamp candidate stem counter

  day_stamp="$(date +%Y_%m_%d)"
  candidate="$output_dir/${project_name}_${day_stamp}.tar.gz"

  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  time_stamp="$(date +%H%M%S)"
  stem="$output_dir/${project_name}_${day_stamp}_${time_stamp}"
  candidate="${stem}.tar.gz"

  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  counter=1
  while :; do
    candidate="$(printf '%s_%02d.tar.gz' "$stem" "$counter")"
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    counter=$((counter + 1))
  done
}

run_image_export() {
  local root="$1"
  local exporter="$root/scripts/export-compose-images.sh"

  if [ ! -x "$exporter" ]; then
    die "Image export script is not executable: $exporter"
  fi

  log "Exporting compose images before clean tar..."
  "$exporter"
}

verify_no_macos_paths() {
  local archive="$1"

  if tar -tzf "$archive" | grep -E '(^|/)(__MACOSX|\.DS_Store|\._[^/]+)$' >/dev/null 2>&1; then
    die "Archive contains macOS metadata path entries"
  fi
  ok "No macOS metadata path entries in clean tar"
}

verify_no_libarchive_xattr_headers() {
  local archive="$1"
  local pattern='LIBARCHIVE[.]xattr[.]'

  if ! command -v strings >/dev/null 2>&1; then
    warn "'strings' not found. Skipping extended header string scan."
    return 0
  fi

  if gzip -dc "$archive" | strings | grep -E "$pattern" >/dev/null 2>&1; then
    die "Archive contains libarchive xattr extended headers"
  fi
  ok "No libarchive xattr extended headers detected"
}

verify_nested_image_archives() {
  local root="$1"
  local found=0
  local image_archive

  if [ ! -d "$root/images" ]; then
    warn "No images directory found for nested image archive checks"
    return 0
  fi

  while IFS= read -r image_archive; do
    found=1
    if tar -tzf "$image_archive" | grep -E '(^|/)(__MACOSX|\.DS_Store|\._[^/]+)$' >/dev/null 2>&1; then
      die "Nested image archive contains macOS metadata path entries: $image_archive"
    fi
    ok "Nested image archive is clean: $image_archive"
  done < <(find "$root/images" -maxdepth 1 -type f -name '*.tar.gz' -print | sort)

  if [ "$found" = "0" ]; then
    warn "No nested image tar.gz files found under images/"
  fi
}

verify_archive() {
  local root="$1"
  local archive="$2"

  log "Verifying clean tar..."
  gzip -t "$archive"
  ok "gzip integrity check passed"

  verify_no_macos_paths "$archive"
  verify_no_libarchive_xattr_headers "$archive"
  verify_nested_image_archives "$root"
}

create_clean_tar() {
  local root="$1"
  local output_path="$2"
  local output_dir project_name parent_dir tmp_archive
  local tar_header_args=()

  output_dir="$(dirname "$output_path")"
  project_name="$(basename "$root")"
  parent_dir="$(dirname "$root")"

  if tar_supports_no_xattrs; then
    tar_header_args+=("--no-xattrs")
  else
    warn "tar does not support --no-xattrs. Continuing with COPYFILE_DISABLE=1 only."
  fi

  tmp_archive="$(mktemp "$output_dir/.${project_name}_clean_tar.XXXXXX")"
  rm -f "$tmp_archive"

  log "Creating clean tar: $output_path"
  COPYFILE_DISABLE=1 tar "${tar_header_args[@]}" \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='__MACOSX' \
    --exclude="$project_name/.git/fsmonitor--daemon.ipc" \
    --exclude="$project_name/$project_name.tar.gz" \
    --exclude="$project_name/${project_name}_"'*.tar.gz' \
    -czf "$tmp_archive" \
    -C "$parent_dir" \
    "$project_name"

  mv "$tmp_archive" "$output_path"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -v|--version)
        echo "export-clean-tar.sh $SCRIPT_VERSION"
        exit 0
        ;;
      --skip-image-export|--no-image-export|--skip-export-images|--no-export-images)
        SKIP_IMAGE_EXPORT=1
        ;;
      --skip-verify)
        VERIFY_ARCHIVE=0
        ;;
      --output-dir)
        shift
        [ "$#" -gt 0 ] || die "--output-dir requires a value"
        CLEAN_TAR_OUTPUT_DIR="$1"
        ;;
      --output-dir=*)
        CLEAN_TAR_OUTPUT_DIR="${1#*=}"
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  local sdir root output_dir output_path
  sdir="${ONPREM_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)}"
  root="$(resolve_project_root "$sdir")"
  output_dir="${CLEAN_TAR_OUTPUT_DIR:-$(dirname "$root")}"

  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" >/dev/null 2>&1 && pwd)"
  output_path="$(pick_output_path "$output_dir" "$(basename "$root")")"

  log "Project root: $root"
  log "Output directory: $output_dir"

  if [ "$SKIP_IMAGE_EXPORT" = "0" ]; then
    run_image_export "$root"
  else
    warn "Skipping image export by request."
  fi

  create_clean_tar "$root" "$output_path"

  if [ "$VERIFY_ARCHIVE" = "1" ]; then
    verify_archive "$root" "$output_path"
  else
    warn "Skipping clean tar verification by request."
  fi

  sha256_file "$output_path"

  log "Clean tar export complete."
  ls -lh "$output_path" "$output_path.sha256" 2>/dev/null || true

  cat <<EOF_DONE

Files created:
  $output_path
  $output_path.sha256

EOF_DONE
}

main "$@"
