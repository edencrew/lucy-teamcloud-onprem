#!/bin/sh
# gitea 컨테이너 최초 실행 시 관리자 계정을 생성하는 스크립트

# EXTERNAL_URL에서 도메인 추출 (https://example.com -> example.com)
EXTERNAL_DOMAIN=$(echo "$EXTERNAL_URL" | sed -E 's#https?://([^/]+).*#\1#')
export GITEA__server__DOMAIN=$EXTERNAL_DOMAIN
export GITEA__server__SSH_DOMAIN=$EXTERNAL_DOMAIN
export GITEA__server__ROOT_URL="${EXTERNAL_URL}/git/"

# 첫 실행 시에만 생성 (백그라운드)
if [ ! -f /data/gitea/.admin-created ]; then
  (
    echo "Waiting for Gitea to start..."
    sleep 20

    # 관리자 계정 생성
    if su-exec git gitea admin user create \
      --config /data/gitea/conf/app.ini \
      --username "${LUCY_ADMIN_NAME}" \
      --password "${LUCY_ADMIN_PASSWORD}" \
      --email "${LUCY_ADMIN_EMAIL}" \
      --admin \
      --must-change-password=false 2>/dev/null; then

      # 생성완료 표시
      touch /data/gitea/.admin-created
      echo "Admin user created successfully"

    else
      echo "Admin user already exists or creation failed"
    fi
  ) &
fi

# 원래 entrypoint 실행 (사용자 전환 포함)
exec /usr/bin/entrypoint