#!/usr/bin/env bash
# TC DB inputs: executes postgres/initdb/01-create-user.sh against a fake psql (records argv/stdin; no real
# DB). Optional HOST_COMPOSE (e.g. "docker compose" or a compose binary) renders both real compose files.
# Run: bash tests/test-db-inputs.sh
set -Eeuo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
INIT="$ROOT/postgres/initdb/01-create-user.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tc-dbinputs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/psql" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/argv"
cat > "$WORK/stdin"
EOF
chmod +x "$WORK/bin/psql"

# init <env assignments...>: runs the real init script with only the given variables.
init() { rm -f "$WORK/argv" "$WORK/stdin"
  env -i PATH="$WORK/bin:/usr/bin:/bin" POSTGRES_USER=postgres POSTGRES_DB=postgres "$@" \
    bash "$INIT" >"$WORK/out" 2>"$WORK/err"; }

# --- positive: nondefault TC DB + user, password with quotes/shell metacharacters ---
PW="p'w\"\$(touch $WORK/pwned);x"
init DB_USERNAME=tc_owner DB_PASSWORD="$PW" TC_DB_NAME=tc_main AUTH_DB_NAME=auth_main GITEA_DB_NAME=gitea_main \
  || { cat "$WORK/err" >&2; fail "nondefault init"; }
[ -e "$WORK/pwned" ] && fail "password was shell-evaluated"
grep -qxF 'db_user=tc_owner' "$WORK/argv" || fail "db_user psql var"
grep -qxF "db_pass=$PW" "$WORK/argv" || fail "db_pass must be passed verbatim as psql var"
grep -qxF 'tc_db=tc_main' "$WORK/argv" || fail "tc_db psql var"
grep -qxF 'auth_db=auth_main' "$WORK/argv" || fail "auth_db psql var"
grep -qxF 'gitea_db=gitea_main' "$WORK/argv" || fail "gitea_db psql var"
grep -qxF 'ON_ERROR_STOP=1' "$WORK/argv" || fail "ON_ERROR_STOP kept"
grep -qF "CREATE USER :\"db_user\" WITH PASSWORD :'db_pass';" "$WORK/stdin" || fail "role/password quoting"
for v in tc_db auth_db gitea_db; do
  grep -qF "CREATE DATABASE :\"$v\" OWNER :\"db_user\";" "$WORK/stdin" || fail "$v identifier quoting"
  grep -qF "GRANT ALL PRIVILEGES ON DATABASE :\"$v\" TO :\"db_user\";" "$WORK/stdin" || fail "$v grant"
done
grep -qE 'lucy_auth|DATABASE git ' "$WORK/stdin" && fail "no hardcoded auth/git DB names in SQL"
grep -qE 'tc_owner|tc_main|auth_main|gitea_main|p.w' "$WORK/stdin" && fail "values must not be interpolated into SQL text"
grep -qF 'p'"'"'w' "$WORK/out" "$WORK/err" && fail "password echoed"
pass "nondefault TC/Auth/Gitea DBs + shared role via psql variables"

# --- default: absent name keys keep lucy_teamcloud / lucy_auth / git ---
init DB_USERNAME=lucy DB_PASSWORD=pw || { cat "$WORK/err" >&2; fail "default init"; }
grep -qxF 'tc_db=lucy_teamcloud' "$WORK/argv" || fail "default TC DB must stay lucy_teamcloud"
grep -qxF 'auth_db=lucy_auth' "$WORK/argv" || fail "default auth DB must stay lucy_auth"
grep -qxF 'gitea_db=git' "$WORK/argv" || fail "default gitea DB must stay git"
grep -qxF 'db_user=lucy' "$WORK/argv" || fail "default user"
pass "default (old) behaviour"

# --- changed namespaces: old internal names are usable when not colliding ---
init DB_USERNAME=lucy DB_PASSWORD=pw TC_DB_NAME=git AUTH_DB_NAME=auth2 GITEA_DB_NAME=lucy_auth \
  || { cat "$WORK/err" >&2; fail "swapped names init"; }
