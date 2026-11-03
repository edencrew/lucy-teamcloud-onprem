#!/usr/bin/env bash
# Offline regression for rootless persistent-data ownership: Compose userns/user policy and the Gitea wrapper's
# creation identity. No container engine/daemon; docker-compose `config` (render only) is used when available.
# Run: bash tests/test-rootless-data-ownership.sh
set -Eeuo pipefail
umask 022

HERE="$(cd -P "$(dirname "$0")" && pwd)"
R="$HERE/.."
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tc-rootless-own.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------- Compose policy (rendered, with a non-default invoking UID/GID) ----------
DC=""
for c in "${DOCKER_COMPOSE_PLUGIN:-}" /Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose \
  /usr/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; do
  [ -n "$c" ] && [ -x "$c" ] && { DC="$c"; break; }
done
render() { # $1 compose file; renders with env-only interpolation, no daemon
  ( cd "$WORK" && env -i PATH="$PATH" HOME="$HOME" DOCKER_CONFIG="$WORK/docker-config" HOST_UID=4242 HOST_GID=4343 TC_PAYLOAD_DIR="$R" \
      DEVORA_ENV_FILE="$WORK/dv.env" DEVORA_MEDIA_DIR="$WORK/media" DEVORA_BE_IMAGE=reg.local/be:1 \
      API_BIND=127.0.0.1 API_PORT=18000 "$DC" -f "$1" --project-directory "$WORK" config ) > "$WORK/out.yml" 2>"$WORK/err" \
    || { cat "$WORK/err" >&2; fail "compose config $1"; }
}
# svc_block FILE SERVICE -> that service's rendered block
svc_block() { awk -v s="  $2:" '$0==s{p=1;next} p&&/^  [^ ]/{p=0} p&&/^[^ ]/{p=0} p' "$1"; }
expect() { # FILE SERVICE USERNS USER
  local b; b="$(svc_block "$1" "$2")"; [ -n "$b" ] || fail "$2 missing in rendered compose"
  grep -qE "^    userns_mode: \"?$3\"?$" <<<"$b" || fail "$2 userns_mode != $3: $(grep userns <<<"$b" || echo none)"
  grep -qE "^    user: \"?$4\"?$" <<<"$b" || fail "$2 user != $4: $(grep 'user:' <<<"$b" || echo none)"
}
none() { local b; b="$(svc_block "$1" "$2")"; [ -n "$b" ] || fail "$2 missing"
  grep -qE '^    userns_mode:' <<<"$b" && fail "$2 must keep the default rootless userns"; return 0; }

if [ -n "$DC" ]; then
  : > "$WORK/.env"; : > "$WORK/dv.env"; mkdir -p "$WORK/media"
  render "$R/compose.podman.yml"; P="$WORK/out.yml"
  expect "$P" db 'keep-id:uid=999,gid=999' '999:999'
  expect "$P" broker 'keep-id:uid=1883,gid=1883' '1883:1883'
  expect "$P" git 'keep-id:uid=4242,gid=4343' '0:0'
  svc_block "$P" git | grep -qE 'USER_UID: "?4242"?$' || fail "git USER_UID must follow HOST_UID"
  svc_block "$P" git | grep -qE 'USER_GID: "?4343"?$' || fail "git USER_GID must follow HOST_GID"
  expect "$P" tc-be 'keep-id:uid=1001,gid=1001' '1001:1001'
  svc_block "$P" tc-be | grep -q 'target: /data/studio-releases' || fail "tc-be studio-release mount"
  svc_block "$P" studio-dl | grep -A4 'target: /srv/studio' | grep -q 'read_only: true' || fail "studio-dl must stay read-only"
  for s in gw auth-be tc-fe auth-fe studio-dl; do none "$P" "$s"; done
  svc_block "$P" db | grep -q 'target: /var/lib/postgresql/data' || fail "db data mount"
  svc_block "$P" broker | grep -q 'target: /mosquitto/data' || fail "broker data mount"
  svc_block "$P" git | grep -q 'target: /data$' || fail "git data mount"
  pass "TC podman rendered userns/user/mounts (HOST_UID=4242 HOST_GID=4343)"
  render "$R/compose.docker.yml"
  grep -q 'userns_mode:' "$WORK/out.yml" && fail "docker compose must not set userns_mode"
  svc_block "$WORK/out.yml" db | grep -qE '^    user:' && fail "docker db must keep image user"
  pass "TC docker unchanged (no userns)"
  render "$R/devora/compose.podman.yml"; P="$WORK/out.yml"
  expect "$P" postgres 'keep-id:uid=999,gid=999' '999:999'
  none "$P" redis; none "$P" api
  svc_block "$P" postgres | grep -A4 'target: /docker-entrypoint-initdb.d' | grep -q 'read_only: true' || fail "devora init ro"
  svc_block "$P" postgres | grep -A8 'target: /docker-entrypoint-initdb.d' | grep -q 'selinux: Z' || fail "devora init Z"
  pass "Devora podman rendered postgres keep-id + init :ro,Z"
