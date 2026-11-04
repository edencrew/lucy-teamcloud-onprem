#!/usr/bin/env bash
# Static + mocked tests for devora/. No container engine, network or real compose: a fake runtime
# binary on PATH records argv. Run: bash tests/test-devora.sh
set -Eeuo pipefail
umask 022

HERE="$(cd -P "$(dirname "$0")" && pwd)"
D="$HERE/../devora"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ---------- static ----------
for f in compose.docker.yml compose.podman.yml; do
  c="$D/$f"
  grep -q '^name: devora$' "$c" || fail "$f project name"
  grep -q 'name: devora_net' "$c" || fail "$f network"
  for v in devora_pgdata devora_redisdata devora_aidata; do grep -q "name: $v" "$c" || fail "$f volume $v"; done
  grep -q 'DEVORA_BE_IMAGE:?' "$c" || fail "$f image must be required, no default"
  grep -q '"--port", "8000"' "$c" || fail "$f granian port"
  grep -q 'app.main:app' "$c" || fail "$f granian app"
  grep -q 'REDIS_ARGS' "$c" || fail "$f REDIS_ARGS"
  grep -q 'redis-stack-server:7.4.0-v3' "$c" || fail "$f redis image"
  grep -q 'pgvector/pgvector:pg16' "$c" || fail "$f pg image"
  grep -q '/docs/spec:/data/doc:ro' "$c" || fail "$f docs/spec mount"
  grep -q '/docs:/data/be_docs:ro' "$c" || fail "$f docs mount"
  grep -q '/db/init:/docker-entrypoint-initdb.d:ro' "$c" || fail "$f init mount"
  grep -q 'API_BIND:?' "$c" || fail "$f API_BIND"
  grep -qE 'chown|777|label=disable|privileged' "$c" && fail "$f must not chown/weaken security"
  grep -qE 'entrypoint:' "$c" && fail "$f must preserve image entrypoints"
  if [ "$f" = compose.docker.yml ]; then
    grep -qE 'user:|userns_mode:' "$c" && fail "$f must not guess UID/userns"
  else
    # Podman: only postgres is pinned (image postgres=999, keep-id maps the host owner to it).
    [ "$(grep -c 'userns_mode:' "$c")" = 1 ] && [ "$(grep -c 'user:' "$c")" = 1 ] || fail "$f only postgres may set user/userns"
    awk '/^  [a-z]+:$/{s=$1} /userns_mode:|user:/{print s, $0}' "$c" | grep -v '^postgres: ' && fail "$f user/userns outside postgres"
    grep -q 'userns_mode: "keep-id:uid=999,gid=999"' "$c" && grep -q 'user: "999:999"' "$c" || fail "$f postgres keep-id 999"
    for m in '/db/init:/docker-entrypoint-initdb.d:ro,Z' '/docs/spec:/data/doc:ro,Z' '/docs:/data/be_docs:ro,Z'; do
      grep -qF "$m" "$c" || fail "$f SELinux label on $m"; done
  fi
  pass "static $f"
done
grep -q 'down -v' "$D/manage.sh" && grep -v '^#' "$D/manage.sh" | grep -q 'down -v' && fail "manage.sh must not down -v"
grep -q 'CHANGE_ME' "$D/.env.example" || fail ".env.example placeholders"
pass "static manage.sh/.env.example"

# ---------- mocked runtime ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tc-devora-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/media/db/init" "$WORK/media/docs/spec" "$WORK/media/images"
LOG="$WORK/calls.log"; : > "$LOG"
# Image IDs are real config digests; $WORK/img_<hex>.tar is the local save of that config.
mkimg() { local d="$WORK/cfg.$1" h; mkdir -p "$d"; printf 'config-%s' "$1" > "$d/c"; h="$(sha256 "$d/c")"
  mkdir -p "$d/blobs/sha256"; mv "$d/c" "$d/blobs/sha256/$h"; printf '[{"Config":"blobs/sha256/%s"}]' "$h" > "$d/manifest.json"
  tar -cf "$WORK/img_$h.tar" -C "$d" manifest.json blobs; printf '%s' "$h"; }
ID="$(mkimg a)"; ID2="$(mkimg b)"
cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
case "\$*" in
  "volume inspect "*) [ -f "$WORK/vol_exists" ] && exit 0 || exit 1 ;;
  *"--entrypoint cat api app/commit_sha.txt"*) cat "$WORK/commit" ;;
  "image inspect -f "*) echo linux/amd64 ;;
  "image save -o "*) cp "$WORK/img_$ID.tar" "\$4" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"
echo e196ad2aa8c3a5a1f130e443e6173af180304cee > "$WORK/commit"

M="$WORK/media"
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do echo "-- $f" > "$M/db/init/$f"; done
echo spec > "$M/docs/spec/a.md"
echo tar > "$M/images/devora-images.tar"
printf '%s\n' reg.local/devora-be:e196ad2 pgvector/pgvector:pg16 redis/redis-stack-server:7.4.0-v3 > "$M/images/devora-images.txt"
printf '%s sha256:%s linux/amd64\n' reg.local/devora-be:e196ad2 "$ID" pgvector/pgvector:pg16 "$ID" \
  redis/redis-stack-server:7.4.0-v3 "$ID" > "$M/images/devora-images.inventory"