grep -qxF 'tc_db=git' "$WORK/argv" && grep -qxF 'gitea_db=lucy_auth' "$WORK/argv" || fail "swapped names vars"
pass "distinctness is pairwise on actual names"

# --- negative: refused before psql is called ---
neg() { local what="$1"; shift
  init "$@" && fail "$what must be refused"
  [ -e "$WORK/argv" ] && fail "$what: psql must not be called"
  grep -qF 'Sekr3t' "$WORK/err" "$WORK/out" && fail "$what: password echoed"
  return 0; }
LONG="a$(printf 'b%.0s' $(seq 1 63))"
for bad in TC_main 1db 'tc-db' 'tc db' 'x;drop' '"q"' postgres template0 template1 pg_x lucy_auth git "$LONG" ''; do
  [ -z "$bad" ] && continue
  neg "TC_DB_NAME '$bad'" DB_USERNAME=lucy DB_PASSWORD=Sekr3t TC_DB_NAME="$bad"
done
for bad in Auth_x 1db 'a-b' 'a b' 'x;drop' '"q"' postgres template0 template1 pg_x lucy_teamcloud git "$LONG"; do
  neg "AUTH_DB_NAME '$bad'" DB_USERNAME=lucy DB_PASSWORD=Sekr3t AUTH_DB_NAME="$bad"
done
for bad in Git 1db 'g-t' 'g t' 'x;drop' '"q"' postgres template0 template1 pg_x lucy_teamcloud lucy_auth "$LONG"; do
  neg "GITEA_DB_NAME '$bad'" DB_USERNAME=lucy DB_PASSWORD=Sekr3t GITEA_DB_NAME="$bad"
done
neg "TC==AUTH" DB_USERNAME=lucy DB_PASSWORD=Sekr3t TC_DB_NAME=same AUTH_DB_NAME=same GITEA_DB_NAME=g2
neg "TC==GITEA" DB_USERNAME=lucy DB_PASSWORD=Sekr3t TC_DB_NAME=same AUTH_DB_NAME=a2 GITEA_DB_NAME=same
neg "AUTH==GITEA" DB_USERNAME=lucy DB_PASSWORD=Sekr3t TC_DB_NAME=t2 AUTH_DB_NAME=same GITEA_DB_NAME=same
for bad in Lucy 1u 'u-x' "u'x" postgres pg_read_all_data template1 "$LONG"; do
  neg "DB_USERNAME '$bad'" DB_USERNAME="$bad" DB_PASSWORD=Sekr3t
done
neg "empty DB_USERNAME" DB_PASSWORD=Sekr3t
neg "empty DB_PASSWORD" DB_USERNAME=lucy
pass "invalid/reserved/colliding identifiers refused before psql"

# --- compose source contract (both runtimes) ---
for f in compose.docker.yml compose.podman.yml; do
  c="$ROOT/$f"
  grep -qF -- '- TC_DB_NAME=${TC_DB_NAME:-lucy_teamcloud}' "$c" || fail "$f db TC_DB_NAME"
  grep -qF 'DB_DATABASE: ${TC_DB_NAME:-lucy_teamcloud}' "$c" || fail "$f tc-be DB_DATABASE"
  grep -qF 'DATABASE_URL: "postgresql://${DB_USERNAME}:${DB_PASSWORD}@db:5432/${TC_DB_NAME:-lucy_teamcloud}"' "$c" \
    || fail "$f tc-be DATABASE_URL"
  grep -qF -- '- AUTH_DB_NAME=${AUTH_DB_NAME:-lucy_auth}' "$c" || fail "$f db AUTH_DB_NAME"
  grep -qF -- '- GITEA_DB_NAME=${GITEA_DB_NAME:-git}' "$c" || fail "$f db GITEA_DB_NAME"
  grep -qF 'DB_DATABASE: ${AUTH_DB_NAME:-lucy_auth}' "$c" || fail "$f auth-be DB_DATABASE"
  grep -qF 'DATABASE_URL: "postgresql://${DB_USERNAME}:${DB_PASSWORD}@db:5432/${AUTH_DB_NAME:-lucy_auth}"' "$c" \
    || fail "$f auth-be DATABASE_URL"
  grep -qF -- '- GITEA__database__NAME=${GITEA_DB_NAME:-git}' "$c" || fail "$f git GITEA__database__NAME"
  grep -qE 'DB_DATABASE: lucy_auth$|5432/lucy_auth"' "$c" && fail "$f must not hardcode lucy_auth"