else
  echo "skip rendered compose checks: docker-compose plugin not found"
fi
# source policy holds even without a renderer
for f in compose.podman.yml devora/compose.podman.yml compose.docker.yml devora/compose.docker.yml; do
  grep -qE '0?777|label=disable|label: *disable|privileged: *true' "$R/$f" && fail "$f must not weaken security"
done
pass "no security weakening"

# ---------- Gitea wrapper: real script, mocked root filesystem paths and su-exec ----------
W="$R/git/gitea-entrypoint.sh"
sh -n "$W" || fail "gitea wrapper syntax"
gw_run() { # $1 case dir; $2 id -u value; rest: env
  local T="$1" uid="$2"; shift 2
  mkdir -p "$T/bin" "$T/data" "$T/secrets"
  printf 'GITEA__security__SECRET_KEY=x\n' > "$T/secrets/secrets.env"
  printf '[server]\nAPP=1\n' > "$T/app.ini.default"
  : > "$T/calls"
  [ -f "$T/s6setup" ] || [ -e "$T/no-s6setup" ] || cp "$STOCK_SETUP" "$T/s6setup"
  sed -e "s|^DATA_ROOT=/data$|DATA_ROOT=$T/data|" -e "s|^GITEA_DATA=/data/gitea$|GITEA_DATA=$T/data/gitea|" -e "s|/run/secrets/secrets.env|$T/secrets/secrets.env|" \
      -e "s|/app.ini.default|$T/app.ini.default|" -e "s|exec /usr/bin/entrypoint|exec $T/bin/entrypoint|" \
      -e "s|^SSH_SETUP=/etc/s6/openssh/setup$|SSH_SETUP=$T/s6setup|" "$W" > "$T/w.sh"
  grep -q "^DATA_ROOT=$T/data$" "$T/w.sh" && grep -q "GITEA_DATA=$T/data/gitea" "$T/w.sh" && grep -q "exec $T/bin/entrypoint" "$T/w.sh" \
    && grep -q "^SSH_SETUP=$T/s6setup$" "$T/w.sh" || fail "wrapper path seam changed"
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo %s; exit 0; }; exec /usr/bin/id "$@"\n' "$uid" > "$T/bin/id"
  # su-exec mock records the target uid (MOCK_SU_UID) so ssh-keygen can model the real getpwuid prerequisite
  printf '#!/bin/sh\necho "su-exec $*" >> %s/calls\nMOCK_SU_UID="${1%%%%:*}"; export MOCK_SU_UID; shift; exec "$@"\n' "$T" > "$T/bin/su-exec"
  printf '#!/bin/sh\necho "chown $*" >> %s/calls\n' "$T" > "$T/bin/chown"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
  # The wrapper now waits for healthz before creating the administrator. Keep this an offline test.
  cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$(dirname "$0")/../calls"
[ "${MOCK_HEALTH_FAIL:-0}" = 0 ]
EOF
  cat > "$T/bin/gitea" <<'EOF'
#!/bin/sh
echo "gitea $*" >> "$(dirname "$0")/../calls"
case "$*" in
  'admin user create '*)
    if [ "${MOCK_CREATE_FAIL:-0}" = 1 ]; then echo 'mock admin create error' >&2; exit 1; fi ;;
  'admin user list '*)
    printf 'ID Username\n'
    [ "${MOCK_ADMIN_EXISTS:-0}" = 1 ] && printf '1 %s\n' "$LUCY_ADMIN_NAME" ;;
