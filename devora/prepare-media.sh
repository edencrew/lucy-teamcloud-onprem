#!/usr/bin/env bash
# Online (connected build host) preparation of Devora offline media. Never run on the target.
#   prepare-media.sh <docker|podman> --be-repo DIR --be-image REF --out DIR
# Exports the exact BE commit with git archive, builds linux/amd64, verifies arch/commit, saves the
# actual BE image plus pgvector/redis, copies db/init + docs, and writes PROVENANCE.txt/SHA256SUMS.
# The build is NOT bit-reproducible (uv.lock unused, floating deps / HF revisions): the saved image
# checksum is the frozen artefact, not the build recipe.
set -Eeuo pipefail
umask 022

BE_COMMIT="e196ad2aa8c3a5a1f130e443e6173af180304cee"
BE_TREE="1528a3b84799db085aad24b6edf7b4c081b483e7"

die() { printf 'prepare-media: ERROR: %s\n' "$*" >&2; exit 1; }
USAGE="usage: prepare-media.sh <docker|podman> [--existing-image] --be-repo DIR --be-image REF --out DIR"
MODE=build
if [ "${2:-}" = --existing-image ]; then MODE=existing; set -- "$1" "${@:3}"; fi
[ $# -eq 7 ] || die "$USAGE"
RUNTIME="$1"; shift
case "$RUNTIME" in docker) PG=pgvector/pgvector:pg16; RD=redis/redis-stack-server:7.4.0-v3 ;;
  podman) PG=docker.io/pgvector/pgvector:pg16; RD=docker.io/redis/redis-stack-server:7.4.0-v3 ;;
  *) die "runtime must be docker or podman" ;; esac
REPO=""; IMG=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in --be-repo) REPO="$2" ;; --be-image) IMG="$2" ;; --out) OUT="$2" ;; *) die "unknown arg $1" ;; esac
  shift 2
done
[ -n "$IMG" ] || die "--be-image required (no default)"
[ -d "$OUT" ] && [ -z "$(ls -A "$OUT")" ] || die "--out must be an existing empty directory"
[ "$(git -C "$REPO" rev-parse "$BE_COMMIT^{tree}")" = "$BE_TREE" ] || die "BE tree mismatch"

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# Docker 28+ supports image inspect/save --platform (Docker Desktop's containerd store reports the
# index/manifest digest as .Id). Classic Docker without it and Podman save the single local image.
PLAT=()
if [ "$RUNTIME" = docker ] && docker image save --help 2>/dev/null | grep -q -- '--platform'; then PLAT=(--platform linux/amd64); fi
# Presence is checked WITHOUT --platform so an existing wrong-arch ref is never treated as missing and
# overwritten. 0 = present, 1 = proved missing; any other inspect error dies (fail closed).
img_exists() {
  local err
  err="$("$RUNTIME" image inspect "$1" 2>&1 >/dev/null)" && return 0
  case "$err" in *"No such image"*|*"image not known"*|*"no such image"*) return 1 ;; esac
  die "cannot determine whether $1 exists: $err"
}
img_fmt() { "$RUNTIME" image inspect ${PLAT[@]+"${PLAT[@]}"} -f "$2" "$1"; }

# Canonical ID = sha256 of the image config bytes in a local save of REF (never runtime .Id). The
# archive must hold exactly one image whose config path names that same digest; else fail closed.
config_id() {
  local t cfg n hex
  t="$(mktemp -d)"
  "$RUNTIME" image save ${PLAT[@]+"${PLAT[@]}"} -o "$t/i.tar" "$1" >/dev/null || { rm -rf "$t"; die "cannot save $1"; }
  tar -xf "$t/i.tar" -C "$t" manifest.json || { rm -rf "$t"; die "no manifest.json in save of $1"; }
  n="$(grep -o '"Config":"[^"]*"' "$t/manifest.json" | wc -l | tr -d ' ')"
  [ "$n" = 1 ] || { rm -rf "$t"; die "save of $1 is ambiguous ($n images)"; }
  cfg="$(grep -o '"Config":"[^"]*"' "$t/manifest.json" | sed 's/^"Config":"//; s/"$//')"
  tar -xf "$t/i.tar" -C "$t" "$cfg" || { rm -rf "$t"; die "config $cfg missing in save of $1"; }
  hex="$(sha256_of "$t/$cfg")"; rm -rf "$t"
  case "$cfg" in *"$hex"*) ;; *) die "config path $cfg does not match its digest for $1" ;; esac
  printf 'sha256:%s\n' "$hex"
}

if [ "$MODE" = existing ]; then
  # Explicit reuse: NO build/pull/tag of any ref; every ref must already exist locally.
  for r in "$IMG" "$PG" "$RD"; do img_exists "$r" || die "existing-image mode: $r not present locally (no pull)"; done
  [ "$(img_fmt "$IMG" '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$BE_COMMIT" ] \
    || die "existing $IMG lacks org.opencontainers.image.revision=$BE_COMMIT"
  rm -rf "$OUT/.source"
  SRC="$OUT/.source"; mkdir -p "$SRC"
  git -C "$REPO" archive "$BE_COMMIT" | tar -x -C "$SRC"
