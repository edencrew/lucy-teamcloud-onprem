#!/usr/bin/env bash
# TeamCloud 오프라인 설치 키트(런타임별) 생성기. 빌드(인터넷 가능) 호스트에서만 실행한다.
# 대상(폐쇄망) 호스트에는 Git/Go/Python/jq/네트워크가 필요 없다.
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.0"
PLATFORM="linux/amd64"
ARCH="amd64"
KIT_VERSION=""
INIT_IMAGE="lucy-teamcloud-onprem-init-secrets:offline"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  printf '[ERROR] %s\n' "$*" >&2
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then
    printf '[ERROR] 작업 디렉터리를 조사용으로 남겨 둡니다: %s\n' "$STAGE" >&2
  fi
  exit 1
}

show_help() {
  cat <<'EOF'
package-offline-installer.sh — TeamCloud 런타임별 오프라인 설치 키트 생성

USAGE
  scripts/package-offline-installer.sh \
    --runtime docker|podman \
    --source-repo PATH --commit SHA40 [--ref v0.0.22] \
    --installer-archive PATH \
    --image-bundle PATH/lucy-teamcloud-onprem-<runtime>-images-linux-amd64.tar.gz \
    --manifest-tool PATH --compose-binary PATH \
    --output-dir DIR [--kit-version 0.0.22] [--readme PATH] [--allow-repo-images-dir]

OPTIONS
  --runtime NAME           docker 또는 podman (키트마다 하나)
  --source-repo PATH       lucy-teamcloud-onprem Git 저장소 (작업 트리 상태는 사용하지 않음)
  --commit SHA40           키트에 넣을 정확한 커밋 (40자리 hex). git archive 로 추출
  --ref REF                선택. 지정하면 REF 가 --commit 과 같은 커밋인지 확인 (예: v0.0.22)
  --installer-archive PATH 기존 설치기 릴리스 아카이브(.tar.gz, 평면 일반 파일 9개 + SHA256SUMS)
  --image-bundle PATH      해당 런타임용 새 이미지 번들. 옆에 .tar.gz.sha256 과 .images.txt 필요
  --manifest-tool PATH     빌드 호스트에서 실행 가능한 teamcloud-installer (ops manifest/verify/version).
                           키트에 넣는 Linux 설치기는 빌드 호스트에서 실행하지 않음
  --compose-binary PATH    빌드 호스트의 standalone Compose CLI. `config` 해석만 (엔진/네트워크 불필요)
  --output-dir DIR         이미 존재하는 출력 디렉터리. 같은 이름의 키트/sha256 이 있으면 중단
  --kit-version VER        키트(제품) 버전. 기본값 없음: 생략하면 vX.Y.Z --ref 에서 유도, 둘 다 주면 일치해야 함
  --readme PATH            키트에 넣을 README.installer.md (기본: 이 스크립트 저장소의 파일)
  --allow-repo-images-dir  --source-repo/images 아래 번들 사용을 명시적으로 허용 (기본 거부)
  -h, --help               도움말
  -V, --script-version     스크립트 버전

OUTPUT
  DIR/teamcloud-offline-v<VER>-linux-amd64-<runtime>.tar.gz
  DIR/teamcloud-offline-v<VER>-linux-amd64-<runtime>.tar.gz.sha256

  압축 안의 최상위 폴더는 하나(teamcloud-offline-v<VER>-linux-amd64-<runtime>/)이며
  일반 파일과 디렉터리만 들어 있다. 발급 라이선스/.env/비밀값/인증서/데이터는 넣지 않는다.

  kit_format=2: product/teamcloud-initial.tar.gz 는 같은 커밋/이미지로 sibling package-update.sh 가
  만든 업데이트 형식 제품 패키지다 (manifest.json 첫 항목, requires kit-format-2,split-init-secrets,
  receipt-identity). 최초 TUI 설치는 이 패키지만 사용한다. KIT-INFO.txt 의 product_sha256 로 고정
  (ops verify 용 product/teamcloud-initial.tar.gz.sha256 사이드카도 같은 해시).
  커밋에 split init 파일(compose.<runtime>.init-secrets.yml)이 없으면 출력 전에 중단한다.

DEVORA (optional, default OFF)
  DEVORA_ENV_FILE(0600, 검증만 하고 키트에 넣지 않음) 와 DEVORA_MEDIA_DIR 를 둘 다 지정하면
  제품 payload 에 devora/ 6개 파일 + requires devora-optional, 키트 루트 devora-media/ 에 검증된 미디어,
  설치기 바이너리 마커 teamcloud-installer-contract:devora-optional:v1 를 요구한다. 하나만 지정하면 중단.

BUILD HOST REQUIREMENTS
  bash, git, tar, gzip, sha256sum 또는 shasum, --compose-binary, --manifest-tool (데몬/네트워크 불필요)
EOF
}

RUNTIME=""
REPO=""
COMMIT=""
REF=""
INSTALLER_ARCHIVE=""
BUNDLE=""
OUTPUT_DIR=""
README_SRC=""
ALLOW_REPO_IMAGES=0
TOOL=""
HOST_COMPOSE=""
PRODUCT_REL="product/teamcloud-initial.tar.gz"
PRODUCT_REQUIRES="kit-format-2 split-init-secrets receipt-identity"
# Fixed ASCII marker the target installer binary must embed (kit_format 2 producer/consumer contract).
INSTALLER_CONTRACT="teamcloud-installer-contract:kit-format-2:product-install:receipt-identity:v1"
# Optional Devora add-on (devora/INTERFACE.md): selected only by DEVORA_ENV_FILE + DEVORA_MEDIA_DIR.
DEVORA_CONTRACT="teamcloud-installer-contract:devora-optional:v1"
DEVORA_FILES="devora/compose.docker.yml devora/compose.podman.yml devora/.env.example devora/manage.sh devora/README.md devora/INTERFACE.md"
DEVORA_INIT_SQL="001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql"
DEVORA=0

