#!/usr/bin/env bash
set -Eeo pipefail

# preflight-podman.sh
#
# Recommended location:
#   <project-root>/scripts/preflight-podman.sh
#
# Purpose:
#   Verify that a Lucy TeamCloud On-Premise installation is ready before:
#     docker compose up -d
#
# Optional:
#   With --compose-up, this script runs:
#     docker compose up -d --no-build
#
# Compatibility:
#   - Bash 3+ compatible. Works with macOS default /bin/bash 3.2.
#   - Intended for Linux offline servers, but most checks also work on macOS.
#
# Why not `set -u`?
#   macOS ships Bash 3.2. With `set -u`, empty arrays can fail unexpectedly.
#   This script avoids nounset for portability and validates values explicitly.

SCRIPT_VERSION="1.0.0"

MIN_DOCKER_VERSION="20.10.0"
MIN_COMPOSE_VERSION="2.20.0"
MIN_PODMAN_VERSION="5.0.0"
MIN_PODMAN_COMPOSE_VERSION="1.5.0"
MIN_RAM_MB="4096"
MIN_DISK_MB="10240"

IMMUTABLE_KEYS="LUCY_ADMIN_EMAIL LUCY_ADMIN_PASSWORD DB_USERNAME DB_PASSWORD DB_ROOT_PASSWORD"
ROOT_OWNED_GENERATED_FILES="git/data/gitea/.admin-created secrets/secrets.env nginx/certs/server.crt nginx/certs/server.key"
ROOT_OWNED_GENERATED_DIRS="git/data/ssh"
COMPOSE_RUNTIME_FLAVOR="podman"
COMPOSE_ARGS_INCLUDE_ENV_FILE="1"
COMPOSE_CONFIG_LABEL="Podman Compose"
CHECK_ROOTLESS_PRIVILEGED_PORTS="1"

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ONPREM_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=scripts/lib/preflight-common.sh
. "$SCRIPT_DIR/lib/preflight-common.sh"

show_help() {
  cat <<'EOF'
preflight-podman.sh

DESCRIPTION
  Verify Lucy TeamCloud On-Premise Podman installation prerequisites before running:
    docker compose up -d

  This script assumes the user has already prepared:
    - .env
    - license/license.json
    - Podman images loaded by load-compose-images.sh
    - optional SSL certificate files

RECOMMENDED LOCATION
  <project-root>/scripts/preflight-podman.sh

USAGE
  ./scripts/preflight-podman.sh [OPTIONS]

OPTIONS
  -h, --help
      Show this help message and exit.

  -v, --version
      Show script version and exit.

  --compose-up
      Run docker compose up after all checks pass:
        docker compose up -d --no-build

  --allow-immutable-change
      Do not fail when immutable .env values changed after the initial lock
      was created. This is dangerous and should only be used intentionally.

  --allow-cert-host-mismatch
      Do not fail when nginx/certs/server.crt does not appear to match
      EXTERNAL_URL hostname. This may break HTTPS BE-to-BE calls.

  --skip-port-check
      Skip host port conflict checks.

  --skip-image-check
      Skip local image existence checks.

  --skip-arch-check
      Skip container image architecture checks.

  --skip-resource-check
      Skip RAM and disk checks.

ENVIRONMENT VARIABLES
  PROJECT_ROOT
      Explicit project root path.
      Default:
        If script is inside ./scripts, parent directory of ./scripts.
        Otherwise, the directory containing this script.

  TARGET_PLATFORM
      Expected container image platform.
      Default: detected from the server CPU architecture.

      Examples:
        TARGET_PLATFORM=linux/amd64
        TARGET_PLATFORM=linux/arm64

  PLATFORM
      Alias for TARGET_PLATFORM when TARGET_PLATFORM is not set.

  TARGET_PLATFORM
      Expected container image platform.
      Default: detected from server CPU architecture.

      Examples:
        TARGET_PLATFORM=linux/amd64
        TARGET_PLATFORM=linux/arm64

  PLATFORM
      Alias for TARGET_PLATFORM when TARGET_PLATFORM is not set.

  COMPOSE_FILES
      Explicit compose files to use, separated by colon (:).
      Paths are resolved relative to PROJECT_ROOT unless absolute.
      Later files override earlier files.

      Example:
        COMPOSE_FILES="docker-compose.yml:docker-compose.prod.yml"

  COMPOSE_OVERRIDE_FILES
      Extra override files to append after auto-detected compose files,
      separated by colon (:).
      Paths are resolved relative to PROJECT_ROOT unless absolute.

EXAMPLES
  Basic check:
    ./scripts/preflight-podman.sh

  Check and start services:
    ./scripts/preflight-podman.sh --compose-up

  Run from anywhere:
    PROJECT_ROOT=/opt/lucy-teamcloud-onprem /opt/lucy-teamcloud-onprem/scripts/preflight-podman.sh

AUTO-DETECTED COMPOSE FILE ORDER
  1. Base compose file
  2. docker-compose.offline.yml / docker-compose.offline.yaml if present
  3. docker-compose.podman.yml / docker-compose.podman.yaml if present
  4. docker-compose.override.yml / docker-compose.override.yaml if present

CHECKS PERFORMED
  - Podman installed and reachable through docker CLI compatibility
  - Podman version >= 5.0
  - podman-compose version >= 1.5
  - Minimum RAM and disk
  - .env exists and required values are present
  - EXTERNAL_URL is valid and not localhost / 127.0.0.1 / 0.0.0.0
  - BROKER_WS_URL scheme matches EXTERNAL_URL scheme
  - LUCY_ADMIN_NAME is admin
  - license/license.json exists, non-empty, and JSON-valid when jq/python exists
  - runtime bind mount directories exist before Podman Compose can auto-create them unexpectedly
  - init-secrets outputs exist, generating them once when missing
  - nginx certificate pair consistency
  - certificate hostname match when openssl is available
  - docker compose config --quiet succeeds
  - host port conflicts from final merged compose config
  - final compose images exist locally
  - final compose image architectures match the target platform
  - immutable .env values are locked and compared on subsequent runs

EOF
}

