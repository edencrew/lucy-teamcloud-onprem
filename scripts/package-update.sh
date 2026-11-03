#!/usr/bin/env bash
# TeamCloud 업데이트 패키지(manifest schema 1) 생성기. 빌드 호스트에서만 실행한다.
# 대상 호스트는 `teamcloud-installer ops verify|stage|load|plan|apply` 로만 소비한다.
# 이 스크립트는 이미지/컨테이너 명령을 실행하지 않는다 (이미 저장된 tar 만 읽음).
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.0"
PLATFORM="linux/amd64"
ARCH="amd64"

log() { printf '[INFO] %s\n' "$*"; }
die() {
  printf '[ERROR] %s\n' "$*" >&2
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then
    printf '[ERROR] 작업 디렉터리를 조사용으로 남겨 둡니다: %s\n' "$STAGE" >&2
  fi
  exit 1
}

show_help() {
  cat <<'EOF'
package-update.sh — TeamCloud 업데이트 패키지(manifest schema 1) 생성

USAGE
  scripts/package-update.sh \
    --runtime docker|podman \
    --source-repo PATH --commit SHA40 [--ref vX.Y.Z] [--version X.Y.Z] \
    --image-tar PATH/NAME.tar \
    --manifest-tool PATH \
    --compose-binary PATH \
    --output-dir DIR

OPTIONS
  --runtime NAME        docker 또는 podman (패키지마다 하나)
  --source-repo PATH    lucy-teamcloud-onprem Git 저장소 (작업 트리 상태는 사용하지 않음)
  --commit SHA40        정확한 소스 커밋 (40자리 소문자 hex)
  --ref REF             선택. vX.Y.Z 이며 --commit 과 같은 커밋이어야 함
                        생략 시 manifest source_ref 는 v<--version> 릴리스 라벨 (Git 태그 검증 아님)
  --version VER         제품(payload) 버전. 기본값 없음: 생략하면 --ref 에서 유도, 둘 다 주면 일치해야 함
  --image-tar PATH      docker/podman save 로 만든 비압축 tar (이름: [A-Za-z0-9._-]+.tar)
  --manifest-tool PATH  빌드 호스트에서 실행 가능한 teamcloud-installer (ops manifest 사용)
  --compose-binary PATH 빌드 호스트의 standalone Compose CLI (docker-compose). `config --images` 만
                        실행하며 엔진 연결/pull/save/load/up 은 하지 않음
  --output-dir DIR      이미 존재하는 출력 디렉터리. 같은 이름이 있으면 중단 (덮어쓰지 않음)
  -h, --help            도움말
  -V, --script-version  스크립트 버전

OUTPUT
  DIR/teamcloud-update-v<VER>-linux-amd64-<runtime>.tar.gz(.sha256)
  항목 순서: manifest.json(첫 항목), payload/<허용 목록 파일>, images/<NAME>.tar
  .env/local/비밀값/라이선스/인증서/데이터/백업은 넣지 않는다.

IMAGE SET CHECK
  커밋의 compose 파일(런타임 main + podman 은 init-secrets)과 payload/.env.example 로
  `config --images` 를 구한 이미지 집합이 --image-tar 의 manifest.json RepoTags 집합과
  정확히 같아야 한다. 동등한 Docker Hub 별칭(docker.io/library/x, index.docker.io/x, x)과
  태그 생략(:latest)만 정규화한다. 다르면 패키지를 쓰기 전에 중단한다.
EOF
}

RUNTIME=""
REPO=""
COMMIT=""
REF=""
VERSION=""
IMAGE_TAR=""
TOOL=""
COMPOSE=""
OUTPUT_DIR=""

need_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 에 값이 필요합니다"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -V|--script-version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    --runtime) need_arg "$@"; RUNTIME="$2"; shift 2 ;;
    --source-repo) need_arg "$@"; REPO="$2"; shift 2 ;;
    --commit) need_arg "$@"; COMMIT="$2"; shift 2 ;;
    --ref) need_arg "$@"; REF="$2"; shift 2 ;;
    --version) need_arg "$@"; VERSION="$2"; shift 2 ;;
    --image-tar) need_arg "$@"; IMAGE_TAR="$2"; shift 2 ;;
    --manifest-tool) need_arg "$@"; TOOL="$2"; shift 2 ;;
    --compose-binary) need_arg "$@"; COMPOSE="$2"; shift 2 ;;
    --output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    *) die "알 수 없는 인자: $1 (--help 참고)" ;;
  esac