echo be_commit=e196ad2aa8c3a5a1f130e443e6173af180304cee > "$M/PROVENANCE.txt"
# Full-file coverage, matching the installer's Go verifier (every file except SHA256SUMS).
mksums() { ( cd "$1" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' | while read -r f; do
    printf '%s  %s\n' "$(sha256 "$f")" "$f"; done ) > "$1/SHA256SUMS"; }
mksums "$M"

ENV="$WORK/devora.env"
U=11111111-2222-3333-4444-555555555555
sed -e "s|^DEVORA_BE_IMAGE=.*|DEVORA_BE_IMAGE=reg.local/devora-be:e196ad2|" \
    -e "s|^API_PORT=.*|API_PORT=18000|" \
    -e "s|^DEPLOYMENT_ORG_ID=.*|DEPLOYMENT_ORG_ID=$U|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=pw|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://devora:pw@postgres:5432/devora|" \
    -e "s|^OIDC_JWKS_URI=.*|OIDC_JWKS_URI=https://idp.local/jwks|" \
    -e "s|^EMBEDDING_BACKEND=.*|EMBEDDING_BACKEND=openai|" \
    -e "s|=CHANGE_ME$|=set|" "$D/.env.example" > "$ENV"
chmod 600 "$ENV"

run() { PATH="$WORK/bin:$PATH" bash "$D/manage.sh" docker "$1" --env-file "$ENV" --media-dir "$M" >/dev/null 2>"$WORK/err"; }

run validate || { cat "$WORK/err" >&2; fail "validate on good input"; }
grep -q -- '-p devora' "$LOG" || fail "compose project flag"
pass "validate good input"

: > "$LOG"; run bootstrap || { cat "$WORK/err" >&2; fail "bootstrap"; }
order="$(grep -oE '00[45]_[a-z_]+\.sql|verify_org_schema' "$LOG" | tr '\n' ' ')"
[ "$order" = "004_org_scope_mapping.sql 004_org_scope.sql verify_org_schema 005_startup_ddl.sql " ] || fail "migration order: $order"
grep -q 'run --rm --no-deps --entrypoint sh api' "$LOG" || fail "migration run form"
pass "bootstrap order"

touch "$WORK/vol_exists"
run bootstrap && fail "bootstrap must fail on existing volumes"
run start || fail "start with existing volumes"
rm "$WORK/vol_exists"
run start && fail "start without volumes must fail"
pass "volume preflight"

echo deadbeef > "$WORK/commit"; run bootstrap && fail "commit mismatch must fail"
echo e196ad2aa8c3a5a1f130e443e6173af180304cee > "$WORK/commit"
pass "image commit check"

chmod 644 "$ENV"; run validate && fail "non-0600 env must fail"; chmod 600 "$ENV"
cp "$ENV" "$ENV.bak"
# Mutate one key, keep mode 0600 so only the mutated value can cause the rejection.
mut() { sed "s|^$1=.*|$1=$2|" "$ENV.bak" > "$ENV"; chmod 600 "$ENV"; }
mut CHAT_MODEL CHANGE_ME; run validate && fail "placeholder must fail"
mut API_BIND 0.0.0.0; run validate && fail "non-loopback must fail"
mut EDENCREW_ENV prod; run validate && fail "EDENCREW_ENV must fail"
mut DATABASE_URL postgresql://x:y@tc-db:5432/z; run validate && fail "foreign DB must fail"
mut CORS_MODE web; run validate && fail "web CORS without origins must fail"
cp "$ENV.bak" "$ENV"; chmod 600 "$ENV"; run validate || fail "restored env must validate"
pass "env rejection"