else
  img_exists "$IMG" && die "$IMG already exists; refusing to overwrite (use --existing-image or a fresh ref)"
  SRC="$OUT/.source"; mkdir -p "$SRC"
  git -C "$REPO" archive "$BE_COMMIT" | tar -x -C "$SRC"
  if [ "$RUNTIME" = docker ]; then
    docker buildx build --platform linux/amd64 --build-arg SOURCE_COMMIT="$BE_COMMIT" -f "$SRC/Dockerfile" --load -t "$IMG" "$SRC"
  else
    podman build --platform linux/amd64 --build-arg SOURCE_COMMIT="$BE_COMMIT" -f "$SRC/Dockerfile" -t "$IMG" "$SRC"
  fi
  # Missing-only pull: an existing pgvector/redis ref is kept as is (identity checked below).
  for r in "$PG" "$RD"; do img_exists "$r" || "$RUNTIME" pull --platform linux/amd64 "$r"; done
fi
for r in "$IMG" "$PG" "$RD"; do
  [ "$(img_fmt "$r" '{{.Os}}/{{.Architecture}}')" = linux/amd64 ] || die "image $r is not linux/amd64"
done
[ "$("$RUNTIME" run --rm ${PLAT[@]+"${PLAT[@]}"} --entrypoint cat "$IMG" app/commit_sha.txt | tr -d '\r\n ')" = "$BE_COMMIT" ] \
  || die "image commit_sha.txt mismatch"

inv_line() { # "REF sha256:<config digest> linux/amd64"
  local id
  id="$(config_id "$1")" && [ -n "$id" ] || return 1 # never emit a blank-ID line
  printf '%s %s linux/amd64\n' "$1" "$id"
}

mkdir -p "$OUT/images" "$OUT/db/init"
printf '%s\n' "$IMG" "$PG" "$RD" > "$OUT/images/devora-images.txt"
{ inv_line "$IMG" && inv_line "$PG" && inv_line "$RD"; } > "$OUT/images/devora-images.inventory" \
  || die "cannot determine canonical config ID for inventory"
# podman save without -m stores the extra names as additional tags of the first image only.
if [ "$RUNTIME" = podman ]; then
  podman save -m -o "$OUT/images/devora-images.tar" "$IMG" "$PG" "$RD"
else
  docker save ${PLAT[@]+"${PLAT[@]}"} -o "$OUT/images/devora-images.tar" "$IMG" "$PG" "$RD"
fi
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do
  cp "$SRC/db/init/$f" "$OUT/db/init/$f"
done
# docs are written straight from the git tree, not via tar -x/cp: macOS libarchive rewrites non-ASCII
# pax names to NFD, which would change the exact BE name bytes (e.g. docs/archive/오브제의 수명규칙_v1.0.md).
while IFS= read -r -d '' ent; do
  p="${ent#*$'\t'}"
  case "${ent%% *}" in 100644|100755) ;; *) die "unsupported git entry in docs (symlink/submodule): $p" ;; esac
  case "$p" in docs/*) ;; *) die "unexpected docs path: $p" ;; esac
  mkdir -p "$OUT/$(dirname "$p")"
  git -C "$REPO" show "$BE_COMMIT:$p" > "$OUT/$p"
done < <(git -C "$REPO" ls-tree -r -z "$BE_COMMIT" -- docs)
[ -d "$OUT/docs/spec" ] || die "BE docs/spec missing at commit"
rm -rf "$SRC"
# SHA256SUMS lines are "<64hex>  <path>"; the path is everything after the two separator spaces, so
# ordinary spaces (e.g. BE docs/archive/오브제의 수명규칙_v1.0.md) round-trip byte-exact. Reject only
# names that a line-based file cannot carry: tab/CR/LF, '..' or backslash.
bad="$(cd "$OUT" && find . -type f \( -name $'*\t*' -o -name $'*\n*' -o -name $'*\r*' -o -name '*..*' -o -name '*\\*' \) | head -n 1)"
[ -z "$bad" ] || die "unsupported file name in media (tab/CR/LF, '..' or backslash): $bad"
{
  printf 'be_commit=%s\n' "$BE_COMMIT"
  printf 'be_tree=%s\n' "$BE_TREE"
  printf 'be_image=%s\n' "$IMG"
  printf 'be_image_id=%s\n' "$(awk 'NR==1{print $2}' "$OUT/images/devora-images.inventory")"
  printf 'runtime=%s\n' "$RUNTIME"
} > "$OUT/PROVENANCE.txt"
# All sidecars must exist before SHA256SUMS: the installer rejects any file it does not cover.
printf '%s  %s\n' "$(sha256_of "$OUT/images/devora-images.tar")" devora-images.tar > "$OUT/images/devora-images.tar.sha256"
( cd "$OUT" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$OUT/SHA256SUMS"
echo "media ready: $OUT"