detect_container_runtime() {
  local raw
  raw="$(docker version 2>&1 || true)"

  if printf '%s\n' "$raw" | grep -Eiq 'podman|libpod'; then
    printf '%s' "podman"
  else
    printf '%s' "docker"
  fi
}

detect_compose_provider() {
  local raw
  raw="$(docker compose version 2>&1 || true)"

  if printf '%s\n' "$raw" | grep -Eiq 'podman-compose|podman version'; then
    printf '%s' "podman-compose"
  else
    printf '%s' "docker-compose"
  fi
}

extract_first_semver() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^v/, "", token)
        sub(/^[^0-9]*/, "", token)
        sub(/[^0-9.].*$/, "", token)
        if (token ~ /^[0-9]+([.][0-9]+)+$/) {
          print token
          exit
        }
      }
    }
  '
}

detect_compose_version() {
  local raw short version

  raw="$(docker compose version 2>&1 || true)"
  version="$(printf '%s\n' "$raw" | sed -n 's/.*podman-compose[[:space:]]*[Vv]ersion[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | sed -n '1p')"
  if [ -n "$version" ]; then
    printf '%s' "$version"
    return 0
  fi

  short="$(docker compose version --short 2>/dev/null || true)"
  version="$(printf '%s\n' "$short" | extract_first_semver)"
  if [ -n "$version" ]; then
    printf '%s' "$version"
    return 0
  fi

  printf '%s\n' "$raw" | extract_first_semver
}

validate_docker_versions() {
  log "Checking Podman and podman-compose versions..."

  local runtime runtime_version compose_provider compose_version
  runtime="$(detect_container_runtime)"
  runtime_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  compose_provider="$(detect_compose_provider)"
  compose_version="$(detect_compose_version)"

  if [ "$runtime" != "podman" ]; then
    fail_msg "This is the Podman preflight, but docker CLI does not appear to target Podman"
  fi

  if [ -z "$runtime_version" ]; then
    fail_msg "Could not detect Podman version"
  elif version_ge "$runtime_version" "$MIN_PODMAN_VERSION"; then
    ok "Podman version $runtime_version >= $MIN_PODMAN_VERSION"
  else
    fail_msg "Podman version $runtime_version is lower than required $MIN_PODMAN_VERSION"
  fi

  if [ "$compose_provider" != "podman-compose" ]; then
    fail_msg "This is the Podman preflight, but docker compose does not appear to use podman-compose"
  fi

  if [ -z "$compose_version" ]; then
    fail_msg "Could not detect podman-compose version"
  elif version_ge "$compose_version" "$MIN_PODMAN_COMPOSE_VERSION"; then
    ok "podman-compose version $compose_version >= $MIN_PODMAN_COMPOSE_VERSION"
  else
    fail_msg "podman-compose version $compose_version is lower than required $MIN_PODMAN_COMPOSE_VERSION"
  fi
}

