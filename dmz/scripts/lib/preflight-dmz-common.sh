#!/usr/bin/env bash

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"
SCRIPT_NAME="${SCRIPT_NAME:-preflight-dmz.sh}"

COMPOSE_UP=0
SKIP_IMAGE_CHECK=0

show_help() {
  cat <<EOF
$SCRIPT_NAME

DESCRIPTION
  Verify the standalone DMZ MQTT WebSocket proxy before running compose up.

USAGE
  ./scripts/$SCRIPT_NAME [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --compose-up
      Start the DMZ stack after all checks pass.

  --skip-image-check
      Skip local image existence checks.

ENVIRONMENT VARIABLES
  DMZ_ROOT
      Explicit DMZ root path. Defaults to the parent directory of dmz/scripts.

  DMZ_ENV_FILE
      Explicit env file. Defaults to dmz/.env. Runtime checks require .env.

  DMZ_RUNTIME
      Force runtime selection. Supported values: docker, podman.

  DMZ_IMAGE_MODE
      Image preparation mode. Defaults to offline.
      Supported values:
        offline  require images to exist locally, usually loaded by load-compose-images.sh
        online   pull registry images during preflight

EXAMPLES
  Basic check:
    ./scripts/$SCRIPT_NAME

  Check and start DMZ:
    ./scripts/$SCRIPT_NAME --compose-up

  Force Podman:
    DMZ_RUNTIME=podman ./scripts/$SCRIPT_NAME --compose-up

EOF
}

parse_preflight_args() {
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
      --compose-up)
        COMPOSE_UP=1
        ;;
      --skip-image-check)
        SKIP_IMAGE_CHECK=1
        ;;
      *)
        die "Unknown option: $1

Run './scripts/$SCRIPT_NAME --help' for usage."
        ;;
    esac
    shift
  done
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

validate_dmz_image_mode() {
  DMZ_IMAGE_MODE_RESOLVED="${DMZ_IMAGE_MODE:-offline}"

  case "$DMZ_IMAGE_MODE_RESOLVED" in
    offline|online)
      log "Image mode: $DMZ_IMAGE_MODE_RESOLVED"
      ;;
    *)
      die "DMZ_IMAGE_MODE must be offline or online: $DMZ_IMAGE_MODE_RESOLVED"
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
  - The image exists only in private ECR.
  - The tag exists, but does not support platform: $TARGET_PLATFORM_RESOLVED

Check:
  docker buildx imagetools inspect $image

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

Checks:
  docker buildx imagetools inspect $image
  docker pull --platform $TARGET_PLATFORM_RESOLVED $image

EOF_GENERIC_REGISTRY
      ;;
  esac
}

normalize_online_pull_source_image() {
  local image="$1"
  local source first

  source="$image"

  case "$source" in
    localhost/*)
      source="${source#localhost/}"
      ;;
  esac

  first="${source%%/*}"

  if [ "$first" = "$source" ]; then
    printf 'docker.io/library/%s' "$source"
    return 0
  fi

  case "$first" in
    *.*|*:*|localhost)
      printf '%s' "$source"
      ;;
    *)
      printf 'docker.io/%s' "$source"
      ;;
  esac
}

prepare_dmz_online_images() {
  validate_dmz_image_mode

  if [ "$DMZ_IMAGE_MODE_RESOLVED" != "online" ]; then
    return 0
  fi

  TARGET_PLATFORM_RESOLVED="$(detect_target_platform)"

  local images img source
  images="$(dmz_compose_images)"
  [ -n "$images" ] || die "No image entries found in DMZ compose config."

  log "Preparing DMZ compose images from registries for online mode..."
  log "Target image platform: $TARGET_PLATFORM_RESOLVED"

  while IFS= read -r img; do
    [ -n "$img" ] || continue
    source="$(normalize_online_pull_source_image "$img")"
    log "Pulling image for online mode: $source"
    if docker pull --platform "$TARGET_PLATFORM_RESOLVED" "$source"; then
      printf '  OK   %s\n' "$source"
    else
      print_pull_error "$source"
      die "Failed to pull DMZ image: $source"
    fi

    if [ "$source" != "$img" ]; then
      if docker tag "$source" "$img"; then
        printf '  OK   Tagged image alias: %s <- %s\n' "$img" "$source"
      else
        die "Failed to tag DMZ image alias: $img <- $source"
      fi
    fi
  done <<EOF_IMAGES
$images
EOF_IMAGES
}

check_local_images() {
  if [ "$SKIP_IMAGE_CHECK" = "1" ]; then
    warn "Skipping local image checks by request."
    return 0
  fi

  local images img missing=0
  images="$(dmz_compose_images)"
  [ -n "$images" ] || die "No image entries found in DMZ compose config."

  log "Checking that DMZ compose images exist locally..."
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      printf '  OK   %s\n' "$img"
    else
      printf '  MISS %s\n' "$img" >&2
      missing=$((missing + 1))
    fi
  done <<EOF_IMAGES
$images
EOF_IMAGES

  if [ "$missing" -gt 0 ]; then
    die "$missing DMZ image(s) are missing locally. Run ./scripts/load-compose-images.sh first."
  fi
}

preflight_dmz_main() {
  parse_preflight_args "$@"

  init_dmz_context require-env
  require_dmz_selected_runtime

  log "DMZ root: $DMZ_ROOT_DIR"
  log "Env file: $DMZ_ENV_FILE_RESOLVED"
  log "Runtime: $DMZ_RUNTIME_RESOLVED"
  log "Compose files, in merge order: $(join_by_space_quoted "${DMZ_COMPOSE_FILES[@]}")"

  require_dmz_runtime_env

  log "Validating DMZ compose config..."
  dmz_compose config --quiet

  prepare_dmz_online_images
  check_local_images

  log "DMZ preflight passed."

  if [ "$COMPOSE_UP" = "1" ]; then
    log "Starting DMZ proxy..."
    dmz_compose_up
  else
    cat <<EOF

Next step:
  cd "$DMZ_ROOT_DIR"
  ./scripts/dmz-compose.sh up

Or run:
  ./scripts/preflight-dmz.sh --compose-up

EOF
  fi
}
