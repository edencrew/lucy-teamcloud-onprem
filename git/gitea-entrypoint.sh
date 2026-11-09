#!/bin/sh
# gitea 컨테이너 래퍼 엔트리포인트
# - /run/secrets/secrets.env 의 GITEA__* 를 export (init-secrets 가 생성, app.ini 의 placeholder 를 런타임 오버라이드)
# - 최초 실행 시 관리자 계정 생성 (tc-be 가 GIT_USERNAME/GIT_PASSWORD 로 쓰는 계정)

set -a
. /run/secrets/secrets.env
set +a

# Gitea 는 docker network 내부 호스트(git)로만 노출. 사용자는 nginx → tc-be Git Proxy 경유로 도달.
# ROOT_URL 은 API 응답의 clone_url 을 결정한다. 외부 도메인이면 BE 컨테이너에서 도달 불가하고,
# 포트가 빠지면 80 포트를 가리켜 시드 push 가 'Failed to connect to git:80' 으로 실패한다
# (v0.0.16~v0.0.25 패키지 결함 — Tutorial 01 이 빈 리포로 남았다). app.ini 의 HTTP_PORT(18080) 를 반드시 포함한다.
export GITEA__server__DOMAIN=git
export GITEA__server__ROOT_URL="http://git:18080/"

GITEA_HEALTHZ_URL="http://localhost:18080/api/healthz"
ADMIN_MARKER=/data/gitea/.admin-created

# app.ini 초기화
# app.ini의 상위폴더가 data폴더로 이미 마운트되어 하위 app.ini는 마운트 불가
# 따라서 /app.ini.default 를 별도로 마운트하고, 최초 실행 시 복사하는 방식 사용.
if [ ! -f /data/gitea/conf/app.ini ]; then
  mkdir -p /data/gitea/conf
  cp /app.ini.default /data/gitea/conf/app.ini
  echo "app.ini initialized from default"
fi

# 관리자 계정이 이미 있는지 (마커 없이 계정만 있는 경우: 데이터 복원·마커 유실)
admin_exists() {
  su-exec git gitea admin user list --config /data/gitea/conf/app.ini --admin 2>/dev/null \
    | awk 'NR > 1 { print $2 }' | grep -qx "${LUCY_ADMIN_NAME}"
}

# 첫 실행 시에만 생성 (백그라운드). 마커는 성공했을 때만 남긴다 → 실패하면 다음 기동 때 재시도.
# compose 의 git healthcheck 가 이 마커를 조건으로 삼아, 계정이 생기기 전에는 tc-be 가 뜨지 않게 한다.
if [ ! -f "$ADMIN_MARKER" ]; then
  (
    # 고정 sleep 대신 Gitea 가 실제로 응답할 때까지 대기 (첫 부팅은 DB 마이그레이션 때문에 느릴 수 있다)
    i=0
    until curl -fsS "$GITEA_HEALTHZ_URL" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 90 ]; then
        echo "Gitea did not become healthy within 180s; admin user creation skipped (retried on next start)" >&2
        exit 1
      fi
      sleep 2
    done

    # 중복방지를 위해 email 은 gitea.com 도메인 사용. 실패 원인은 숨기지 않고 컨테이너 로그에 남긴다.
    if su-exec git gitea admin user create \
      --config /data/gitea/conf/app.ini \
      --username "${LUCY_ADMIN_NAME}" \
      --password "${LUCY_ADMIN_PASSWORD}" \
      --email "${LUCY_ADMIN_NAME}@gitea.com" \
      --admin \
      --must-change-password=false; then
      touch "$ADMIN_MARKER"
      echo "Admin user created successfully"
    elif admin_exists; then
      touch "$ADMIN_MARKER"
      echo "Admin user already exists"
    else
      echo "Admin user creation failed (see error above); will retry on next start" >&2
    fi
  ) &
fi

# 원래 entrypoint 실행 (사용자 전환 포함)
exec /usr/bin/entrypoint