# DB identifiers: nondefault user/DB with the matching DSN pass; invalid/reserved are refused before any
# runtime call, and neither the identifier nor the password is echoed.
dbenv() { sed -e "s|^POSTGRES_USER=.*|POSTGRES_USER=$1|" -e "s|^POSTGRES_DB=.*|POSTGRES_DB=$2|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=Sekr3tPw|" \
  -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://$1:Sekr3tPw@postgres:5432/$2|" "$ENV.bak" > "$ENV"; chmod 600 "$ENV"; }
: > "$LOG"; dbenv dv_app dv_main; run validate || { cat "$WORK/err" >&2; fail "nondefault user/DB with matching DSN"; }
grep -q 'config -q' "$LOG" || fail "nondefault user/DB must reach compose config"
dbenv dv_app dv_main; sed -i.x "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://dv_app:Sekr3tPw@postgres:5432/devora|" "$ENV"
rm -f "$ENV.x"; chmod 600 "$ENV"; run validate && fail "DSN DB mismatch must fail"
for bad in Dv_app 1abc 'dv-app' postgres pg_monitor template0 template1 "a$(printf 'b%.0s' $(seq 1 63))"; do
  for which in user db; do
    if [ "$which" = user ]; then dbenv "$bad" dv_main; else dbenv dv_app "$bad"; fi
    : > "$LOG"; run validate && fail "invalid/reserved $which '$bad' must fail"
    [ -s "$LOG" ] && fail "invalid $which '$bad' must fail before any runtime call"
    grep -q 'POSTGRES_USER\|POSTGRES_DB' "$WORK/err" || fail "invalid $which '$bad' error message"
    grep -qF 'Sekr3tPw' "$WORK/err" && fail "password leaked in identifier error"
    [ "$bad" != postgres ] && grep -qF -- "$bad" "$WORK/err" && fail "identifier value echoed"
  done
done
cp "$ENV.bak" "$ENV"; chmod 600 "$ENV"; run validate || fail "restored env must validate"
pass "devora DB identifier contract"

# Conditional embedding contract (mocked; no network, no dimension probe).
grep -q '^OLLAMA_BASE_URL=$' "$ENV.bak" || fail "fixture must have empty OLLAMA_BASE_URL"
run validate || { cat "$WORK/err" >&2; fail "openai without OLLAMA_BASE_URL must validate"; }
grep -v '^OLLAMA_BASE_URL=' "$ENV.bak" > "$ENV"; chmod 600 "$ENV"
run validate || { cat "$WORK/err" >&2; fail "openai with OLLAMA_BASE_URL absent must validate"; }
mut LITELLM_BASE_URL ''; run validate && fail "openai without LITELLM_BASE_URL must fail"
mut LITELLM_MASTER_KEY ''; run validate && fail "openai without LITELLM_MASTER_KEY must fail"
mut EMBEDDING_MODEL ''; run validate && fail "openai without EMBEDDING_MODEL must fail"
mut EMBEDDING_BACKEND ollama; run validate && fail "ollama without OLLAMA_BASE_URL must fail"
grep -q 'requires OLLAMA_BASE_URL' "$WORK/err" || fail "ollama-without-url error message"
sed -e "s|^EMBEDDING_BACKEND=.*|EMBEDDING_BACKEND=ollama|" -e "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=CHANGE_ME|" \
  "$ENV.bak" > "$ENV"; chmod 600 "$ENV"; run validate && fail "ollama placeholder OLLAMA_BASE_URL must fail"
sed -e "s|^EMBEDDING_BACKEND=.*|EMBEDDING_BACKEND=ollama|" -e "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://ollama.local:11434|" \
  "$ENV.bak" > "$ENV"; chmod 600 "$ENV"; run validate || { cat "$WORK/err" >&2; fail "ollama with OLLAMA_BASE_URL must validate"; }
for b in set huggingface OpenAI; do
  mut EMBEDDING_BACKEND "$b"; run validate && fail "unknown backend $b must fail"
  grep -q 'EMBEDDING_BACKEND must be openai or ollama' "$WORK/err" || fail "unknown backend $b error message"
done
mut AUTH_MODE off; run validate && fail "openai path must keep AUTH_MODE enforce guard"
mut ORG_SCOPE_ENABLED 0; run validate && fail "openai path must keep ORG_SCOPE guard"
mut PLAN_LOCK_ENABLED false; run validate && fail "openai path must keep PLAN_LOCK guard"
mut OIDC_ISSUER ''; run validate && fail "openai path must keep OIDC guard"
cp "$ENV.bak" "$ENV"; chmod 600 "$ENV"; run validate || fail "restored env must validate"
pass "conditional embedding backend contract"

echo tampered >> "$M/images/devora-images.tar"; run validate && fail "checksum mismatch must fail"
pass "media checksum"

PATH="$WORK/bin:$PATH" bash "$D/manage.sh" docker validate --env-file "$ENV" >/dev/null 2>&1 && fail "short argv must fail"
pass "argv contract"

for f in compose.docker.yml compose.podman.yml; do
  grep -q 'aidata:/app/.local/ai-data' "$D/$f" || fail "$f aidata target must be /app/.local/ai-data"
  grep -q 'AI_DATA_LOG_PATH: /app/.local/ai-data$' "$D/$f" || fail "$f AI_DATA_LOG_PATH must be /app/.local/ai-data"
  # BE Dockerfile (e196ad2) bakes the model cache at ENV HF_HOME=/data/hfcache (no /app prefix).
  grep -q 'HF_HOME: /data/hfcache$' "$D/$f" || fail "$f HF_HOME must match BE Dockerfile /data/hfcache"
  grep -q 'HF_HOME: /app/' "$D/$f" && fail "$f HF_HOME must not use /app prefix"
done
pass "aidata target / HF_HOME source contract"

# Compose provider: DEVORA_COMPOSE_BINARY (installer's standalone CLI) instead of `<rt> compose`.
mksums "$M"
CLOG="$WORK/compose.log"; : > "$CLOG"; : > "$LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CLOG" > "$WORK/fake-compose"
chmod +x "$WORK/fake-compose"
DEVORA_COMPOSE_BINARY="$WORK/fake-compose" run validate || { cat "$WORK/err" >&2; fail "validate via DEVORA_COMPOSE_BINARY"; }
grep -q '^-p devora -f .*compose.docker.yml config -q$' "$CLOG" || fail "compose provider argv"
grep -q 'compose' "$LOG" && fail "runtime compose must not be used when DEVORA_COMPOSE_BINARY is set"
pass "compose provider"

# ---------- Docker 29 load preflight (pure mock image store; no real load/save/tag) ----------
# Fake Docker 29: advertises/accepts --platform, runtime .Id is an index digest != saved config digest.
# Store entry per ref: "<config hex|FAIL> <runtime id hex>"; FAIL = ref exists but save fails.
export D29S="$WORK/d29s" D29LOG="$WORK/d29.log" D29W="$WORK" D29INV="$WORK/d29media/images/devora-images.inventory"
printf 'index-manifest-%s' "$ID" > "$WORK/d29idx"; export D29RID="$(sha256 "$WORK/d29idx")"
mkdir -p "$WORK/d29bin" "$D29S"; DM="$WORK/d29media"; cp -R "$M" "$DM"
cat > "$WORK/d29bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$D29LOG"
k() { printf '%s' "$1" | tr '/:' '__'; }
r="${*: -1}"; f="$D29S/$(k "$r")"
case "$*" in
  "image save --help") echo "      --platform string   Save only the given platform variant" ;;
  "image inspect --platform linux/amd64 -f {{.Os}}/{{.Architecture}} "*) [ -f "$f" ] || exit 1; echo linux/amd64 ;;
  "image inspect --platform linux/amd64 -f {{.Id}} "*) [ -f "$f" ] || exit 1; echo "sha256:$(cut -d' ' -f2 "$f")" ;;
  "image inspect "*) [ $# = 3 ] || { echo "fake docker29: unexpected inspect form" >&2; exit 9; }
    [ -f "$f" ] || { echo "Error response from daemon: No such image: $r" >&2; exit 1; }
    printf '[{"Id":"sha256:%s"}]\n' "$(cut -d' ' -f2 "$f")" ;;
  "image save --platform linux/amd64 -o "*) [ -f "$f" ] || exit 1; h="$(cut -d' ' -f1 "$f")"
    [ "$h" != FAIL ] && cp "$D29W/img_$h.tar" "$6" || { echo "Error response from daemon: failed to export image" >&2; exit 1; } ;;
  "image save "*) echo "fake docker29: save without --platform not expected" >&2; exit 9 ;;
  "load -i "*) while read -r ref id p; do [ -f "$D29S/$(k "$ref")" ] \
      || printf '%s %s\n' "${id#sha256:}" "$D29RID" > "$D29S/$(k "$ref")"; done < "$D29INV" ;;