done

# ---------- helpers ----------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "필요한 명령이 없습니다: $1"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

abs_dir() { (cd -P "$1" >/dev/null 2>&1 && pwd); }

# Canonicalises image refs on stdin, one per line. Only equivalent Docker Hub
# aliases and an omitted tag (:latest) are folded; other registries/tags stay exact.
normalize_refs() {
  awk '
    NF == 0 { next }
    {
      r = $0; hub = 0; i = index(r, "/")
      if (i == 0) { hub = 1 }
      else {
        first = substr(r, 1, i - 1)
        if (first == "docker.io" || first == "index.docker.io" || first == "registry-1.docker.io") { hub = 1; r = substr(r, i + 1) }
        else if (first !~ /[.:]/ && first != "localhost") { hub = 1 }
      }
      if (hub && index(r, "/") == 0) r = "library/" r
      last = r; sub(/.*\//, "", last)
      if (last !~ /[:@]/) r = r ":latest"
      print (hub ? "docker.io/" : "") r
    }' | LC_ALL=C sort -u
}

regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# ---------- argument validation ----------
case "$RUNTIME" in
  docker) RUNTIME_FILES="compose.docker.yml compose.docker.init-secrets.yml scripts/load-compose-images-docker.sh"
          COMPOSE_FILES="compose.docker.yml compose.docker.init-secrets.yml" ;;
  podman) RUNTIME_FILES="compose.podman.yml compose.podman.init-secrets.yml scripts/load-compose-images-podman.sh"
          COMPOSE_FILES="compose.podman.yml compose.podman.init-secrets.yml" ;;
  *) die "--runtime 은 docker 또는 podman 이어야 합니다" ;;
esac
if [ -z "$VERSION" ]; then
  case "$REF" in
    v[0-9]*) VERSION="${REF#v}" ;;
    *) die "--version 또는 vX.Y.Z 형식의 --ref 가 필요합니다 (기본값 없음)" ;;
  esac
elif [ -n "$REF" ] && [ "$REF" != "v$VERSION" ]; then
  die "--ref $REF 가 --version v$VERSION 과 다릅니다"
fi
case "$VERSION" in
  *[!0-9.]*|'') die "--version 형식 오류: $VERSION" ;;
esac
case "$COMMIT" in
  *[!0-9a-f]*|'') die "--commit 은 40자리 소문자 hex 여야 합니다" ;;
esac
[ "${#COMMIT}" -eq 40 ] || die "--commit 은 40자리 소문자 hex 여야 합니다"
[ -n "$REPO" ] || die "--source-repo 가 필요합니다"
[ -n "$IMAGE_TAR" ] || die "--image-tar 가 필요합니다"
[ -n "$TOOL" ] || die "--manifest-tool 이 필요합니다"
[ -n "$COMPOSE" ] || die "--compose-binary 가 필요합니다 (이미지 집합 검증)"
[ -n "$OUTPUT_DIR" ] || die "--output-dir 이 필요합니다"

for c in git tar gzip awk find mktemp sort comm cmp grep sed tr wc; do require_cmd "$c"; done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "sha256sum 또는 shasum 이 필요합니다"

[ -d "$REPO" ] && [ ! -L "$REPO" ] || die "--source-repo 디렉터리가 아닙니다: $REPO"
REPO="$(abs_dir "$REPO")"
[ -n "$REPO" ] || die "--source-repo 경로를 해석할 수 없습니다"
[ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ] || die "--output-dir 은 이미 존재하는 디렉터리여야 합니다: $OUTPUT_DIR"
OUTPUT_DIR="$(abs_dir "$OUTPUT_DIR")"
regular_file "$TOOL" && [ -x "$TOOL" ] || die "--manifest-tool 실행 파일이 아닙니다: $TOOL"
TOOL="$(abs_dir "$(dirname "$TOOL")")/$(basename "$TOOL")"
regular_file "$COMPOSE" && [ -x "$COMPOSE" ] || die "--compose-binary 실행 파일이 아닙니다: $COMPOSE"
COMPOSE="$(abs_dir "$(dirname "$COMPOSE")")/$(basename "$COMPOSE")"
regular_file "$IMAGE_TAR" || die "--image-tar 일반 파일이 아닙니다: $IMAGE_TAR"
IMAGE_NAME="$(basename "$IMAGE_TAR")"
case "$IMAGE_NAME" in
  *[!A-Za-z0-9._-]*|.tar|'') die "--image-tar 이름 형식 오류: $IMAGE_NAME" ;;
  *.tar) ;;
  *) die "--image-tar 는 비압축 .tar 여야 합니다: $IMAGE_NAME" ;;