esac
exit 0
EOF
  printf '#!/bin/sh\necho entrypoint >> %s/calls\n' "$T" > "$T/bin/entrypoint"
  # ssh-keygen mock: records argv, writes key pair at -f (0600 private like real ssh-keygen); KEYGEN_FAIL=1 fails.
  # Like the real image before stock entrypoint remaps git: only uid 0 (root) and 1000 (git) resolve via getpwuid.
  printf '#!/bin/sh\necho "ssh-keygen $*" >> %s/calls\ncase "${MOCK_SU_UID:-0}" in 0|1000) ;; *) echo "No user exists for uid $MOCK_SU_UID" >&2; exit 255 ;; esac\n[ -n "$KEYGEN_FAIL" ] && exit 1\nwhile [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done\numask 077; echo "priv $f $$" > "$f"; umask 022; echo "pub $f $$" > "$f.pub"\n' "$T" > "$T/bin/ssh-keygen"
  chmod +x "$T/bin/"*
  # compose.podman.yml opt-in is the default here; pass TC_GITEA_SSH_KEY_OWNER= to model Docker (stock policy)
  env -i PATH="$T/bin:/usr/bin:/bin" LUCY_ADMIN_NAME=admin LUCY_ADMIN_PASSWORD=pw TC_GITEA_SSH_KEY_OWNER=data "$@" sh "$T/w.sh" > "$T/out" 2>&1
}
# run_setup CASE: execute the case's (possibly adapted) s6 openssh setup with bash, paths rebased into the case dir
run_setup() {
  sed -e "s|/data/ssh|$1/data/ssh|g" -e "s|/etc/ssh|$1/etc/ssh|g" -e "s|/etc/templates|$1/etc/templates|g" "$1/s6setup" > "$1/setup.run"
  : > "$1/calls"; env -i PATH="$1/bin:/usr/bin:/bin" bash "$1/setup.run" > "$1/setup.out" 2>&1
}
sums() { (cd "$1/data/ssh" && cksum ssh_host_*); }
grep -q 'TC_GITEA_SSH_KEY_OWNER=data' "$R/compose.podman.yml" || fail "podman git must opt in to data-owned SSH host keys"
grep -q 'TC_GITEA_SSH_KEY_OWNER' "$R/compose.docker.yml" && fail "docker git must keep stock SSH host key policy"
pass "SSH host key owner opt-in is Podman-only"

# Exact /etc/s6/openssh/setup of docker.gitea.com/gitea:1.25.3 (extracted read-only from the fixed image on the VM).
# Its unconditional trailing `chown root:root /data/ssh/*` is the contract the wrapper must adapt or refuse.
STOCK_SETUP="$WORK/stock-openssh-setup"
cat > "$STOCK_SETUP" <<'EOF'
#!/bin/bash

if [ ! -d /data/ssh ]; then
    mkdir -p /data/ssh
fi

if [ ! -f /data/ssh/ssh_host_ed25519_key ]; then
    echo "Generating /data/ssh/ssh_host_ed25519_key..."
    ssh-keygen -t ed25519 -f /data/ssh/ssh_host_ed25519_key -N "" > /dev/null
fi

if [ ! -f /data/ssh/ssh_host_rsa_key ]; then
    echo "Generating /data/ssh/ssh_host_rsa_key..."
    ssh-keygen -t rsa -b 3072 -f /data/ssh/ssh_host_rsa_key -N "" > /dev/null
fi

if [ ! -f /data/ssh/ssh_host_ecdsa_key ]; then
    echo "Generating /data/ssh/ssh_host_ecdsa_key..."
    ssh-keygen -t ecdsa -b 256 -f /data/ssh/ssh_host_ecdsa_key -N "" > /dev/null
fi

if [ -e /data/ssh/ssh_host_ed25519_cert ]; then
  SSH_ED25519_CERT=${SSH_ED25519_CERT:-"/data/ssh/ssh_host_ed25519_cert"}
fi

if [ -e /data/ssh/ssh_host_rsa_cert ]; then
  SSH_RSA_CERT=${SSH_RSA_CERT:-"/data/ssh/ssh_host_rsa_cert"}
fi

if [ -e /data/ssh/ssh_host_ecdsa_cert ]; then
  SSH_ECDSA_CERT=${SSH_ECDSA_CERT:-"/data/ssh/ssh_host_ecdsa_cert"}
fi

# In case someone wants to sign the `{keyname}.pub` key by `ssh-keygen -s ca -I identity ...` to
# make use of the ssh-key certificate authority feature (see ssh-keygen CERTIFICATES section),
# the generated key file name is `{keyname}-cert.pub`
if [ -e /data/ssh/ssh_host_ed25519_key-cert.pub ]; then
  SSH_ED25519_CERT=${SSH_ED25519_CERT:-"/data/ssh/ssh_host_ed25519_key-cert.pub"}