esac
exit 0
EOF
chmod +x "$WORK/d29bin/docker"
dseed() { rm -f "$D29S"/*; : > "$D29LOG"; while [ $# -gt 0 ]; do
  printf '%s %s\n' "$2" "$D29RID" > "$D29S/$(printf '%s' "$1" | tr '/:' '__')"; shift 2; done; }
drun() { DEVORA_COMPOSE_BINARY="$WORK/fake-compose" PATH="$WORK/d29bin:$PATH" \
  bash "$D/manage.sh" docker load --env-file "$ENV" --media-dir "$DM" >/dev/null 2>"$WORK/err"; }
dsnap() { for f in "$D29S"/*; do printf '%s=%s\n' "${f##*/}" "$(cat "$f")"; done; }
DPG=pgvector/pgvector:pg16; DRD=redis/redis-stack-server:7.4.0-v3
[ "$D29RID" != "$ID" ] && [ "$D29RID" != "$ID2" ] && [ "$ID" != "$ID2" ] || fail "docker29 fixtures must be distinct"
case "$(tar -xOf "$WORK/img_$ID.tar" manifest.json)" in *"blobs/sha256/$ID"*) ;; *) fail "saved fixture config digest" ;; esac
DBE=reg.local/devora-be:e196ad2

dseed "$DBE" "$ID" "$DPG" "$ID" "$DRD" "$ID"
[ "$(PATH="$WORK/d29bin:$PATH" docker image inspect --platform linux/amd64 -f '{{.Id}}' "$DPG")" = "sha256:$D29RID" ] \
  || fail "fake docker29 runtime .Id must be the index digest"
: > "$D29LOG"
drun || { cat "$WORK/err" >&2; fail "docker29 same canonical digest must pass despite runtime .Id"; }
grep -q '^image save --platform linux/amd64 -o ' "$D29LOG" || fail "docker29 selected-platform save not exercised"
grep -q '^image inspect --platform linux/amd64 -f ' "$D29LOG" || fail "docker29 selected-platform inspect not exercised"
grep -q '^load -i ' "$D29LOG" || fail "docker29 load must run when digests match"
grep -q '^tag ' "$D29LOG" && fail "docker29 must not tag when refs correct"
dseed "$DBE" "$ID" "$DPG" "$ID2" "$DRD" "$ID"; before="$(dsnap)"
drun && fail "docker29 different canonical digest must be refused"
grep -q 'already exists with another id/platform' "$WORK/err" || fail "docker29 conflict error path"
grep -qE '^(load|tag) ' "$D29LOG" && fail "docker29 conflict must fail before load/tag"
[ "$(dsnap)" = "$before" ] || fail "docker29 conflicting ref mutated"
pass "docker29 canonical digest vs runtime index .Id preflight"