esac
IMAGE_TAR="$(abs_dir "$(dirname "$IMAGE_TAR")")/$IMAGE_NAME"

PKG_NAME="teamcloud-update-v${VERSION}-linux-${ARCH}-${RUNTIME}"
OUT="$OUTPUT_DIR/$PKG_NAME.tar.gz"
OUT_SUM="$OUT.sha256"
for p in "$OUT" "$OUT_SUM" "$OUT.partial" "$OUT_SUM.partial"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    die "출력 경로가 이미 있습니다 (덮어쓰지 않음): $p"
  fi
done

# Capabilities the new split-init source requires (installer/manifest.go OpsCapabilities).
# manifest.ComposeFiles stays the normal base only; the init file is bootstrap-only payload.
REQUIRES="manifest-v1,kit-format-2,split-init-secrets,receipt-identity"

# Mirrors installer/manifest.go ProductFiles for this runtime (allowlist, never a directory copy).
SOURCE_FILES="$RUNTIME_FILES .env.example init-secrets/Dockerfile init-secrets/docker-entrypoint.sh nginx/nginx.conf nginx/nginx.http.conf git/app.ini git/gitea-entrypoint.sh auth/auth-entrypoint.sh tc/tc-entrypoint.sh broker/mosquitto.conf postgres/initdb/01-create-user.sh studio-dl/nginx.conf scripts/studio-upload.sh"