need_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 에 값이 필요합니다"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -V|--script-version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    --runtime) need_arg "$@"; RUNTIME="$2"; shift 2 ;;
    --source-repo) need_arg "$@"; REPO="$2"; shift 2 ;;
    --commit) need_arg "$@"; COMMIT="$2"; shift 2 ;;
    --ref) need_arg "$@"; REF="$2"; shift 2 ;;
    --installer-archive) need_arg "$@"; INSTALLER_ARCHIVE="$2"; shift 2 ;;
    --image-bundle) need_arg "$@"; BUNDLE="$2"; shift 2 ;;
    --output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --manifest-tool) need_arg "$@"; TOOL="$2"; shift 2 ;;
    --compose-binary) need_arg "$@"; HOST_COMPOSE="$2"; shift 2 ;;
    --kit-version) need_arg "$@"; KIT_VERSION="$2"; shift 2 ;;
    --readme) need_arg "$@"; README_SRC="$2"; shift 2 ;;
    --allow-repo-images-dir) ALLOW_REPO_IMAGES=1; shift ;;
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

# regular, non-symlink file
regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

is_hex64() {
  case "$1" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# ELF64 little-endian x86-64 check (no `file` dependency)
is_elf_amd64() {
  local magic machine class
  magic="$(LC_ALL=C head -c 4 "$1" | od -An -tx1 | tr -d ' \n')"
  class="$(LC_ALL=C dd if="$1" bs=1 skip=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  machine="$(LC_ALL=C dd if="$1" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] && [ "$class" = "02" ] && [ "$machine" = "3e00" ]
}

# every `tar -tv` line must describe a regular file or directory
check_tar_types() {
  local listing="$1" what="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      -*|d*) ;;
      *) die "$what 에 일반 파일/디렉터리가 아닌 항목이 있습니다: $line" ;;
    esac
  done < "$listing"
}

