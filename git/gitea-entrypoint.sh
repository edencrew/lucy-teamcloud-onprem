#!/bin/sh
# gitea 컨테이너 최초 실행 시 관리자 계정을 생성하는 스크립트

# /run/secrets/secrets.env 의 GITEA__* 환경변수를 export
# (init-secrets 가 자동 생성, app.ini 의 placeholder 들을 런타임 오버라이드)
set -a
. /run/secrets/secrets.env
set +a

# Gitea 는 docker network 내부 호스트(git)로만 노출. 사용자는 nginx → tc-be Git Proxy 경유로 도달.
# ROOT_URL 을 외부 도메인으로 두면 응답 cloneUrl 이 BE 컨테이너에서 도달 불가 → 시드 push 실패.
export GITEA__server__DOMAIN=git
export GITEA__server__ROOT_URL="http://git/"

# app.ini 초기화
# app.ini의 상위폴더가 data폴더로 이미 마운트되어 하위 app.ini는 마운트 불가
# 따라서 /app.ini.default 를 별도로 마운트하고, 최초 실행 시 복사하는 방식 사용.
if [ ! -f /data/gitea/conf/app.ini ]; then
  mkdir -p /data/gitea/conf
  cp /app.ini.default /data/gitea/conf/app.ini
  echo "app.ini initialized from default"
fi

# 첫 실행 시에만 생성 (백그라운드)
if [ ! -f /data/gitea/.admin-created ]; then
  (
    echo "Waiting for Gitea to start..."
    sleep 20

    # 관리자 계정 생성 (중복방지를 위해 email 은 gitea.com도메인 사용)
    if su-exec git gitea admin user create \
      --config /data/gitea/conf/app.ini \
      --username "${LUCY_ADMIN_NAME}" \
      --password "${LUCY_ADMIN_PASSWORD}" \
      --email "${LUCY_ADMIN_NAME}@gitea.com" \
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