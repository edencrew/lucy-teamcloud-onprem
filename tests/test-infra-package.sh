#!/usr/bin/env bash
# Fixture test for scripts/package-update.sh. No container engine, network or real
# pull/save/load/up: the source repo is a disposable local Git fixture and the image
# archive is a hand-built docker-save tar with real config bytes.
#
# Required environment (the success path is never skipped):
#   TC_MANIFEST_TOOL  native teamcloud-installer (ops manifest / ops verify --package)
#   TC_TEST_COMPOSE   native standalone Compose CLI (only `config --images` is used)
set -Eeuo pipefail
umask 022

HERE="$(cd -P "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/package-update.sh"
PREFIX="tc-infra-package-test"

fail() { printf 'FAIL: %s\n' "$*" >&2; [ -n "${WORK:-}" ] && printf 'diagnostics kept: %s\n' "$WORK" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[ -f "$SCRIPT" ] || fail "package-update.sh not found: $SCRIPT"
[ -n "${TC_MANIFEST_TOOL:-}" ] && [ -f "$TC_MANIFEST_TOOL" ] && [ -x "$TC_MANIFEST_TOOL" ] \
  || fail "TC_MANIFEST_TOOL must name the native manifest helper (success path is mandatory)"
[ -n "${TC_TEST_COMPOSE:-}" ] && [ -f "$TC_TEST_COMPOSE" ] && [ -x "$TC_TEST_COMPOSE" ] \
  || fail "TC_TEST_COMPOSE must name a native standalone Compose binary"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ---------- safe temporary root ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX.XXXXXX")" || fail "mktemp -d failed"
case "$WORK" in
  ''|/) fail "unsafe temporary directory: '$WORK'" ;;
esac
case "$(basename "$WORK")" in
  "$PREFIX".??????) ;;
  *) fail "temporary directory has unexpected name: $WORK" ;;
esac
[ -d "$WORK" ] && [ ! -L "$WORK" ] || fail "temporary directory is not a plain directory: $WORK"
WORK="$(cd -P "$WORK" && pwd)"

cleanup_success() {
  # Inspect before removal: plain directory, exact task prefix, nothing else.
  [ -d "$WORK" ] && [ ! -L "$WORK" ] || return 0
  case "$(basename "$WORK")" in "$PREFIX".??????) ;; *) return 0 ;; esac
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf -- "$WORK"
}

# Isolate git/compose from user configuration.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$WORK/home" DOCKER_CONFIG="$WORK/home/.docker"
mkdir -p "$HOME/.docker"
G() { git -C "$SRC" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }

# ---------- source fixture repo ----------
SRC="$WORK/src"
mkdir -p "$SRC"
case "$SRC" in "$WORK"/src) ;; *) fail "fixture repo outside work dir" ;; esac
G init -q
put() { mkdir -p "$(dirname "$SRC/$1")"; printf '%s\n' "$2" > "$SRC/$1"; }
put compose.docker.yml 'services:
  tc:
    image: ${TC_REGISTRY}/teamcloud/tc:${TC_VERSION}
  db:
    image: docker.io/library/postgres:16'
put compose.docker.init-secrets.yml 'services:
  init-secrets:
    image: lucy-teamcloud-onprem-init-secrets:offline'
put compose.podman.yml 'services:
  tc:
    image: ${TC_REGISTRY}/teamcloud/tc:${TC_VERSION}
  db:
    image: docker.io/library/postgres:16'
put compose.podman.init-secrets.yml 'services:
  init-secrets:
    image: localhost/lucy-teamcloud-onprem-init-secrets:offline'
put .env.example 'TC_REGISTRY=registry.example.com
TC_VERSION=1.2.3'
for f in scripts/load-compose-images-docker.sh scripts/load-compose-images-podman.sh \
         init-secrets/docker-entrypoint.sh git/gitea-entrypoint.sh auth/auth-entrypoint.sh \
         tc/tc-entrypoint.sh postgres/initdb/01-create-user.sh scripts/studio-upload.sh; do
  put "$f" '#!/bin/sh