dseed "$DBE" "$ID" "$DPG" FAIL "$DRD" "$ID"; before="$(dsnap)"
drun && fail "docker existing ref with unreadable save must fail closed"
grep -q 'cannot read canonical config id of existing pgvector/pgvector:pg16' "$WORK/err" || fail "save-failure error path (rc 3)"
grep -q 'unreadable id/platform; refusing to load over it' "$WORK/err" || fail "unreadable ref must not be treated as missing"
grep -qE '^(load|tag) ' "$D29LOG" && fail "unreadable ref must fail before load/tag"
[ "$(dsnap)" = "$before" ] || fail "unreadable ref mutated"
pass "docker existing ref with failing save fails closed before load"

# ---------- podman inventory / same-ID alias (pure mock image store; no real load/tag) ----------
export PSTORE="$WORK/ps" PLOG="$WORK/podman.log" PCOMMIT="$WORK/commit" PREPO_SRC="$WORK/besrc" PWORK="$WORK"
mkdir -p "$WORK/pbin" "$PSTORE"
cat > "$WORK/pbin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PLOG"
k() { printf '%s' "$1" | tr '/:' '__'; }
case "$1 $2" in
  "image inspect") r="${*: -1}"; [ -f "$PSTORE/$(k "$r")" ] || { echo "Error: $r: image not known" >&2; exit 125; }
    [ $# = 3 ] && exit 0
    case "$4" in '{{.Os}}/{{.Architecture}}') cut -d' ' -f2 "$PSTORE/$(k "$5")" ;;
      *image.revision*) cat "$PCOMMIT" ;; *) cat "$PSTORE/$(k "$5")" ;; esac ;;
  "image save") [ "$3" = -o ] && [ -f "$PSTORE/$(k "$5")" ] || exit 1; cp "$PWORK/img_$(cut -d' ' -f1 "$PSTORE/$(k "$5")").tar" "$4" ;;
  "tag "*) cp "$PSTORE/$(k "$2")" "$PSTORE/$(k "$3")" ;;
  "save -m") [ "$3" = -o ] || exit 2; echo images > "$4" ;;
  "save -o") echo "podman save without -m keeps only the first image" >&2; exit 3 ;;
  # like real load, moves existing tags onto the archive IDs (only when PLOADINV is set)
  "load -i") [ -n "${PLOADINV:-}" ] || exit 0
    while read -r r i p; do printf '%s %s\n' "${i#sha256:}" "$p" > "$PSTORE/$(k "$r")"; done < "$PLOADINV" ;;
  "run --rm") cat "$PCOMMIT" ;;
  # build creates the -t ref with the content of $PWORK/built (ID PLATFORM)
  "build "*) a=("$@"); for ((i=0; i<${#a[@]}-1; i++)); do
      [ "${a[i]}" = -t ] && cp "$PWORK/built" "$PSTORE/$(k "${a[i+1]}")"; done ;;
esac
exit 0
EOF
cat > "$WORK/pbin/git" <<'EOF'
#!/usr/bin/env bash
case "$3" in rev-parse) echo 1528a3b84799db085aad24b6edf7b4c081b483e7 ;; archive) tar -cf - -C "$PREPO_SRC" . ;;
  ls-tree) cd "$PREPO_SRC" && find docs -type f -print0 | while IFS= read -r -d '' f; do printf '100644 blob 0\t%s\0' "$f"; done ;;
  show) cat "$PREPO_SRC/${4#*:}" ;; *) exit 1 ;; esac
