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

DATA_ROOT=/data
GITEA_DATA=/data/gitea
ADMIN_MARKER="$GITEA_DATA/.admin-created"

# 이 래퍼가 만드는 데이터는 처음부터 데이터 소유자(USER_UID:USER_GID, stock entrypoint 가 git 사용자에 쓰는 값)로
# 만든다. rootless keep-id 에서 이 숫자는 호스트 설치 계정이고, root 로 만들면 subordinate UID 소유가 된다.
DATA_UID="${USER_UID:-1000}"
DATA_GID="${USER_GID:-1000}"
case "$DATA_UID:$DATA_GID" in
  *[!0-9:]*|:*|*:) echo "invalid USER_UID/USER_GID: $DATA_UID:$DATA_GID" >&2; exit 1 ;;
esac
as_data() {
  if [ "$(id -u)" = 0 ]; then su-exec "$DATA_UID:$DATA_GID" "$@"; else "$@"; fi
}
# 없는 디렉터리만 하나씩 만들고 그 디렉터리만 데이터 소유자로 둔다(기존 데이터 재귀 chown 없음).
data_dir() {
  [ -d "$1" ] && return 0
  mkdir "$1" || return 1
  if [ "$(id -u)" = 0 ]; then chown "$DATA_UID:$DATA_GID" "$1" || return 1; fi
}

# stock entrypoint/s6 가 root 로 먼저 만들지 않도록 최소 초기 디렉터리를 app.ini 유무와 무관하게 미리 만든다.
# 이미 있는 디렉터리는 건드리지 않는다(기존 설치 마이그레이션은 별도). 권한은 umask 기본값 그대로.
data_dir "$GITEA_DATA" && data_dir "$GITEA_DATA/conf" && data_dir "$GITEA_DATA/log" \
  || { echo "cannot create $GITEA_DATA dirs" >&2; exit 1; }
