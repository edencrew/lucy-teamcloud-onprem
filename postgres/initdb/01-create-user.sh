#!/bin/bash
set -e

# Runs once on an empty data dir (docker-entrypoint-initdb.d). Existing data is never renamed/reinitialised.
TC_DB_NAME="${TC_DB_NAME:-lucy_teamcloud}"
AUTH_DB_NAME="${AUTH_DB_NAME:-lucy_auth}"
GITEA_DB_NAME="${GITEA_DB_NAME:-git}"

fail() { printf '01-create-user: ERROR: %s\n' "$*" >&2; exit 1; }

# Lowercase unquoted-safe PostgreSQL identifier; values are still passed to psql as quoted :"var".
check_ident() {
  local kind="$1" name="$2" v="$3"
  # Explicit character lists: [a-z] ranges can match uppercase under some locales' collation.
  case "$v" in ''|[0123456789]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_]*) fail "$name must match [a-z_][a-z0-9_]{0,62}" ;; esac
  [ "${#v}" -le 63 ] || fail "$name must match [a-z_][a-z0-9_]{0,62}"
  case "$v" in
    postgres|template0|template1|pg_*) fail "$name uses a reserved $kind name" ;;
  esac
}

check_ident role DB_USERNAME "${DB_USERNAME:-}"
check_ident database TC_DB_NAME "$TC_DB_NAME"
check_ident database AUTH_DB_NAME "$AUTH_DB_NAME"
check_ident database GITEA_DB_NAME "$GITEA_DB_NAME"
[ "$TC_DB_NAME" != "$AUTH_DB_NAME" ] || fail "TC_DB_NAME and AUTH_DB_NAME must differ"
[ "$TC_DB_NAME" != "$GITEA_DB_NAME" ] || fail "TC_DB_NAME and GITEA_DB_NAME must differ"
[ "$AUTH_DB_NAME" != "$GITEA_DB_NAME" ] || fail "AUTH_DB_NAME and GITEA_DB_NAME must differ"
[ -n "${DB_PASSWORD:-}" ] || fail "DB_PASSWORD is empty"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v db_user="$DB_USERNAME" -v db_pass="$DB_PASSWORD" \
  -v tc_db="$TC_DB_NAME" -v auth_db="$AUTH_DB_NAME" -v gitea_db="$GITEA_DB_NAME" <<-'EOSQL'
    CREATE USER :"db_user" WITH PASSWORD :'db_pass';
    CREATE DATABASE :"auth_db" OWNER :"db_user";
    CREATE DATABASE :"tc_db" OWNER :"db_user";
    CREATE DATABASE :"gitea_db" OWNER :"db_user";
    GRANT ALL PRIVILEGES ON DATABASE :"auth_db" TO :"db_user";
    GRANT ALL PRIVILEGES ON DATABASE :"tc_db" TO :"db_user";
    GRANT ALL PRIVILEGES ON DATABASE :"gitea_db" TO :"db_user";
EOSQL