fi

if [ -e /data/ssh/ssh_host_rsa_key-cert.pub ]; then
  SSH_RSA_CERT=${SSH_RSA_CERT:-"/data/ssh/ssh_host_rsa_key-cert.pub"}
fi

if [ -e /data/ssh/ssh_host_ecdsa_key-cert.pub ]; then
  SSH_ECDSA_CERT=${SSH_ECDSA_CERT:-"/data/ssh/ssh_host_ecdsa_key-cert.pub"}
fi

if [ -d /etc/ssh ]; then
    SSH_PORT=${SSH_PORT:-"22"} \
    SSH_LISTEN_PORT=${SSH_LISTEN_PORT:-"${SSH_PORT}"} \
    SSH_ED25519_CERT="${SSH_ED25519_CERT:+"HostCertificate "}${SSH_ED25519_CERT}" \
    SSH_RSA_CERT="${SSH_RSA_CERT:+"HostCertificate "}${SSH_RSA_CERT}" \
    SSH_ECDSA_CERT="${SSH_ECDSA_CERT:+"HostCertificate "}${SSH_ECDSA_CERT}" \
    SSH_MAX_STARTUPS="${SSH_MAX_STARTUPS:+"MaxStartups "}${SSH_MAX_STARTUPS}" \
    SSH_MAX_SESSIONS="${SSH_MAX_SESSIONS:+"MaxSessions "}${SSH_MAX_SESSIONS}" \
    SSH_INCLUDE_FILE="${SSH_INCLUDE_FILE:+"Include "}${SSH_INCLUDE_FILE}" \
    SSH_LOG_LEVEL=${SSH_LOG_LEVEL:-"INFO"} \
    envsubst < /etc/templates/sshd_config > /etc/ssh/sshd_config

    chmod 0644 /etc/ssh/sshd_config
fi

chown root:root /data/ssh/*
chmod 0700 /data/ssh
chmod 0600 /data/ssh/*
EOF
[ "$(tail -n 3 "$STOCK_SETUP" | head -n 1)" = 'chown root:root /data/ssh/*' ] || fail "stock setup fixture"
wait_marker() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$1" ] && return 0; sleep 0.2; done; return 1; }

T="$WORK/g1"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 GITEA__server__DISABLE_SSH=true || { cat "$T/out" >&2; fail "gitea wrapper as root"; }
wait_marker "$T/data/gitea/.admin-created" || { cat "$T/out" "$T/calls" >&2; fail "admin marker not created"; }
cmp -s "$T/app.ini.default" "$T/data/gitea/conf/app.ini" || fail "app.ini content"
grep -qx "chown 4242:4343 $T/data/gitea" "$T/calls" || fail "new /data/gitea must be data-owned: $(cat "$T/calls")"
grep -qx "chown 4242:4343 $T/data/gitea/conf" "$T/calls" || fail "new conf dir must be data-owned"
grep -qx "su-exec 4242:4343 tee $T/data/gitea/conf/app.ini" "$T/calls" || fail "app.ini must be created as data uid"
grep -qx "su-exec 4242:4343 touch $T/data/gitea/.admin-created" "$T/calls" || fail "marker must be created as data uid"
grep -q '^su-exec git gitea admin user create' "$T/calls" || fail "admin create via git user"
grep -q -- '-R' "$T/calls" && fail "wrapper must not chown recursively"
tail -n 1 "$T/out" >/dev/null; grep -qx entrypoint "$T/calls" || fail "stock entrypoint must be exec'd"
pass "gitea wrapper creates conf/app.ini/marker as numeric data owner (root start)"
# stock entrypoint/s6 otherwise creates /data/ssh and /data/gitea/log as root (rootless: subordinate 165536)
grep -qx "chown 4242:4343 $T/data/gitea/log" "$T/calls" || fail "new log dir must be data-owned"
grep -qx "chown 4242:4343 $T/data/ssh" "$T/calls" || fail "new ssh dir must be data-owned when SSH disabled"
c="$(grep -nE "^(chown 4242:4343 $T/data/(ssh|gitea/log)|entrypoint)$" "$T/calls" | cut -d: -f2- | tr '\n' ' ')"
[ "$c" = "chown 4242:4343 $T/data/gitea/log chown 4242:4343 $T/data/ssh entrypoint " ] || fail "ssh/log must precede stock entrypoint: $c"
for d in data/ssh data/gitea/log; do
  [ "$(ls -ld "$T/$d" | cut -c1-10)" = drwxr-xr-x ] || fail "$d mode must stay umask default: $(ls -ld "$T/$d")"
done
pass "gitea wrapper precreates /data/ssh and /data/gitea/log as data owner before stock entrypoint"
# stock s6 openssh setup generates missing host keys as root -> wrapper generates the same three as data owner first
k="$T/data/ssh/ssh_host"
# real ssh-keygen needs getpwuid(USER_UID), which only exists after stock entrypoint: keygen runs as root into a
# transient dir, the persistent files are created new by the data owner (noclobber), all before stock entrypoint
grep -q '^su-exec .* ssh-keygen' "$T/calls" && fail "ssh-keygen must not run as unresolved data uid: $(cat "$T/calls")"
c="$(grep -E '^(ssh-keygen|su-exec 4242:4343 sh -c|entrypoint)' "$T/calls" | sed -E 's|^ssh-keygen (.*) -f .*/(ssh_host_[a-z0-9]+_key)$|keygen \1 \2|; s|^su-exec 4242:4343 sh -c .* sh '"$T"'/data/ssh/|put |' | tr '\n' ' ')"
[ "$c" = "keygen -q -t ed25519 -N  ssh_host_ed25519_key put ssh_host_ed25519_key put ssh_host_ed25519_key.pub keygen -q -t rsa -b 3072 -N  ssh_host_rsa_key put ssh_host_rsa_key put ssh_host_rsa_key.pub keygen -q -t ecdsa -b 256 -N  ssh_host_ecdsa_key put ssh_host_ecdsa_key put ssh_host_ecdsa_key.pub entrypoint " ] \
  || fail "host keys must be created by data owner before stock entrypoint: $c"