# member names: relative, no '..', no leading '/'
check_tar_names() {
  local listing="$1" what="$2" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      /*) die "$what 에 절대 경로 항목이 있습니다: $name" ;;
    esac
    case "/$name/" in
      */../*) die "$what 에 '..' 경로 항목이 있습니다: $name" ;;
    esac
  done < "$listing"
}

normalize_images() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' \
      -e 's#^docker\.io/library/##' -e 's#^docker\.io/##' "$1" | LC_ALL=C sort -u
}

# ---------- argument validation ----------
case "$RUNTIME" in
  docker|podman) ;;
  *) die "--runtime 은 docker 또는 podman 이어야 합니다" ;;
esac
# No implicit default: the kit version is explicit or derived from an exact vX.Y.Z --ref.
if [ -z "$KIT_VERSION" ]; then
  case "$REF" in
    v[0-9]*) KIT_VERSION="${REF#v}" ;;
    *) die "--kit-version 또는 vX.Y.Z 형식의 --ref 가 필요합니다 (기본값 없음)" ;;
  esac
elif [ -n "$REF" ] && [ "$REF" != "v$KIT_VERSION" ]; then
  die "--ref $REF 가 --kit-version v$KIT_VERSION 과 다릅니다"
fi
case "$KIT_VERSION" in
  *[!0-9.]*|'') die "--kit-version 형식 오류: $KIT_VERSION" ;;
esac
case "$COMMIT" in
  *[!0-9a-f]*|'') die "--commit 은 40자리 소문자 hex 여야 합니다" ;;
esac
[ "${#COMMIT}" -eq 40 ] || die "--commit 은 40자리 소문자 hex 여야 합니다"
[ -n "$REPO" ] || die "--source-repo 가 필요합니다"
[ -n "$INSTALLER_ARCHIVE" ] || die "--installer-archive 가 필요합니다"
[ -n "$BUNDLE" ] || die "--image-bundle 이 필요합니다"
[ -n "$OUTPUT_DIR" ] || die "--output-dir 이 필요합니다"
[ -n "$TOOL" ] || die "--manifest-tool 이 필요합니다 (빌드 호스트용 teamcloud-installer, 제품 패키지 생성)"
[ -n "$HOST_COMPOSE" ] || die "--compose-binary 가 필요합니다 (빌드 호스트용 Compose CLI)"

for c in git tar gzip awk sed sort od dd head tr find cmp grep; do require_cmd "$c"; done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "sha256sum 또는 shasum 이 필요합니다"
regular_file "$TOOL" && [ -x "$TOOL" ] || die "--manifest-tool 실행 파일이 아닙니다: $TOOL"
TOOL="$(abs_dir "$(dirname "$TOOL")")/$(basename "$TOOL")"
regular_file "$HOST_COMPOSE" && [ -x "$HOST_COMPOSE" ] || die "--compose-binary 실행 파일이 아닙니다: $HOST_COMPOSE"
HOST_COMPOSE="$(abs_dir "$(dirname "$HOST_COMPOSE")")/$(basename "$HOST_COMPOSE")"
# Devora: both set selects, both unset keeps the TC-only kit unchanged, exactly one is an error.
# The env file is only validated here; it is never copied into the kit/product nor printed.
if [ -n "${DEVORA_ENV_FILE:-}" ] || [ -n "${DEVORA_MEDIA_DIR:-}" ]; then
  [ -n "${DEVORA_ENV_FILE:-}" ] && [ -n "${DEVORA_MEDIA_DIR:-}" ] \
    || die "DEVORA_ENV_FILE 와 DEVORA_MEDIA_DIR 는 둘 다 지정하거나 둘 다 비워야 합니다"
  DEVORA=1
  PRODUCT_REQUIRES="$PRODUCT_REQUIRES devora-optional"
fi
TOOL_CAPS="$("$TOOL" ops version 2>/dev/null | sed -n 's/^capabilities=//p')" || true
for cap in $PRODUCT_REQUIRES; do
  case ",$TOOL_CAPS," in
    *",$cap,"*) ;;
    *) die "--manifest-tool 이 $cap 을 지원하지 않습니다 (capabilities=${TOOL_CAPS:-없음})" ;;
  esac
done

[ -d "$REPO" ] && [ ! -L "$REPO" ] || die "--source-repo 디렉터리가 아닙니다: $REPO"
REPO="$(abs_dir "$REPO")"
[ -n "$REPO" ] || die "--source-repo 경로를 해석할 수 없습니다"
[ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ] || die "--output-dir 은 이미 존재하는 디렉터리여야 합니다: $OUTPUT_DIR"
OUTPUT_DIR="$(abs_dir "$OUTPUT_DIR")"
[ -n "$OUTPUT_DIR" ] || die "--output-dir 경로를 해석할 수 없습니다"

SCRIPT_DIR="$(abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$SCRIPT_DIR" ] || die "스크립트 위치를 해석할 수 없습니다"
[ -n "$README_SRC" ] || README_SRC="$SCRIPT_DIR/../README.installer.md"
regular_file "$README_SRC" || die "README.installer.md 일반 파일이 없습니다: $README_SRC"

KIT_NAME="teamcloud-offline-v${KIT_VERSION}-linux-${ARCH}-${RUNTIME}"
KIT_FILE="$KIT_NAME.tar.gz"
OUT="$OUTPUT_DIR/$KIT_FILE"
OUT_SUM="$OUT.sha256"
BUNDLE_NAME="lucy-teamcloud-onprem-${RUNTIME}-images-linux-${ARCH}.tar.gz"
if [ "$RUNTIME" = "podman" ]; then
  EXPECT_INIT="localhost/$INIT_IMAGE"
  OTHER_INIT="$INIT_IMAGE"
  COMPOSE_FILES="compose.podman.yml compose.podman.init-secrets.yml"
  RUNTIME_FILES="compose.podman.yml compose.podman.init-secrets.yml scripts/load-compose-images-podman.sh"
else
  EXPECT_INIT="$INIT_IMAGE"
  OTHER_INIT="localhost/$INIT_IMAGE"
  COMPOSE_FILES="compose.docker.yml compose.docker.init-secrets.yml"
  RUNTIME_FILES="compose.docker.yml compose.docker.init-secrets.yml scripts/load-compose-images-docker.sh"
fi
INIT_FILE="compose.$RUNTIME.init-secrets.yml"
# Mirrors the installer allowlist (runtime + common + Studio profile files).
SOURCE_FILES="$RUNTIME_FILES .env.example init-secrets/Dockerfile init-secrets/docker-entrypoint.sh nginx/nginx.conf nginx/nginx.http.conf git/app.ini git/gitea-entrypoint.sh auth/auth-entrypoint.sh tc/tc-entrypoint.sh broker/mosquitto.conf postgres/initdb/01-create-user.sh studio-dl/nginx.conf scripts/studio-upload.sh"

for p in "$OUT" "$OUT_SUM" "$OUT.partial" "$OUT_SUM.partial"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    die "출력 경로가 이미 있습니다 (덮어쓰지 않음): $p"
  fi
done

# ---------- source commit ----------
log "소스 저장소: $REPO"
got="$(git -C "$REPO" rev-parse --verify --quiet "${COMMIT}^{commit}" 2>/dev/null || true)"
[ "$got" = "$COMMIT" ] || die "커밋을 찾을 수 없습니다: $COMMIT"
if [ -n "$REF" ]; then
  got="$(git -C "$REPO" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null || true)"
  [ "$got" = "$COMMIT" ] || die "--ref $REF 는 $COMMIT 가 아닙니다 (${got:-없음})"
fi
log "소스 커밋: $COMMIT${REF:+ ($REF)}"
# kit_format 2 needs the split bootstrap file in the exact commit; legacy sources fail closed here.
git -C "$REPO" cat-file -e "$COMMIT:$INIT_FILE" 2>/dev/null \
  || die "커밋 $COMMIT 에 $INIT_FILE 이 없습니다: kit_format 2(split-init-secrets) 키트를 만들 수 없습니다"
if [ "$RUNTIME" = "docker" ] && git -C "$REPO" show "$COMMIT:compose.docker.yml" | grep -qE '^[[:space:]]+init-secrets:'; then
  die "커밋 $COMMIT 의 compose.docker.yml 에 init-secrets 가 남아 있습니다 (기본 파일 분리 전 소스)"
fi
SIBLING_UPDATE="$(abs_dir "$(dirname "${BASH_SOURCE[0]}")")/package-update.sh"
regular_file "$SIBLING_UPDATE" || die "sibling package-update.sh 가 없습니다: $SIBLING_UPDATE"

# ---------- image bundle (explicit, never implicit) ----------
regular_file "$BUNDLE" || die "이미지 번들 일반 파일이 아닙니다: $BUNDLE"
BUNDLE_DIR="$(abs_dir "$(dirname "$BUNDLE")")"
[ -n "$BUNDLE_DIR" ] || die "이미지 번들 경로를 해석할 수 없습니다"
[ "$(basename "$BUNDLE")" = "$BUNDLE_NAME" ] || die "번들 이름이 $BUNDLE_NAME 이 아닙니다: $(basename "$BUNDLE")"
BUNDLE="$BUNDLE_DIR/$BUNDLE_NAME"
case "$BUNDLE_DIR/" in
  "$REPO/images/"*)
    [ "$ALLOW_REPO_IMAGES" -eq 1 ] || die "소스 저장소 images/ 의 번들은 오래된 것일 수 있어 거부합니다. 새로 export 한 번들을 쓰거나 --allow-repo-images-dir 로 명시하세요"
    warn "소스 저장소 images/ 의 번들을 명시적 허용으로 사용합니다: $BUNDLE"
    ;;
esac
BUNDLE_SUM="$BUNDLE.sha256"
BUNDLE_LIST="${BUNDLE%.tar.gz}.images.txt"
regular_file "$BUNDLE_SUM" || die "번들 체크섬 파일이 없습니다: $BUNDLE_SUM"
regular_file "$BUNDLE_LIST" || die "번들 이미지 목록이 없습니다: $BUNDLE_LIST"
set -- $(cat "$BUNDLE_SUM")
[ "$#" -ge 1 ] && is_hex64 "$1" || die "번들 체크섬 형식 오류: $BUNDLE_SUM"
BUNDLE_EXPECT="$1"
if [ "$#" -ge 2 ]; then
  [ "${2#\*}" = "$BUNDLE_NAME" ] || die "번들 체크섬의 파일명이 다릅니다: $2"
fi
set --
log "번들 gzip 검사: $BUNDLE"
gzip -t "$BUNDLE" || die "번들 gzip 스트림이 손상되었습니다"
log "번들 SHA-256 계산"
BUNDLE_HASH="$(sha256_of "$BUNDLE")"
[ "$BUNDLE_HASH" = "$BUNDLE_EXPECT" ] || die "번들 SHA-256 불일치 (기대 $BUNDLE_EXPECT, 실제 $BUNDLE_HASH)"

# ---------- staging ----------
STAGE="$(mktemp -d "$OUTPUT_DIR/.teamcloud-kit-staging.XXXXXX")" || die "작업 디렉터리를 만들 수 없습니다"
[ -n "$STAGE" ] && [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die "작업 디렉터리 확인 실패"
chmod 700 "$STAGE"
WORK="$STAGE/work"
ROOT="$STAGE/kit/$KIT_NAME"
mkdir "$WORK" "$STAGE/kit" "$ROOT"
log "작업 디렉터리: $STAGE"

log "번들이 docker save 형식(manifest.json)인지 확인"
tar -tzf "$BUNDLE" > "$WORK/bundle.list" || die "번들 tar 목록을 읽을 수 없습니다"
grep -qx 'manifest.json' "$WORK/bundle.list" || die "번들에 manifest.json 이 없습니다 (docker save 형식 아님)"

# ---------- installer archive ----------
regular_file "$INSTALLER_ARCHIVE" || die "설치기 아카이브 일반 파일이 아닙니다: $INSTALLER_ARCHIVE"
INSTALLER_ARCHIVE="$(abs_dir "$(dirname "$INSTALLER_ARCHIVE")")/$(basename "$INSTALLER_ARCHIVE")"
gzip -t "$INSTALLER_ARCHIVE" || die "설치기 아카이브 gzip 손상"
if regular_file "$INSTALLER_ARCHIVE.sha256"; then
  set -- $(cat "$INSTALLER_ARCHIVE.sha256")
  [ "$#" -ge 1 ] && is_hex64 "$1" || die "설치기 아카이브 체크섬 형식 오류"
  [ "$(sha256_of "$INSTALLER_ARCHIVE")" = "$1" ] || die "설치기 아카이브 SHA-256 불일치"
  set --
  log "설치기 아카이브 외부 체크섬 일치"
else
  warn "설치기 아카이브 옆에 .sha256 이 없어 내부 SHA256SUMS 로만 검증합니다"
fi
INSTALLER_ARCHIVE_HASH="$(sha256_of "$INSTALLER_ARCHIVE")"
tar -tzf "$INSTALLER_ARCHIVE" > "$WORK/inst.names"
tar -tvzf "$INSTALLER_ARCHIVE" > "$WORK/inst.long"
check_tar_names "$WORK/inst.names" "설치기 아카이브"
check_tar_types "$WORK/inst.long" "설치기 아카이브"
[ "$(grep -c . "$WORK/inst.names")" -eq 9 ] || die "설치기 아카이브는 평면 일반 파일 9개여야 합니다 ($(grep -c . "$WORK/inst.names")개)"
while IFS= read -r n; do
  case "$n" in
    */*|.*|'') die "설치기 아카이브 항목이 평면 파일명이 아닙니다: $n" ;;
  esac
