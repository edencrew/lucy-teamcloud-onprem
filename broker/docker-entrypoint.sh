#!/usr/bin/env bash
set -euo pipefail

VMQ_HOME="/vernemq"
ETC_DIR="${VMQ_HOME}/etc"
CONF_FILE="${ETC_DIR}/vernemq.conf"
VM_ARGS="${ETC_DIR}/vm.args"
PASS_FILE="${ETC_DIR}/vmq.passwd"

ts(){ date +'%H:%M:%S'; }
log(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] [error] $*" >&2; exit 1; }

ROOTLESS_USERNS=0
VMQ_RUN_AS_ROOT=0

detect_rootless_userns() {
  local inside outside count

  [ -r /proc/self/uid_map ] || return 1
  read -r inside outside count < /proc/self/uid_map || return 1
  [[ "$inside" == "0" && "$outside" != "0" ]]
}

if [[ "$(id -u)" == "0" ]] && detect_rootless_userns; then
  ROOTLESS_USERNS=1
  VMQ_RUN_AS_ROOT=1
  log "[entrypoint] rootless user namespace detected; running as container root and skipping bind-mount chown"
fi

should_run_as_vmq_user() {
  [[ "$(id -u)" == "0" && "$VMQ_RUN_AS_ROOT" != "1" ]]
}

chown_vmq() {
  if [[ "$VMQ_RUN_AS_ROOT" == "1" ]]; then
    return 0
  fi

  chown "$@"
}

# vernemq 명령을 항상 동일 ENV로 실행
as_vmq() {
  local erts_bin; erts_bin="$(ls -d /vernemq/erts-*/bin 2>/dev/null | head -1)"
  local PATH_VMQ="${erts_bin:+$erts_bin:}/vernemq/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
  if should_run_as_vmq_user; then
    runuser -u vernemq -m -- env \
      HOME="${VMQ_HOME}" \
      PATH="$PATH_VMQ" \
      RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-/vernemq/log}" \
      PIPE_DIR="${PIPE_DIR:-/tmp/erl_pipes}" \
      ERL_AFLAGS="${ERL_AFLAGS:- -proto_dist inet_tcp}" \
      ERL_INETRC="${ERL_INETRC:-/vernemq/etc/inetrc}" \
      ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" \
      "$@"
  else
    env HOME="${VMQ_HOME}" PATH="$PATH_VMQ" \
      RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-/vernemq/log}" \
      PIPE_DIR="${PIPE_DIR:-/tmp/erl_pipes}" \
      ERL_AFLAGS="${ERL_AFLAGS:- -proto_dist inet_tcp}" \
      ERL_INETRC="${ERL_INETRC:-/vernemq/etc/inetrc}" \
      ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" \
      "$@"
  fi
}

# 0) 기본 디렉토리/권한 & HOME=/vernemq (★ 중요: /root 참조 방지)
mkdir -p "${ETC_DIR}" "${VMQ_HOME}/data" "${VMQ_HOME}/log"
export HOME="${VMQ_HOME}"
export RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-${VMQ_HOME}/log}"
export PIPE_DIR="${PIPE_DIR:-/tmp/erl_pipes}"

numeric_id(){ [[ "$1" =~ ^[0-9]+$ ]]; }

stat_uid() {
  stat -c '%u' "$1" 2>/dev/null || true
}

stat_gid() {
  stat -c '%g' "$1" 2>/dev/null || true
}

detect_data_owner() {
  local path="$1"
  local uid gid

  uid="$(stat_uid "$path")"
  gid="$(stat_gid "$path")"

  if numeric_id "${uid:-}" && numeric_id "${gid:-}" && [[ "$uid" != "0" ]]; then
    VMQ_UID="$uid"
    VMQ_GID="$gid"
    log "[entrypoint] detected /vernemq/data owner -> ${VMQ_UID}:${VMQ_GID}"
    return 0
  fi

  return 1
}

