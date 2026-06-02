# DMZ Gateway Proxy

This standalone compose stack runs an nginx proxy in the DMZ.

It supports two modes:

- `DMZ_PROXY_MODE=mqtt`: the default. Exposes only MQTT-over-WebSocket `/mqtt`
  and returns `404` for other paths.
- `DMZ_PROXY_MODE=teamcloud`: exposes the full TeamCloud gateway through the
  DMZ, including `/`, `/api`, `/auth`, `/git`, and `/mqtt`.

Use `teamcloud` mode only when the DMZ is intended to be the external
TeamCloud entrypoint. It exposes a much wider surface than broker-only `mqtt`
mode.

```text
MQTT mode:
Mobile app
  -> wss://<dmz-domain>/mqtt
  -> or ws://<dmz-ip>/mqtt for plain WS mode
  -> DMZ nginx
  -> https://<internal-teamcloud>/mqtt
  -> internal broker

TeamCloud mode:
Browser / Lucy Studio / Git / MQTT client
  -> https://<canonical-teamcloud-domain>/...
  -> DMZ nginx
  -> https://<internal-teamcloud>/...
  -> internal onprem nginx
```

## Setup

```bash
cd dmz
cp .env.example .env
```

Edit `.env`:

```env
DMZ_SERVER_NAME=mqtt.company.com
DMZ_PROXY_MODE=mqtt
DMZ_ENABLE_TLS=1
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

In `mqtt` mode, `INTERNAL_MQTT_UPSTREAM` must be reachable from the DMZ host and
must not include `/mqtt`; the proxy preserves the incoming request path.

For full TeamCloud gateway mode:

```env
DMZ_SERVER_NAME=teamcloud.company.com
DMZ_PROXY_MODE=teamcloud
DMZ_ENABLE_TLS=1
INTERNAL_TEAMCLOUD_UPSTREAM=https://10.0.0.10
```

`INTERNAL_TEAMCLOUD_UPSTREAM` must point to the internal onprem nginx origin and
must not include a path. If it is empty, `teamcloud` mode falls back to
`INTERNAL_MQTT_UPSTREAM` for compatibility.

In `teamcloud` mode, use a single canonical URL for both internal and external
clients. The onprem `.env` should use the canonical DNS URL, not a raw DMZ IP:

```env
EXTERNAL_URL=https://teamcloud.company.com
BROKER_WS_URL=wss://teamcloud.company.com/mqtt
PUBLIC_BROKER_WS_URL=wss://teamcloud.company.com/mqtt
```

Internal DNS should resolve `teamcloud.company.com` to the internal onprem
gateway or to an internally reachable DMZ address. External DNS should resolve
the same host to the DMZ address.

Put the public DMZ TLS certificate and key here:

```text
dmz/certs/server.crt
dmz/certs/server.key
```

For IP-only test/private environments without a certificate, use plain WS:

```env
DMZ_SERVER_NAME=203.0.113.10
DMZ_PROXY_MODE=mqtt
DMZ_ENABLE_TLS=0
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

In Docker plain WS mode, mobile clients connect to:

```text
ws://203.0.113.10/mqtt
```

Podman 환경의 기본 포트는 rootless 환경을 고려해 `18080/18443`으로 고정되어 있습니다.

```text
https://<dmz-host>:18443/mqtt
# or, in plain WS mode:
http://<dmz-host>:18080/mqtt
```

The scripts under `dmz/scripts/` are standalone and do not call the parent
on-premise `scripts/` directory. For daily operation, use
`dmz-compose.sh <command>` in the same style as the on-premise
`onprem-compose.sh <command>` wrapper.
See `scripts/OPERATOR_QUICK_GUIDE.md` for the short operator guide and
`scripts/README.md` for full script-focused usage.

Auto-detect Docker or Podman:

```bash
./scripts/dmz-compose.sh check
./scripts/dmz-compose.sh up
./scripts/dmz-compose.sh ps
./scripts/dmz-compose.sh logs
./scripts/dmz-compose.sh down
```

To pin a runtime explicitly, set `DMZ_RUNTIME` on the same wrapper:

```bash
DMZ_RUNTIME=docker ./scripts/dmz-compose.sh up
DMZ_RUNTIME=podman ./scripts/dmz-compose.sh up
```

