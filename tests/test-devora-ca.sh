#!/usr/bin/env bash
# Mocked tests for optional DEVORA_CA_BUNDLE_FILE in devora/manage.sh. Real helper calls; a fake runtime
# on PATH records argv and captures the override. No engine, network or real compose.
# Run: bash tests/test-devora-ca.sh
set -Eeuo pipefail
umask 022

HERE="$(cd -P "$(dirname "$0")" && pwd)"
D="$HERE/../devora"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

WORK="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/tc-devora-ca.XXXXXX")" && pwd)"
# Tiny owned fixtures are retained (no recursive deletion); location printed for manual removal.
trap 'printf "fixtures retained: %s\n" "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/media/db/init" "$WORK/media/docs/spec" "$WORK/media/images"
LOG="$WORK/calls.log"; : > "$LOG"
d="$WORK/cfg"; mkdir -p "$d/blobs/sha256"; printf 'config-a' > "$d/c"; ID="$(sha256 "$d/c")"
mv "$d/c" "$d/blobs/sha256/$ID"; printf '[{"Config":"blobs/sha256/%s"}]' "$ID" > "$d/manifest.json"
tar -cf "$WORK/img.tar" -C "$d" manifest.json blobs
cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
prev=""
for a in "\$@"; do
  [ "\$prev" = -f ] && case "\$a" in */ca.override.yml) cp "\$a" "$WORK/override.captured"
    [ -z "\${TC_EXTRA:-}" ] || : > "\${a%/*}/extra" ;; esac
  [ "\$prev" = -f ] && case "\$a" in */db.override.yml) cp "\$a" "$WORK/dboverride.captured"
    [ "\${DEVORA_API_DATABASE_URL:-}" = "\${TC_DSN:-}" ] && : > "$WORK/dsn.ok" ;; esac
  prev="\$a"
done
case "\$*" in
  "volume inspect "*) [ -e "$WORK/volumes.present" ] || exit 1 ;;
  *"--entrypoint cat api app/commit_sha.txt"*) echo e196ad2aa8c3a5a1f130e443e6173af180304cee ;;
  "image inspect -f "*) echo linux/amd64 ;;
  "image save -o "*) cp "$WORK/img.tar" "\$4" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"

M="$WORK/media"
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do echo "-- $f" > "$M/db/init/$f"; done
echo spec > "$M/docs/spec/a.md"; echo tar > "$M/images/devora-images.tar"
printf '%s\n' reg.local/devora-be:e196ad2 pgvector/pgvector:pg16 redis/redis-stack-server:7.4.0-v3 > "$M/images/devora-images.txt"
printf '%s sha256:%s linux/amd64\n' reg.local/devora-be:e196ad2 "$ID" pgvector/pgvector:pg16 "$ID" \
  redis/redis-stack-server:7.4.0-v3 "$ID" > "$M/images/devora-images.inventory"
echo be_commit=e196ad2aa8c3a5a1f130e443e6173af180304cee > "$M/PROVENANCE.txt"
( cd "$M" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' | while read -r f; do
    printf '%s  %s\n' "$(sha256 "$f")" "$f"; done ) > "$M/SHA256SUMS"

ENV="$WORK/devora.env"
sed -e "s|^DEVORA_BE_IMAGE=.*|DEVORA_BE_IMAGE=reg.local/devora-be:e196ad2|" \
    -e "s|^API_PORT=.*|API_PORT=18000|" \
    -e "s|^DEPLOYMENT_ORG_ID=.*|DEPLOYMENT_ORG_ID=11111111-2222-3333-4444-555555555555|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=pw|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://devora:pw@postgres:5432/devora|" \
    -e "s|^OIDC_JWKS_URI=.*|OIDC_JWKS_URI=https://idp.local/jwks|" \
    -e "s|^EMBEDDING_BACKEND=.*|EMBEDDING_BACKEND=openai|" \
    -e "s|=CHANGE_ME$|=set|" "$D/.env.example" > "$ENV.base"