ensure_owned_recursive() {
  local path="$1"
  local uid="$2"
  local gid="$3"
  local mismatch

  if [[ "$VMQ_RUN_AS_ROOT" == "1" ]]; then
    return 0
  fi

  [ -e "$path" ] || return 0

  mismatch="$(find "$path" \( ! -user "$uid" -o ! -group "$gid" \) -print -quit 2>/dev/null || true)"
  if [[ -n "$mismatch" ]]; then
    log "[entrypoint] chown ${path} -> ${uid}:${gid}"
    chown -R "${uid}:${gid}" "$path" || die "failed to chown ${path} to ${uid}:${gid}"
  fi
}

prepare_vmq_paths() {
  if [[ "$(id -u)" != "0" ]]; then
    return 0
  fi

  if [[ "$VMQ_RUN_AS_ROOT" == "1" ]]; then
    return 0
  fi

  ensure_owned_recursive "${ETC_DIR}" "$VMQ_UID" "$VMQ_GID"
  ensure_owned_recursive "${VMQ_HOME}/data" "$VMQ_UID" "$VMQ_GID"
  ensure_owned_recursive "${RUNNER_LOG_DIR}" "$VMQ_UID" "$VMQ_GID"
  ensure_owned_recursive "${PIPE_DIR}" "$VMQ_UID" "$VMQ_GID"
}

remap_vmq_user() {
  local data_uid data_gid has_explicit_owner

  if [[ "$(id -u)" != "0" ]]; then
    return 0
  fi

  if [[ "$ROOTLESS_USERNS" == "1" ]]; then
    unset VMQ_UID
    unset VMQ_GID
    return 0
  fi

  has_explicit_owner=0
  if [[ -n "${VMQ_UID:-}" || -n "${VMQ_GID:-}" ]]; then
    has_explicit_owner=1
  fi

  if [[ "$has_explicit_owner" == "1" && ( -z "${VMQ_UID:-}" || -z "${VMQ_GID:-}" ) ]]; then
    die "VMQ_UID and VMQ_GID must be set together. Run preflight or set HOST_UID/HOST_GID in .env."
  fi

  if [[ -z "${VMQ_UID:-}" || -z "${VMQ_GID:-}" ]]; then
    data_uid="$(stat_uid "${VMQ_HOME}/data")"
    data_gid="$(stat_gid "${VMQ_HOME}/data")"

    if [[ "$data_uid" == "0" ]]; then
      die "/vernemq/data is root-owned and VMQ_UID/VMQ_GID are not set. Run ./scripts/preflight-onprem.sh or set HOST_UID/HOST_GID in .env before recreating broker."
    fi

    if numeric_id "${data_uid:-}" && numeric_id "${data_gid:-}"; then
      detect_data_owner "${VMQ_HOME}/data" || true
    fi
  fi

  if [[ -z "${VMQ_UID:-}" || -z "${VMQ_GID:-}" ]]; then
    VMQ_UID="$(id -u vernemq)"
    VMQ_GID="$(id -g vernemq)"
    log "[entrypoint] VMQ_UID/VMQ_GID unset; using image default vernemq uid:gid -> ${VMQ_UID}:${VMQ_GID}"
  fi

  if ! numeric_id "$VMQ_UID" || ! numeric_id "$VMQ_GID"; then
    die "VMQ_UID/VMQ_GID must be numeric: ${VMQ_UID}:${VMQ_GID}"
  fi

  log "[entrypoint] remap vernemq uid:gid -> ${VMQ_UID}:${VMQ_GID}"
  getent group vernemq >/dev/null 2>&1 && groupmod -o -g "${VMQ_GID}" vernemq || groupadd -g "${VMQ_GID}" vernemq
  if id vernemq >/dev/null 2>&1; then
    usermod -o -u "${VMQ_UID}" -g "${VMQ_GID}" vernemq || true
  else useradd -m -u "${VMQ_UID}" -g "${VMQ_GID}" -d "${VMQ_HOME}" -s /sbin/nologin vernemq; fi
}
remap_vmq_user

