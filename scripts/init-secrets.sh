#!/bin/sh
# Lucy onprem 인스턴스별 시크릿 자동 생성 스크립트
#
# 첫 부팅 시 한 번만 실행되어 /secrets/secrets.env 를 생성한다.
# 이후 부팅에서는 파일이 이미 존재하면 아무 것도 하지 않는다 (idempotent).
# 생성 결과 파일은 데이터 폴더(postgres/data, git/data)와 동일한 라이프사이클로 보존되어야 한다.
# 이 파일이 분실되면 모든 사용자 재로그인 + Gitea 2FA 데이터 복호화 불가.

set -e

SECRETS=/secrets/secrets.env

if [ -f "$SECRETS" ]; then
  echo "[init-secrets] $SECRETS already exists, skipping."
  exit 0
fi

echo "[init-secrets] generating $SECRETS ..."

# alpine 이미지에 openssl 이 없으면 설치
if ! command -v openssl >/dev/null 2>&1; then
  apk add --no-cache openssl >/dev/null
fi

mkdir -p /secrets

# RSA 2048 키쌍 (auth-be JWT 서명/검증)
JWT_PRIV=$(openssl genrsa 2048 2>/dev/null)
JWT_PRIV_B64=$(printf '%s' "$JWT_PRIV" | base64 | tr -d '\n')
JWT_PUB_B64=$(printf '%s' "$JWT_PRIV" | openssl rsa -pubout 2>/dev/null | base64 | tr -d '\n')

# 단발 시크릿
JWT_ONETIME=$(openssl rand -base64 32 | tr -d '\n')
COOKIE_K1=$(openssl rand -base64 32 | tr -d '\n')
COOKIE_K2=$(openssl rand -base64 32 | tr -d '\n')
TC_OIDC_SECRET=$(openssl rand -hex 32)
AUTH_OIDC_SECRET=$(openssl rand -hex 32)
GITEA_WEBHOOK=$(openssl rand -hex 32)

# Gitea 자체 시크릿
GITEA_SECRET_KEY=$(openssl rand -hex 64)
GITEA_INTERNAL_TOKEN=$(openssl rand -hex 32)
GITEA_LFS_JWT=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
GITEA_OAUTH2_JWT=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')

cat > "$SECRETS" <<EOF
# Lucy onprem secrets — 자동 생성 (수동 편집 금지)
# 생성 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)

JWT_PRIVATE_KEY_BASE64=$JWT_PRIV_B64
JWT_PUBLIC_KEY_BASE64=$JWT_PUB_B64
JWT_ONETIME_TOKEN_SECRET=$JWT_ONETIME
OIDC_COOKIE_KEYS=$COOKIE_K1,$COOKIE_K2
TC_OIDC_CLIENT_SECRET=$TC_OIDC_SECRET
AUTH_OIDC_CLIENT_SECRET=$AUTH_OIDC_SECRET
GITEA_WEBHOOK_SECRET=$GITEA_WEBHOOK

GITEA__security__SECRET_KEY=$GITEA_SECRET_KEY
GITEA__security__INTERNAL_TOKEN=$GITEA_INTERNAL_TOKEN
GITEA__server__LFS_JWT_SECRET=$GITEA_LFS_JWT
GITEA__oauth2__JWT_SECRET=$GITEA_OAUTH2_JWT
EOF

chmod 644 "$SECRETS"

echo "[init-secrets] done."