exit 0'
done
put init-secrets/Dockerfile 'FROM scratch'
put nginx/nginx.conf 'events {}'
put nginx/nginx.http.conf 'events {}'
put git/app.ini '[server]'
put broker/mosquitto.conf 'listener 1883'
put studio-dl/nginx.conf 'events {}'
# Protected material deliberately committed; must never reach the package.
put .env 'TC_REGISTRY=evil.example.com
TC_VERSION=9.9.9
SECRET=do-not-ship'
put license/teamcloud.lic 'LICENSE-DO-NOT-SHIP'
put data/db.sqlite 'DATA-DO-NOT-SHIP'
G add -A
G commit -q -m fixture
G tag v1.2.3
COMMIT="$(G rev-parse HEAD)"
put README.md 'later'
G add -A
G commit -q -m later
G tag v1.2.4
OTHER="$(G rev-parse HEAD)"
# Legacy source without the split Docker bootstrap file: modern kits must fail closed.
G rm -q compose.docker.init-secrets.yml
G commit -q -m legacy
G tag v1.2.5
LEGACY="$(G rev-parse HEAD)"
[ "${#COMMIT}" -eq 40 ] && [ "$COMMIT" != "$OTHER" ] && [ "$OTHER" != "$LEGACY" ] || fail "fixture commits"

# ---------- fake docker-save image tars ----------
# make_image_tar OUT.tar REF[,REF...] [REF[,REF...] ...]  (one image per argument)
make_image_tar() {
  local out="$1"; shift
  local d; d="$(mktemp -d "$WORK/imgbuild.XXXXXX")"
  local entries="" n=0 refs tags r layer diff cfg cfgsum
  for refs in "$@"; do
    n=$((n + 1))
    mkdir -p "$d/content$n"; printf 'image %s\n' "$refs" > "$d/content$n/hello"
    (cd "$d/content$n" && COPYFILE_DISABLE=1 tar -cf "$d/layer$n.tar" hello)
    diff="$(sha256 "$d/layer$n.tar")"
    mkdir -p "$d/out/$diff"; mv "$d/layer$n.tar" "$d/out/$diff/layer.tar"
    cfg="{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{\"Labels\":{\"n\":\"$n\"}},\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:$diff\"]}}"
    printf '%s' "$cfg" > "$d/cfg.tmp"; cfgsum="$(sha256 "$d/cfg.tmp")"; mv "$d/cfg.tmp" "$d/out/$cfgsum.json"
    tags=""
    for r in $(printf '%s' "$refs" | tr ',' ' '); do tags="${tags:+$tags,}\"$r\""; done
    entries="${entries:+$entries,}{\"Config\":\"$cfgsum.json\",\"RepoTags\":[$tags],\"Layers\":[\"$diff/layer.tar\"]}"
  done
  printf '[%s]' "$entries" > "$d/out/manifest.json"
  (cd "$d/out" && set -- && for e in *; do [ "$e" = manifest.json ] || set -- "$@" "$e"; done \
    && COPYFILE_DISABLE=1 tar -cf "$out" manifest.json "$@")
}

IMG="$WORK/images"; mkdir -p "$IMG"
# Hub alias forms differ from compose on purpose (postgres:16 == docker.io/library/postgres:16).
# Docker set = main base + split bootstrap (init image unused by the regular base).
DINIT=lucy-teamcloud-onprem-init-secrets:offline
PINIT=localhost/lucy-teamcloud-onprem-init-secrets:offline
make_image_tar "$IMG/teamcloud-images.tar" registry.example.com/teamcloud/tc:1.2.3 postgres:16 "$DINIT"
make_image_tar "$IMG/podman-images.tar" registry.example.com/teamcloud/tc:1.2.3 postgres:16 "$PINIT"
make_image_tar "$IMG/extra.tar" registry.example.com/teamcloud/tc:1.2.3 postgres:16 "$DINIT" redis:7
make_image_tar "$IMG/missing.tar" registry.example.com/teamcloud/tc:1.2.3 "$DINIT"
make_image_tar "$IMG/noinit.tar" registry.example.com/teamcloud/tc:1.2.3 postgres:16
make_image_tar "$IMG/wrongtag.tar" registry.example.com/teamcloud/tc:1.2.3 postgres:latest "$DINIT"
make_image_tar "$IMG/otherreg.tar" mirror.example.com/teamcloud/tc:1.2.3 postgres:16 "$DINIT"
make_image_tar "$IMG/envleak.tar" evil.example.com/teamcloud/tc:9.9.9 postgres:16 "$DINIT"
ln -s "$IMG/teamcloud-images.tar" "$IMG/link.tar"

