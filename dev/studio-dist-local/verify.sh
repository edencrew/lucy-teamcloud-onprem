#!/usr/bin/env bash
# build-dist.sh 로 만든 이미지를 compose.verify.yml 로 띄우고 Notion 6절 체크리스트의 HTTP 항목을 돌린다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${STUDIO_DIST_IMAGE:-$(cat "$HERE/.work/image.txt" 2>/dev/null || echo lucy-studio-dist:local)}"
BASE_HOST="${BASE_HOST:-http://localhost:28080}"
export STUDIO_DIST_IMAGE="$IMAGE" STUDIO_BASE_URL="$BASE_HOST/studio"

pass=0; fail=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check() { # check <desc> <cmd...>  (명령이 0 이면 PASS)
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
hdr() { curl -s -o /dev/null -D - "$@" 2>/dev/null; }

cd "$HERE"
echo "image: $IMAGE"
echo "STUDIO_BASE_URL: $STUDIO_BASE_URL"

echo "== STUDIO_BASE_URL 비우면 기동 실패"
if docker run --rm -e STUDIO_BASE_URL= "$IMAGE" >/dev/null 2>&1; then bad "빈 STUDIO_BASE_URL 인데 기동됨"; else ok "빈 STUDIO_BASE_URL 이면 exit != 0"; fi

echo "== compose up"
docker compose -f compose.verify.yml up -d --quiet-pull >/dev/null
for i in $(seq 1 40); do
  s="$(docker compose -f compose.verify.yml ps --format '{{.Service}} {{.Health}}' | awk '$1=="studio-dl"{print $2}')"
  [ "$s" = "healthy" ] && break; sleep 1
done
check "studio-dl healthy" test "$s" = "healthy"

S="$BASE_HOST/studio"
echo "== 피드/메타"
h="$(hdr "$S/healthz")";                check "/studio/healthz 200 (gw 경유)"                 grep -q '^HTTP/.* 200' <<<"$h"
h="$(hdr "$S/latest.json")";            check "latest.json 200"                               grep -q '^HTTP/.* 200' <<<"$h"
                                        check "latest.json Content-Type application/json"     grep -qi '^content-type: application/json' <<<"$h"
                                        check "latest.json Cache-Control no-cache"            grep -qi '^cache-control: no-cache, max-age=0' <<<"$h"
h="$(hdr "$S/macos/appcast.xml")";      check "appcast.xml 200"                               grep -q '^HTTP/.* 200' <<<"$h"
                                        check "appcast.xml Content-Type application/xml"      grep -qi '^content-type: application/xml' <<<"$h"
                                        check "appcast.xml Cache-Control no-cache"            grep -qi '^cache-control: no-cache, max-age=0' <<<"$h"
body="$(curl -s "$S/macos/appcast.xml")"
                                        check "appcast enclosure url 이 전부 $S/macos/ 로 렌더링" bash -c '[ "$(grep -o "url=\"[^\"]*\"" <<<"$0" | grep -vc "url=\"$1/macos/")" = 0 ]' "$body" "$S"
                                        check "appcast 에 item 하나만"                        bash -c '[ "$(grep -c "<item>" <<<"$0")" = 1 ]' "$body"
                                        check "자리표시자 미잔존"                             bash -c '! grep -q __STUDIO_BASE_URL__ <<<"$0"' "$body"
h="$(hdr "$S/windows/LucyStudio.appinstaller")"; check "appinstaller 200"                     grep -q '^HTTP/.* 200' <<<"$h"
                                        check "appinstaller Content-Type application/appinstaller" grep -qi '^content-type: application/appinstaller' <<<"$h"
                                        check "appinstaller Cache-Control no-cache"           grep -qi '^cache-control: no-cache, max-age=0' <<<"$h"
wbody="$(curl -s "$S/windows/LucyStudio.appinstaller")"
                                        check "appinstaller 두 Uri 가 $S/windows/ 로 렌더링"   bash -c '[ "$(grep -o "Uri=\"[^\"]*\"" <<<"$0" | grep -vc "Uri=\"$1/windows/")" = 0 ]' "$wbody" "$S"
h="$(hdr "$S/macos/appcast.xml.tmpl")"; check ".tmpl 경로 404"                                grep -q '^HTTP/.* 404' <<<"$h"
h="$(hdr "$S/")";                        check "디렉터리 목록 노출 안 됨 (/studio/ 403|404)"   grep -qE '^HTTP/.* (403|404)' <<<"$h"

echo "== 패키지 (Range, MIME, 캐시)"
msix="$(python3 -c 'import json,sys; d=json.load(open("dist/latest.json")); print((d["files"]["windowsMsix"] or {}).get("path",""))')"
if [ -n "$msix" ]; then
  h="$(hdr -r 0-65535 "$S/$msix")";     check "msix Range 요청 → 206"                         grep -q '^HTTP/.* 206' <<<"$h"
                                        check "msix Content-Type application/msix"            grep -qi '^content-type: application/msix' <<<"$h"
                                        check "msix Content-Range 헤더"                       grep -qi '^content-range: bytes 0-65535/' <<<"$h"
                                        check "msix Cache-Control immutable"                  grep -qi 'immutable' <<<"$h"
  h2="$(hdr "$S/$msix")";               check "msix GET 200 에 Accept-Ranges bytes"            grep -qi '^accept-ranges: bytes' <<<"$h2"
fi
delta="$(ls dist/macos/*.delta 2>/dev/null | head -1 | xargs -I{} basename {} 2>/dev/null || true)"
if [ -n "$delta" ]; then
  enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$delta")"
  h="$(hdr "$S/macos/$enc")";           check "공백 포함 델타 파일명(URL 인코딩) 200"           grep -q '^HTTP/.* 200' <<<"$h"
                                        check "delta Content-Type application/octet-stream"   grep -qi '^content-type: application/octet-stream' <<<"$h"
fi
dmg="$(python3 -c 'import json; d=json.load(open("dist/latest.json")); print(d["files"]["macosDmg"]["path"])')"
h="$(hdr "$S/$dmg")";                   check "dmg Content-Type application/x-apple-diskimage" grep -qi '^content-type: application/x-apple-diskimage' <<<"$h"
echo "== latest.json 의 size/sha256 대조 (전체 다운로드)"
python3 - "$S" <<'PY'
import json, hashlib, sys, urllib.request
S = sys.argv[1]
d = json.load(open('dist/latest.json'))
bad = 0
for k, v in d['files'].items():
    if not v: continue
    data = urllib.request.urlopen(f"{S}/{v['path']}").read()
    okk = len(data) == v['size'] and hashlib.sha256(data).hexdigest() == v['sha256']
    print(f"  {'PASS' if okk else 'FAIL'} {k}: {v['path']} ({len(data)} bytes)")
    bad += (not okk)
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] && ok "latest.json 의 모든 파일 size/sha256 일치" || bad "latest.json size/sha256 불일치"

echo
echo "PASS=$pass FAIL=$fail"
docker compose -f compose.verify.yml down -v >/dev/null 2>&1 || true
[ "$fail" = 0 ]