grep -qx 'DEVORA_CA_BUNDLE_FILE=' "$ENV.base" || fail ".env.example must ship DEVORA_CA_BUNDLE_FILE empty"
setca() { grep -v '^DEVORA_CA_BUNDLE_FILE=' "$ENV.base" > "$ENV"; [ $# -eq 0 ] || printf 'DEVORA_CA_BUNDLE_FILE=%s\n' "$1" >> "$ENV"; chmod 600 "$ENV"; }
# Mock volume state: bootstrap needs a new empty DB (no volumes); every other action sees existing volumes.
run() { : > "$LOG"; rm -f "$WORK/override.captured" "$WORK/dboverride.captured" "$WORK/dsn.ok"
  if [ "$1" = bootstrap ]; then rm -f "$WORK/volumes.present"; else : > "$WORK/volumes.present"; fi
  PATH="$WORK/bin:$PATH" bash "$D/manage.sh" docker "$1" --env-file "$ENV" --media-dir "$M" >/dev/null 2>"$WORK/err"; }

CERT='-----BEGIN CERTIFICATE-----
TUlJQnB1YmxpY2Zha2U=
-----END CERTIFICATE-----'

# ---------- unset / empty: argv unchanged ----------
for mode in absent empty; do
  if [ "$mode" = absent ]; then setca; else setca ""; fi
  for a in validate bootstrap start; do
    run "$a" || { cat "$WORK/err" >&2; fail "$mode CA $a"; }
    grep -q 'ca.override' "$LOG" && fail "$mode CA must not add override ($a)"
    [ ! -e "$WORK/override.captured" ] || fail "$mode CA captured override"
  done
  run validate; grep -qx "compose -p devora -f $D/compose.docker.yml config -q" "$LOG" \
    || grep -q "compose -p devora -f .*/compose.docker.yml config -q$" "$LOG" || fail "$mode CA validate argv"
done
pass "unset/empty CA leaves argv unchanged"

# ---------- valid file with space + Unicode ----------
CADIR="$WORK/ca dir ü"; mkdir -p "$CADIR"; CA="$CADIR/combined ca.pem"
printf '%s\n%s\n' "$CERT" "$CERT" > "$CA"
setca "$CA"
for a in validate bootstrap start; do
  run "$a" || { cat "$WORK/err" >&2; fail "valid CA $a"; }
  [ -f "$WORK/override.captured" ] || fail "override not passed ($a)"
  grep -v 'ca.override' "$LOG" | grep -q '^compose ' && fail "every compose call must carry the override ($a)"
done
expected="services:
  api:
    environment:
      SSL_CERT_FILE: \"/etc/devora/ca/ca-bundle.pem\"
    volumes:
      - type: bind
        source: \"$CA\"
        target: \"/etc/devora/ca/ca-bundle.pem\"
        read_only: true
        bind:
          selinux: z"
[ "$(cat "$WORK/override.captured")" = "$expected" ] || { cat "$WORK/override.captured" >&2; fail "override content"; }
grep -qE 'postgres|redis|ports|API_|AUTH|DATABASE|\bZ\b' "$WORK/override.captured" && fail "override touches more than api CA"
grep -q 'TUlJQnB1YmxpY2Zha2U' "$WORK/err" && fail "bundle body logged"
grep -q 'pw' "$WORK/err" && fail "secret logged"
tmpd="$(grep -o -- '-f [^ ]*ca.override.yml' "$LOG" | head -n 1 | sed 's/^-f //; s|/ca.override.yml$||')"
[ -n "$tmpd" ] && [ ! -e "$tmpd" ] || fail "override temp dir must be removed on exit"
[ -f "$CA" ] || fail "certificate source must never be deleted"
TC_EXTRA=1 run validate || { cat "$WORK/err" >&2; fail "extra-entry run"; }
tmpd="$(grep -o -- '-f [^ ]*ca.override.yml' "$LOG" | head -n 1 | sed 's/^-f //; s|/ca.override.yml$||')"
[ -f "$tmpd/ca.override.yml" ] && [ -f "$tmpd/extra" ] || fail "unexpected temp contents must be retained"
grep -q 'retained' "$WORK/err" || fail "retained temp dir must be reported"
run stop; grep -q 'ca.override' "$LOG" && fail "stop must not use override"
run status; grep -q 'ca.override' "$LOG" && fail "status must not use override"
pass "valid CA: one ro,z bind + SSL_CERT_FILE on api only, cleaned up"

# ---------- valid CA + DEVORA_API_DATABASE_URL together: start/start ----------
export TC_DSN='postgresql://devora:Sekr3tPw@postgres:5432/devora_restored'
setca "$CA"; grep -v '^DEVORA_API_DATABASE_URL=' "$ENV" > "$ENV.db"
printf 'DEVORA_API_DATABASE_URL=%s\n' "$TC_DSN" >> "$ENV.db"; mv "$ENV.db" "$ENV"; chmod 600 "$ENV"
pgbefore="$(grep -E '^(POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|DATABASE_URL)=' "$ENV")"
for i in 1 2; do
  run start || { cat "$WORK/err" >&2; fail "CA+DB start $i"; }
  [ -f "$WORK/override.captured" ] && [ -f "$WORK/dboverride.captured" ] || fail "CA+DB start $i: both overrides required"
  grep 'ca.override' "$LOG" | grep -q 'db.override' || fail "CA+DB start $i: CA and DB override argv together"
  grep -v 'ca.override' "$LOG" | grep -q '^compose ' && fail "CA+DB start $i: every compose call must carry CA override"
  [ -f "$WORK/dsn.ok" ] || fail "CA+DB start $i: DSN must reach compose via env"
  [ "$(cat "$WORK/override.captured")" = "$expected" ] || fail "CA+DB start $i: CA override content"
  grep -q 'DATABASE_URL: "${DEVORA_API_DATABASE_URL:?}"' "$WORK/dboverride.captured" || fail "CA+DB start $i: DB override content"
  grep -q 'Sekr3tPw' "$WORK/override.captured" "$WORK/dboverride.captured" "$LOG" "$WORK/err" && fail "CA+DB start $i: secret leaked"
  grep -qE 'postgres:|POSTGRES|initdb' "$WORK/dboverride.captured" && fail "CA+DB start $i: DB override touches PG init"
  [ "$(grep -E '^(POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|DATABASE_URL)=' "$ENV")" = "$pgbefore" ] || fail "PG init fields changed"
done
[ -f "$CA" ] || fail "certificate source must never be deleted (CA+DB)"
unset TC_DSN
pass "valid CA + DEVORA_API_DATABASE_URL survive start/start, secret absent"

# ---------- rejects ----------
reject() { setca "$1"; run validate && fail "must reject: $2"; grep -q 'DEVORA_CA_BUNDLE_FILE' "$WORK/err" || fail "reject message: $2"; }
reject "relative/ca.pem" relative
reject "$WORK/missing.pem" missing
mkdir -p "$WORK/d"; reject "$WORK/d" directory
ln -s "$CA" "$WORK/link.pem"; reject "$WORK/link.pem" "symlink file"
ln -s "$CADIR" "$WORK/linkdir"; reject "$WORK/linkdir/combined ca.pem" "symlinked parent"
reject "$CADIR/../ca dir ü/combined ca.pem" "dotdot"
reject "$WORK//x.pem" "double slash"
printf '%s\n' "$CERT" > "$WORK/q\"x.pem"; reject "$WORK/q\"x.pem" quote
printf '%s\n' "$CERT" > "$WORK/d\$x.pem"; reject "$WORK/d\$x.pem" dollar
printf '%s\n' "$CERT" > "$WORK/t	x.pem"; reject "$WORK/t	x.pem" "control char"
: > "$WORK/empty.pem"; reject "$WORK/empty.pem" empty
printf '%s\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n' "$CERT" > "$WORK/key.pem"; reject "$WORK/key.pem" "private key"
printf '%s\n-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n' "$CERT" > "$WORK/eckey.pem"; reject "$WORK/eckey.pem" "ec private key"
printf 'not a cert\n' > "$WORK/junk.pem"; reject "$WORK/junk.pem" "no certificate"
printf '%s\n-----BEGIN X509 CRL-----\nAAAA\n-----END X509 CRL-----\n' "$CERT" > "$WORK/crl.pem"; reject "$WORK/crl.pem" "non-cert block"
printf '%s\n-----BEGIN CERTIFICATE-----\nAAAA\n' "$CERT" > "$WORK/noend.pem"; reject "$WORK/noend.pem" "missing END"
printf '%s\n-----END CERTIFICATE-----\n' "$CERT" > "$WORK/xend.pem"; reject "$WORK/xend.pem" "extra END"
grep -q 'AAAA' "$WORK/err" && fail "rejected body logged"
pass "missing/unsafe/private-key CA rejected"

# ---------- unaffected actions: load ignores CA even if bad ----------
setca "$WORK/missing.pem"; run load || { cat "$WORK/err" >&2; fail "load must ignore CA"; }
pass "load ignores CA"

# ---------- shipped compose unchanged: SQL Z, API bind ----------
grep -q '/db/init:/docker-entrypoint-initdb.d:ro,Z' "$D/compose.podman.yml" || fail "SQL ro,Z mount must be unchanged"
grep -q '"${API_BIND:?API_BIND required}:${API_PORT:?API_PORT required}:8000"' "$D/compose.podman.yml" || fail "API bind unchanged"
grep -q 'SSL_CERT_FILE\|ca-bundle' "$D/compose.podman.yml" "$D/compose.docker.yml" && fail "base compose must not reference CA"
pass "base compose untouched"
