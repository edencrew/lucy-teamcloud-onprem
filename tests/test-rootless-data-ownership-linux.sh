#!/usr/bin/env bash
# Real-engine rootless data ownership acceptance (disposable rootless Linux account only).
# Usage: tests/test-rootless-data-ownership-linux.sh ROOT COMPOSE PAYLOAD
#   ROOT    owned empty work dir (not /, $HOME, or the Podman graphRoot)
#   COMPOSE standalone docker-compose binary path
#   PAYLOAD dir containing compose.podman.yml, devora/, postgres/initdb, broker/, git/
# Never pulls/builds/installs; images must already be loaded. Exits nonzero unless every case verifies.
set -uo pipefail

[ $# -eq 3 ] || { echo "usage: $0 ROOT COMPOSE PAYLOAD" >&2; exit 2; }
ROOT=$(realpath -m "$1"); COMPOSE=$2; PAYLOAD=$(realpath -m "$3")
UIDN=$(id -u); GIDN=$(id -g)
die() { echo "PRECHECK FAIL: $*" >&2; exit 2; }
[ "$UIDN" -ne 0 ] || die "must run as rootless non-root user"
[ -x "$COMPOSE" ] || die "COMPOSE not executable"
[ -f "$PAYLOAD/compose.podman.yml" ] && [ -f "$PAYLOAD/devora/compose.podman.yml" ] || die "PAYLOAD missing compose files"
[ -d "$ROOT" ] && [ ! -L "$1" ] || die "ROOT must be an existing plain dir"
case "$ROOT" in /|"$HOME"|"$HOME/") die "ROOT must not be / or HOME";; esac
[ "$(stat -c %u "$ROOT")" = "$UIDN" ] || die "ROOT not owned by caller"
GRAPH=$(timeout 30 podman info --format '{{.Store.GraphRoot}}' 2>/dev/null) || die "podman info failed"
case "$ROOT/" in "$GRAPH"/*) die "ROOT inside graphRoot";; esac
case "$GRAPH/" in "$ROOT"/*) die "graphRoot inside ROOT";; esac
[ -z "$(ls -A "$ROOT" 2>/dev/null | grep -vx records)" ] || die "ROOT not empty"

P=tc-ownership; PD=tc-ownership-devora
for v in devora_pgdata devora_redisdata; do
  ! timeout 30 podman volume exists "$v" || die "volume $v already exists"
done
[ -z "$(timeout 30 podman ps -aq --filter label=com.docker.compose.project=$P --filter label=com.docker.compose.project=$PD)" ] || die "project containers already exist"

REC=$ROOT/records; mkdir -p "$REC"; chmod 700 "$REC"
SOCK=${XDG_RUNTIME_DIR:-/run/user/$UIDN}/podman/podman.sock
[ -S "$SOCK" ] || die "native podman socket missing"
export DOCKER_HOST=unix://$SOCK TC_PAYLOAD_DIR=$PAYLOAD HOST_UID=$UIDN HOST_GID=$GIDN
rnd() { head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9; }
( umask 077
  printf 'DB_ROOT_PASSWORD=%s\nDB_USERNAME=tcprobe\nDB_PASSWORD=%s\nLUCY_ADMIN_NAME=probeadmin\nLUCY_ADMIN_PASSWORD=%s\nEXTERNAL_URL=http://localhost\nTZ=UTC\n' "$(rnd)" "$(rnd)" "$(rnd)" > "$REC/.env"
  mkdir -p "$ROOT/devora-media"
  printf 'POSTGRES_USER=devora\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=devora\n' "$(rnd)" > "$REC/devora.env" )
export DEVORA_ENV_FILE=$REC/devora.env DEVORA_MEDIA_DIR=$ROOT/devora-media
export DEVORA_BE_IMAGE=${DEVORA_BE_IMAGE:-public.ecr.aws/edencrew/lucy-teamcloud-be:onprem-prod-0.0.24}
export API_BIND=127.0.0.1 API_PORT=18999

SUMMARY=$REC/summary.tsv; printf 'case\tstatus\tdetail\n' > "$SUMMARY"
FIRST_FAIL=""; RC=0
res() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$SUMMARY"; [ "$2" = PASS ] || { RC=1; [ -n "$FIRST_FAIL" ] || FIRST_FAIL="$1: $3"; }; }
run() { # name cmd... ; logs exit+stderr to records
  local n=$1; shift
  # tc/dv are shell functions (timeout cannot exec them); they apply timeout to COMPOSE themselves
  if declare -F "$1" >/dev/null; then "$@" >"$REC/$n.out" 2>"$REC/$n.err"; else timeout 120 "$@" >"$REC/$n.out" 2>"$REC/$n.err"; fi; local e=$?
  echo "$n exit=$e first_stderr=$(grep -v -m1 '^\s*$' "$REC/$n.err" | cut -c1-200)" >> "$REC/commands.log"; return $e; }
tc() { timeout 120 "$COMPOSE" -p $P -f "$PAYLOAD/compose.podman.yml" --project-directory "$ROOT" --env-file "$REC/.env" "$@"; }
dv() { timeout 120 "$COMPOSE" -p $PD -f "$PAYLOAD/devora/compose.podman.yml" --project-directory "$ROOT" --env-file "$REC/.env" "$@"; }
CTR=$REC/containers.txt; : >> "$CTR"
# cid runs in $(...) subshells, so the records file (not a shell array) is the source of truth for cleanup
cid() { local c; c=$("$1" ps -aq "$2" 2>/dev/null | head -1); [ -n "$c" ] && echo "$1 $2 $c" >> "$CTR"; echo "$c"; }
cleanup() { local s v c; [ -f "$CTR" ] || return 0
  awk 'NF==3{print $3}' "$CTR" | sort -u | while read -r c; do
    [ -n "$c" ] && timeout 60 podman stop -t 10 "$c" >/dev/null 2>&1; done; }
trap cleanup EXIT
waitfor() { local i; for i in $(seq 30); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
health() { [ "$(podman inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ]; }
idcheck() { podman inspect -f '{{.HostConfig.UsernsMode}} user={{.Config.User}}' "$1" 2>&1; }
native() { # dir realfile -> owner + CRUD check, prints flags
  local d=$1 f=$2 bad pd=$1/.ownership-probe
  [ -n "$(find "$d" -mindepth 1 -print -quit 2>/dev/null)" ] || { echo "data=empty"; return 1; }
  bad=$(find "$d" \( ! -uid "$UIDN" -o ! -gid "$GIDN" \) -print 2>/dev/null | head -3)
  [ -z "$bad" ] || { echo "owner=bad:$(echo $bad | tr ' ' ,)"; return 1; }
  [ -f "$f" ] || { echo "realfile=missing:$(basename "$f")"; return 1; }
  local sum; sum=$(sha256sum "$f" | cut -c1-16)
  mkdir "$pd" && cp "$f" "$pd/copy" && cat "$pd/copy" >/dev/null && echo probe >> "$pd/copy" \
    && rm -f "$pd/copy" && rmdir "$pd" || { echo "nativeCRUD=fail"; return 1; }
  [ "$(sha256sum "$f" | cut -c1-16)" = "$sum" ] || { echo "realfile=changed"; return 1; }
  echo "owner=$UIDN:$GIDN data=nonempty realfile=$(basename "$f") nativeCRUD=ok unshare=no"; }

{ echo "== before"; free -m; df -m "$ROOT"; } > "$REC/resources.txt" 2>&1
run config-tc tc config -q || die "tc compose config failed (see $REC/config-tc.err)"
run config-dv dv config -q || die "devora compose config failed (see $REC/config-dv.err)"

# --- TC PostgreSQL 17
case_db() {
  run db-up tc up -d --no-build --pull never db || { res tc-db FAIL "up exit $?"; return; }
  local c; c=$(cid tc db); echo "db $(idcheck "$c")" >> "$REC/identity.txt"
  waitfor health "$c" || { res tc-db FAIL "not healthy"; return; }
  run db-sql podman exec "$c" psql -U postgres -v ON_ERROR_STOP=1 -c "BEGIN; CREATE TABLE own_probe(v text); INSERT INTO own_probe VALUES('persist-ok'); COMMIT;" || { res tc-db FAIL "sql"; return; }
  run db-stop tc stop db || { res tc-db FAIL "stop"; return; }
  local d=$ROOT/postgres/data n; n=$(native "$d" "$d/PG_VERSION") || { res tc-db FAIL "$n"; return; }
  for s in base global pg_wal; do [ -n "$(ls -A "$d/$s" 2>/dev/null)" ] || { res tc-db FAIL "$s empty"; return; }; done
  run db-recreate tc up -d --no-build --pull never --force-recreate db || { res tc-db FAIL "recreate"; return; }
  c=$(cid tc db); waitfor health "$c" || { res tc-db FAIL "recreate unhealthy"; return; }
  run db-read podman exec "$c" psql -U postgres -tAc "SELECT v FROM own_probe"
  grep -qx persist-ok "$REC/db-read.out" || { res tc-db FAIL "value lost"; return; }
  res tc-db PASS "$n persist=ok"; }

# --- Broker
case_broker() {
  run broker-up tc up -d --no-build --pull never broker || { res tc-broker FAIL "up"; return; }
  local c; c=$(cid tc broker); echo "broker $(idcheck "$c")" >> "$REC/identity.txt"; sleep 3
  local partial=""
  if ! run broker-pub podman exec "$c" mosquitto_pub -h localhost -r -t own/probe -m persist-ok; then partial="pub:$(head -c 120 "$REC/broker-pub.err")"; fi
  run broker-stop tc stop broker || { res tc-broker FAIL "stop"; return; }
  local d=$ROOT/broker/data n; n=$(native "$d" "$d/mosquitto.db") || { res tc-broker FAIL "$n"; return; }
  run broker-recreate tc up -d --no-build --pull never --force-recreate broker || { res tc-broker FAIL "recreate"; return; }
  c=$(cid tc broker); sleep 3
  if [ -z "$partial" ]; then
    run broker-sub podman exec "$c" mosquitto_sub -h localhost -t own/probe -C 1 -W 5
    grep -qx persist-ok "$REC/broker-sub.out" || partial="retained message lost"
  fi
  [ -z "$partial" ] && res tc-broker PASS "$n persist=ok" || res tc-broker PARTIAL "$n $partial"
  run broker-stop2 tc stop broker; }

# --- Gitea (DB+git pair) — secrets layout not modelled here; skip honestly
case_git() { res tc-git SKIPPED "Gitea secrets/app.ini bootstrap not exercised by this script; unverified"; }

# --- Devora PG16 + Redis (named volumes)
case_devora() {
  run dv-up dv up -d --no-build --pull never postgres redis || { res devora-pg FAIL "up"; res devora-redis FAIL "up"; return; }
  local pc rc; pc=$(cid dv postgres); rc=$(cid dv redis)
  echo "devora-pg $(idcheck "$pc")" >> "$REC/identity.txt"; echo "devora-redis $(idcheck "$rc")" >> "$REC/identity.txt"
  waitfor podman exec "$pc" pg_isready -U devora || { res devora-pg FAIL "not ready"; }
  run dv-sql podman exec "$pc" psql -U devora -d devora -v ON_ERROR_STOP=1 -c "BEGIN; CREATE TABLE own_probe(v text); INSERT INTO own_probe VALUES('persist-ok'); COMMIT;"
  local sqlok=$?
  waitfor podman exec "$rc" redis-cli ping
  run dv-redis-set sh -c "podman exec $rc redis-cli SET own_probe persist-ok && podman exec $rc redis-cli SAVE"
  local redok=$?
  run dv-stop dv stop postgres redis
  local pm rm n m
  pm=$(podman volume inspect -f '{{.Mountpoint}}' devora_pgdata 2>/dev/null)
  rm=$(podman volume inspect -f '{{.Mountpoint}}' devora_redisdata 2>/dev/null)
  n=$(native "$pm" "$pm/PG_VERSION"); local pn=$?
  local rf; rf=$(find "$rm" -maxdepth 3 \( -name 'dump.rdb' -o -name '*.aof' \) -type f 2>/dev/null | head -1)
  m=$(native "$rm" "${rf:-$rm/dump.rdb}"); local rn=$?
  run dv-recreate dv up -d --no-build --pull never --force-recreate postgres redis
  pc=$(cid dv postgres); rc=$(cid dv redis)
  waitfor podman exec "$pc" pg_isready -U devora
  run dv-read podman exec "$pc" psql -U devora -d devora -tAc "SELECT v FROM own_probe"
  waitfor podman exec "$rc" redis-cli ping
  run dv-redis-get podman exec "$rc" redis-cli GET own_probe
  if [ $sqlok -eq 0 ] && [ $pn -eq 0 ] && grep -qx persist-ok "$REC/dv-read.out"; then res devora-pg PASS "$n persist=ok"; else res devora-pg FAIL "sql=$sqlok $n"; fi
  if [ $redok -eq 0 ] && [ $rn -eq 0 ] && grep -qx persist-ok "$REC/dv-redis-get.out"; then res devora-redis PASS "$m persist=ok"; else res devora-redis FAIL "set=$redok $m"; fi
  run dv-stop2 dv stop postgres redis; }

# --- Studio identity probe only (tc-be image, no deps); never counted as service acceptance
case_studio() {
  # placeholders only for missing bind sources inside ROOT; cert must be a file so no directory is auto-created
  [ -e "$ROOT/secrets" ] || mkdir -p "$ROOT/secrets"
  [ -e "$ROOT/license" ] || mkdir -p "$ROOT/license"
  [ -e "$ROOT/tc/logs" ] || mkdir -p "$ROOT/tc/logs"
  [ -e "$ROOT/nginx/certs/server.crt" ] || { mkdir -p "$ROOT/nginx/certs" && touch "$ROOT/nginx/certs/server.crt"; }
  local pn; pn=own-probe-$(rnd | cut -c1-10)
  run studio-probe tc run --rm --no-deps --entrypoint node tc-be -e \
    "const fs=require('fs'),d='/data/studio-releases/$pn';fs.mkdirSync(d);fs.writeFileSync(d+'/probe','x');console.log('uid='+process.getuid()+' gid='+process.getgid())"
  local pe=$? sm n; sm=$(podman volume inspect -f '{{.Mountpoint}}' ${P}_studio-release 2>/dev/null)
  if [ $pe -ne 0 ]; then n="probe=fail"
  elif [ -z "$sm" ]; then n="volume=missing"
  else n=$(native "$sm" "$sm/$pn/probe") || n="FAILED $n"; fi
  res studio UNVERIFIED "identity probe exit=$pe $(head -1 "$REC/studio-probe.out" 2>/dev/null) $n; API/Studio upload not verified"; }
case_ai() { res ai UNVERIFIED "AI API image not loaded/memory unknown"; }

case_db; tc stop db >/dev/null 2>&1
case_broker; case_git; case_devora; case_studio; case_ai
{ echo "== after"; free -m; df -m "$ROOT"; } >> "$REC/resources.txt" 2>&1
awk -F'\t' 'NR>1{printf "%s{\"case\":\"%s\",\"status\":\"%s\",\"detail\":\"%s\"}",(n++?",":"["),$1,$2,$3}END{print "]"}' "$SUMMARY" > "$REC/summary.json"
echo "records: $REC"; [ -z "$FIRST_FAIL" ] || echo "FIRST_FAIL: $FIRST_FAIL"
exit $RC
