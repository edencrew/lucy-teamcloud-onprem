# Devora optional add-on — installer interface (shared protocol)

Status: onprem packaging is wired (`scripts/package-update.sh`, `scripts/package-offline-installer.sh`).
Go installer integration lives in installer-src and is not part of this repository.
TC-only installs/kits stay byte-for-byte unchanged when Devora is not selected (default OFF).

## Capability and markers
- Capability `devora-optional`. The manifest schema is unchanged; `requires` gains `devora-optional`
  if and only if the product payload carries the devora files. An old binary rejects the unknown
  capability (fail closed). TC-only manifests never list it.
- New binary ASCII marker `teamcloud-installer-contract:devora-optional:v1`. A Devora-selected kit
  byte-scans the installer binary for it and requires `devora-optional` in the manifest tool's
  `ops version` `capabilities=`. The TC-only marker
  `teamcloud-installer-contract:kit-format-2:product-install:receipt-identity:v1` is unchanged.
- No generic plugin framework. Manifest `ComposeFiles`/`Images`/`ImageArchive` remain TC only;
  Devora is a separate Compose project with its own image archive inside the media.

## Product files (optional, exact allowlist)
```
devora/compose.docker.yml  devora/compose.podman.yml  devora/.env.example
devora/manage.sh           devora/README.md           devora/INTERFACE.md
```
The product payload never contains media, `devora.env` or any operator value.

## Packaging inputs (build host)
- `DEVORA_ENV_FILE` — absolute path to the operator env file (mode `0600`, template
  `devora/.env.example`). Used only to validate (e.g. `DEVORA_BE_IMAGE` is listed in the media
  inventory); never copied into the kit/product/Git and never printed.
- `DEVORA_MEDIA_DIR` — absolute path to media produced by `devora/prepare-media.sh`.
Both unset → TC-only kit. Exactly one set → error. Both set → Devora selected.

## Kit layout (Devora selected)
- `product/teamcloud-initial.tar.gz` payload carries the six files above; `requires` +`devora-optional`.
- Kit root `devora-media/` is a validated copy of `DEVORA_MEDIA_DIR` (no symlinks, no `..`/absolute
  `SHA256SUMS` entries, media `SHA256SUMS` verified). Every file is covered by the kit `SHA256SUMS`.
- `KIT-INFO.txt` adds `devora=optional`, `devora_media=devora-media`, `devora_media_sha256sums=…`,
  `devora_installer_contract=…` (absent for TC-only kits).

## Media layout (`DEVORA_MEDIA_DIR` / kit `devora-media/`)
```
PROVENANCE.txt                  be_commit=e196ad2a…, be_tree=1528a3b8…, be_image=REF, be_image_id, runtime
SHA256SUMS                      "<sha256>  <relpath>"; covers EVERY file except itself, no symlinks
                                (written last by prepare-media, after all sidecars)
images/devora-images.tar        runtime save of BE image + dedicated pgvector + redis images
                                (Docker: `docker save REF...`; Podman: `podman save -m REF...` — `-m`
                                is required for a multi-image archive, without it Podman keeps one image)
images/devora-images.tar.sha256
images/devora-images.txt        one image ref per line; must contain DEVORA_BE_IMAGE exactly
images/devora-images.inventory  exactly 3 lines "REF sha256:<64hex> linux/amd64" (BE, pgvector, redis)
db/init/001_init.sql 002_rag_document_mgmt.sql 003_dashboard_cols.sql   (exactly these three, LF, from exact commit)
docs/ (incl. docs/spec/)        mounted ro: docs/spec -> /data/doc, docs -> /data/be_docs
```
Image refs are never synthesized: the BE ref comes from the env, pgvector/redis refs are the fixed
contract refs (`pgvector/pgvector:pg16`, `redis/redis-stack-server:7.4.0-v3`; Podman uses the
`docker.io/…` canonical form). Podman short-ref aliasing is only allowed for an explicit required
inventory ref with the same config ID as the archive; never guess a repo or overwrite a different ID.
External LLM + embedding only (no model images/weights). Model/embedding addresses and model IDs are
independent inputs; the embedding dimension is 1024.

## Installer selection and install steps
Selection is explicit: `--devora-env PATH --devora-media PATH` (both or neither; default OFF).
`--devora-media` may point at the kit root `devora-media/`.
1. Copy the six product files to `TARGET/devora/`.
2. Copy the env file to `TARGET/devora/devora.env`, mode `0600`, owner = installer user.
3. Copy media to `TARGET/devora/media/`, verifying `SHA256SUMS`.
4. Call, as an argv array (no shell interpolation; exactly six args after the script):
```
bash TARGET/devora/manage.sh <docker|podman> <action> --env-file TARGET/devora/devora.env --media-dir TARGET/devora/media
```
   in order `validate`, `load`, `bootstrap`. An existing Devora volume prevents bootstrap.
No automatic upgrade and no migration of an existing DB.

| action    | effect | when |
|-----------|--------|------|
| validate  | env + media checks, `compose config -q` | always first |
| load      | pre-load `refs_not_conflicting`: before any `<rt> load`, every inventory ref already present locally must have the recorded ID, otherwise fail with nothing loaded or retagged (a wrong-ID ref is rejected before load, never overwritten by it); then `<rt> load -i images/devora-images.tar`, verifies every inventory ref has the exact recorded ID + linux/amd64; existing ref with another ID fails (never retagged); Podman only: missing `docker.io/pgvector/pgvector:pg16` / `docker.io/redis/redis-stack-server:7.4.0-v3` may be tagged from its Hub shortname or `localhost/` name when that has the same ID+platform; the BE ref is never normalized | first install |
| bootstrap | fails if any of `devora_pgdata devora_redisdata devora_aidata` exists; checks image `app/commit_sha.txt` == BE commit; up postgres/redis (001-003 via initdb); 004 mapping → 004 org scope → verify → 005; up api | first install only |
| start     | requires existing volumes; `compose up -d` (no bootstrap) | restart |
| stop      | `compose stop` (never `down -v`) | stop |
| status    | `compose ps` | status |

Stop/status/restart route to the separate `devora` project only if Devora is installed; the TC
project identity is unchanged.

Exit 0 = success; non-zero with `devora: ERROR: …` on stderr. Env values are never printed.

## Compose provider
- If `DEVORA_COMPOSE_BINARY` is exported (the installer's standalone Compose CLI; for Podman the
  installer also exports `DOCKER_HOST` for its Podman socket provider), `manage.sh` runs it as
  `DEVORA_COMPOSE_BINARY -p devora -f compose.<rt>.yml …`. Otherwise `<rt> compose`.
  Python `podman-compose` is never required.

## Compose
- Project `devora`, network `devora_net`, volumes `devora_pgdata`, `devora_redisdata`, `devora_aidata`
  (`devora_aidata` mounted at `/app/.local/ai-data`).
- API published only on `API_BIND` (loopback) : `API_PORT` (operator-chosen; must not collide with TC ports).
- Health: `GET /health`, `GET /readyz` (readiness is not JWT/model acceptance). Embedding startup
  retries 20×15s; installer must not assume a 30s readiness.
- No existing DB migration, no deletion, no automatic old-DB upgrade.
