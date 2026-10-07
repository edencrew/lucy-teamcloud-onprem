#!/bin/sh
# lucy-studio-dist entrypoint.
# STUDIO_BASE_URL 로 피드 템플릿을 렌더링한 뒤 nginx 를 띄운다.
set -eu

TEMPLATES=/opt/studio-dist/templates
WEBROOT=/usr/share/nginx/html

BASE="${STUDIO_BASE_URL:-}"
if [ -z "$BASE" ]; then
  echo "[studio-dist] STUDIO_BASE_URL is required (e.g. https://teamcloud.example.com/studio)" >&2
  exit 1
fi
# 끝의 / 는 전부 뗀다. 피드 템플릿이 __STUDIO_BASE_URL__/macos/... 형태로 / 를 붙이기 때문이다.
while [ "${BASE%/}" != "$BASE" ]; do BASE="${BASE%/}"; done
case "$BASE" in
  http://*|https://*) ;;
  *) echo "[studio-dist] STUDIO_BASE_URL must start with http:// or https:// : $BASE" >&2; exit 1 ;;
esac

# sed 치환용 이스케이프 (구분자 | 와 & , \ )
BASE_ESC=$(printf '%s' "$BASE" | sed 's/[|&\\]/\\&/g')

if [ -d "$TEMPLATES" ]; then
  find "$TEMPLATES" -type f -name '*.tmpl' | while IFS= read -r tmpl; do
    rel="${tmpl#"$TEMPLATES"/}"
    out="$WEBROOT/${rel%.tmpl}"
    mkdir -p "$(dirname "$out")"
    sed "s|__STUDIO_BASE_URL__|$BASE_ESC|g" "$tmpl" > "$out"
    echo "[studio-dist] rendered ${rel%.tmpl}"
  done
fi

if grep -rl '__STUDIO_BASE_URL__' "$WEBROOT" >/dev/null 2>&1; then
  echo "[studio-dist] unrendered placeholder remains under $WEBROOT" >&2
  exit 1
fi

echo "[studio-dist] STUDIO_BASE_URL=$BASE"
# nginx 공식 이미지의 entrypoint 를 그대로 태워 기본 동작(envsubst, 로그 설정)을 유지한다.
exec /docker-entrypoint.sh nginx -g 'daemon off;'