# Optional Devora add-on (devora/INTERFACE.md). Selected only when DEVORA_ENV_FILE and DEVORA_MEDIA_DIR
# are both set; both unset keeps the TC-only package byte-identical. The env file is validated only
# (never copied, never printed); media is never part of the product payload (kit root devora-media/).
DEVORA_FILES="devora/compose.docker.yml devora/compose.podman.yml devora/.env.example devora/manage.sh devora/README.md devora/INTERFACE.md"
DEVORA=0
if [ -n "${DEVORA_ENV_FILE:-}" ] || [ -n "${DEVORA_MEDIA_DIR:-}" ]; then
  [ -n "${DEVORA_ENV_FILE:-}" ] && [ -n "${DEVORA_MEDIA_DIR:-}" ] \
    || die "DEVORA_ENV_FILE 와 DEVORA_MEDIA_DIR 는 둘 다 지정하거나 둘 다 비워야 합니다"
  case "$DEVORA_ENV_FILE" in /*) ;; *) die "DEVORA_ENV_FILE 은 절대 경로여야 합니다" ;; esac
  case "$DEVORA_MEDIA_DIR" in /*) ;; *) die "DEVORA_MEDIA_DIR 은 절대 경로여야 합니다" ;; esac
  regular_file "$DEVORA_ENV_FILE" || die "DEVORA_ENV_FILE 이 일반 파일이 아니거나 심볼릭 링크입니다"
  [ "$(stat -c '%a' "$DEVORA_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$DEVORA_ENV_FILE")" = "600" ] \
    || die "DEVORA_ENV_FILE 은 mode 0600 이어야 합니다"
  [ -d "$DEVORA_MEDIA_DIR" ] && [ ! -L "$DEVORA_MEDIA_DIR" ] || die "DEVORA_MEDIA_DIR 이 디렉터리가 아니거나 심볼릭 링크입니다"
  DEVORA=1
  REQUIRES="$REQUIRES,devora-optional"
  SOURCE_FILES="$SOURCE_FILES $DEVORA_FILES"
  log "Devora 선택됨: payload 에 devora/ 6개 파일 추가, requires +devora-optional"
fi

# ---------- source commit ----------
got="$(git -C "$REPO" rev-parse --verify --quiet "${COMMIT}^{commit}" 2>/dev/null || true)"
[ "$got" = "$COMMIT" ] || die "커밋을 찾을 수 없습니다: $COMMIT"
if [ -n "$REF" ]; then
  got="$(git -C "$REPO" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null || true)"
  [ "$got" = "$COMMIT" ] || die "--ref $REF 는 $COMMIT 가 아닙니다 (${got:-없음})"
fi
log "소스 커밋: $COMMIT${REF:+ ($REF)}"
[ -n "$REF" ] || log "경고: --ref 없음. source_ref=v$VERSION 은 --version 에서 만든 릴리스 라벨이며 Git 태그로 검증되지 않음 (출처는 source_commit)"

# ---------- staging ----------
STAGE="$(mktemp -d "$OUTPUT_DIR/.teamcloud-update-staging.XXXXXX")" || die "작업 디렉터리를 만들 수 없습니다"
[ -n "$STAGE" ] && [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die "작업 디렉터리 확인 실패"
chmod 700 "$STAGE"
PKG="$STAGE/pkg"
mkdir "$PKG" "$PKG/payload" "$PKG/images"

# shellcheck disable=SC2086
git -C "$REPO" archive --format=tar -o "$STAGE/source.tar" "$COMMIT" -- $SOURCE_FILES \
  || die "git archive 실패 (커밋에 필요한 파일이 없을 수 있음)"
tar -tvf "$STAGE/source.tar" > "$STAGE/source.long"
while IFS= read -r line; do
  case "$line" in
    -*|d*) ;;
    *) die "소스 아카이브에 일반 파일/디렉터리가 아닌 항목이 있습니다: $line" ;;
  esac
done < "$STAGE/source.long"
tar -xf "$STAGE/source.tar" -C "$PKG/payload"
for rel in $SOURCE_FILES; do
  regular_file "$PKG/payload/$rel" || die "커밋에 필수 소스 파일이 없습니다: $rel"
done
[ -z "$(find "$PKG/payload" -mindepth 1 ! -type f ! -type d)" ] || die "payload 에 일반 파일/디렉터리가 아닌 항목이 있습니다"
find "$PKG/payload" -type d -exec chmod 755 {} +
find "$PKG/payload" -type f ! -name '*.sh' -exec chmod 644 {} +
find "$PKG/payload" -type f -name '*.sh' -exec chmod 755 {} +

# ---------- image set: exact source compose vs saved archive ----------
# Compose runs with a scrubbed environment and only the committed .env.example,
# so host COMPOSE_*/.env values cannot change the expected set. No engine is contacted.
mkdir "$STAGE/compose-home"
set --
for f in $COMPOSE_FILES; do set -- "$@" -f "$PKG/payload/$f"; done
(cd "$PKG/payload" && env -i PATH="$PATH" HOME="$STAGE/compose-home" DOCKER_CONFIG="$STAGE/compose-home" \
  "$COMPOSE" --project-directory "$PKG/payload" --env-file "$PKG/payload/.env.example" \
  -p teamcloud-package-verify "$@" config --images) > "$STAGE/images.compose.raw" \
  || die "compose config --images 실패"
tar -xOf "$IMAGE_TAR" manifest.json > "$STAGE/image-tar.manifest.json" 2>/dev/null \
  || die "--image-tar 에 manifest.json 이 없습니다 (docker/podman save 형식 아님)"
tr -d '\r\n' < "$STAGE/image-tar.manifest.json" \
  | grep -oE '"RepoTags"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
  | sed -E 's/^"RepoTags"[[:space:]]*:[[:space:]]*\[//; s/\]$//' \
  | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' > "$STAGE/images.archive.raw" || true
entries="$(tr -d '\r\n' < "$STAGE/image-tar.manifest.json" | grep -oE '"Config"[[:space:]]*:' | wc -l | tr -d ' ')"
tagged="$(tr -d '\r\n' < "$STAGE/image-tar.manifest.json" | grep -oE '"RepoTags"[[:space:]]*:[[:space:]]*\[[[:space:]]*"' | wc -l | tr -d ' ')"
[ "$entries" -ge 1 ] && [ "$entries" = "$tagged" ] || die "--image-tar 의 모든 이미지에 RepoTags 가 있어야 합니다 ($tagged/$entries)"
for raw in "$STAGE/images.compose.raw" "$STAGE/images.archive.raw"; do
  if grep -vE '^[A-Za-z0-9._/:@-]*$' "$raw" >/dev/null; then die "이미지 참조 형식 오류: $raw"; fi
