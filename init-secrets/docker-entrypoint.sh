#!/bin/sh
# Lucy onprem offline init-secrets entrypoint
#
# 이 스크립트는 폐쇄망용 init-secrets 이미지 안에서 실행된다.
# 런타임에 apk add를 하지 않는다.
# openssl은 Dockerfile 빌드 시점에 이미지에 포함된다.

set -e

SECRETS=/secrets/secrets.env
CERT_DIR=/certs

if ! command -v openssl >/dev/null 2>&1; then
  echo "[init-secrets] openssl is not installed in this image." >&2
  exit 1
fi

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# ──────────────────────────────────────────────
# 1) self-signed 인증서 발급
# ──────────────────────────────────────────────
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
  echo "[init-secrets] $CERT_DIR/server.{crt,key} already exist, skipping cert."
else
  HOST=$(printf '%s' "$EXTERNAL_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')

  if [ -z "$HOST" ]; then
    echo "[init-secrets] EXTERNAL_URL is empty; cannot generate cert." >&2
    exit 1
  fi

  if is_ipv4 "$HOST"; then
    SAN="IP:$HOST,DNS:localhost"
  else
    SAN="DNS:$HOST,DNS:localhost"
  fi

  echo "[init-secrets] generating self-signed cert for $HOST ..."
  echo "[init-secrets] subjectAltName=$SAN"

  mkdir -p "$CERT_DIR"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -days 3650 \
    -subj "/CN=$HOST/O=Lucy TeamCloud/C=KR" \
    -addext "subjectAltName=$SAN" \
    >/dev/null 2>&1

  chmod 644 "$CERT_DIR/server.crt"
  chmod 600 "$CERT_DIR/server.key"
fi

# ──────────────────────────────────────────────
# 2) 인스턴스별 시크릿 발급
# ──────────────────────────────────────────────
if [ -f "$SECRETS" ]; then
  echo "[init-secrets] $SECRETS already exists, skipping."
  exit 0
fi

echo "[init-secrets] generating $SECRETS ..."

mkdir -p /secrets

JWT_PRIV=$(openssl genrsa 2048 2>/dev/null)
JWT_PRIV_B64=$(printf '%s' "$JWT_PRIV" | base64 | tr -d '\n')
JWT_PUB_B64=$(printf '%s' "$JWT_PRIV" | openssl rsa -pubout 2>/dev/null | base64 | tr -d '\n')

JWT_ONETIME=$(openssl rand -base64 32 | tr -d '\n')
COOKIE_K1=$(openssl rand -base64 32 | tr -d '\n')
COOKIE_K2=$(openssl rand -base64 32 | tr -d '\n')
TC_OIDC_SECRET=$(openssl rand -hex 32)
AUTH_OIDC_SECRET=$(openssl rand -hex 32)
GITEA_WEBHOOK=$(openssl rand -hex 32)

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