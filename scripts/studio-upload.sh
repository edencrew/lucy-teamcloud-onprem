#!/usr/bin/env bash
# Studio 번들(.tar / .tar.gz / .zip)을 TC 에 올린다. 조직 owner 의 PAT(api scope)가 필요하다.
#
# 사용: ./scripts/studio-upload.sh <번들 파일> [TC 주소]
#   TC 주소를 생략하면 환경변수 EXTERNAL_URL, 그것도 없으면 입력을 받는다.
#   자체 서명 인증서면 CACERT=nginx/certs/server.crt 를 함께 준다.
set -euo pipefail

FILE="${1:?usage: $0 <bundle file> [TC url]}"
[ -f "$FILE" ] || { echo "파일이 없습니다: $FILE" >&2; exit 1; }
BASE="${2:-${EXTERNAL_URL:-}}"
[ -n "$BASE" ] || read -rp "TC 주소 (예: https://teamcloud.example.com): " BASE
BASE="${BASE%/}"
read -rsp "PAT (api scope): " TOKEN; echo
[ -n "$TOKEN" ] || { echo "PAT 가 비었습니다." >&2; exit 1; }

CURL_TLS=()
[ -n "${CACERT:-}" ] && CURL_TLS=(--cacert "$CACERT")

RESP="$(mktemp)"; trap 'rm -f "$RESP"' EXIT
# Content-Type 은 반드시 application/octet-stream. 빠지면 415 로 거절된다.
# --data-binary @파일 은 파일 전체를 메모리에 올리므로 -T 로 스트리밍한다(-X POST 로 메서드만 바꾼다).
# 토큰은 프로세스 목록에 남지 않도록 stdin 의 curl 설정(-K -)으로 넘긴다. -s 는 진행 표시까지 끄므로 쓰지 않는다.
STATUS="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -K - "${CURL_TLS[@]+"${CURL_TLS[@]}"}" \
  -o "$RESP" -w '%{http_code}' --progress-bar -X POST \
  "$BASE/api/v1/onprem/studio-releases" \
  -H "Content-Type: application/octet-stream" \
  -T "$FILE")"
cat "$RESP"; echo
if [ "$STATUS" != "201" ]; then echo "업로드 실패 (HTTP $STATUS)" >&2; exit 1; fi
echo "업로드 완료. $BASE/studio/latest.json 의 version·build 를 확인하고, 사용한 PAT 는 TC 웹에서 폐기하세요."