EOF
chmod +x "$WORK/pbin/podman" "$WORK/pbin/git"
# seed REF ID PLATFORM ... (podman reports .Id without the sha256: prefix)
seed() { rm -f "$PSTORE"/*; : > "$PLOG"; while [ $# -gt 0 ]; do
  printf '%s %s\n' "$2" "$3" > "$PSTORE/$(printf '%s' "$1" | tr '/:' '__')"; shift 3; done; }
prun() { DEVORA_COMPOSE_BINARY="$WORK/fake-compose" PATH="$WORK/pbin:$PATH" \
  bash "$D/manage.sh" podman "$1" --env-file "$ENV" --media-dir "$2" >/dev/null 2>"$WORK/err"; }
BE=reg.local/devora-be:e196ad2; PGC=docker.io/pgvector/pgvector:pg16; RDC=docker.io/redis/redis-stack-server:7.4.0-v3
PM="$WORK/pmedia"; cp -R "$M" "$PM"
printf '%s\n' "$BE" "$PGC" "$RDC" > "$PM/images/devora-images.txt"
printf '%s sha256:%s linux/amd64\n' "$BE" "$ID" "$PGC" "$ID" "$RDC" "$ID" > "$PM/images/devora-images.inventory"
mksums "$PM"
prun validate "$PM" || { cat "$WORK/err" >&2; fail "podman validate with inventory"; }

seed "$BE" "$ID" linux/amd64 pgvector/pgvector:pg16 "$ID" linux/amd64 localhost/redis/redis-stack-server:7.4.0-v3 "$ID" linux/amd64
prun load "$PM" || { cat "$WORK/err" >&2; fail "same-ID alias load"; }
grep -qx "tag pgvector/pgvector:pg16 $PGC" "$PLOG" || fail "Hub shortname alias tag"
grep -qx "tag localhost/redis/redis-stack-server:7.4.0-v3 $RDC" "$PLOG" || fail "localhost alias tag"
seed "$BE" "$ID" linux/amd64 "$PGC" "$ID" linux/amd64 "$RDC" "$ID" linux/amd64
prun load "$PM" || fail "existing canonical correct ID must be accepted"
grep -q '^tag ' "$PLOG" && fail "no tag when canonical refs already correct"
pass "podman same-ID+platform alias"

seed "$BE" "$ID" linux/amd64 "$PGC" "$ID2" linux/amd64 pgvector/pgvector:pg16 "$ID" linux/amd64 "$RDC" "$ID" linux/amd64
PLOADINV="$PM/images/devora-images.inventory" prun load "$PM" && fail "existing canonical wrong ID must fail"
grep -q '^tag ' "$PLOG" && fail "wrong-ID canonical must not be retagged"
grep -q '^load ' "$PLOG" && fail "wrong-ID canonical must fail before load (load moves tags)"
[ "$(cat "$PSTORE/$(printf '%s' "$PGC" | tr '/:' '__')")" = "$ID2 linux/amd64" ] || fail "wrong-ID canonical changed"
seed "$BE" "$ID" linux/amd64
PLOADINV="$PM/images/devora-images.inventory" prun load "$PM" || { cat "$WORK/err" >&2; fail "load of absent refs"; }
grep -q '^load -i ' "$PLOG" || fail "load must run when no ref conflicts"
seed "$BE" "$ID" linux/amd64 pgvector/pgvector:pg16 "$ID" linux/arm64 "$RDC" "$ID" linux/amd64
prun load "$PM" && fail "wrong-platform alias candidate must fail"
grep -q '^tag ' "$PLOG" && fail "wrong-platform candidate must not be tagged"
seed "$BE" "$ID" linux/arm64 "$PGC" "$ID" linux/amd64 "$RDC" "$ID" linux/amd64
prun load "$PM" && fail "wrong-platform canonical must fail"
seed "localhost/$BE" "$ID" linux/amd64 "$PGC" "$ID" linux/amd64 "$RDC" "$ID" linux/amd64
prun load "$PM" && fail "non-Hub operator BE ref must never be normalized"
grep -q '^tag ' "$PLOG" && fail "BE ref must not be aliased"
pass "podman wrong ID/platform fail closed"

cp "$PM/images/devora-images.inventory" "$WORK/inv.bak"
sed -i.x "s|linux/amd64|linux/arm64|" "$PM/images/devora-images.inventory"; rm -f "$PM/images/devora-images.inventory.x"
mksums "$PM"; prun validate "$PM" && fail "inventory wrong platform must fail"
{ cat "$WORK/inv.bak"; head -n 1 "$WORK/inv.bak"; } > "$PM/images/devora-images.inventory"
mksums "$PM"; prun validate "$PM" && fail "duplicate inventory ref must fail"
sed "s|sha256:$ID|sha256:abc|" "$WORK/inv.bak" > "$PM/images/devora-images.inventory"
mksums "$PM"; prun validate "$PM" && fail "short image id must fail"
rm "$PM/images/devora-images.inventory"; mksums "$PM"; prun validate "$PM" && fail "missing inventory must fail"
cp "$WORK/inv.bak" "$PM/images/devora-images.inventory"; mksums "$PM"; echo extra > "$PM/images/extra.txt"
prun validate "$PM" && fail "uncovered media file must fail"
pass "inventory fail-closed + full SHA256SUMS coverage"

# prepare-media with fake git/podman (no real build/pull/save): every file must be covered by SHA256SUMS.
mkdir -p "$PREPO_SRC/db/init" "$PREPO_SRC/docs/spec" "$WORK/pout"
echo 'FROM scratch' > "$PREPO_SRC/Dockerfile"; echo s > "$PREPO_SRC/docs/spec/s.md"
for f in 001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql; do echo "-- $f" > "$PREPO_SRC/db/init/$f"; done
# fresh BE ref (default mode refuses an existing one); deps already present are kept (missing-only pull)
printf '%s linux/amd64\n' "$ID" > "$WORK/built"
pseed() { seed "$PGC" "$ID2" linux/amd64 "$RDC" "$ID" linux/amd64; }
seed "$BE" "$ID" linux/arm64 "$PGC" "$ID2" linux/amd64 "$RDC" "$ID" linux/amd64
PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --be-repo "$WORK/nrepo" --be-image "$BE" --out "$WORK/pout" \
  >/dev/null 2>"$WORK/err" && fail "existing (wrong-arch) BE must be refused"
grep -q '^build ' "$PLOG" && fail "refused existing BE must not be built over"
grep -q '^pull ' "$PLOG" && fail "refused existing BE must not pull"
pseed
PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --be-repo "$WORK/nrepo" --be-image "$BE" --out "$WORK/pout" \
  >/dev/null 2>"$WORK/err" || { cat "$WORK/err" >&2; fail "mock prepare-media"; }
grep -qx "save -m -o $WORK/pout/images/devora-images.tar $BE $PGC $RDC" "$PLOG" || fail "podman save must use -m (multi-image archive)"
PO="$WORK/pout"
[ -z "$(find "$PO" -type l)" ] || fail "prepared media has symlinks"
( cd "$PO" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' ) | while read -r f; do
  [ "$(awk -v f="$f" '$2==f{print $1}' "$PO/SHA256SUMS")" = "$(sha256 "$PO/$f")" ] || fail "SHA256SUMS does not cover $f"
done || fail "prepared media coverage"
grep -q '  images/devora-images.tar.sha256$' "$PO/SHA256SUMS" || fail "tar.sha256 sidecar not covered"
grep -q '  images/devora-images.inventory$' "$PO/SHA256SUMS" || fail "inventory not covered"
[ "$(cat "$PO/images/devora-images.inventory")" = "$BE sha256:$ID linux/amd64
$PGC sha256:$ID2 linux/amd64
$RDC sha256:$ID linux/amd64" ] || fail "inventory content"
prun validate "$PO" || { cat "$WORK/err" >&2; fail "manage validate on prepared media"; }
mkdir -p "$WORK/pout2" "$PREPO_SRC/docs/archive"; echo x > "$PREPO_SRC/docs/archive/오브제의 수명규칙_v1.0.md"
pseed; PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --be-repo "$WORK/nrepo" --be-image "$BE" --out "$WORK/pout2" \
  >/dev/null 2>"$WORK/err" || { cat "$WORK/err" >&2; fail "space file name must be kept by prepare-media"; }
grep -qxF "$(sha256 "$WORK/pout2/docs/archive/오브제의 수명규칙_v1.0.md")  docs/archive/오브제의 수명규칙_v1.0.md" \
  "$WORK/pout2/SHA256SUMS" || fail "space file name must be covered byte-exact"
prun validate "$WORK/pout2" || { cat "$WORK/err" >&2; fail "manage validate with space file name"; }
cp "$WORK/pout2/SHA256SUMS" "$WORK/sums.bak"; tail -n 1 "$WORK/sums.bak" >> "$WORK/pout2/SHA256SUMS"
prun validate "$WORK/pout2" && fail "duplicate SHA256SUMS entry must fail"
grep -v ' docs/archive/' "$WORK/sums.bak" > "$WORK/pout2/SHA256SUMS"
prun validate "$WORK/pout2" && fail "uncovered space file name must fail"
rm -f "$PREPO_SRC/docs/archive/오브제의 수명규칙_v1.0.md"
mkdir -p "$WORK/pout3"; echo x > "$PREPO_SRC/docs/spec/a"$'\t'"b.md"
pseed; PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --be-repo "$WORK/nrepo" --be-image "$BE" --out "$WORK/pout3" \
  >/dev/null 2>"$WORK/err" && fail "tab file name must be rejected by prepare-media"
[ -e "$WORK/pout3/SHA256SUMS" ] && fail "rejected media must not get SHA256SUMS"
rm -f "$PREPO_SRC/docs/spec/a"$'\t'"b.md"; rmdir "$PREPO_SRC/docs/archive"
pass "prepare-media sidecars before SHA256SUMS (mock)"

# actual inv_line: valid ID -> unchanged line; config_id failure propagates and emits nothing
INVF="$(sed -n '/^inv_line() {/,/^}/p' "$D/prepare-media.sh")"
[ "$(bash -c "$INVF"'
config_id() { echo sha256:'"$ID"'; }; inv_line test-ref')" = "test-ref sha256:$ID linux/amd64" ] || fail "inv_line positive line"
o="$(bash -c "$INVF"'
config_id() { return 7; }; inv_line test-ref')" && fail "inv_line must propagate config_id failure"
[ -z "$o" ] || fail "inv_line must emit no line on config_id failure"
pass "inv_line propagates config_id failure"

# --existing-image: all refs local + OCI revision + commit_sha + amd64 -> no build/pull/tag; missing dep fails, no pull
mkdir -p "$WORK/pout4" "$WORK/pout5"
seed "$BE" "$ID" linux/amd64 "$PGC" "$ID2" linux/amd64 "$RDC" "$ID" linux/amd64
PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --existing-image --be-repo "$WORK/nrepo" --be-image "$BE" \
  --out "$WORK/pout4" >/dev/null 2>"$WORK/err" || { cat "$WORK/err" >&2; fail "existing-image prepare"; }
grep -Eq '^(build|pull|tag) ' "$PLOG" && fail "existing-image must not build/pull/tag"
grep -qx "$BE sha256:$ID linux/amd64" "$WORK/pout4/images/devora-images.inventory" || fail "existing-image inventory"
seed "$BE" "$ID" linux/amd64 "$PGC" "$ID2" linux/amd64
PATH="$WORK/pbin:$PATH" bash "$D/prepare-media.sh" podman --existing-image --be-repo "$WORK/nrepo" --be-image "$BE" \
  --out "$WORK/pout5" >/dev/null 2>"$WORK/err" && fail "existing-image with missing dep must fail"
grep -q '^pull ' "$PLOG" && fail "existing-image missing dep must not pull"
pass "prepare-media --existing-image (mock)"

# ---------- packaging (pure mock: fake git repo, manifest tool, compose, image tar) ----------
command -v git >/dev/null 2>&1 || { echo "skip packaging: git missing"; echo "all devora tests passed"; exit 0; }
PU="$HERE/../scripts/package-update.sh"
R="$WORK/repo"; mkdir -p "$R"
TC_FILES="compose.docker.yml compose.docker.init-secrets.yml scripts/load-compose-images-docker.sh .env.example init-secrets/Dockerfile init-secrets/docker-entrypoint.sh nginx/nginx.conf nginx/nginx.http.conf git/app.ini git/gitea-entrypoint.sh auth/auth-entrypoint.sh tc/tc-entrypoint.sh broker/mosquitto.conf postgres/initdb/01-create-user.sh studio-dl/nginx.conf scripts/studio-upload.sh"
for f in $TC_FILES; do mkdir -p "$R/$(dirname "$f")"; echo "x" > "$R/$f"; done
mkdir -p "$R/devora"
for f in compose.docker.yml compose.podman.yml .env.example manage.sh README.md INTERFACE.md; do cp "$D/$f" "$R/devora/$f"; done
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@t.invalid commit -q -m t
SHA="$(git -C "$R" rev-parse HEAD)"
cat > "$WORK/bin/fake-tool" <<'EOF'
#!/usr/bin/env bash
payload=""; req=""; out=""
while [ $# -gt 0 ]; do case "$1" in --payload) payload="$2"; shift 2 ;; --requires) req="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) shift ;; esac; done
{ printf '{"requires":['; printf '%s' "$req" | sed 's/[^,]*/"&"/g'; printf '],"files":['
  (cd "$payload" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | sed 's/.*/"&"/' | paste -sd, -); printf ']}\n'; } > "$out"