# Shell-only stub: negative cases must be refused before the manifest helper runs.
STUB="$WORK/stub-manifest-tool"
STUB_MARK="$WORK/stub-was-called"
printf '#!/bin/sh\n: > "%s"\necho "STUB manifest tool must not be reached" >&2\nexit 99\n' "$STUB_MARK" > "$STUB"
chmod 755 "$STUB"

run_pkg() { # run_pkg LOG ARGS...
  local log="$1"; shift
  bash "$SCRIPT" --runtime docker --source-repo "$SRC" --compose-binary "$TC_TEST_COMPOSE" "$@" > "$log" 2>&1
}

expect_fail() { # expect_fail NAME PATTERN ARGS...
  local name="$1" pat="$2"; shift 2
  local out="$WORK/out-$name"; mkdir -p "$out"
  if run_pkg "$WORK/log-$name" --output-dir "$out" "$@"; then fail "$name: unexpectedly succeeded"; fi
  grep -q -- "$pat" "$WORK/log-$name" || fail "$name: missing '$pat' in $WORK/log-$name"
  [ -z "$(find "$out" -maxdepth 1 -name 'teamcloud-update-*')" ] || fail "$name: package written despite failure"
  [ ! -e "$STUB_MARK" ] || fail "$name: stub manifest tool was reached"
  pass "$name"
}

# ---------- negative cases (stub tool) ----------
expect_fail no-version '기본값 없음' --commit "$COMMIT" --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB"
expect_fail ref-version-mismatch '과 다릅니다' --commit "$COMMIT" --ref v1.2.3 --version 1.2.4 \
  --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB"
expect_fail ref-commit-mismatch '가 아닙니다' --commit "$COMMIT" --ref v1.2.4 \
  --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB"
expect_fail short-commit '40자리' --commit "${COMMIT%????}" --ref v1.2.3 \
  --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB"
expect_fail symlink-image '일반 파일이 아닙니다' --commit "$COMMIT" --ref v1.2.3 \
  --image-tar "$IMG/link.tar" --manifest-tool "$STUB"
mkdir -p "$WORK/real-out"; ln -s "$WORK/real-out" "$WORK/link-out"
if run_pkg "$WORK/log-symlink-out" --commit "$COMMIT" --ref v1.2.3 --image-tar "$IMG/teamcloud-images.tar" \
     --manifest-tool "$STUB" --output-dir "$WORK/link-out"; then fail "symlink-output: unexpectedly succeeded"; fi
grep -q '디렉터리여야' "$WORK/log-symlink-out" || fail "symlink-output: wrong error"
[ -z "$(ls -A "$WORK/real-out")" ] || fail "symlink-output: wrote through symlink"
pass symlink-output
expect_fail no-compose-binary '실행 파일이 아닙니다' --commit "$COMMIT" --ref v1.2.3 \
  --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB" --compose-binary "$WORK/nonexistent"
for c in extra missing noinit wrongtag otherreg envleak podman-images; do
  expect_fail "image-set-$c" '이미지 집합' --commit "$COMMIT" --ref v1.2.3 \
    --image-tar "$IMG/$c.tar" --manifest-tool "$STUB"
done

# Existing output is never overwritten.
mkdir -p "$WORK/out-exists"
printf 'sentinel\n' > "$WORK/out-exists/teamcloud-update-v1.2.3-linux-amd64-docker.tar.gz"
if run_pkg "$WORK/log-exists" --commit "$COMMIT" --ref v1.2.3 --image-tar "$IMG/teamcloud-images.tar" \
     --manifest-tool "$STUB" --output-dir "$WORK/out-exists"; then fail "no-overwrite: unexpectedly succeeded"; fi
[ "$(cat "$WORK/out-exists/teamcloud-update-v1.2.3-linux-amd64-docker.tar.gz")" = sentinel ] || fail "no-overwrite: clobbered"
[ ! -e "$STUB_MARK" ] || fail "no-overwrite: stub reached"
pass no-overwrite