done < "$WORK/inst.names"
mkdir "$WORK/inst"
tar -xzf "$INSTALLER_ARCHIVE" -C "$WORK/inst"
[ -z "$(find "$WORK/inst" -mindepth 1 ! -type f)" ] || die "설치기 아카이브 추출 결과에 일반 파일이 아닌 항목이 있습니다"
regular_file "$WORK/inst/SHA256SUMS" || die "설치기 아카이브에 SHA256SUMS 가 없습니다"

INSTALLER_BIN=""
COMPOSE_BIN=""
LICENSES=""
DOCS=""
while IFS= read -r n; do
  f="$WORK/inst/$n"
  lower="$(printf '%s' "$n" | tr 'A-Z' 'a-z')"
  case "$n" in
    SHA256SUMS) continue ;;
    docker-compose-linux-amd64)
      [ -z "$COMPOSE_BIN" ] || die "docker-compose 바이너리가 둘 이상입니다"
      is_elf_amd64 "$f" || die "docker-compose-linux-amd64 가 Linux amd64 ELF 가 아닙니다"
      COMPOSE_BIN="$n"; continue ;;
    teamcloud-installer*.md|teamcloud-installer*.txt) ;;
    teamcloud-installer*)
      [ -z "$INSTALLER_BIN" ] || die "설치기 바이너리 후보가 둘 이상입니다: $INSTALLER_BIN, $n"
      is_elf_amd64 "$f" || die "설치기 바이너리가 Linux amd64 ELF 가 아닙니다: $n"
      INSTALLER_BIN="$n"; continue ;;
  esac
  case "$lower" in
    *.json) die "설치기 아카이브에 JSON 파일이 있습니다 (발급 라이선스 혼입 의심): $n" ;;
    *license*|*notice*|*copying*) LICENSES="$LICENSES $n" ;;
    *.md|*.txt|*.html|*.pdf) DOCS="$DOCS $n" ;;
    *) die "설치기 아카이브의 알 수 없는 파일: $n" ;;
  esac