prepare_init_secrets_outputs() {
  local secrets="$ROOT_DIR/secrets/secrets.env"
  local cert="$ROOT_DIR/nginx/certs/server.crt"
  local key="$ROOT_DIR/nginx/certs/server.key"
  local external_url

  if [ -f "$secrets" ] && [ -f "$cert" ] && [ -f "$key" ]; then
    return 0
  fi

  external_url="$(get_env_value EXTERNAL_URL)"

  log "Preparing init-secrets outputs..."
  if docker run --rm --pull=never \
    -e "EXTERNAL_URL=$external_url" \
    -v "$ROOT_DIR/secrets:/secrets:z" \
    -v "$ROOT_DIR/nginx/certs:/certs:z" \
    localhost/lucy-teamcloud-onprem-init-secrets:offline; then
    ok "init-secrets completed"
  else
    fail_msg "init-secrets failed"
  fi
}

prepare_and_validate_directories() {
  prepare_bind_mount_directories "secrets nginx/certs license" "postgres/data git/data broker/data broker/logs"
}

run_compose_up() {
  log "Starting Podman Compose services..."
  compose up -d --no-build
}

parse_args() {
  COMPOSE_UP=0
  ALLOW_IMMUTABLE_CHANGE=0
  ALLOW_CERT_HOST_MISMATCH=0
  SKIP_PORT_CHECK=0
  SKIP_IMAGE_CHECK=0
  SKIP_ARCH_CHECK=0
  SKIP_RESOURCE_CHECK=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        echo "preflight-podman.sh $SCRIPT_VERSION"
        exit 0
        ;;
      --compose-up)
        COMPOSE_UP=1
        ;;
      --allow-immutable-change)
        ALLOW_IMMUTABLE_CHANGE=1
        ;;
      --allow-cert-host-mismatch)
        ALLOW_CERT_HOST_MISMATCH=1
        ;;
      --skip-port-check)
        SKIP_PORT_CHECK=1
        ;;
      --skip-image-check)
        SKIP_IMAGE_CHECK=1
        ;;
      --skip-arch-check)
        SKIP_ARCH_CHECK=1
        ;;
      --skip-resource-check)
        SKIP_RESOURCE_CHECK=1
        ;;
      *)
        die "Unknown argument: $1

Run './scripts/preflight-podman.sh --help' for usage."
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  FAILURES=0

  require_cmd docker
  require_cmd podman
  require_cmd awk
  require_cmd sed
  require_cmd sort
  require_cmd grep

  docker info >/dev/null 2>&1 || die "Podman is not running or current user cannot access it through docker CLI."
  docker compose version >/dev/null 2>&1 || die "podman-compose provider is not available. Check: docker compose version"

  local sdir
  sdir="$(script_dir)"

  ROOT_DIR="$(resolve_project_root "$sdir")"
  cd "$ROOT_DIR"

  detect_compose_files
  build_compose_args

  log "Project root: $ROOT_DIR"
  log "Compose files, in merge order:$(join_by_space_quoted "${COMPOSE_FILE_LIST[@]}")"

  validate_docker_versions
  validate_resources
  validate_required_env
  validate_urls
  validate_admin_name
  prepare_and_validate_directories
  validate_license
  validate_compose_config
  validate_ports
  validate_local_images
  validate_image_architectures
  prepare_init_secrets_outputs
  validate_certificates
  validate_immutable_env_lock

  if [ "$FAILURES" -gt 0 ]; then
    die "Preflight failed with $FAILURES failure(s). Fix them before running docker compose up."
  fi

  log "Preflight passed."
  write_immutable_env_lock_after_success

  if [ "$COMPOSE_UP" = "1" ]; then
    run_compose_up
  else
    cat <<EOF

Next step:
  cd "$ROOT_DIR"
  ./scripts/onprem-compose-podman.sh up

Or run:
  ./scripts/preflight-podman.sh --compose-up

EOF
  fi
}

main "$@"