# ---------- success path (real helper + real compose) ----------
OUTD="$WORK/out-ok"; mkdir -p "$OUTD"
# No --ref: source_ref must fall back to the v<--version> release label (not a tag check).
run_pkg "$WORK/log-ok" --commit "$COMMIT" --version 1.2.3 --image-tar "$IMG/teamcloud-images.tar" \
  --manifest-tool "$TC_MANIFEST_TOOL" --output-dir "$OUTD" || fail "success path failed: $WORK/log-ok"
PKGF="$OUTD/teamcloud-update-v1.2.3-linux-amd64-docker.tar.gz"
[ -f "$PKGF" ] && [ -f "$PKGF.sha256" ] || fail "package or sidecar missing"
[ -z "$(find "$OUTD" -maxdepth 1 -name '*.partial')" ] || fail "partial files left"
[ "$(awk '{print $1}' "$PKGF.sha256")" = "$(sha256 "$PKGF")" ] || fail "sidecar checksum mismatch"
tar -tzf "$PKGF" > "$WORK/listing"
[ "$(head -n 1 "$WORK/listing")" = manifest.json ] || fail "manifest.json is not the first entry"
if grep -E '(^|/)(\.env|license|data|README\.md)(/|$)|\.lic$|/\._' "$WORK/listing"; then fail "protected/unlisted file in package"; fi
grep -qx 'payload/\.env\.example' "$WORK/listing" || fail "payload/.env.example missing"
grep -qx 'images/teamcloud-images\.tar' "$WORK/listing" || fail "image archive missing"
tar -xOzf "$PKGF" > "$WORK/package-contents" || fail "cannot read package contents"
if grep -aq 'DO-NOT-SHIP' "$WORK/package-contents"; then fail "protected content in package"; fi
"$TC_MANIFEST_TOOL" ops verify --package "$PKGF" > "$WORK/log-verify" 2>&1 \
  || fail "ops verify --package rejected the package: $WORK/log-verify"
tar -xOzf "$PKGF" manifest.json > "$WORK/manifest.noref.json"
grep -Eq '"source_?[Rr]ef" *: *"v1\.2\.3"' "$WORK/manifest.noref.json" || fail "manifest source_ref is not v1.2.3"
grep -Eq "\"source_?[Cc]ommit\" *: *\"$COMMIT\"" "$WORK/manifest.noref.json" || fail "manifest source_commit is not $COMMIT"
grep -q '릴리스 라벨' "$WORK/log-ok" || fail "no-ref release-label warning missing"
pass success-and-verify

# Rerun into the same directory must refuse and leave the package untouched.
before="$(sha256 "$PKGF")"
if run_pkg "$WORK/log-rerun" --commit "$COMMIT" --ref v1.2.3 --image-tar "$IMG/teamcloud-images.tar" \
     --manifest-tool "$TC_MANIFEST_TOOL" --output-dir "$OUTD"; then fail "rerun: unexpectedly succeeded"; fi
[ "$(sha256 "$PKGF")" = "$before" ] || fail "rerun: package changed"
pass rerun-no-overwrite

# Split bootstrap: init file shipped, capabilities declared, ComposeFiles stays the normal base.
grep -qx 'payload/compose\.docker\.init-secrets\.yml' "$WORK/listing" || fail "docker init file missing from payload"
tar -xOzf "$PKGF" manifest.json > "$WORK/manifest.docker.json"
for cap in kit-format-2 split-init-secrets receipt-identity; do
  grep -q "\"$cap\"" "$WORK/manifest.docker.json" || fail "manifest lacks $cap"
done
tr -d ' \n' < "$WORK/manifest.docker.json" | grep -q '"compose_files":\["compose.docker.yml"\]' \
  || grep -q 'compose.docker.yml' "$WORK/manifest.docker.json" || fail "manifest compose files"
if tr -d ' \n' < "$WORK/manifest.docker.json" | grep -qE '"compose_files":\[[^]]*init-secrets'; then
  fail "init file listed in manifest compose files"
fi
pass docker-split-init-manifest

expect_fail legacy-source 'git archive' --commit "$LEGACY" --ref v1.2.5 \
  --image-tar "$IMG/teamcloud-images.tar" --manifest-tool "$STUB"

# Podman: same contract, own image set.
run_pod() { local log="$1"; shift
  bash "$SCRIPT" --runtime podman --source-repo "$SRC" --compose-binary "$TC_TEST_COMPOSE" "$@" > "$log" 2>&1; }
