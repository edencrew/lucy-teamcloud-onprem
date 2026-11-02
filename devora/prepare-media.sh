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
[ $# -eq 7 ] || die "usage: prepare-media.sh <docker|podman> --be-repo DIR --be-image REF --out DIR"
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

SRC="$OUT/.source"; mkdir -p "$SRC"
git -C "$REPO" archive "$BE_COMMIT" | tar -x -C "$SRC"
if [ "$RUNTIME" = docker ]; then
  docker buildx build --platform linux/amd64 --build-arg SOURCE_COMMIT="$BE_COMMIT" -f "$SRC/Dockerfile" --load -t "$IMG" "$SRC"
else
  podman build --platform linux/amd64 --build-arg SOURCE_COMMIT="$BE_COMMIT" -f "$SRC/Dockerfile" -t "$IMG" "$SRC"
fi
[ "$("$RUNTIME" image inspect -f '{{.Architecture}}' "$IMG")" = amd64 ] || die "image arch is not amd64"
[ "$("$RUNTIME" run --rm --entrypoint cat "$IMG" app/commit_sha.txt | tr -d '\r\n ')" = "$BE_COMMIT" ] \
  || die "image commit_sha.txt mismatch"
"$RUNTIME" pull --platform linux/amd64 "$PG"
"$RUNTIME" pull --platform linux/amd64 "$RD"

inv_line() { # "REF sha256:<64hex> linux/amd64" from the actual local image
  local id plat
  read -r id plat <<<"$("$RUNTIME" image inspect -f '{{.Id}} {{.Os}}/{{.Architecture}}' "$1")" || true
  id="sha256:${id#sha256:}"
  printf '%s' "$id" | grep -Eqx 'sha256:[0-9a-f]{64}' || die "image id for $1 is not a full sha256"
  [ "$plat" = linux/amd64 ] || die "image $1 platform is not linux/amd64"
  printf '%s %s %s\n' "$1" "$id" "$plat"
}

mkdir -p "$OUT/images" "$OUT/db/init"
printf '%s\n' "$IMG" "$PG" "$RD" > "$OUT/images/devora-images.txt"
{ inv_line "$IMG"; inv_line "$PG"; inv_line "$RD"; } > "$OUT/images/devora-images.inventory"
# podman save without -m stores the extra names as additional tags of the first image only.
if [ "$RUNTIME" = podman ]; then
  podman save -m -o "$OUT/images/devora-images.tar" "$IMG" "$PG" "$RD"
else
  docker save -o "$OUT/images/devora-images.tar" "$IMG" "$PG" "$RD"
fi
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do
  cp "$SRC/db/init/$f" "$OUT/db/init/$f"
done
cp -R "$SRC/docs" "$OUT/docs"
[ -d "$OUT/docs/spec" ] || die "BE docs/spec missing at commit"
rm -rf "$SRC"
# SHA256SUMS consumers parse "<hash>  <path>" by whitespace; reject names they cannot round-trip.
bad="$(cd "$OUT" && find . -type f \( -name '*[[:space:]]*' -o -name '*..*' -o -name '*\\*' \) | head -n 1)"
[ -z "$bad" ] || die "unsupported file name in media (whitespace, '..' or backslash): $bad"
{
  printf 'be_commit=%s\n' "$BE_COMMIT"
  printf 'be_tree=%s\n' "$BE_TREE"
  printf 'be_image=%s\n' "$IMG"
  printf 'be_image_id=%s\n' "$("$RUNTIME" image inspect -f '{{.Id}}' "$IMG")"
  printf 'runtime=%s\n' "$RUNTIME"
} > "$OUT/PROVENANCE.txt"
# All sidecars must exist before SHA256SUMS: the installer rejects any file it does not cover.
printf '%s  %s\n' "$(sha256_of "$OUT/images/devora-images.tar")" devora-images.tar > "$OUT/images/devora-images.tar.sha256"
( cd "$OUT" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$OUT/SHA256SUMS"
echo "media ready: $OUT"