EOF
printf '#!/usr/bin/env bash\necho x/tc:1\n' > "$WORK/bin/fake-hostcompose"
chmod +x "$WORK/bin/fake-tool" "$WORK/bin/fake-hostcompose"
mkdir "$WORK/img"; echo '[{"Config":"c.json","RepoTags":["x/tc:1"]}]' > "$WORK/img/manifest.json"
(cd "$WORK/img" && tar -cf "$WORK/images.tar" manifest.json)
pkg() { # $1 = output dir; remaining env from caller
  mkdir "$1"
  bash "$PU" --runtime docker --source-repo "$R" --commit "$SHA" --version 9.9.9 --image-tar "$WORK/images.tar" \
    --manifest-tool "$WORK/bin/fake-tool" --compose-binary "$WORK/bin/fake-hostcompose" --output-dir "$1" >/dev/null 2>"$WORK/err"
}
P="teamcloud-update-v9.9.9-linux-amd64-docker.tar.gz"
( unset DEVORA_ENV_FILE DEVORA_MEDIA_DIR; pkg "$WORK/out-tc" ) || { cat "$WORK/err" >&2; fail "TC-only package"; }
tar -tzf "$WORK/out-tc/$P" | grep -q 'devora' && fail "TC-only package must not carry devora files"
tar -xzOf "$WORK/out-tc/$P" manifest.json | grep -q 'devora-optional' && fail "TC-only manifest must not require devora-optional"
pass "package-update TC-only unchanged path"