done < "$WORK/inst.names"
[ -n "$INSTALLER_BIN" ] || die "설치기 바이너리(teamcloud-installer*)가 없습니다"
[ -n "$COMPOSE_BIN" ] || die "docker-compose-linux-amd64 가 없습니다"
[ -n "$LICENSES" ] || die "라이선스 고지 파일이 없습니다"
# The public installer version is unchanged across formats, so a kit_format 2 kit gates on the fixed
# contract marker embedded in the target binary (also printed as binary_contract by `ops version`).
# Byte scan only: the Linux binary is never executed here. This is an embedded capability declaration
# plus the recorded executable hash, not runtime behaviour or attestation proof.
LC_ALL=C grep -aFq "$INSTALLER_CONTRACT" "$WORK/inst/$INSTALLER_BIN" \
  || die "설치기 바이너리에 kit_format 2 계약 마커($INSTALLER_CONTRACT)가 없습니다: $INSTALLER_BIN (이전 릴리스 바이너리이거나 계약 반영 전 빌드입니다. 마커를 포함한 새 설치기 빌드를 사용하세요)"
if [ "$DEVORA" -eq 1 ]; then
  LC_ALL=C grep -aFq "$DEVORA_CONTRACT" "$WORK/inst/$INSTALLER_BIN" \
    || die "Devora 선택 키트이지만 설치기 바이너리에 $DEVORA_CONTRACT 마커가 없습니다: $INSTALLER_BIN"
fi
# installer version/capabilities are separate from the product version; record the actual binary hash
INSTALLER_BIN_HASH="$(sha256_of "$WORK/inst/$INSTALLER_BIN")"

# inner SHA256SUMS must cover exactly the other 8 files
: > "$WORK/inst.sumnames"
while read -r h n rest; do
  [ -n "${h:-}" ] || continue
  n="${n#\*}"
  [ -z "${rest:-}" ] || die "SHA256SUMS 형식 오류: $h $n $rest"
  is_hex64 "$h" || die "SHA256SUMS 해시 형식 오류: $n"
  case "$n" in */*|SHA256SUMS|'') die "SHA256SUMS 파일명 오류: $n" ;; esac
  regular_file "$WORK/inst/$n" || die "SHA256SUMS 의 파일이 아카이브에 없습니다: $n"
  [ "$(sha256_of "$WORK/inst/$n")" = "$h" ] || die "설치기 아카이브 내부 해시 불일치: $n"
  printf '%s\n' "$n" >> "$WORK/inst.sumnames"
done < "$WORK/inst/SHA256SUMS"
grep -vx 'SHA256SUMS' "$WORK/inst.names" | LC_ALL=C sort > "$WORK/a"
LC_ALL=C sort "$WORK/inst.sumnames" > "$WORK/b"
cmp -s "$WORK/a" "$WORK/b" || die "SHA256SUMS 가 아카이브의 나머지 8개 파일과 정확히 대응하지 않습니다"
log "설치기 아카이브 검증 완료: 바이너리=$INSTALLER_BIN compose=$COMPOSE_BIN 라이선스=${LICENSES# } (문서${DOCS:+:$DOCS} 는 키트에서 제외)"

# ---------- clean source tree from the exact commit ----------
# shellcheck disable=SC2086
git -C "$REPO" archive --format=tar -o "$WORK/source.tar" "$COMMIT" -- $SOURCE_FILES \
  || die "git archive 실패 (커밋에 필요한 파일이 없을 수 있음)"
tar -tf "$WORK/source.tar" > "$WORK/src.names"
tar -tvf "$WORK/source.tar" > "$WORK/src.long"
check_tar_names "$WORK/src.names" "소스 아카이브"
check_tar_types "$WORK/src.long" "소스 아카이브"
mkdir "$ROOT/source"
tar -xf "$WORK/source.tar" -C "$ROOT/source"
for rel in $SOURCE_FILES; do
  regular_file "$ROOT/source/$rel" || die "커밋에 필수 소스 파일이 없습니다: $rel"
done
[ -z "$(find "$ROOT/source" -mindepth 1 ! -type f ! -type d)" ] || die "소스 트리에 일반 파일/디렉터리가 아닌 항목이 있습니다"

# ---------- compose image set vs bundle sidecar ----------
log "Compose 이미지 집합 해석: $COMPOSE_FILES"
# Scrubbed environment: host COMPOSE_*/.env values cannot change the expected set. No engine is contacted.
mkdir "$WORK/compose-home"
set -- --project-directory "$ROOT/source" --env-file "$ROOT/source/.env.example" -p teamcloud-kit-verify
for f in $COMPOSE_FILES; do set -- "$@" -f "$ROOT/source/$f"; done
(cd "$ROOT/source" && env -i PATH="$PATH" HOME="$WORK/compose-home" DOCKER_CONFIG="$WORK/compose-home" \
  "$HOST_COMPOSE" "$@" config --quiet) || die "Compose 구성 해석 실패"
(cd "$ROOT/source" && env -i PATH="$PATH" HOME="$WORK/compose-home" DOCKER_CONFIG="$WORK/compose-home" \
  "$HOST_COMPOSE" "$@" config --images) > "$WORK/compose.images.raw" || die "Compose 이미지 목록 해석 실패"
set --
normalize_images "$WORK/compose.images.raw" > "$WORK/compose.images"
normalize_images "$BUNDLE_LIST" > "$WORK/bundle.images"
[ -s "$WORK/compose.images" ] || die "Compose 이미지 목록이 비어 있습니다"
if ! cmp -s "$WORK/compose.images" "$WORK/bundle.images"; then
  printf '[ERROR] Compose(-) 와 번들 목록(+) 차이:\n' >&2
  diff "$WORK/compose.images" "$WORK/bundle.images" >&2 || true
  die "이미지 번들 목록이 커밋 $COMMIT 의 $RUNTIME Compose 이미지 집합과 다릅니다"
