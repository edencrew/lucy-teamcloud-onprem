#!/usr/bin/env bash
# Bounded Devora lifecycle helper (see devora/INTERFACE.md for the exact argv contract).
#   manage.sh <docker|podman> <validate|load|bootstrap|start|stop|status> \
#     --env-file FILE --media-dir DIR
# Never prints env values. Never removes volumes (no down -v). Bootstrap only on new empty volumes.
set -Eeuo pipefail
umask 077

BE_COMMIT="e196ad2aa8c3a5a1f130e443e6173af180304cee"
PROJECT="devora"
VOLUMES="devora_pgdata devora_redisdata devora_aidata"
INIT_SQL="001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql"
REQUIRED_KEYS="DEVORA_BE_IMAGE API_BIND API_PORT APP_ENV AUTH_MODE CORS_MODE ORG_SCOPE_ENABLED
PLAN_LOCK_ENABLED DEPLOYMENT_ORG_ID THREAD_NAMESPACE_SECRET TEAMCLOUD_BASE_URL OIDC_ISSUER OIDC_AUDIENCE
OIDC_JWKS_URI OIDC_JWKS_HOST_ALLOWLIST OIDC_EXPECTED_TYP POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
DATABASE_URL REDIS_URL LITELLM_BASE_URL LITELLM_MASTER_KEY CHAT_MODEL DESIGN_EDIT_MODEL SCRIPT_MODEL
EMBEDDING_BACKEND EMBEDDING_MODEL"