kt="$(sed -n 's|^ssh-keygen .* -f \(.*\)/ssh_host_ed25519_key$|\1|p' "$T/calls")"
case "$kt" in "$T"/data*|"") fail "transient keygen dir must be outside persistent data: $kt" ;; esac
[ -e "$kt" ] && fail "transient keygen dir must be removed: $kt"
for t in ed25519 rsa ecdsa; do
  [ "$(ls -l "${k}_${t}_key" | cut -c1-10)" = -rw------- ] || fail "private host key mode: $(ls -l "${k}_${t}_key")"
  [ "$(ls -l "${k}_${t}_key.pub" | cut -c1-10)" = -rw-r--r-- ] || fail "public host key mode: $t"
  grep -q "^priv .*/ssh_host_${t}_key " "${k}_${t}_key" && grep -q "^pub .*/ssh_host_${t}_key " "${k}_${t}_key.pub" \
    || fail "persistent key must be the generated content: $t"
done
MOCK_SU_UID=4242 "$T/bin/ssh-keygen" -q -t ed25519 -N "" -f "$WORK/probe" 2>"$WORK/probe.err" && fail "mock must reject unresolved uid"
grep -q 'No user exists for uid 4242' "$WORK/probe.err" || fail "mock getpwuid message"
pass "gitea wrapper creates missing SSH host keys as data owner (0600/0644) without keygen under unresolved uid"

T="$WORK/g1b"; mkdir -p "$T/data/gitea/conf"; printf 'keep\n' > "$T/data/gitea/conf/app.ini"; touch "$T/data/gitea/.admin-created"
gw_run "$T" 0 USER_UID=4242 USER_GID=4343 GITEA__server__DISABLE_SSH=true || { cat "$T/out" >&2; fail "gitea wrapper restart"; }
c="$(grep -E '^(chown|su-exec)' "$T/calls" | cut -d' ' -f1-4 | tr '\n' ' ')"
p="su-exec 4242:4343 sh -c "
[ "$c" = "chown 4242:4343 $T/data/gitea/log chown 4242:4343 $T/data/ssh $p$p$p$p$p$p" ] || fail "restart must create only missing ssh/log/keys: $c"
pass "gitea wrapper creates missing ssh/log/keys even when app.ini already exists"