fi
norm_init="$(printf '%s\n' "$EXPECT_INIT" | sed -e 's#^docker\.io/library/##' -e 's#^docker\.io/##')"
grep -qxF "$norm_init" "$WORK/bundle.images" || die "번들에 $EXPECT_INIT 가 없습니다 ($RUNTIME 번들 아님)"
if grep -qxF "$OTHER_INIT" "$WORK/bundle.images"; then die "번들에 다른 런타임 init 이미지($OTHER_INIT)가 있습니다"; fi
log "이미지 집합 일치: $(grep -c . "$WORK/bundle.images")개"

# ---------- modern product package (kit_format 2) ----------
# Same commit/ref/version and the verified bundle's saved tar, built by the sibling update packager.
IMAGE_TAR_NAME="${BUNDLE_NAME%.gz}"
mkdir "$WORK/product-images" "$WORK/product-out" "$ROOT/product"
gzip -dc "$BUNDLE" > "$WORK/product-images/$IMAGE_TAR_NAME" || die "이미지 번들 압축 해제 실패"
log "제품 패키지 생성 (package-update.sh)"
set -- --runtime "$RUNTIME" --source-repo "$REPO" --commit "$COMMIT" --version "$KIT_VERSION" \
  --image-tar "$WORK/product-images/$IMAGE_TAR_NAME" --manifest-tool "$TOOL" --compose-binary "$HOST_COMPOSE" \
  --output-dir "$WORK/product-out"
[ -z "$REF" ] || set -- "$@" --ref "$REF"
bash "$SIBLING_UPDATE" "$@" || die "제품 패키지 생성 실패"
set --
PRODUCT_BUILT="$WORK/product-out/teamcloud-update-v${KIT_VERSION}-linux-${ARCH}-${RUNTIME}.tar.gz"
regular_file "$PRODUCT_BUILT" || die "제품 패키지가 생성되지 않았습니다: $PRODUCT_BUILT"
cp "$PRODUCT_BUILT" "$ROOT/$PRODUCT_REL"
rm -f "$WORK/product-images/$IMAGE_TAR_NAME"
PRODUCT_HASH="$(sha256_of "$ROOT/$PRODUCT_REL")"
[ "$PRODUCT_HASH" = "$(awk '{print $1}' "$PRODUCT_BUILT.sha256")" ] || die "제품 패키지 체크섬 불일치"
# ops verify reads PKG.sha256 next to the package; the sidecar names the renamed inner file.
printf '%s  %s\n' "$PRODUCT_HASH" "$(basename "$PRODUCT_REL")" > "$ROOT/$PRODUCT_REL.sha256"