DEVORA_ENV_FILE="$ENV" pkg "$WORK/out-one" && fail "only DEVORA_ENV_FILE set must fail"
chmod 644 "$ENV"
DEVORA_ENV_FILE="$ENV" DEVORA_MEDIA_DIR="$M" pkg "$WORK/out-mode" && fail "non-0600 DEVORA_ENV_FILE must fail"
chmod 600 "$ENV"
DEVORA_ENV_FILE="$ENV" DEVORA_MEDIA_DIR="$M" pkg "$WORK/out-dv" || { cat "$WORK/err" >&2; fail "Devora package"; }
tar -tzf "$WORK/out-dv/$P" | grep 'payload/devora/' | grep -v '/$' | sed 's#^payload/##' | LC_ALL=C sort > "$WORK/dv.names"
printf '%s\n' devora/.env.example devora/INTERFACE.md devora/README.md devora/compose.docker.yml devora/compose.podman.yml devora/manage.sh \
  | LC_ALL=C sort | cmp -s - "$WORK/dv.names" || fail "Devora payload must be exactly the six devora files"
tar -xzOf "$WORK/out-dv/$P" manifest.json | grep -q '"devora-optional"' || fail "Devora manifest must require devora-optional"
tar -tzf "$WORK/out-dv/$P" | grep -qE 'devora-media|devora\.env|PROVENANCE|devora-images' && fail "product must not carry media/env"
tar -xzOf "$WORK/out-dv/$P" | grep -aqF 'POSTGRES_PASSWORD=pw' && fail "operator env value leaked into product"
grep -qF 'POSTGRES_PASSWORD=pw' "$WORK/err" && fail "operator env value leaked into logs"
pass "package-update Devora selected path"
echo "all devora tests passed"
