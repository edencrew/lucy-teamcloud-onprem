#!/usr/bin/env bash

onprem_script_dir() {
  if [ -n "${ONPREM_SCRIPT_DIR:-}" ]; then
    printf '%s' "$ONPREM_SCRIPT_DIR"
    return 0
  fi

  local src="${BASH_SOURCE[1]}"
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

onprem_project_root() {
  local sdir="$1"
  local root

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

  (cd "$root" >/dev/null 2>&1 && pwd)
}

onprem_detect_compose_provider() {
  local raw
  raw="$(docker compose version 2>&1 || true)"

  if printf '%s\n' "$raw" | grep -Eiq 'podman-compose|podman version'; then
    printf '%s' "podman"
  else
    printf '%s' "docker"
  fi
}

onprem_detect_runtime() {
  local raw
  raw="$(docker version 2>&1 || true)"

  if printf '%s\n' "$raw" | grep -Eiq 'podman|libpod'; then
    printf '%s' "podman"
  else
    printf '%s' "docker"
  fi
}

onprem_detect_target() {
  local provider runtime
  provider="$(onprem_detect_compose_provider)"
  runtime="$(onprem_detect_runtime)"

  if [ "$provider" = "podman" ] || [ "$runtime" = "podman" ]; then
    printf '%s' "podman"
  else
    printf '%s' "docker"
  fi
}

onprem_exec_target_script() {
  local target="$1"
  local kind="$2"
  shift 2

  local sdir script
  sdir="$(onprem_script_dir)"
  script="$sdir/${kind}-${target}.sh"

  if [ ! -x "$script" ]; then
    printf '\033[1;31m[ERROR]\033[0m target script is not executable: %s\n' "$script" >&2
    exit 1
  fi

  exec "$script" "$@"
}