mkdir -p "${RUNNER_LOG_DIR}/VerneMQ" "${PIPE_DIR}"
chmod 1777 "${PIPE_DIR}" || true
prepare_vmq_paths
LOG_FILE="${RUNNER_LOG_DIR}/VerneMQ/console.log"; : > "${LOG_FILE}" || true
chown_vmq vernemq:vernemq "${LOG_FILE}" || true

# 1) 네트워크 정보
detect_iface(){ ip -o route show default 2>/dev/null | awk '{print $5; exit}'; }
detect_ip_from_iface(){ ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1; }
NET_IFACE="${DOCKER_NET_INTERFACE:-$(detect_iface || true)}"
IP_ADDRESS="${DOCKER_IP_ADDRESS:-$(detect_ip_from_iface "${NET_IFACE:-}" || true)}"
[[ -z "${IP_ADDRESS}" ]] && IP_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
[[ -z "${IP_ADDRESS}" ]] && IP_ADDRESS="127.0.0.1"
export ERL_EPMD_ADDRESS="${IP_ADDRESS}"
log "[net] iface=${NET_IFACE:-N/A} ip=${IP_ADDRESS}"

# ---------- 1.5) write hosts & inetrc (fixes your inetrc error) ----------
mkdir -p /vernemq/etc
cat >/vernemq/etc/hosts <<EOF
127.0.0.1   localhost
${IP_ADDRESS} ${HOSTNAME}
EOF
cat >/vernemq/etc/inetrc <<'EOF'
{lookup, [file, dns]}.
{hosts_file, "/vernemq/etc/hosts"}.
EOF
chown_vmq vernemq:vernemq /vernemq/etc/hosts /vernemq/etc/inetrc || true
export ERL_INETRC=/vernemq/etc/inetrc
log "[diag] ERL_INETRC=${ERL_INETRC}"

# ---------- 2) vm.args generate (or skip) ----------
maybe_generate_vm_args(){
  local force="${DOCKER_VERNEMQ_VM_ARGS_FORCE:-0}"
  if [[ -s "${VM_ARGS}" && "$force" != "1" ]]; then
    log "[vm.args] existing file detected (skip). Set DOCKER_VERNEMQ_VM_ARGS_FORCE=1 to regenerate."
  else
  local P="${DOCKER_VERNEMQ_ERLANG__PROCESS_LIMIT:-512000}"
  local E="${DOCKER_VERNEMQ_ERLANG__MAX_ETS_TABLES:-256000}"
  local Q="${DOCKER_VERNEMQ_ERLANG__MAX_PORTS:-512000}"
  local A="${DOCKER_VERNEMQ_ERLANG__ASYNC_THREADS:-64}"
  local Z="${DOCKER_VERNEMQ_ERLANG__DISTRIBUTION_BUFFER_SIZE:-32768}"
  local CRASH="${DOCKER_VERNEMQ_ERLANG__CRASH_DUMP:-/erl_crash.dump}"
  local FULL="${DOCKER_VERNEMQ_ERLANG__FULLSWEEP_AFTER:-0}"
  local KPOLL="${DOCKER_VERNEMQ_ERLANG__KERNEL_POLL:-true}"
  local COOKIE="${DOCKER_VERNEMQ_DISTRIBUTED_COOKIE:-vmq}"
  local NAME; if [[ -n "${DOCKER_VERNEMQ_NODENAME:-}" ]]; then NAME="${DOCKER_VERNEMQ_NODENAME}"; else NAME="VerneMQ@${IP_ADDRESS}"; fi
    # inet_dist_use_interface = bind distribution to this IPv4
    local TUPLE; TUPLE="$(echo "$IP_ADDRESS" | awk -F. '{printf "{%d,%d,%d,%d}",$1,$2,$3,$4}')"

  cat > "${VM_ARGS}" <<EOF
+P ${P}
+e ${E}
-env ERL_CRASH_DUMP ${CRASH}
-env ERL_FULLSWEEP_AFTER ${FULL}
+Q ${Q}
+A ${A}
-setcookie ${COOKIE}
-name ${NAME}
+K ${KPOLL}
+W w
+sbwt none
+sbwtdcpu none
+sbwtdio none
-smp enable
+zdbbl ${Z}
-kernel inet_dist_use_interface ${TUPLE}
EOF

  chown_vmq vernemq:vernemq "${VM_ARGS}" || true
  log "[vm.args] generated at ${VM_ARGS}"
  fi

  # cookie file must match -setcookie (for vmq-admin/vernemq ping)
  local cookie; cookie="$(awk '$1=="-setcookie"{print $2}' "${VM_ARGS}" | head -1 || true)"
  [[ -z "$cookie" ]] && cookie="vmq"
  printf '%s' "$cookie" > "${VMQ_HOME}/.erlang.cookie"
  chown_vmq vernemq:vernemq "${VMQ_HOME}/.erlang.cookie" || true
  chmod 400 "${VMQ_HOME}/.erlang.cookie" || true
}
maybe_generate_vm_args