# SSH host key 소유자 정책(opt-in, compose.podman.yml 만 TC_GITEA_SSH_KEY_OWNER=data). 미설정이면 stock 동작 그대로(Docker).
# stock s6 openssh setup 은 DISABLE_SSH 와 무관하게 없는 host key 를 root 로 ssh-keygen 하고, 끝에서 무조건
# `chown root:root /data/ssh/*` 한다(rootless: subordinate 소유). 그래서 key 를 미리 만드는 것만으로는 부족하다.
# 정확한 stock 계약을 확인한 뒤 컨테이너 안(비영속 layer)의 setup 에서 그 chown 한 줄만 "데이터 소유자 파일은 건너뛰고
# 나머지는 stock 대로 root:root" 로 바꾼다. 계약이 다르면 SSH 를 끄지 않고 시작을 거부한다. 데이터 파일 chown/이전 없음.
SSH_SETUP=/etc/s6/openssh/setup
case "${TC_GITEA_SSH_KEY_OWNER:-}" in
  "") ;;
  data)
    STOCK_CHOWN='chown root:root /data/ssh/*'
    OWNED_CHOWN="for f in /data/ssh/*; do find \"\$f\" -prune -user $DATA_UID -group $DATA_GID | grep -q . || chown root:root \"\$f\"; done # teamcloud: keep data-owned host keys"
    ssh_contract() { # stock 또는 이미 같은 정책으로 바뀐 setup 만 허용(컨테이너 재시작 시 layer 유지)
      [ -f "$SSH_SETUP" ] && [ "$(grep -c chown "$SSH_SETUP")" = 1 ] || return 1
      grep -qxF 'chmod 0700 /data/ssh' "$SSH_SETUP" && grep -qxF 'chmod 0600 /data/ssh/*' "$SSH_SETUP" || return 1
      for t in ed25519 rsa ecdsa; do grep -qxF "if [ ! -f /data/ssh/ssh_host_${t}_key ]; then" "$SSH_SETUP" || return 1; done
      [ "$(( $(grep -cxF "$STOCK_CHOWN" "$SSH_SETUP") + $(grep -cxF "$OWNED_CHOWN" "$SSH_SETUP") ))" = 1 ]
    }
    ssh_contract || { echo "unknown stock $SSH_SETUP contract; refusing to start (SSH key owner policy)" >&2; exit 1; }
    if grep -qxF "$STOCK_CHOWN" "$SSH_SETUP"; then
      awk -v old="$STOCK_CHOWN" -v new="$OWNED_CHOWN" '$0==old{print new;next}{print}' "$SSH_SETUP" > "$SSH_SETUP.tc.$$" \
        && cat "$SSH_SETUP.tc.$$" > "$SSH_SETUP" && rm -f "$SSH_SETUP.tc.$$" && grep -qxF "$OWNED_CHOWN" "$SSH_SETUP" \
        || { rm -f "$SSH_SETUP.tc.$$"; echo "cannot adapt $SSH_SETUP" >&2; exit 1; }
    fi
    # stock 과 같은 종류/경로의 없는 key 만 데이터 소유자로 먼저 만들면 stock 은 파일이 있으므로 생성을 건너뛴다.
    # 기존 key 는 건드리지 않는다(재시작/재생성 시 같은 fingerprint).
    # ssh-keygen 은 실행 UID 의 passwd 항목(getpwuid)을 요구하는데, git 사용자를 USER_UID 로 바꾸는 것은 이 래퍼 뒤의
    # stock entrypoint 이다. 그래서 key 는 현재 계정(root, stock 과 같은 주체)으로 컨테이너 안 비영속 0700 임시 디렉터리에
    # 만들고, 영속 파일은 데이터 소유자가 noclobber 로 "새로" 만든다(개인키 0600, 공개키 0644). chown 없음.
    data_dir "$DATA_ROOT/ssh" || { echo "cannot create $DATA_ROOT/ssh" >&2; exit 1; }
    KEYTMP=""
    key_tmp_safe() {
      case "${KEYTMP:-}" in /tmp/tc-hostkey.??????) ;; *) return 1 ;; esac
      [ -d "$KEYTMP" ] && [ ! -L "$KEYTMP" ]
    }
    key_tmp_cleanup() {
      [ -n "$KEYTMP" ] || return 0
      key_tmp_safe || return 1
      # 이 실행이 생성하는 정확한 여섯 파일만 제거한다. 링크/다른 타입/예상 밖 파일은 재귀 삭제하지 않는다.
      for temp_name in ssh_host_ed25519_key ssh_host_ed25519_key.pub ssh_host_rsa_key ssh_host_rsa_key.pub ssh_host_ecdsa_key ssh_host_ecdsa_key.pub; do
        temp_path="${KEYTMP:?}/$temp_name"
        [ ! -L "$temp_path" ] || return 1
        if [ -e "$temp_path" ]; then
          [ -f "$temp_path" ] && rm -- "$temp_path" || return 1
        fi
      done
      rmdir -- "$KEYTMP" || return 1
      KEYTMP=""
    }
    for spec in "ed25519" "rsa -b 3072" "ecdsa -b 256"; do
      name="ssh_host_${spec%% *}_key"; key="$DATA_ROOT/ssh/$name"
      [ -f "$key" ] && continue
      # 개인키 없이 남은 공개키 등은 덮어쓰지도 옮기지도 않는다(부분 생성 방지, 시작 거부)
      [ -e "$key.pub" ] && { echo "ssh host key init refused: $key.pub exists without $key" >&2; exit 1; }
      if [ -z "$KEYTMP" ]; then
        KEYTMP="$(mktemp -d /tmp/tc-hostkey.XXXXXX)" && key_tmp_safe && chmod 0700 "$KEYTMP" \
          || { echo "cannot create transient host key dir" >&2; exit 1; }
      fi
      # shellcheck disable=SC2086
      ssh-keygen -q -t $spec -N "" -f "$KEYTMP/$name" < /dev/null \
        && as_data sh -c 'set -C && umask 077 && cat > "$1"' sh "$key" < "$KEYTMP/$name" \
        && as_data sh -c 'set -C && umask 022 && cat > "$1"' sh "$key.pub" < "$KEYTMP/$name.pub" \
        || { key_tmp_cleanup || echo "cannot clean transient host key dir" >&2; echo "ssh host key init failed: $key" >&2; exit 1; }
    done
    key_tmp_cleanup || { echo "cannot clean transient host key dir" >&2; exit 1; } ;;
  *) echo "invalid TC_GITEA_SSH_KEY_OWNER: $TC_GITEA_SSH_KEY_OWNER" >&2; exit 1 ;;
esac

# app.ini 초기화
# app.ini의 상위폴더가 data폴더로 이미 마운트되어 하위 app.ini는 마운트 불가
# 따라서 /app.ini.default 를 별도로 마운트하고, 최초 실행 시 복사하는 방식 사용.
if [ ! -f "$GITEA_DATA/conf/app.ini" ]; then
  # 원본은 root 가 읽고, 대상 파일은 데이터 소유자가 생성한다.
  as_data tee "$GITEA_DATA/conf/app.ini" < /app.ini.default > /dev/null || { echo "app.ini init failed" >&2; exit 1; }
  echo "app.ini initialized from default"
fi

# 관리자 계정이 이미 있는지 (마커 없이 계정만 있는 경우: 데이터 복원·마커 유실)
admin_exists() {
  su-exec git gitea admin user list --config "$GITEA_DATA/conf/app.ini" --admin 2>/dev/null \
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
      --config "$GITEA_DATA/conf/app.ini" \
      --username "${LUCY_ADMIN_NAME}" \
      --password "${LUCY_ADMIN_PASSWORD}" \
      --email "${LUCY_ADMIN_NAME}@gitea.com" \
      --admin \
      --must-change-password=false; then
      as_data touch "$ADMIN_MARKER"
      echo "Admin user created successfully"
    elif admin_exists; then
      as_data touch "$ADMIN_MARKER"
      echo "Admin user already exists"
    else
      echo "Admin user creation failed (see error above); will retry on next start" >&2
    fi
  ) &
fi

# 원래 entrypoint 실행 (사용자 전환 포함)
exec /usr/bin/entrypoint