done
pass "compose source contract"

# --- optional real compose render ---
if [ -z "${HOST_COMPOSE:-}" ]; then
  echo "skip compose render: HOST_COMPOSE unset"
else
  read -r -a HC <<< "$HOST_COMPOSE"
  render() { # $1 compose file, $2 env file
    "${HC[@]}" --project-directory "$ROOT" -f "$ROOT/$1" --env-file "$2" config > "$WORK/rendered" 2>"$WORK/cerr" \
      || { cat "$WORK/cerr" >&2; fail "compose config $1"; }; }
  grep -vE '^(TC|AUTH|GITEA)_DB_NAME=' "$ROOT/.env.example" > "$WORK/old.env"
  { cat "$WORK/old.env"; echo TC_DB_NAME=tc_main; echo AUTH_DB_NAME=auth_main; echo GITEA_DB_NAME=gitea_main; } \
    > "$WORK/new.env"
  for f in compose.docker.yml compose.podman.yml; do
    render "$f" "$WORK/new.env"
    grep -qE 'DB_DATABASE: "?tc_main"?$' "$WORK/rendered" || fail "$f effective tc-be DB_DATABASE"
    grep -qE 'DATABASE_URL: "?postgresql://lucy:[^@]*@db:5432/tc_main"?$' "$WORK/rendered" || fail "$f effective tc-be DATABASE_URL"
    grep -qE 'TC_DB_NAME: "?tc_main"?$' "$WORK/rendered" || fail "$f effective db TC_DB_NAME"
    grep -qE 'AUTH_DB_NAME: "?auth_main"?$' "$WORK/rendered" || fail "$f effective db AUTH_DB_NAME"
    grep -qE 'GITEA_DB_NAME: "?gitea_main"?$' "$WORK/rendered" || fail "$f effective db GITEA_DB_NAME"
    grep -qE 'DB_DATABASE: "?auth_main"?$' "$WORK/rendered" || fail "$f effective auth-be DB_DATABASE"
    grep -qE 'DATABASE_URL: "?postgresql://lucy:[^@]*@db:5432/auth_main"?$' "$WORK/rendered" || fail "$f effective auth-be DATABASE_URL"
    grep -qE 'GITEA__database__NAME: "?gitea_main"?$' "$WORK/rendered" || fail "$f effective GITEA__database__NAME"
    grep -qE '@db:5432/lucy_auth"?$' "$WORK/rendered" && fail "$f auth DSN must follow AUTH_DB_NAME"
    render "$f" "$WORK/old.env"
    grep -qE '@db:5432/lucy_auth"?$' "$WORK/rendered" || fail "$f old env auth DSN default"
    grep -qE 'GITEA__database__NAME: "?git"?$' "$WORK/rendered" || fail "$f old env GITEA__database__NAME default"
    grep -qE 'DB_DATABASE: "?lucy_teamcloud"?$' "$WORK/rendered" || fail "$f old env must keep lucy_teamcloud"
    grep -qE 'TC_DB_NAME: "?lucy_teamcloud"?$' "$WORK/rendered" || fail "$f old env db TC_DB_NAME default"
    pass "compose render $f"
  done
fi
echo "all db-inputs tests passed"