The wrapper selects the TLS/plain-WS compose override from `DMZ_ENABLE_TLS`.
Podman uses `docker-compose.podman.yml`, and plain WS adds
`docker-compose.podman.ws.yml`.

Equivalent Docker command for WSS mode:

```bash
docker compose --env-file .env up -d
```

Equivalent Docker command for plain WS mode:

```bash
docker compose -f docker-compose.yml -f docker-compose.ws.yml --env-file .env up -d
```

Equivalent Podman command for WSS mode:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.podman.yml up -d --no-build
```

Equivalent Podman command for plain WS mode:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.podman.ws.yml up -d --no-build
```

## Offline Image Flow

On an internet-connected machine:

```bash
cd dmz
./scripts/export-compose-images.sh
```

This creates:

```text
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz.sha256
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.images.txt
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.archive-images.txt
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.explicit-images.txt
dmz/images/lucy-teamcloud-dmz-images-linux-amd64.services.txt
```

Copy `dmz/` and `dmz/images/` to the DMZ server, create `dmz/.env`, then load
images and start the proxy through preflight.

```bash
cd dmz
./scripts/load-compose-images.sh
./scripts/preflight-dmz.sh --compose-up
```

Or specify the archive explicitly:

```bash
./scripts/load-compose-images.sh ./images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
```

After changing `dmz/.env`, apply the change with:

```bash
./scripts/dmz-compose.sh recreate
```

The recreate command validates the new env and compose config before replacing
the running DMZ proxy.

Stop the DMZ proxy while preserving files:

```bash
./scripts/dmz-compose.sh down
```

Check health:

```bash
curl -k https://mqtt.company.com/health
# or, in plain WS mode:
curl http://203.0.113.10/health
# or, with Podman defaults:
curl -k https://203.0.113.10:18443/health
curl http://203.0.113.10:18080/health
```

## Proxy Modes

### `DMZ_PROXY_MODE=mqtt`

This is the default and safest DMZ mode.

- `/mqtt` is proxied to `INTERNAL_MQTT_UPSTREAM`.
- `/health` is served locally by the DMZ nginx container.
- All other paths return `404`.
- Use this when only mobile MQTT-over-WebSocket traffic should cross the DMZ.

### `DMZ_PROXY_MODE=teamcloud`

This mode makes the DMZ proxy the external TeamCloud gateway.

- `/health` is served locally by the DMZ nginx container.
- All other paths are proxied to `INTERNAL_TEAMCLOUD_UPSTREAM`.
- Browser access, auth login/callbacks, Lucy Studio TeamCloud calls, Git HTTP
  clone/push, and `/mqtt` WebSocket traffic all pass through the same canonical
  host.
- The upstream receives `Host: $http_host`, `X-Forwarded-Host`,
  `X-Forwarded-Proto`, and `X-Forwarded-For` so the canonical host and port are
  preserved.

## Network Policy

- Internet/mobile clients should reach only DMZ TCP 443.
- In plain WS mode, clients reach DMZ TCP 80 instead.
- In `mqtt` mode, DMZ should reach only the internal TeamCloud nginx `/mqtt`
  origin.
- In `teamcloud` mode, DMZ must reach the internal onprem nginx origin for the
  full TeamCloud gateway.
- Do not expose internal broker ports `1883` or `8080` to the internet.

If mobile clients receive the broker URL from TeamCloud in `mqtt` mode, set the
internal onprem `.env` value to the DMZ URL. This value must match the DMZ
endpoint clients can reach:

```env
BROKER_WS_URL=wss://mqtt.company.com/mqtt
```

In plain WS mode:

```env
BROKER_WS_URL=ws://203.0.113.10/mqtt
```

With the Podman DMZ default ports:

```env
BROKER_WS_URL=wss://203.0.113.10:18443/mqtt
# or:
BROKER_WS_URL=ws://203.0.113.10:18080/mqtt
```

## Security Note

This proxy does not add broker authentication, topic ACLs, application auth, or
new access controls. It only forwards traffic.

The current broker configuration allows anonymous access, so external
production exposure requires a separate broker authentication and ACL hardening
task.

`DMZ_PROXY_MODE=teamcloud` exposes TeamCloud, Auth, API, Git, and MQTT paths
through the DMZ. Treat it as a full external application gateway, not as a
broker-only proxy.

Plain `ws://` mode sends MQTT-over-WebSocket traffic without TLS. Use it only
for controlled private networks or temporary validation, not public production
mobile traffic.