T="$WORK/g1c"; mkdir -p "$T/data/ssh"; printf 'old\n' > "$T/data/ssh/ssh_host_ed25519_key"
gw_run "$T" 0 USER_UID=4242 USER_GID=4343 || { cat "$T/out" >&2; fail "gitea wrapper SSH enabled"; }
[ "$(cat "$T/data/ssh/ssh_host_ed25519_key")" = old ] || fail "existing host key must be kept (same fingerprint)"
grep -q "ssh-keygen .*ed25519" "$T/calls" && fail "existing ed25519 key must not be regenerated"
grep -qE "^ssh-keygen -q -t rsa -b 3072 -N  -f .*/ssh_host_rsa_key$" "$T/calls" || fail "only missing keys generated"
grep -qE "^su-exec 4242:4343 sh -c .* sh $T/data/ssh/ssh_host_rsa_key$" "$T/calls" || fail "missing key created as data owner"
grep -q "sh $T/data/ssh/ssh_host_ed25519_key" "$T/calls" && fail "existing ed25519 key must not be rewritten"
grep -q "chown 4242:4343 $T/data/ssh" "$T/calls" && fail "existing ssh dir must not be chowned"
pass "gitea wrapper keeps existing host keys and generates only missing ones (SSH enabled)"

T="$WORK/g1d"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 KEYGEN_FAIL=1 && fail "ssh-keygen failure must fail wrapper"
grep -qx entrypoint "$T/calls" && fail "keygen failure must not start stock entrypoint (it would create root-owned keys)"
grep -q 'ssh host key init failed' "$T/out" || fail "keygen failure message"
kt="$(sed -n 's|^ssh-keygen .* -f \(.*\)/ssh_host_ed25519_key$|\1|p' "$T/calls")"
[ -n "$kt" ] && [ ! -e "$kt" ] || fail "transient keygen dir must be removed on failure: $kt"
[ -e "$T/data/ssh/ssh_host_ed25519_key" ] && fail "keygen failure must not leave a persistent key"
pass "gitea wrapper stops on host key generation failure"

# orphan public key without private key: never overwritten (noclobber), fail closed before stock entrypoint
T="$WORK/g1e"; mkdir -p "$T/data/ssh"; printf 'orphan\n' > "$T/data/ssh/ssh_host_ed25519_key.pub"
gw_run "$T" 0 USER_UID=4242 USER_GID=4343 && fail "existing orphan .pub must fail closed"
[ "$(cat "$T/data/ssh/ssh_host_ed25519_key.pub")" = orphan ] || fail "existing .pub must not be overwritten"
[ -e "$T/data/ssh/ssh_host_ed25519_key" ] && fail "orphan .pub must not get a new private key"
grep -qx entrypoint "$T/calls" && fail "orphan .pub must not start gitea"
pass "gitea wrapper never overwrites existing host key files"

T="$WORK/g2"; mkdir -p "$T/data/gitea/conf" "$T/data/gitea/log" "$T/data/ssh"; printf 'keep\n' > "$T/data/gitea/conf/app.ini"; touch "$T/data/gitea/.admin-created"
for t in ed25519 rsa ecdsa; do : > "$T/data/ssh/ssh_host_${t}_key"; done
gw_run "$T" 0 USER_UID=4242 USER_GID=4343 GITEA__server__DISABLE_SSH=true || { cat "$T/out" >&2; fail "gitea wrapper rerun"; }
[ "$(cat "$T/data/gitea/conf/app.ini")" = keep ] || fail "existing app.ini must be kept"
grep -qE '^(chown|su-exec)' "$T/calls" && fail "rerun on existing data must not touch ownership: $(cat "$T/calls")"
pass "gitea wrapper leaves existing data untouched"

T="$WORK/g3"; gw_run "$T" 0 || { cat "$T/out" >&2; fail "gitea wrapper default ids"; }
grep -qx "su-exec 1000:1000 tee $T/data/gitea/conf/app.ini" "$T/calls" || fail "default USER_UID/GID 1000 (Docker default)"
pass "gitea wrapper Docker default ids"

T="$WORK/g4"; gw_run "$T" 0 USER_UID=abc USER_GID=1 && fail "non-numeric USER_UID must fail"
[ -e "$T/data/gitea" ] && fail "invalid ids must not create data"
grep -qx entrypoint "$T/calls" && fail "invalid ids must not start gitea"
pass "gitea wrapper rejects non-numeric ids before creating data"

