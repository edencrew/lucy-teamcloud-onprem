#!/usr/bin/env bash
# S3 의 Studio 피드/패키지로 dist/ 와 templates/ 를 구성하고 lucy-studio-dist 이미지를 빌드한다.
# Studio CI 의 publish_onprem_dist job 이 할 일을 로컬에서 흉내 내는 검증용 스크립트다.
#
# 사용 예:
#   ./build-dist.sh --variant saas --build 323 --dummy-large
#   ./build-dist.sh --variant onprem                    # appcast 최신 item 기준, 대용량 파일 실제 다운로드
#
# --dummy-large : zip/msix/dmg/exe 를 받지 않고 같은 이름의 더미 파일(8MB 등)을 만든다.
#                 Range/MIME/헤더 검증에는 충분하고, 서명 검증(실제 Sparkle/App Installer 동작)에는 쓸 수 없다.
set -Eeuo pipefail

BUCKET="${BUCKET:-lucy-studio-dist}"
VARIANT="onprem"
BUILD=""
DUMMY_LARGE=0
IMAGE_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --dummy-large) DUMMY_LARGE=1; shift ;;
    --tag) IMAGE_TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/.work"
DIST="$HERE/dist"
TPL="$HERE/templates"
rm -rf "$WORK" "$DIST" "$TPL"
mkdir -p "$WORK" "$DIST/macos" "$DIST/windows" "$TPL/macos" "$TPL/windows"

S3_MAC="s3://$BUCKET/macos/$VARIANT"
S3_WIN="s3://$BUCKET/windows/$VARIANT"

log() { printf '\n\033[1;34m[build-dist]\033[0m %s\n' "$*"; }

dummy() { # dummy <path> <MiB>
  mkdir -p "$(dirname "$1")"
  head -c $(( $2 * 1024 * 1024 )) /dev/urandom > "$1"
}

# ── macOS: appcast ───────────────────────────────────────────────────────────
log "appcast.xml 받기: $S3_MAC/appcast.xml"
if ! aws s3 cp "$S3_MAC/appcast.xml" "$WORK/appcast.xml" --only-show-errors; then
  echo "appcast 가 없다 ($S3_MAC). macOS 피드 없이 진행한다." >&2
  MAC_FEED=0
else
  MAC_FEED=1
fi

MAC_ZIP=""; MAC_DELTAS=()
if [ "$MAC_FEED" = 1 ]; then
  # 최신 item(또는 --build) 하나만 남기고, URL prefix 를 자리표시자로 바꾼다.
  python3 - "$WORK/appcast.xml" "$TPL/macos/appcast.xml.tmpl" "$BUILD" "$WORK/mac-files.txt" <<'PY'
import re, sys, urllib.parse
src, dst, want, listing = sys.argv[1:5]
xml = open(src, encoding='utf-8').read()
items = re.findall(r'<item>.*?</item>', xml, flags=re.S)
if not items:
    sys.exit("appcast 에 item 이 없다")
def build_of(it):
    m = re.search(r'<sparkle:version>(\d+)</sparkle:version>', it)
    return int(m.group(1)) if m else -1
items.sort(key=build_of, reverse=True)
keep = next((it for it in items if str(build_of(it)) == want), None) if want else items[0]
if keep is None:
    sys.exit(f"build {want} 인 item 이 없다")
urls = re.findall(r'url="([^"]+)"', keep)
prefix = urls[0].rsplit('/', 1)[0]
keep2 = keep.replace(f'url="{prefix}/', 'url="__STUDIO_BASE_URL__/macos/')
head = xml[:xml.index('<item>')]
tail = xml[xml.rindex('</item>') + len('</item>'):]
open(dst, 'w', encoding='utf-8', newline='\n').write(head + keep2 + tail)
with open(listing, 'w', encoding='utf-8') as f:
    for u in urls:
        f.write(urllib.parse.unquote(u.rsplit('/', 1)[1]) + '\n')
print(f"kept build {build_of(keep)}; files: {len(urls)}")
PY
  MAC_BUILD="$(grep -o '<sparkle:version>[0-9]*' "$TPL/macos/appcast.xml.tmpl" | head -1 | tr -dc 0-9)"
  while IFS= read -r f; do
    case "$f" in
      *.zip) MAC_ZIP="$f" ;;
      *.delta) MAC_DELTAS+=("$f") ;;
    esac
  done < "$WORK/mac-files.txt"
  log "macOS build $MAC_BUILD: zip=$MAC_ZIP deltas=${#MAC_DELTAS[@]}"
  for d in "${MAC_DELTAS[@]}"; do
    aws s3 cp "$S3_MAC/$d" "$DIST/macos/$d" --only-show-errors
  done
  if [ "$DUMMY_LARGE" = 1 ]; then dummy "$DIST/macos/$MAC_ZIP" 8; else aws s3 cp "$S3_MAC/$MAC_ZIP" "$DIST/macos/$MAC_ZIP" --only-show-errors; fi