mkdir -p "$WORK/out-pod-bad"
if run_pod "$WORK/log-pod-bad" --commit "$COMMIT" --ref v1.2.3 --image-tar "$IMG/teamcloud-images.tar" \
     --manifest-tool "$STUB" --output-dir "$WORK/out-pod-bad"; then fail "podman mismatch: unexpectedly succeeded"; fi
grep -q '이미지 집합' "$WORK/log-pod-bad" || fail "podman mismatch: wrong error"
[ ! -e "$STUB_MARK" ] || fail "podman mismatch: stub reached"
pass podman-image-set-mismatch
mkdir -p "$WORK/out-pod"
run_pod "$WORK/log-pod" --commit "$COMMIT" --ref v1.2.3 --image-tar "$IMG/podman-images.tar" \
  --manifest-tool "$TC_MANIFEST_TOOL" --output-dir "$WORK/out-pod" || fail "podman success failed: $WORK/log-pod"
PODF="$WORK/out-pod/teamcloud-update-v1.2.3-linux-amd64-podman.tar.gz"
[ "$(tar -tzf "$PODF" | head -n 1)" = manifest.json ] || fail "podman: manifest.json not first"
"$TC_MANIFEST_TOOL" ops verify --package "$PODF" > "$WORK/log-pod-verify" 2>&1 \
  || fail "podman ops verify failed: $WORK/log-pod-verify"
pass podman-success-and-verify