T="$WORK/g5"; gw_run "$T" 4242 USER_UID=4242 USER_GID=4343 || { cat "$T/out" >&2; fail "gitea wrapper non-root"; }
grep -qE '^(chown|su-exec 4242)' "$T/calls" && fail "non-root start must not chown/su-exec"
[ -f "$T/data/gitea/conf/app.ini" ] || fail "non-root app.ini"
pass "gitea wrapper non-root start"

# ---------- stock s6 openssh setup root re-chown contract ----------
ME="$(id -u):$(id -g)"
# baseline: unadapted stock setup re-chowns even pre-generated data-owned keys to root (why pre-generation alone fails)
T="$WORK/s0"; gw_run "$T" 0 USER_UID="${ME%:*}" USER_GID="${ME#*:}" TC_GITEA_SSH_KEY_OWNER= || { cat "$T/out" >&2; fail "stock policy run"; }
cmp -s "$STOCK_SETUP" "$T/s6setup" || fail "disabled policy must leave stock setup unchanged"
[ -e "$T/data/ssh" ] && fail "disabled policy must leave /data/ssh to stock"
grep -q 'ssh-keygen' "$T/calls" && fail "disabled policy must not pre-generate keys"
grep -qx entrypoint "$T/calls" || fail "disabled policy must start stock entrypoint"
mkdir -p "$T/data/ssh"; : > "$T/data/ssh/ssh_host_ed25519_key"
run_setup "$T"
# stock `chown root:root /data/ssh/*` is one call with every glob-expanded file as an argument
for f in "$T"/data/ssh/*; do
  grep '^chown root:root ' "$T/calls" | tr ' ' '\n' | grep -qxF "$f" || fail "stock setup must chown root $f: $(cat "$T/calls")"
done
pass "policy disabled (Docker): stock setup untouched; stock contract re-chowns host keys to root"

# enabled: wrapper adapts the in-container setup; adapted stock skips data-owned keys, keeps modes
T="$WORK/s1"; gw_run "$T" 0 USER_UID="${ME%:*}" USER_GID="${ME#*:}" || { cat "$T/out" >&2; fail "policy enabled run"; }
grep -qxF 'chown root:root /data/ssh/*' "$T/s6setup" && fail "stock chown must be adapted"
[ "$(grep -c '# teamcloud: keep data-owned host keys' "$T/s6setup")" = 1 ] || fail "adapted chown line"
[ "$(diff "$STOCK_SETUP" "$T/s6setup" | grep -c '^[<>]')" = 2 ] || fail "only the chown line may change: $(diff "$STOCK_SETUP" "$T/s6setup")"
grep -qx entrypoint "$T/calls" || fail "enabled policy must start stock entrypoint"
before="$(sums "$T")"
run_setup "$T" || { cat "$T/setup.out" >&2; fail "adapted setup run"; }
grep -q '^chown' "$T/calls" && fail "adapted setup must keep data-owned keys: $(cat "$T/calls")"
grep -q 'ssh-keygen' "$T/calls" && fail "stock setup must not regenerate pre-generated keys"
[ "$(sums "$T")" = "$before" ] || fail "host keys must be preserved by setup"
[ "$(ls -ld "$T/data/ssh" | cut -c1-10)" = drwx------ ] || fail "stock 0700 ssh dir mode"
for f in "$T"/data/ssh/*; do [ "$(ls -l "$f" | cut -c1-10)" = -rw------- ] || fail "stock 0600 mode: $f"; done
pass "policy enabled: adapted stock setup keeps data-owned keys, 0700/0600 modes intact"

# non-data-owned files (existing installs, foreign certs) still get stock root:root; nothing is migrated
T="$WORK/s2"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 || { cat "$T/out" >&2; fail "policy foreign run"; }
run_setup "$T"
for f in "$T"/data/ssh/*; do grep -qx "chown root:root $f" "$T/calls" || fail "foreign-owned $f must keep stock root chown"; done
grep -q -- '-R' "$T/calls" && fail "no recursive chown"
pass "policy enabled: non-data-owned files keep stock root:root"

# repeated startup (container restart keeps the adapted layer) is idempotent; keys/fingerprints preserved
T="$WORK/s1"; cp "$T/s6setup" "$T/s6setup.1"; before="$(sums "$T")"
gw_run "$T" 0 USER_UID="${ME%:*}" USER_GID="${ME#*:}" || { cat "$T/out" >&2; fail "repeat startup"; }
cmp -s "$T/s6setup.1" "$T/s6setup" || fail "repeat startup must not re-adapt setup"
grep -q 'ssh-keygen' "$T/calls" && fail "repeat startup must not regenerate keys"
[ "$(sums "$T")" = "$before" ] || fail "repeat startup must keep key fingerprints"
grep -qx entrypoint "$T/calls" || fail "repeat startup entrypoint"
pass "policy enabled: repeated startup idempotent, keys preserved"

# unknown stock contract (different/missing chown, missing setup, other uid adaptation) fails closed, SSH not disabled
for v in recursive extra missing otheruid; do
  T="$WORK/u-$v"; mkdir -p "$T"
  case $v in
    recursive) sed 's|^chown root:root /data/ssh/\*$|chown -R root:root /data/ssh|' "$STOCK_SETUP" > "$T/s6setup" ;;
    extra) { cat "$STOCK_SETUP"; echo 'chown root:root /data/ssh'; } > "$T/s6setup" ;;
    missing) : > "$T/no-s6setup" ;;
    otheruid) cp "$WORK/s2/s6setup" "$T/s6setup" ;;
  esac
  [ -f "$T/s6setup" ] && cp "$T/s6setup" "$T/s6setup.0"
  gw_run "$T" 0 USER_UID="${ME%:*}" USER_GID="${ME#*:}" && fail "unknown contract ($v) must fail"
  if [ "$v" = missing ]; then [ -e "$T/s6setup" ] && fail "missing setup must not be created"
  else cmp -s "$T/s6setup.0" "$T/s6setup" || fail "unknown contract ($v) must not modify setup"; fi
  [ -e "$T/data/ssh" ] && fail "unknown contract ($v) must fail before creating ssh data"
  grep -q 'unknown stock' "$T/out" || fail "unknown contract ($v) message: $(cat "$T/out")"
  grep -qx entrypoint "$T/calls" && fail "unknown contract ($v) must not start gitea"
done
pass "unknown stock setup contract fails closed before touching data"

T="$WORK/s3"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 TC_GITEA_SSH_KEY_OWNER=yes && fail "invalid policy value must fail"
grep -qx entrypoint "$T/calls" && fail "invalid policy must not start gitea"
T="$WORK/s4"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 KEYGEN_FAIL=1 && fail "ssh-keygen error must fail"
grep -q '# teamcloud: keep data-owned host keys' "$T/s6setup" || fail "adaptation precedes keygen"
grep -qx entrypoint "$T/calls" && fail "ssh-keygen error must not start gitea"
pass "invalid policy value and ssh-keygen error fail closed"

# Upstream readiness and restored-account behavior must keep the local marker ownership contract.
T="$WORK/admin-existing"; gw_run "$T" 0 USER_UID=4242 USER_GID=4343 MOCK_CREATE_FAIL=1 MOCK_ADMIN_EXISTS=1
wait_marker "$T/data/gitea/.admin-created" || { cat "$T/out" >&2; fail "existing admin marker not created"; }
grep -qx "su-exec 4242:4343 touch $T/data/gitea/.admin-created" "$T/calls" || fail "restored admin marker must be data-owned"
grep -qx 'mock admin create error' "$T/out" || fail "admin creation stderr must be retained"
grep -qx 'Admin user already exists' "$T/out" || fail "existing administrator must be recognized"
pass "restored admin account gets a data-owned marker and preserves create stderr"

for scenario in unhealthy create-failed; do
  T="$WORK/admin-$scenario"
  if [ "$scenario" = unhealthy ]; then
    gw_run "$T" 0 USER_UID=4242 USER_GID=4343 MOCK_HEALTH_FAIL=1
    expected='Gitea did not become healthy within 180s'
  else
    gw_run "$T" 0 USER_UID=4242 USER_GID=4343 MOCK_CREATE_FAIL=1
    expected='Admin user creation failed'
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "$expected" "$T/out" && break
    sleep 0.2
  done
  grep -q "$expected" "$T/out" || { cat "$T/out" >&2; fail "$scenario did not reach its failure branch"; }
  [ ! -e "$T/data/gitea/.admin-created" ] || fail "$scenario must not create readiness marker"
  if [ "$scenario" = unhealthy ]; then
    grep -q '^gitea admin user create' "$T/calls" && fail "unhealthy Gitea must not create admin"
  else
    grep -qx 'mock admin create error' "$T/out" || fail "failed create stderr must be retained"
  fi
done
pass "health timeout and failed admin creation leave no readiness marker"
echo "all rootless data ownership tests passed"
