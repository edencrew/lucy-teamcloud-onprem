# Devora (optional add-on)

Optional Devora BE for TeamCloud on-prem, pinned to BE commit
`e196ad2aa8c3a5a1f130e443e6173af180304cee` (tree `1528a3b84799db085aad24b6edf7b4c081b483e7`).
No published BE tag. Runs as a separate Compose project (`devora`) with its own postgres
(pgvector/pgvector:pg16), redis (redis/redis-stack-server:7.4.0-v3) and api; nothing is shared with TC.
TC-only installs are unaffected. See [INTERFACE.md](INTERFACE.md) for the installer contract.

## Online preparation (connected build host)
```
bash devora/prepare-media.sh docker --be-repo /path/to/be-clone --be-image REGISTRY/devora-be:e196ad2 --out /empty/dir
```
Reuse an already-built BE image (same for `podman`):
```
bash devora/prepare-media.sh docker --existing-image --be-repo DIR --be-image REF --out EMPTY_DIR
```
Every ref (BE, pgvector, redis) must already exist locally; selected linux/amd64, OCI label
`org.opencontainers.image.revision` = pinned BE commit and `app/commit_sha.txt` are checked; no
build/pull/retag. Default mode refuses an existing BE ref and pulls only proven-missing dependencies.
Inventory/`be_image_id` are the canonical sha256 of the saved image config, not Docker's
index/platform-manifest `.Id`; an unreadable save fails closed (never treated as missing).
Docker `--platform` is used only when the CLI supports it. Docker same-daemon acceptance does not
certify real Podman, classic/fresh stores or app/install.

Default build mode does: `git archive` of the exact commit → `docker buildx build --platform linux/amd64
--build-arg SOURCE_COMMIT=<commit> -f source/Dockerfile --load -t "$BE_IMAGE" source` → verify arch and
`app/commit_sha.txt` → save BE image (Podman: `podman save -m`, multi-image archive) + pgvector + redis → copy `db/init` 001-003 and `docs` → write
`PROVENANCE.txt` and `SHA256SUMS`. The build is not bit-reproducible (uv.lock unused, floating
dependency / HF revisions), so freeze the saved image checksum. No build/pull on the target.

## Required operator input
Copy `.env.example`, replace every `CHANGE_ME`. External LLM (LiteLLM) and embedding endpoints must
already exist (1024-dim embeddings checked at startup). OIDC JWKS must be HTTPS/RS256 with real CA
trust. `WEB_SEARCH_ENABLED=false` is not an egress blocker; keep requests at `use_web=none` and apply a real network policy.

Secret env is stored at0600. Runtime SQL/docs files use0644 and media directories0755, including readable parent directories; do not guess container UIDs, chown or use0777. The installer copies only these non-secret media with readable modes.

## Lifecycle
`bash devora/manage.sh <docker|podman> <validate|load|bootstrap|start|stop|status> --env-file F --media-dir D`
(the scripts are mode 0644; always invoke them with `bash`).
`load` fails before loading if an inventory ref already exists with another ID/platform (load would move the tag).
`bootstrap` only on new empty volumes; restart uses `start`. Volumes are never removed by the script.
Rootless Podman is unverified.