# ---------- offline kit (kit_format 2) ----------
OFFLINE="$HERE/../scripts/package-offline-installer.sh"
BUN="$WORK/bundle"; mkdir -p "$BUN"
BNAME=lucy-teamcloud-onprem-docker-images-linux-amd64
gzip -nc "$IMG/teamcloud-images.tar" > "$BUN/$BNAME.tar.gz"
printf '%s  %s\n' "$(sha256 "$BUN/$BNAME.tar.gz")" "$BNAME.tar.gz" > "$BUN/$BNAME.tar.gz.sha256"
printf '%s\n' registry.example.com/teamcloud/tc:1.2.3 postgres:16 "$DINIT" > "$BUN/$BNAME.images.txt"
# Target Linux binaries are ELF-header stubs only; they are never executed here.
INS="$WORK/inst"; mkdir -p "$INS"
elf_stub() { printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000\n# stub %s --version 0.0.0-fixture\n' "$2" > "$1"; chmod 755 "$1"; }
CONTRACT=teamcloud-installer-contract:kit-format-2:product-install:receipt-identity:v1
# make_installer DIR ARCHIVE [MARKER]: same version string; only the embedded contract marker differs.
make_installer() { local d="$1" a="$2" n
  mkdir -p "$d"
  elf_stub "$d/teamcloud-installer-linux-amd64" teamcloud-installer
  [ -z "${3:-}" ] || printf '%s\n' "$3" >> "$d/teamcloud-installer-linux-amd64"
  elf_stub "$d/docker-compose-linux-amd64" docker-compose
  for n in LICENSE NOTICE COPYING.txt README.md CHANGELOG.md USAGE.txt; do printf '%s\n' "$n" > "$d/$n"; done
  (cd "$d" && for n in *; do printf '%s  %s\n' "$(sha256 "$n")" "$n"; done > "$d.SHA256SUMS.tmp" && mv "$d.SHA256SUMS.tmp" SHA256SUMS)
  (cd "$d" && COPYFILE_DISABLE=1 tar -cf - *) | gzip -n > "$a"; }
make_installer "$INS" "$WORK/installer.tar.gz" "$CONTRACT"
make_installer "$WORK/inst-old" "$WORK/installer-old.tar.gz"
INSTALLER_TGZ="$WORK/installer.tar.gz"
run_kit() { local log="$1"; shift
  bash "$OFFLINE" --runtime docker --source-repo "$SRC" --installer-archive "$INSTALLER_TGZ" \
    --image-bundle "$BUN/$BNAME.tar.gz" --compose-binary "$TC_TEST_COMPOSE" "$@" > "$log" 2>&1; }

mkdir -p "$WORK/kit-oldbin"
INSTALLER_TGZ="$WORK/installer-old.tar.gz"
if run_kit "$WORK/log-kit-oldbin" --commit "$COMMIT" --ref v1.2.3 --manifest-tool "$TC_MANIFEST_TOOL" \
     --output-dir "$WORK/kit-oldbin"; then fail "kit old binary: unexpectedly succeeded"; fi
INSTALLER_TGZ="$WORK/installer.tar.gz"
grep -qF "$CONTRACT" "$WORK/log-kit-oldbin" && grep -q '이전 릴리스 바이너리' "$WORK/log-kit-oldbin" \
  || fail "kit old binary: wrong error: $WORK/log-kit-oldbin"
[ -z "$(find "$WORK/kit-oldbin" -mindepth 1 -maxdepth 1 -name 'teamcloud-offline-*')" ] || fail "kit old binary: output written"
pass kit-old-installer-binary-without-contract-fails-closed

mkdir -p "$WORK/kit-legacy"
if run_kit "$WORK/log-kit-legacy" --commit "$LEGACY" --ref v1.2.5 --manifest-tool "$TC_MANIFEST_TOOL" \
     --output-dir "$WORK/kit-legacy"; then fail "kit legacy: unexpectedly succeeded"; fi
grep -q 'kit_format 2' "$WORK/log-kit-legacy" || fail "kit legacy: wrong error"
[ -z "$(ls -A "$WORK/kit-legacy")" ] || fail "kit legacy: output written"
pass kit-legacy-source-fails-closed
mkdir -p "$WORK/kit-notool"
if run_kit "$WORK/log-kit-notool" --commit "$COMMIT" --ref v1.2.3 --output-dir "$WORK/kit-notool"; then
  fail "kit without --manifest-tool: unexpectedly succeeded"; fi
grep -q -- '--manifest-tool' "$WORK/log-kit-notool" || fail "kit notool: wrong error"
pass kit-requires-manifest-tool

KOUT="$WORK/kit-ok"; mkdir -p "$KOUT"
run_kit "$WORK/log-kit" --commit "$COMMIT" --ref v1.2.3 --manifest-tool "$TC_MANIFEST_TOOL" --output-dir "$KOUT" \
  || fail "kit success failed: $WORK/log-kit"
KNAME=teamcloud-offline-v1.2.3-linux-amd64-docker
KITF="$KOUT/$KNAME.tar.gz"
[ "$(awk '{print $1}' "$KITF.sha256")" = "$(sha256 "$KITF")" ] || fail "kit sidecar checksum"
mkdir -p "$WORK/kit-x"; tar -xzf "$KITF" -C "$WORK/kit-x"
KR="$WORK/kit-x/$KNAME"
(cd "$KR" && while read -r h n; do [ "$(sha256 "$n")" = "$h" ] || exit 1; done < SHA256SUMS) || fail "kit SHA256SUMS"
grep -qx 'kit_format=2' "$KR/KIT-INFO.txt" || fail "KIT-INFO kit_format"
grep -qx 'product_package=product/teamcloud-initial.tar.gz' "$KR/KIT-INFO.txt" || fail "KIT-INFO product_package"
grep -qx "product_sha256=$(sha256 "$KR/product/teamcloud-initial.tar.gz")" "$KR/KIT-INFO.txt" || fail "KIT-INFO product_sha256"
grep -qx 'version=1.2.3' "$KR/KIT-INFO.txt" && grep -qx "source_commit=$COMMIT" "$KR/KIT-INFO.txt" \
  && grep -qx 'runtime=docker' "$KR/KIT-INFO.txt" && grep -qx 'arch=amd64' "$KR/KIT-INFO.txt" || fail "KIT-INFO identity"
INNER="$KR/product/teamcloud-initial.tar.gz"
[ "$(tar -tzf "$INNER" | head -n 1)" = manifest.json ] || fail "inner: manifest.json not first"
tar -xOzf "$INNER" manifest.json > "$WORK/inner.manifest.json"
for cap in kit-format-2 split-init-secrets receipt-identity; do
  grep -q "\"$cap\"" "$WORK/inner.manifest.json" || fail "inner manifest lacks $cap"
done
grep -q "$COMMIT" "$WORK/inner.manifest.json" || fail "inner manifest commit"
if tar -xOzf "$INNER" | grep -aq 'DO-NOT-SHIP'; then fail "protected content in inner package"; fi
if tar -tzf "$INNER" | grep -E '(^|/)(\.env|license|data)(/|$)|\.lic$'; then fail "protected path in inner package"; fi
"$TC_MANIFEST_TOOL" ops verify --package "$INNER" > "$WORK/log-inner-verify" 2>&1 \
  || fail "inner ops verify failed: $WORK/log-inner-verify"
pass offline-kit-format2-success

# ---------- offline kit with optional Devora selected (DEVORA_ENV_FILE + DEVORA_MEDIA_DIR) ----------
# Extend the modern split-init fixture, not HEAD (the deliberately legacy case).
G checkout -q --detach "$COMMIT"
DEVORA_CONTRACT=teamcloud-installer-contract:devora-optional:v1
"$TC_MANIFEST_TOOL" ops version 2>/dev/null | sed -n 's/^capabilities=//p' | tr ',' '\n' | grep -qx devora-optional \
  || fail "TC_MANIFEST_TOOL lacks devora-optional capability"
for f in compose.docker.yml compose.podman.yml .env.example manage.sh README.md INTERFACE.md; do
  put "devora/$f" "# devora fixture $f"
done
G add -A
G commit -q -m devora-fixture
G tag v1.2.7
DCOMMIT="$(G rev-parse HEAD)"
DV_SECRET=devora-env-literal-DO-NOT-SHIP-7f3a
DV_ENV="$WORK/devora.env"
printf 'DEVORA_BE_IMAGE=registry.example.com/devora/be:1.0.0\nDEVORA_API_KEY=%s\n' "$DV_SECRET" > "$DV_ENV"
chmod 600 "$DV_ENV"
DV_MEDIA="$WORK/devora-media-src"
mkdir -p "$DV_MEDIA/images" "$DV_MEDIA/db/init" "$DV_MEDIA/docs/spec"
printf 'fake devora image archive\n' > "$DV_MEDIA/images/devora-images.tar"
printf '%s\n' registry.example.com/devora/be:1.0.0 pgvector/pgvector:pg16 redis/redis-stack-server:7.4.0-v3 \
  > "$DV_MEDIA/images/devora-images.txt"
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do printf -- '-- %s\n' "$f" > "$DV_MEDIA/db/init/$f"; done
printf 'spec fixture\n' > "$DV_MEDIA/docs/spec/spec.md"
printf 'source=fixture\n' > "$DV_MEDIA/PROVENANCE.txt"
(cd "$DV_MEDIA" && for n in images/devora-images.tar images/devora-images.txt db/init/001_init.sql \
   db/init/002_rag_document_mgmt.sql db/init/003_dashboard_cols.sql docs/spec/spec.md PROVENANCE.txt; do
   printf '%s  %s\n' "$(sha256 "$n")" "$n"; done > SHA256SUMS)
make_installer "$WORK/inst-dv" "$WORK/installer-dv.tar.gz" "$CONTRACT
$DEVORA_CONTRACT"
grep -aqF "$CONTRACT" "$WORK/inst-dv/teamcloud-installer-linux-amd64" \
  && grep -aqF "$DEVORA_CONTRACT" "$WORK/inst-dv/teamcloud-installer-linux-amd64" || fail "devora installer fixture markers"

DKOUT="$WORK/kit-dv"; mkdir -p "$DKOUT"
INSTALLER_TGZ="$WORK/installer-dv.tar.gz"
DEVORA_ENV_FILE="$DV_ENV" DEVORA_MEDIA_DIR="$DV_MEDIA" \
  run_kit "$WORK/log-kit-dv" --commit "$DCOMMIT" --ref v1.2.7 --manifest-tool "$TC_MANIFEST_TOOL" --output-dir "$DKOUT" \
  || fail "devora kit success failed: $WORK/log-kit-dv"
INSTALLER_TGZ="$WORK/installer.tar.gz"
DKNAME=teamcloud-offline-v1.2.7-linux-amd64-docker
DKITF="$DKOUT/$DKNAME.tar.gz"
[ "$(awk '{print $1}' "$DKITF.sha256")" = "$(sha256 "$DKITF")" ] || fail "devora kit sidecar checksum"
mkdir -p "$WORK/kit-dv-x"; tar -xzf "$DKITF" -C "$WORK/kit-dv-x"
DKR="$WORK/kit-dv-x/$DKNAME"
(cd "$DKR" && while read -r h n; do [ "$(sha256 "$n")" = "$h" ] || exit 1; done < SHA256SUMS) || fail "devora kit SHA256SUMS"
DINNER="$DKR/product/teamcloud-initial.tar.gz"
tar -tzf "$DINNER" | grep '^payload/devora/' | grep -v '/$' | LC_ALL=C sort > "$WORK/dv.payload"
printf 'payload/devora/%s\n' .env.example INTERFACE.md README.md compose.docker.yml compose.podman.yml manage.sh \
  | LC_ALL=C sort > "$WORK/dv.expected"
cmp -s "$WORK/dv.payload" "$WORK/dv.expected" || fail "devora payload is not exactly the 6 files: $WORK/dv.payload"
tar -xOzf "$DINNER" manifest.json > "$WORK/dv.manifest.json"
grep -q '"devora-optional"' "$WORK/dv.manifest.json" || fail "devora inner manifest lacks devora-optional"
grep -q "$DCOMMIT" "$WORK/dv.manifest.json" || fail "devora inner manifest commit"
if tar -tzf "$DINNER" | grep -q 'devora-media\|devora-images'; then fail "devora media inside product package"; fi
grep -qx 'devora=optional' "$DKR/KIT-INFO.txt" && grep -qx 'devora_media=devora-media' "$DKR/KIT-INFO.txt" \
  && grep -q '^product_requires=.*devora-optional' "$DKR/KIT-INFO.txt" || fail "devora KIT-INFO"
grep -aqF "$DEVORA_CONTRACT" "$DKR/teamcloud-installer" && grep -aqF "$CONTRACT" "$DKR/teamcloud-installer" \
  || fail "devora kit installer markers"
(cd "$DKR" && find devora-media -type f) | LC_ALL=C sort > "$WORK/dv.media"
[ "$(grep -c . "$WORK/dv.media")" = 8 ] || fail "devora-media file set: $WORK/dv.media"
sed 's/^[0-9a-f]*  *\**//; s#^\./##' "$DKR/SHA256SUMS" > "$WORK/dv.kitsums"
while read -r f; do grep -qxF "$f" "$WORK/dv.kitsums" || fail "kit SHA256SUMS misses $f"; done < "$WORK/dv.media"
cmp -s "$DV_MEDIA/images/devora-images.tar" "$DKR/devora-media/images/devora-images.tar" || fail "devora media content"
if grep -rqaF "$DV_SECRET" "$WORK/kit-dv-x" || tar -xOzf "$DINNER" | grep -aqF "$DV_SECRET" \
   || gzip -dc "$DKITF" | grep -aqF "$DV_SECRET"; then fail "devora env literal leaked into kit"; fi
if grep -aqF "$DV_SECRET" "$WORK/log-kit-dv"; then fail "devora env literal printed"; fi
"$TC_MANIFEST_TOOL" ops verify --package "$DINNER" > "$WORK/log-dv-verify" 2>&1 \
  || fail "devora inner ops verify failed: $WORK/log-dv-verify"
pass offline-kit-devora-selected-success

# Old-marker-only binary (kit_format 2 contract, no devora marker) must be rejected for a Devora kit.
mkdir -p "$WORK/kit-dv-old"
if DEVORA_ENV_FILE="$DV_ENV" DEVORA_MEDIA_DIR="$DV_MEDIA" \
   run_kit "$WORK/log-kit-dv-old" --commit "$DCOMMIT" --ref v1.2.7 --manifest-tool "$TC_MANIFEST_TOOL" \
     --output-dir "$WORK/kit-dv-old"; then fail "devora kit with old-marker binary: unexpectedly succeeded"; fi
grep -qF "$DEVORA_CONTRACT" "$WORK/log-kit-dv-old" || fail "devora old-marker: wrong error: $WORK/log-kit-dv-old"
[ -z "$(find "$WORK/kit-dv-old" -mindepth 1 -maxdepth 1 -name 'teamcloud-offline-*')" ] || fail "devora old-marker: output written"
pass offline-kit-devora-old-marker-binary-fails-closed

cleanup_success
printf 'PASS test-infra-package\n'