fi

# ── Windows: appinstaller ────────────────────────────────────────────────────
log "LucyStudio.appinstaller 받기: $S3_WIN/LucyStudio.appinstaller"
WIN_MSIX=""
if aws s3 cp "$S3_WIN/LucyStudio.appinstaller" "$WORK/LucyStudio.appinstaller" --only-show-errors; then
  WIN_FEED=1
  python3 - "$WORK/LucyStudio.appinstaller" "$TPL/windows/LucyStudio.appinstaller.tmpl" "$WORK/win-msix.txt" <<'PY'
import re, sys
src, dst, out = sys.argv[1:4]
xml = open(src, encoding='utf-8').read()
uris = re.findall(r'Uri="([^"]+)"', xml)
prefix = uris[0].rsplit('/', 1)[0]
xml2 = xml.replace(f'Uri="{prefix}/', 'Uri="__STUDIO_BASE_URL__/windows/')
open(dst, 'w', encoding='utf-8', newline='\n').write(xml2)
msix = [u.rsplit('/', 1)[1] for u in uris if u.endswith('.msix')]
m = re.search(r'<MainPackage\b[^>]*?\bVersion="([0-9.]+)"', xml, flags=re.S)
open(out, 'w').write((msix[0] if msix else '') + '\n' + (m.group(1) if m else '') + '\n')
PY
  WIN_MSIX="$(sed -n 1p "$WORK/win-msix.txt")"
  WIN_VER="$(sed -n 2p "$WORK/win-msix.txt")"
  log "Windows $WIN_VER: msix=$WIN_MSIX"
  if [ "$DUMMY_LARGE" = 1 ]; then dummy "$DIST/windows/$WIN_MSIX" 8; else aws s3 cp "$S3_WIN/$WIN_MSIX" "$DIST/windows/$WIN_MSIX" --only-show-errors; fi
else
  echo "appinstaller 가 없다 ($S3_WIN). Windows 피드 없이 진행한다." >&2
  WIN_FEED=0
fi

# ── 설치 파일 (DMG / 설치기 exe / Windows zip) ──────────────────────────────
# CI 아티팩트에서 오는 파일이라 S3 에는 없다. 로컬 검증에서는 이름만 맞춘 더미를 만든다.
VERSION="${VERSION:-0.0.34}"
BUILD_NO="${MAC_BUILD:-${WIN_VER##*.}}"
TAG="studio-v$VERSION"
DMG="LucyStudio-macos-$TAG-$BUILD_NO-$VARIANT.dmg"
EXE="LucyStudio_MsixSetup_${TAG}_${BUILD_NO}_$VARIANT.exe"
WZIP="studio-windows-$TAG-$BUILD_NO-$VARIANT.zip"
dummy "$DIST/macos/$DMG" 4
dummy "$DIST/windows/$EXE" 4
dummy "$DIST/windows/$WZIP" 4

# ── latest.json ──────────────────────────────────────────────────────────────
python3 - "$DIST" "$VERSION" "$BUILD_NO" "$TAG" "$VARIANT" "macos/$DMG" "macos/${MAC_ZIP:-}" "windows/${WIN_MSIX:-}" "windows/$EXE" "windows/$WZIP" "$MAC_FEED" "$WIN_FEED" <<'PY'
import hashlib, json, os, sys, datetime
dist, version, build, tag, variant, dmg, mzip, msix, exe, wzip, macfeed, winfeed = sys.argv[1:13]
def entry(rel):
    p = os.path.join(dist, rel)
    if not rel.endswith(('/',)) and os.path.isfile(p):
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        return {"path": rel, "size": os.path.getsize(p), "sha256": h.hexdigest()}
    return None
doc = {
  "schemaVersion": 1, "product": "lucy-studio", "variant": variant,
  "version": version, "build": int(build), "gitTag": tag,
  "releasedAt": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  "feeds": {"macos": "macos/appcast.xml" if macfeed == "1" else None,
            "windows": "windows/LucyStudio.appinstaller" if winfeed == "1" else None},
  "files": {"macosDmg": entry(dmg), "macosUpdateZip": entry(mzip), "windowsMsix": entry(msix),
            "windowsInstaller": entry(exe), "windowsZip": entry(wzip)},
}
with open(os.path.join(dist, 'latest.json'), 'w', encoding='utf-8', newline='\n') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2); f.write('\n')
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY

# ── 이미지 빌드 ──────────────────────────────────────────────────────────────
IMAGE="${IMAGE_TAG:-lucy-studio-dist:local-$VARIANT-$VERSION.$BUILD_NO}"
log "docker build → $IMAGE"
docker build -t "$IMAGE" "$HERE"
log "done: $IMAGE"
echo "$IMAGE" > "$WORK/image.txt"