die() { printf 'devora: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'devora: %s\n' "$*" >&2; }
usage() { die "usage: manage.sh <docker|podman> <validate|load|bootstrap|start|stop|status> --env-file FILE --media-dir DIR"; }

[ $# -eq 6 ] || usage
RUNTIME="$1"; ACTION="$2"; shift 2
case "$RUNTIME" in docker|podman) ;; *) usage ;; esac
case "$ACTION" in validate|load|bootstrap|start|stop|status) ;; *) usage ;; esac
ENV_FILE=""; MEDIA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --media-dir) MEDIA="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$ENV_FILE" in /*) ;; *) die "--env-file must be absolute" ;; esac
case "$MEDIA" in /*) ;; *) die "--media-dir must be absolute" ;; esac

HERE="$(cd -P "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$HERE/compose.$RUNTIME.yml"
[ -f "$COMPOSE_FILE" ] || die "compose file missing: $COMPOSE_FILE"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Read KEY=VALUE without sourcing (no shell evaluation of operator input).
env_get() { awk -v k="$1" 'index($0, k"=")==1 { v=substr($0, length(k)+2) } END { print v }' "$ENV_FILE"; }

validate_env() {
  [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || die "env file missing or symlink"
  [ "$(file_mode "$ENV_FILE")" = "600" ] || die "env file must be mode 0600"
  grep -q $'\r' "$ENV_FILE" && die "env file must use LF line endings"
  local k v
  for k in $REQUIRED_KEYS; do
    v="$(env_get "$k")"
    [ -n "$v" ] || die "required key empty or absent: $k"
    case "$v" in *CHANGE_ME*|*changeme*|*'<'*'>'*) die "placeholder value: $k" ;; esac
  done
  # openai: embeddings + chat share LITELLM_BASE_URL/MASTER_KEY (required above); OLLAMA_BASE_URL optional.
  # ollama: embeddings need a real OLLAMA_BASE_URL. Anything else fails closed.
  case "$(env_get EMBEDDING_BACKEND)" in
    openai) v="$(env_get OLLAMA_BASE_URL)"
            case "$v" in *CHANGE_ME*|*changeme*|*'<'*'>'*) die "placeholder value: OLLAMA_BASE_URL" ;; esac ;;
    ollama) v="$(env_get OLLAMA_BASE_URL)"; [ -n "$v" ] || die "EMBEDDING_BACKEND=ollama requires OLLAMA_BASE_URL"
            case "$v" in *CHANGE_ME*|*changeme*|*'<'*'>'*) die "placeholder value: OLLAMA_BASE_URL" ;; esac ;;
    *) die "EMBEDDING_BACKEND must be openai or ollama" ;;
  esac
  [ "$(env_get APP_ENV)" = production ] || die "APP_ENV must be production"
  [ "$(env_get AUTH_MODE)" = enforce ] || die "AUTH_MODE must be enforce"
  [ "$(env_get ORG_SCOPE_ENABLED)" = 1 ] || die "ORG_SCOPE_ENABLED must be 1"
  [ "$(env_get PLAN_LOCK_ENABLED)" = true ] || die "PLAN_LOCK_ENABLED must be true"
  [ -z "$(env_get EDENCREW_ENV)" ] || die "EDENCREW_ENV must be unset/empty on-prem"
  case "$(env_get CORS_MODE)" in
    native) ;;
    web) v="$(env_get ALLOWED_ORIGINS)"; [ -n "$v" ] || die "CORS_MODE=web requires ALLOWED_ORIGINS"
         case "$v" in *'*'*) die "ALLOWED_ORIGINS must not contain *" ;; esac ;;
    *) die "CORS_MODE must be native or web" ;;
  esac
  [ "$(env_get CONTEXT_PREPARATION_ENABLED)" = false ] || die "CONTEXT_PREPARATION_ENABLED must be false"
  [ "$(env_get CONTEXT_PREPARATION_BINDING_BYPASS)" = false ] || die "CONTEXT_PREPARATION_BINDING_BYPASS must be false"
  [ "$(env_get WEB_SEARCH_ENABLED)" = false ] || die "WEB_SEARCH_ENABLED must be false"
  [ -z "$(env_get JINA_API_KEY)" ] || die "JINA_API_KEY must be unset"
  [ "$(env_get LOCAL_RERANKER_ENABLED)" = false ] || die "LOCAL_RERANKER_ENABLED must be false"
  [ "$(env_get AI_DATA_ENABLED)" = false ] || die "AI_DATA_ENABLED must be false"
  case "$(env_get API_BIND)" in 127.0.0.1|::1) ;; *) die "API_BIND must be loopback" ;; esac
  case "$(env_get API_PORT)" in ''|*[!0-9]*) die "API_PORT must be numeric" ;; esac
  case "$(env_get OIDC_JWKS_URI)" in https://*) ;; *) die "OIDC_JWKS_URI must be https" ;; esac
  local u p d
  u="$(env_get POSTGRES_USER)"; p="$(env_get POSTGRES_PASSWORD)"; d="$(env_get POSTGRES_DB)"
  [ "$(env_get DATABASE_URL)" = "postgresql://$u:$p@postgres:5432/$d" ] \
    || die "DATABASE_URL must be postgresql://POSTGRES_USER:POSTGRES_PASSWORD@postgres:5432/POSTGRES_DB"
  case "$(env_get REDIS_URL)" in redis://redis:6379*) ;; *) die "REDIS_URL must point at dedicated redis service" ;; esac
  printf '%s' "$(env_get DEPLOYMENT_ORG_ID)" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    || die "DEPLOYMENT_ORG_ID must be a UUID"
}

INVENTORY="images/devora-images.inventory"
expected_refs() {
  printf '%s\n' "$(env_get DEVORA_BE_IMAGE)"
  if [ "$RUNTIME" = podman ]; then printf '%s\n' docker.io/pgvector/pgvector:pg16 docker.io/redis/redis-stack-server:7.4.0-v3
  else printf '%s\n' pgvector/pgvector:pg16 redis/redis-stack-server:7.4.0-v3; fi
}

# Inventory written by prepare-media: exactly the three expected refs, one "REF sha256:<64hex> linux/amd64" each.
validate_inventory() {
  local inv="$MEDIA/$INVENTORY" ref id plat extra n=0
  [ -f "$inv" ] && [ ! -L "$inv" ] || die "missing $INVENTORY"
  [ "$(awk '{print $1}' "$inv" | LC_ALL=C sort)" = "$(expected_refs | LC_ALL=C sort)" ] \
    || die "$INVENTORY must list exactly the expected three image refs (no duplicates)"
  while read -r ref id plat extra; do
    [ -z "$extra" ] || die "malformed $INVENTORY line for $ref"
    printf '%s' "$id" | grep -Eqx 'sha256:[0-9a-f]{64}' || die "malformed image id in $INVENTORY for $ref"
    [ "$plat" = linux/amd64 ] || die "image $ref platform is not linux/amd64 in $INVENTORY"
    n=$((n + 1))
  done < "$inv"
  [ "$n" = 3 ] || die "$INVENTORY must have exactly 3 lines"
}

# Docker 28+ selects linux/amd64 explicitly; classic Docker/Podman inspect/save the single local image.
PLAT=()
if [ "$RUNTIME" = docker ] && docker image save --help 2>/dev/null | grep -q -- '--platform'; then PLAT=(--platform linux/amd64); fi

# Prints "sha256:<config digest> os/arch" for a local ref; fails if absent. The ID is the canonical
# config digest from a local save (same as prepare-media), never runtime .Id (may be index/manifest).
# Return codes: 0 = printed; 1 = ref PROVED missing (platform-independent inspect says "no such
# image"); 3 = ref exists (or presence unknown) but its id/platform cannot be read -> callers fail.
ref_state() { # present|missing|error, never platform-selected
  local err
  if err="$("$RUNTIME" image inspect "$1" 2>&1 >/dev/null)"; then echo present; return; fi
  case "$err" in *"No such image"*|*"image not known"*|*"no such image"*) echo missing ;; *) echo error ;; esac
}
inspect_image() {
  local plat t cfg n hex st
  st="$(ref_state "$1")"
  [ "$st" = missing ] && return 1
  [ "$st" = present ] || { echo "error: cannot determine whether $1 exists" >&2; return 3; }
  plat="$("$RUNTIME" image inspect ${PLAT[@]+"${PLAT[@]}"} -f '{{.Os}}/{{.Architecture}}' "$1" 2>/dev/null)" \
    || { echo "error: existing $1 has no readable linux/amd64 platform" >&2; return 3; }
  t="$(mktemp -d)"
  "$RUNTIME" image save ${PLAT[@]+"${PLAT[@]}"} -o "$t/i.tar" "$1" >/dev/null 2>&1 && tar -xf "$t/i.tar" -C "$t" manifest.json 2>/dev/null \
    || { rm -rf "$t"; echo "error: cannot read canonical config id of existing $1" >&2; return 3; }
  n="$(grep -o '"Config":"[^"]*"' "$t/manifest.json" | wc -l | tr -d ' ')"
  [ "$n" = 1 ] || { rm -rf "$t"; echo "error: save of existing $1 is ambiguous ($n images)" >&2; return 3; }
  cfg="$(grep -o '"Config":"[^"]*"' "$t/manifest.json" | sed 's/^"Config":"//; s/"$//')"
  tar -xf "$t/i.tar" -C "$t" "$cfg" 2>/dev/null || { rm -rf "$t"; echo "error: config missing in save of $1" >&2; return 3; }
  hex="$(sha256_of "$t/$cfg")"; rm -rf "$t"
  case "$cfg" in *"$hex"*) ;; *) echo "error: config path does not match digest for $1" >&2; return 3 ;; esac
  printf 'sha256:%s %s\n' "$hex" "$plat"
}

validate_media() {
  [ -d "$MEDIA" ] && [ ! -L "$MEDIA" ] || die "media dir missing or symlink"
  [ -f "$MEDIA/PROVENANCE.txt" ] || die "media PROVENANCE.txt missing"
  grep -qx "be_commit=$BE_COMMIT" "$MEDIA/PROVENANCE.txt" || die "media be_commit mismatch"
  [ -f "$MEDIA/SHA256SUMS" ] || die "media SHA256SUMS missing"
  local s f line
  for f in $INIT_SQL; do [ -f "$MEDIA/db/init/$f" ] || die "missing db/init/$f"; done
  [ "$(ls -1 "$MEDIA/db/init" | wc -l | tr -d ' ')" = 3 ] || die "db/init must contain exactly $INIT_SQL"
  [ -d "$MEDIA/docs/spec" ] || die "missing docs/spec"
  for f in images/devora-images.tar images/devora-images.txt; do [ -f "$MEDIA/$f" ] || die "missing $f"; done
  # Lines are "<64hex>  <path>"; the path is the exact rest of the line (spaces kept byte-exact).
  while IFS= read -r line; do
    printf '%s\n' "$line" | grep -Eq '^[0-9a-f]{64}  [^[:cntrl:]]+$' || die "malformed SHA256SUMS line"
    s="${line%%  *}"; f="${line#*  }"
    case "$f" in /*|*..*|*\\*|./*) die "unsafe SHA256SUMS entry" ;; esac
    [ -f "$MEDIA/$f" ] && [ ! -L "$MEDIA/$f" ] || die "SHA256SUMS names missing file: $f"
    [ "$(sha256_of "$MEDIA/$f")" = "$s" ] || die "checksum mismatch: $f"
  done < "$MEDIA/SHA256SUMS"
  [ -z "$(cut -c67- "$MEDIA/SHA256SUMS" | LC_ALL=C sort | uniq -d | head -n 1)" ] || die "duplicate SHA256SUMS entry"
  # Same contract as the installer's Go verifier: no symlinks, every file except SHA256SUMS is covered.
  [ -z "$(find "$MEDIA" -type l | head -n 1)" ] || die "media must not contain symlinks"
  ( cd "$MEDIA" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' ) | while IFS= read -r f; do
    awk -v f="$f" 'substr($0,67)==f{found=1} END{exit !found}' "$MEDIA/SHA256SUMS" || die "SHA256SUMS does not cover $f"
  done || die "media coverage check failed"
  validate_inventory
  local img
  img="$(env_get DEVORA_BE_IMAGE)"
  grep -qxF "$img" "$MEDIA/images/devora-images.txt" || die "DEVORA_BE_IMAGE not in images/devora-images.txt"
  if [ "$RUNTIME" = podman ]; then
    grep -qxF docker.io/pgvector/pgvector:pg16 "$MEDIA/images/devora-images.txt" || die "pgvector image not listed"
    grep -qxF docker.io/redis/redis-stack-server:7.4.0-v3 "$MEDIA/images/devora-images.txt" || die "redis image not listed"
  else
    grep -qxF pgvector/pgvector:pg16 "$MEDIA/images/devora-images.txt" || die "pgvector image not listed"
    grep -qxF redis/redis-stack-server:7.4.0-v3 "$MEDIA/images/devora-images.txt" || die "redis image not listed"
  fi
}

# Optional DEVORA_CA_BUNDLE_FILE: absolute host path of a public PEM bundle (approved private roots
# plus public roots, since SSL_CERT_FILE replaces the default pool). When set, an ephemeral override
# (owned temp dir, removed on exit) adds ONE read-only shared-label (z) file bind to api and
# SSL_CERT_FILE. Only shape is checked (PEM certs, no key); CA cryptography is not validated.
CA_TARGET="/etc/devora/ca/ca-bundle.pem"
CA_ARGS=()
CA_TMP=""
CA_TMP_ROOT=""
# Bounded cleanup: remove only our own regular ca.override.yml, then rmdir. Anything unexpected
# (symlink, extra entries, failure) is retained and reported; never recursive deletion.
cleanup_ca() {
  local t="$CA_TMP" f
  [ -n "$t" ] && [ -n "$CA_TMP_ROOT" ] || return 0
  CA_TMP=""
  f="$t/ca.override.yml"
  case "$t" in "$CA_TMP_ROOT"/devora-ca.*) ;; *) log "CA override temp dir retained (unexpected path): $t"; return 0 ;; esac
  case "${t#"$CA_TMP_ROOT"/devora-ca.}" in ''|*/*) log "CA override temp dir retained (unexpected path): $t"; return 0 ;; esac
  if [ ! -d "$t" ] || [ -L "$t" ] || [ "$(cd -P "$t" 2>/dev/null && pwd)" != "$t" ] \
     || [ "$(ls -A -- "$t" 2>/dev/null)" != ca.override.yml ] || [ ! -f "$f" ] || [ -L "$f" ]; then
    log "CA override temp dir retained (unexpected contents): $t"; return 0
  fi
  rm -f -- "$f" && rmdir -- "$t" 2>/dev/null || log "CA override temp dir retained (cleanup failed): $t"
  return 0
}
prepare_ca() {
  local p d
  p="$(env_get DEVORA_CA_BUNDLE_FILE)"
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; *) die "DEVORA_CA_BUNDLE_FILE must be absolute" ;; esac
  printf '%s' "$p" | LC_ALL=C grep -q '[[:cntrl:]]' && die "DEVORA_CA_BUNDLE_FILE contains control characters"
  case "$p" in *'"'*|*\\*|*'$'*|*'/./'*|*'/../'*|*/.|*/..|*//*) die "DEVORA_CA_BUNDLE_FILE has unsafe characters or components" ;; esac
  [ -f "$p" ] && [ ! -L "$p" ] || die "DEVORA_CA_BUNDLE_FILE missing, not a regular file, or symlink"
  d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || die "DEVORA_CA_BUNDLE_FILE directory unreadable"
  [ "$d/$(basename "$p")" = "$p" ] || die "DEVORA_CA_BUNDLE_FILE path must not traverse symlinks"
  [ -r "$p" ] && [ -s "$p" ] || die "DEVORA_CA_BUNDLE_FILE unreadable or empty"
  grep -q 'PRIVATE KEY' "$p" && die "DEVORA_CA_BUNDLE_FILE must not contain private key material"
  grep -qx -- '-----BEGIN CERTIFICATE-----' "$p" || die "DEVORA_CA_BUNDLE_FILE has no PEM certificate"
  local nb ne
  nb="$(grep -c -- '^-----BEGIN CERTIFICATE-----$' "$p" || true)"
  ne="$(grep -c -- '^-----END CERTIFICATE-----$' "$p" || true)"
  [ "$(grep -c -- '^-----BEGIN ' "$p" || true)" = "$nb" ] && [ "$(grep -c -- '^-----END ' "$p" || true)" = "$ne" ] \
    || die "DEVORA_CA_BUNDLE_FILE must contain only PEM CERTIFICATE blocks"
  [ "$nb" -gt 0 ] && [ "$nb" = "$ne" ] || die "DEVORA_CA_BUNDLE_FILE BEGIN/END CERTIFICATE counts do not match"
  local root t
  root="$(cd -P "${TMPDIR:-/tmp}" 2>/dev/null && pwd)" || die "temp directory unusable"
  t="$(mktemp -d "$root/devora-ca.XXXXXX")" || die "could not create CA override temp dir"
  case "$t" in "$root"/devora-ca.*) ;; *) die "unexpected CA override temp dir" ;; esac
  case "${t#"$root"/devora-ca.}" in ''|*/*) die "unexpected CA override temp dir" ;; esac
  [ -d "$t" ] && [ ! -L "$t" ] && [ "$(cd -P "$t" 2>/dev/null && pwd)" = "$t" ] \
    || die "CA override temp dir is not a plain directory (retained: $t)"
  CA_TMP="$t"; CA_TMP_ROOT="$root"
  trap cleanup_ca EXIT
  cat > "$CA_TMP/ca.override.yml" <<EOF
services:
  api:
    environment:
      SSL_CERT_FILE: "$CA_TARGET"
    volumes:
      - type: bind
        source: "$p"
        target: "$CA_TARGET"
        read_only: true
        bind:
          selinux: z
EOF
  CA_ARGS=(-f "$CA_TMP/ca.override.yml")
  log "using DEVORA_CA_BUNDLE_FILE (read-only, SSL_CERT_FILE=$CA_TARGET)"
}

# Compose provider: the installer exports DEVORA_COMPOSE_BINARY (its standalone Compose CLI; for
# Podman the caller also exports DOCKER_HOST for the Podman socket). Otherwise `<rt> compose`.
# Python podman-compose is never required.
compose() {
  if [ -n "${DEVORA_COMPOSE_BINARY:-}" ]; then
    [ -x "$DEVORA_COMPOSE_BINARY" ] || die "DEVORA_COMPOSE_BINARY is not executable"
    set -- "$DEVORA_COMPOSE_BINARY" -p "$PROJECT" -f "$COMPOSE_FILE" ${CA_ARGS[@]+"${CA_ARGS[@]}"} "$@"
  else
    set -- "$RUNTIME" compose -p "$PROJECT" -f "$COMPOSE_FILE" ${CA_ARGS[@]+"${CA_ARGS[@]}"} "$@"
  fi
  DEVORA_ENV_FILE="$ENV_FILE" DEVORA_MEDIA_DIR="$MEDIA" \
  DEVORA_BE_IMAGE="$(env_get DEVORA_BE_IMAGE)" API_BIND="$(env_get API_BIND)" API_PORT="$(env_get API_PORT)" \
    "$@"
}

# Every inventory ref must exist locally with the exact recorded ID and platform. An existing ref with
# another ID fails and is never retagged. With "alias" (podman load only), a missing canonical Hub ref
# for pgvector/redis may be recreated from its Hub shortname or localhost/ name when that candidate has
# the exact same ID+platform. The operator BE ref and any non-Hub ref are never normalized.
images_present() {
  local ref id plat got cand src rc
  while read -r ref id plat; do
    rc=0; got="$(inspect_image "$ref")" || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 1 ] || die "existing image $ref is unreadable; refusing to continue"
    if [ "$rc" = 0 ]; then
      [ "$got" = "$id $plat" ] || die "image $ref has unexpected id/platform; refusing to retag"
      continue
    fi
    [ "${1:-}" = alias ] && [ "$RUNTIME" = podman ] || die "image not loaded: $ref"
    case "$ref" in
      docker.io/pgvector/pgvector:pg16|docker.io/redis/redis-stack-server:7.4.0-v3) ;;
      *) die "image not loaded: $ref" ;;
    esac
    src=""
    for cand in "${ref#docker.io/}" "localhost/${ref#docker.io/}"; do
      rc=0; got="$(inspect_image "$cand")" || rc=$?
      [ "$rc" = 1 ] && continue
      [ "$rc" = 0 ] || die "alias candidate $cand is unreadable; refusing to alias"
      [ "$got" = "$id $plat" ] && { src="$cand"; break; }
    done
    [ -n "$src" ] || die "image not loaded: $ref (no same-id/platform alias)"
    "$RUNTIME" tag "$src" "$ref" >/dev/null
    [ "$(inspect_image "$ref")" = "$id $plat" ] || die "alias verification failed: $ref"
  done < "$MEDIA/$INVENTORY"
}

# Runs BEFORE load: docker/podman load moves an existing tag onto the loaded image, so an existing
# inventory ref with another ID/platform must fail here, while it is still unchanged.
refs_not_conflicting() {
  local ref id plat got rc
  while read -r ref id plat; do
    rc=0; got="$(inspect_image "$ref")" || rc=$?
    [ "$rc" = 1 ] && continue
    [ "$rc" = 0 ] || die "existing image $ref has an unreadable id/platform; refusing to load over it"
    [ "$got" = "$id $plat" ] || die "image $ref already exists with another id/platform; refusing to load over it"
  done < "$MEDIA/$INVENTORY"
}

volume_exists() { "$RUNTIME" volume inspect "$1" >/dev/null 2>&1; }

api_run() { compose run --rm --no-deps --entrypoint sh api -c "$1"; }

do_bootstrap() {
  local v
  for v in $VOLUMES; do volume_exists "$v" && die "volume $v already exists; bootstrap is for a NEW EMPTY DB only (use start)"; done
  images_present
  local got
  got="$(compose run --rm --no-deps --entrypoint cat api app/commit_sha.txt | tr -d '\r\n ')"
  [ "$got" = "$BE_COMMIT" ] || die "image source commit mismatch (expected $BE_COMMIT)"
  log "starting postgres/redis (init SQL 001-003 run by postgres entrypoint on empty volume)"
  compose up -d --wait postgres redis
  log "applying 004_org_scope_mapping"
  api_run 'python3 deploy/apply_migration.py db/migration/004_org_scope_mapping.sql --dsn "$DATABASE_URL" --var deployment_org_id="$DEPLOYMENT_ORG_ID"'
  log "applying 004_org_scope"
  api_run 'python3 deploy/apply_migration.py db/migration/004_org_scope.sql --dsn "$DATABASE_URL" --var deployment_org_id="$DEPLOYMENT_ORG_ID" --var release_sha="$(cat app/commit_sha.txt)"'
  log "verifying org schema"
  api_run 'python3 deploy/verify_org_schema.py --dsn "$DATABASE_URL"'
  log "applying 005_startup_ddl"
  api_run 'python3 deploy/apply_migration.py db/migration/005_startup_ddl.sql --dsn "$DATABASE_URL" --var release_sha="$(cat app/commit_sha.txt)"'
  compose up -d api
  log "bootstrap complete"
}

validate_env
validate_media
case "$ACTION" in validate|bootstrap|start) prepare_ca ;; esac
case "$ACTION" in
  validate) compose config -q; log "validate ok" ;;
  load)
    refs_not_conflicting
    "$RUNTIME" load -i "$MEDIA/images/devora-images.tar" >/dev/null
    images_present alias; log "images loaded" ;;
  bootstrap) do_bootstrap ;;
  start)
    for v in $VOLUMES; do volume_exists "$v" || die "volume $v missing; run bootstrap first"; done
    images_present
    compose up -d ;;
  stop) compose stop ;;
  status) compose ps ;;
esac
