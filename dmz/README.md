# DMZ MQTT-over-WebSocket Proxy

This standalone compose stack exposes only MQTT-over-WebSocket for mobile
clients and proxies it to the internal Lucy TeamCloud nginx `/mqtt` endpoint.

```text
Mobile app
  -> wss://<dmz-domain>/mqtt
  -> or ws://<dmz-ip>/mqtt for plain WS mode
  -> DMZ nginx
  -> https://<internal-teamcloud>/mqtt
  -> internal broker
```

## Setup

```bash
cd dmz
cp .env.example .env
```

Edit `.env`:

```env
DMZ_SERVER_NAME=mqtt.company.com
DMZ_ENABLE_TLS=1
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

`INTERNAL_MQTT_UPSTREAM` must be reachable from the DMZ host and must not
include `/mqtt`; the proxy preserves the incoming request path.

Put the public DMZ TLS certificate and key here:

```text
dmz/certs/server.crt
dmz/certs/server.key
```

For IP-only test/private environments without a certificate, use plain WS:

```env
DMZ_SERVER_NAME=203.0.113.10
DMZ_ENABLE_TLS=0
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

Mobile clients then connect to:

```text
ws://203.0.113.10/mqtt
```

Start the proxy in WSS mode:

```bash
docker compose --env-file .env up -d
```

Start the proxy in plain WS mode:

```bash
docker compose -f docker-compose.yml -f docker-compose.ws.yml --env-file .env up -d
```

The scripts under `dmz/scripts/` are standalone and do not call the parent
on-premise `scripts/` directory. They use `dmz/` as their project root, write
archives under `dmz/images/` by default, and automatically include
`docker-compose.ws.yml` when `DMZ_ENABLE_TLS=0`.

## Offline Image Flow

On an internet-connected machine:

```bash
cd dmz
./scripts/download-compose-images.sh
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

Copy `dmz/` and `dmz/images/` to the DMZ server, create `dmz/.env`, then run:

```bash
cd dmz
./scripts/load-images-and-up.sh
```

Or specify the archive explicitly:

```bash
./scripts/load-images-and-up.sh ./images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
```

After changing `dmz/.env`, apply the change with:

```bash
./scripts/restart-after-env-change.sh
```

The restart script validates the new env and compose config before stopping the
running DMZ proxy.

Check health:

```bash
curl -k https://mqtt.company.com/health
# or, in plain WS mode:
curl http://203.0.113.10/health
```

## Network Policy

- Internet/mobile clients should reach only DMZ TCP 443.
- In plain WS mode, clients reach DMZ TCP 80 instead.
- DMZ should reach only the internal TeamCloud nginx HTTPS origin.
- Do not expose internal broker ports `1883`, `8080`, `8081`, or `8888` to the internet.

If mobile clients receive the broker URL from TeamCloud, set the internal
on-prem `.env` value to the DMZ URL:

```env
BROKER_WS_URL=wss://mqtt.company.com/mqtt
```

In plain WS mode:

```env
BROKER_WS_URL=ws://203.0.113.10/mqtt
```

## Security Note

This proxy does not add broker authentication or topic ACLs. The current broker
image defaults to anonymous access, so external production exposure requires a
separate broker authentication and ACL hardening task.

Plain `ws://` mode sends MQTT-over-WebSocket traffic without TLS. Use it only
for controlled private networks or temporary validation, not public production
mobile traffic.