# 3) 환경변수 → vernemq.conf (USER_*는 비번파일)
: > "${CONF_FILE}"
chown_vmq vernemq:vernemq "${CONF_FILE}" || true
wrote_passwd=0
while IFS='=' read -r K V; do
  [[ "$K" == DOCKER_VERNEMQ_* ]] || continue
  # 조인/K8s/Swarm/Compose는 conf 직기입 제외
  if [[ "$K" =~ ^DOCKER_VERNEMQ_(DISCOVERY|KUBERNETES|SWARM|COMPOSE) ]]; then continue; fi

  if [[ "$K" == DOCKER_VERNEMQ_USER_* ]]; then
    U="$(echo "${K#DOCKER_VERNEMQ_USER_}" | tr '[:upper:]' '[:lower:]')"
    if [[ $wrote_passwd -eq 0 ]]; then
      echo "plugins.vmq_passwd = on" >> "${CONF_FILE}"
      echo "vmq_passwd.password_file = ${PASS_FILE}" >> "${CONF_FILE}"
      wrote_passwd=1
    fi
    if [[ ! -f "${PASS_FILE}" ]]; then as_vmq vmq-passwd -c "${PASS_FILE}" "${U}" "${V}" || die "vmq-passwd create failed"
    else as_vmq vmq-passwd "${PASS_FILE}" "${U}" "${V}" || die "vmq-passwd update failed"; fi
    continue
  fi

  KEY="$(echo "${K#DOCKER_VERNEMQ_}" | tr '[:upper:]' '[:lower:]' | sed 's/__/./g')"
  # ★ 호환: HTTP__DEFAULT를 metrics로 자동 맵핑(명시적 METRICS가 없을 때만)
  if [[ "$KEY" == "listener.http.default" ]] && ! env | grep -q '^DOCKER_VERNEMQ_LISTENER__HTTP__METRICS='; then
    KEY="listener.http.metrics"
  fi
  echo "${KEY} = ${V}" >> "${CONF_FILE}"
done < <(env)

# defaults
grep -Eq '^[[:space:]]*nodename[[:space:]]*='               "${CONF_FILE}" || echo "nodename = VerneMQ@${IP_ADDRESS}" >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*erlang\.distribution\.port_range\.minimum[[:space:]]*=' "${CONF_FILE}" || echo "erlang.distribution.port_range.minimum = 9100" >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*erlang\.distribution\.port_range\.maximum[[:space:]]*=' "${CONF_FILE}" || echo "erlang.distribution.port_range.maximum = 9109" >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*listener\.tcp\.default[[:space:]]*=' "${CONF_FILE}" || echo "listener.tcp.default = ${IP_ADDRESS}:1883"   >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*listener\.ws\.default[[:space:]]*='  "${CONF_FILE}" || echo "listener.ws.default = ${IP_ADDRESS}:8080"    >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*listener\.vmq\.clustering[[:space:]]*=' "${CONF_FILE}" || echo "listener.vmq.clustering = ${IP_ADDRESS}:44053" >> "${CONF_FILE}"
grep -Eq '^[[:space:]]*listener\.http\.'                    "${CONF_FILE}" || echo "listener.http.metrics = ${IP_ADDRESS}:8888"  >> "${CONF_FILE}"

# 4) cuttlefish generate (검증)
if ! as_vmq vernemq config generate > /tmp/config.out 2>&1; then
  echo "[config]"; sed -n '1,200p' /tmp/config.out; die "cuttlefish generate failed"
fi
log "[config] pre-start generate OK"

# pre-start epmd on the chosen IP (helps distribution init)
ERTS_BIN="$(ls -d /vernemq/erts-*/bin 2>/dev/null | head -1 || true)"
if [[ -n "$ERTS_BIN" ]]; then
  "$ERTS_BIN/epmd" -kill >/dev/null 2>&1 || true
  "$ERTS_BIN/epmd" -daemon -address "$IP_ADDRESS" || true
fi

# ---------- 4.5) Auto-join for Docker Compose ----------
# DOCKER_VERNEMQ_DISCOVERY_NODE 가 설정되면, vm.args 에 -eval join 을 주입해
# 부팅 시 자동으로 클러스터에 조인한다.
if env | grep -q '^DOCKER_VERNEMQ_DISCOVERY_NODE='; then
  discovery_node_raw="${DOCKER_VERNEMQ_DISCOVERY_NODE}"
  # host:port 형태가 와도 host 부분만 추출
  discovery_host="${discovery_node_raw%%:*}"

  # Compose라면 컨테이너 DNS를 IP로 해석 (vmq1 -> 172.19.0.2)
  if [[ -n "${DOCKER_VERNEMQ_COMPOSE:-}" ]]; then
    disc_ip=""
    # DNS가 뜰 때까지 대기 (컨테이너 생성 순서/의존성 대비)
    while [[ -z "$disc_ip" ]]; do
      disc_ip="$(getent hosts "$discovery_host" | awk '{print $1}' | head -1 || true)"
      [[ -z "$disc_ip" ]] && sleep 1
    done
  else
    # Compose가 아니면 이미 IP일 수도 있음. 아니면 getent로 해석 시도
    if [[ "$discovery_host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      disc_ip="$discovery_host"
    else
      disc_ip="$(getent hosts "$discovery_host" | awk '{print $1}' | head -1 || true)"
    fi
  fi

  # 자기 자신을 discovery로 지정한 경우는 스킵(쓸모 없음)
  if [[ "$disc_ip" == "$IP_ADDRESS" || -z "$disc_ip" ]]; then
    log "[cluster] skip auto-join: discovery=$discovery_host ip=$disc_ip (self or unresolved)"
  else
    # vm.args 안에 기존 join -eval 라인 제거 후 새 라인 주입 (중복 방지)
    sed -i.bak -r "/-eval.+vmq_server_cmd:node_join/d" "${VM_ARGS}"
    echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${disc_ip}')\"" >> "${VM_ARGS}"
    log "[cluster] auto-join enabled: discovery VerneMQ@${disc_ip}"
  fi
fi

# ---------- 5) run foreground & trap ----------
trap 'log "[info] stopping vernemq..."; as_vmq vmq-admin node stop >/dev/null 2>&1 || true; exit 0' TERM INT
as_vmq vernemq console -noshell -noinput "$@" &
pid=$!


# 6) (옵션) API KEY
if [[ -n "${API_KEY:-}" ]]; then
  ( sleep 60; log "Adding API_KEY..."; as_vmq vmq-admin api-key add key="${API_KEY}" || true ) &
fi

wait $pid