tar -tzf "$ROOT/$PRODUCT_REL" > "$WORK/product.names" || die "제품 패키지 목록을 읽을 수 없습니다"
tar -tvzf "$ROOT/$PRODUCT_REL" > "$WORK/product.long"
check_tar_names "$WORK/product.names" "제품 패키지"
check_tar_types "$WORK/product.long" "제품 패키지"
[ "$(head -n 1 "$WORK/product.names")" = "manifest.json" ] || die "제품 패키지 첫 항목이 manifest.json 이 아닙니다"
while IFS= read -r n; do
  n="${n#./}"; n="${n%/}"
  case "$n" in
    manifest.json|payload|images|"images/$IMAGE_TAR_NAME") continue ;;
    payload/*)
      rel="${n#payload/}"
      case " $SOURCE_FILES " in *" $rel "*) continue ;; esac
      case " $SOURCE_FILES" in *" $rel/"*) continue ;; esac
      if [ "$DEVORA" -eq 1 ]; then
        case " $DEVORA_FILES " in *" $rel "*) continue ;; esac
        [ "$rel" != devora ] || continue
      fi ;;
  esac
  die "제품 패키지에 허용 목록 밖 항목이 있습니다: $n"
done < "$WORK/product.names"
grep -qxF "payload/$INIT_FILE" "$WORK/product.names" || die "제품 패키지에 $INIT_FILE 이 없습니다"
if [ "$DEVORA" -eq 1 ]; then
  for rel in $DEVORA_FILES; do
    grep -qxF "payload/$rel" "$WORK/product.names" || die "Devora 선택 제품 패키지에 $rel 이 없습니다"
  done
fi
tar -xzOf "$ROOT/$PRODUCT_REL" manifest.json > "$WORK/product.manifest.json" || die "제품 manifest 를 읽을 수 없습니다"
for cap in $PRODUCT_REQUIRES; do
  grep -q "\"$cap\"" "$WORK/product.manifest.json" || die "제품 manifest 에 $cap 이 없습니다"
done
grep -q "\"$COMMIT\"" "$WORK/product.manifest.json" || die "제품 manifest 의 source commit 이 $COMMIT 가 아닙니다"
"$TOOL" ops verify --package "$ROOT/$PRODUCT_REL" || die "제품 패키지 ops verify 실패"
log "제품 패키지 검증 완료: $PRODUCT_REL sha256=$PRODUCT_HASH"

# ---------- assemble kit ----------
mkdir "$ROOT/source/images" "$ROOT/licenses"
if ! ln "$BUNDLE" "$ROOT/source/images/$BUNDLE_NAME" 2>/dev/null; then
  log "하드 링크 불가 — 번들을 복사합니다 (디스크 공간 필요)"
  cp "$BUNDLE" "$ROOT/source/images/$BUNDLE_NAME"
fi
[ "$(sha256_of "$ROOT/source/images/$BUNDLE_NAME")" = "$BUNDLE_HASH" ] || die "작업 디렉터리 번들 해시가 다릅니다"
cp "$BUNDLE_SUM" "$ROOT/source/images/$BUNDLE_NAME.sha256"
cp "$BUNDLE_LIST" "$ROOT/source/images/${BUNDLE_NAME%.tar.gz}.images.txt"
cp "$WORK/inst/$INSTALLER_BIN" "$ROOT/teamcloud-installer"
cp "$WORK/inst/$COMPOSE_BIN" "$ROOT/docker-compose-linux-amd64"
chmod 755 "$ROOT/teamcloud-installer" "$ROOT/docker-compose-linux-amd64"
for n in $LICENSES; do cp "$WORK/inst/$n" "$ROOT/licenses/$n"; done
cp "$README_SRC" "$ROOT/README.installer.md"

# ---------- optional Devora media (separate kit root devora-media/, never in the product) ----------
if [ "$DEVORA" -eq 1 ]; then
  case "$DEVORA_ENV_FILE" in /*) ;; *) die "DEVORA_ENV_FILE 은 절대 경로여야 합니다" ;; esac
  case "$DEVORA_MEDIA_DIR" in /*) ;; *) die "DEVORA_MEDIA_DIR 은 절대 경로여야 합니다" ;; esac
  regular_file "$DEVORA_ENV_FILE" || die "DEVORA_ENV_FILE 이 일반 파일이 아니거나 심볼릭 링크입니다"
  [ -d "$DEVORA_MEDIA_DIR" ] && [ ! -L "$DEVORA_MEDIA_DIR" ] || die "DEVORA_MEDIA_DIR 이 디렉터리가 아니거나 심볼릭 링크입니다"
  DM="$(abs_dir "$DEVORA_MEDIA_DIR")"
  [ -z "$(find "$DM" -mindepth 1 ! -type f ! -type d)" ] || die "Devora 미디어에 일반 파일/디렉터리가 아닌 항목(심볼릭 링크 등)이 있습니다"
  for f in PROVENANCE.txt SHA256SUMS images/devora-images.tar images/devora-images.txt; do
    regular_file "$DM/$f" || die "Devora 미디어에 $f 가 없습니다"
  done
  for f in $DEVORA_INIT_SQL; do regular_file "$DM/db/init/$f" || die "Devora 미디어에 db/init/$f 가 없습니다"; done
  [ "$(find "$DM/db/init" -mindepth 1 | wc -l | tr -d ' ')" = 3 ] || die "Devora db/init 는 정확히 $DEVORA_INIT_SQL 이어야 합니다"
  [ -d "$DM/docs/spec" ] && [ ! -L "$DM/docs/spec" ] || die "Devora 미디어에 docs/spec 이 없습니다"
  : > "$WORK/devora.sumnames"
  while read -r h n rest; do
    [ -n "${h:-}" ] || continue
    n="${n#\*}"
    [ -z "${rest:-}" ] && is_hex64 "$h" || die "Devora SHA256SUMS 형식 오류"
    case "/$n/" in //*|*/../*|*/./*) die "Devora SHA256SUMS 에 안전하지 않은 경로가 있습니다: $n" ;; esac
    regular_file "$DM/$n" || die "Devora SHA256SUMS 의 파일이 없습니다: $n"
    [ "$(sha256_of "$DM/$n")" = "$h" ] || die "Devora 미디어 해시 불일치: $n"
    printf '%s\n' "$n" >> "$WORK/devora.sumnames"
  done < "$DM/SHA256SUMS"
  for f in images/devora-images.tar db/init/001_init.sql db/init/002_rag_document_mgmt.sql db/init/003_dashboard_cols.sql; do
    grep -qxF "$f" "$WORK/devora.sumnames" || die "Devora SHA256SUMS 가 $f 를 포함하지 않습니다"
  done
  # Image refs come only from the operator env + media inventory; nothing is synthesized here.
  be_img="$(awk 'index($0, "DEVORA_BE_IMAGE=")==1 { v=substr($0, 17) } END { print v }' "$DEVORA_ENV_FILE")"
  [ -n "$be_img" ] || die "DEVORA_ENV_FILE 에 DEVORA_BE_IMAGE 가 없습니다"
  grep -qxF "$be_img" "$DM/images/devora-images.txt" || die "DEVORA_BE_IMAGE 가 images/devora-images.txt 에 없습니다"
  if [ "$RUNTIME" = podman ]; then dv_refs="docker.io/pgvector/pgvector:pg16 docker.io/redis/redis-stack-server:7.4.0-v3"
  else dv_refs="pgvector/pgvector:pg16 redis/redis-stack-server:7.4.0-v3"; fi
  for r in $dv_refs; do grep -qxF "$r" "$DM/images/devora-images.txt" || die "Devora 이미지 목록에 $r 가 없습니다"; done
  # The operator env must never land in the kit, even renamed.
  env_hash="$(sha256_of "$DEVORA_ENV_FILE")"
  while IFS= read -r f; do
    [ "$(sha256_of "$f")" != "$env_hash" ] || die "Devora 미디어에 운영자 env 와 같은 파일이 있습니다 (비밀값 혼입 거부)"
  done < <(find "$DM" -type f ! -name 'devora-images.tar')
  mkdir "$ROOT/devora-media"
  (cd "$DM" && COPYFILE_DISABLE=1 tar -cf - .) | tar -xf - -C "$ROOT/devora-media" || die "Devora 미디어 복사 실패"
  [ -z "$(find "$ROOT/devora-media" -mindepth 1 ! -type f ! -type d)" ] || die "복사한 Devora 미디어에 일반 파일이 아닌 항목이 있습니다"
  log "Devora 미디어 포함: devora-media/ ($(grep -c . "$WORK/devora.sumnames")개 해시 확인)"
fi

{
  printf 'kit_name=%s\n' "$KIT_NAME"
  printf 'kit_format=2\n'
  printf 'version=%s\n' "$KIT_VERSION"
  printf 'runtime=%s\n' "$RUNTIME"
  printf 'arch=%s\n' "$ARCH"
  printf 'platform=%s\n' "$PLATFORM"
  printf 'product_package=%s\n' "$PRODUCT_REL"
  printf 'product_sha256=%s\n' "$PRODUCT_HASH"
  printf 'product_requires=%s\n' "$(printf '%s' "$PRODUCT_REQUIRES" | tr ' ' ',')"
  printf 'manifest_tool_capabilities=%s\n' "$TOOL_CAPS"
  printf 'source_commit=%s\n' "$COMMIT"
  printf 'source_ref=%s\n' "${REF:-}"
  printf 'installer_archive=%s\n' "$(basename "$INSTALLER_ARCHIVE")"
  printf 'installer_archive_sha256=%s\n' "$INSTALLER_ARCHIVE_HASH"
  printf 'installer_binary_original_name=%s\n' "$INSTALLER_BIN"
  printf 'installer_binary_sha256=%s\n' "$INSTALLER_BIN_HASH"
  printf 'image_bundle=%s\n' "$BUNDLE_NAME"
  printf 'image_bundle_sha256=%s\n' "$BUNDLE_HASH"
  printf 'image_count=%s\n' "$(grep -c . "$WORK/bundle.images")"
  printf 'readme_sha256=%s\n' "$(sha256_of "$README_SRC")"
  printf 'created_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'excluded=issued license.json, .env, secrets, certificates, runtime data\n'
  if [ "$DEVORA" -eq 1 ]; then
    printf 'devora=optional\n'
    printf 'devora_media=devora-media\n'
    printf 'devora_media_sha256sums=%s\n' "$(sha256_of "$ROOT/devora-media/SHA256SUMS")"
    printf 'devora_installer_contract=%s\n' "$DEVORA_CONTRACT"
  fi
} > "$ROOT/KIT-INFO.txt"

# payload guard: nothing secret-like may be present
bad="$(cd "$ROOT" && find . \( -name 'license.json' -o -name '.env' -o -name 'secrets.env' -o -name '*.key' \
  -o -name '*.crt' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '._*' \) -print)"
[ -z "$bad" ] || die "키트에 넣으면 안 되는 파일이 있습니다: $bad"
[ -z "$(find "$ROOT" -mindepth 1 ! -type f ! -type d)" ] || die "키트에 일반 파일/디렉터리가 아닌 항목이 있습니다"
find "$ROOT" -type d -exec chmod 755 {} +
# the bundle may be a hard link to the caller's file: never chmod it
find "$ROOT" -type f ! -name teamcloud-installer ! -name docker-compose-linux-amd64 ! -name '*.sh' \
  ! -name "$BUNDLE_NAME" -exec chmod 644 {} +
find "$ROOT" -type f -name '*.sh' -exec chmod 755 {} +

log "키트 내부 SHA256SUMS 작성"
(cd "$ROOT" && find . -type f ! -path ./SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort) > "$WORK/kit.files"
while IFS= read -r rel; do
  printf '%s  %s\n' "$(sha256_of "$ROOT/$rel")" "$rel"
done < "$WORK/kit.files" > "$ROOT/SHA256SUMS"
chmod 644 "$ROOT/SHA256SUMS"

# ---------- write output (no clobber) ----------
set -o noclobber
TAR_OWNER=""
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TAR_OWNER="--owner=0 --group=0 --numeric-owner"
else
  TAR_OWNER="--uid 0 --gid 0 --uname root --gname root"
fi
log "키트 압축 작성: $OUT.partial"
# shellcheck disable=SC2086
(cd "$STAGE/kit" && COPYFILE_DISABLE=1 tar $TAR_OWNER -cf - "$KIT_NAME") | gzip -n > "$OUT.partial" \
  || die "키트 압축 작성 실패 (부분 파일: $OUT.partial)"

log "키트 압축 검증"
gzip -t "$OUT.partial" || die "작성한 키트 gzip 검사 실패"
tar -tzf "$OUT.partial" > "$WORK/out.names"
tar -tvzf "$OUT.partial" > "$WORK/out.long"
check_tar_names "$WORK/out.names" "출력 키트"
check_tar_types "$WORK/out.long" "출력 키트"
while IFS= read -r n; do
  case "$n" in
    "$KIT_NAME"|"$KIT_NAME"/|"$KIT_NAME"/*) ;;
    *) die "출력 키트에 최상위 폴더 밖 항목이 있습니다: $n" ;;
  esac
  case "$n" in */._*) die "출력 키트에 macOS 메타데이터 항목이 있습니다: $n" ;; esac
done < "$WORK/out.names"
grep -qxF "$KIT_NAME/SHA256SUMS" "$WORK/out.names" || die "출력 키트에 SHA256SUMS 가 없습니다"

ln "$OUT.partial" "$OUT" || die "출력 파일 생성 실패 (덮어쓰지 않음): $OUT"
regular_file "$OUT.partial" || die "정리할 부분 파일의 형식이 바뀌었습니다"
rm "$OUT.partial"
printf '%s  %s\n' "$(sha256_of "$OUT")" "$KIT_FILE" > "$OUT_SUM.partial"
ln "$OUT_SUM.partial" "$OUT_SUM" || die "체크섬 파일 생성 실패 (덮어쓰지 않음): $OUT_SUM"
regular_file "$OUT_SUM.partial" || die "정리할 체크섬 부분 파일의 형식이 바뀌었습니다"
rm "$OUT_SUM.partial"
chmod 644 "$OUT" "$OUT_SUM"

log "완료"
printf '\n  키트:     %s\n  체크섬:   %s\n  작업 폴더: %s (검증 후 직접 삭제 가능)\n\n' "$OUT" "$OUT_SUM" "$STAGE"