done
normalize_refs < "$STAGE/images.compose.raw" > "$STAGE/images.compose"
normalize_refs < "$STAGE/images.archive.raw" > "$STAGE/images.archive"
[ -s "$STAGE/images.compose" ] || die "compose 이미지 집합이 비어 있습니다"
if ! cmp -s "$STAGE/images.compose" "$STAGE/images.archive"; then
  printf '[ERROR] 이미지 집합 불일치 (< compose 에만 / > 아카이브에만):\n' >&2
  comm -3 "$STAGE/images.compose" "$STAGE/images.archive" \
    | awk -F '\t' '{ if ($1 == "") print "  > " $2; else print "  < " $1 }' >&2
  die "소스 compose 이미지 집합과 --image-tar 가 다릅니다 (패키지를 쓰지 않음)"
fi
log "이미지 집합 일치: $(wc -l < "$STAGE/images.compose" | tr -d ' ')개"

if ! ln "$IMAGE_TAR" "$PKG/images/$IMAGE_NAME" 2>/dev/null; then
  cp "$IMAGE_TAR" "$PKG/images/$IMAGE_NAME"
fi

# The manifest tool validates the allowlist, reads real saved config bytes for
# digest/OS/arch and refuses symlinks/protected paths.
log "manifest 생성 (ops manifest)"
"$TOOL" ops manifest --runtime "$RUNTIME" --platform "$PLATFORM" --payload "$PKG/payload" \
  --image-tar "$PKG/images/$IMAGE_NAME" --payload-version "$VERSION" --source-ref "${REF:-v$VERSION}" \
  --source-commit "$COMMIT" --requires "$REQUIRES" --out "$PKG/manifest.json" || die "manifest 생성 실패"
grep -q '"kit-format-2"' "$PKG/manifest.json" && grep -q '"split-init-secrets"' "$PKG/manifest.json" \
  && grep -q '"receipt-identity"' "$PKG/manifest.json" || die "manifest 에 필수 capability 가 없습니다: $REQUIRES"
if [ "$DEVORA" -eq 1 ]; then
  grep -q '"devora-optional"' "$PKG/manifest.json" || die "manifest 에 devora-optional 이 없습니다"
elif grep -q '"devora-optional"\|devora/' "$PKG/manifest.json"; then
  die "Devora 미선택 manifest 에 devora 항목이 있습니다"
fi
regular_file "$PKG/manifest.json" || die "manifest.json 이 생성되지 않았습니다"

# ---------- write output (manifest.json first, no clobber) ----------
set -o noclobber
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TAR_OWNER="--owner=0 --group=0 --numeric-owner"
else
  TAR_OWNER="--uid 0 --gid 0 --uname root --gname root"
fi
# shellcheck disable=SC2086
(cd "$PKG" && COPYFILE_DISABLE=1 tar $TAR_OWNER -cf - manifest.json payload images) | gzip -n > "$OUT.partial" \
  || die "패키지 압축 작성 실패 (부분 파일: $OUT.partial)"
gzip -t "$OUT.partial" || die "작성한 패키지 gzip 검사 실패"
first="$(tar -tzf "$OUT.partial" | head -n 1)"
[ "$first" = "manifest.json" ] || die "패키지 첫 항목이 manifest.json 이 아닙니다: $first"
if tar -tzf "$OUT.partial" | grep -q '/\._\|^\._'; then die "패키지에 macOS 메타데이터 항목이 있습니다"; fi

ln "$OUT.partial" "$OUT" || die "출력 파일 생성 실패 (덮어쓰지 않음): $OUT"
rm "$OUT.partial"
printf '%s  %s\n' "$(sha256_of "$OUT")" "$PKG_NAME.tar.gz" > "$OUT_SUM.partial"
ln "$OUT_SUM.partial" "$OUT_SUM" || die "체크섬 파일 생성 실패 (덮어쓰지 않음): $OUT_SUM"
rm "$OUT_SUM.partial"
chmod 644 "$OUT" "$OUT_SUM"

log "완료"
printf '\n  패키지: %s\n  체크섬: %s\n  작업 폴더: %s (검증 후 직접 삭제 가능)\n\n' "$OUT" "$OUT_SUM" "$STAGE"
