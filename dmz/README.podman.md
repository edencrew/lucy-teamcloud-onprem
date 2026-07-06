# Lucy TeamCloud DMZ Podman 설치 가이드

## 1. 환경 설정

```bash
cd dmz
cp .env.example .env
vi .env
```

예시:

```env
DMZ_SERVER_NAME=<DMZ_HOST>
INTERNAL_MQTT_UPSTREAM=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
```

`DMZ_SERVER_NAME`에는 scheme, path, port를 넣지 마세요. `INTERNAL_MQTT_UPSTREAM`에는
`/mqtt`를 붙이지 않습니다. `INTERNAL_MQTT_UPSTREAM`의 port는 내부 onprem gateway가
실제로 listen하는 port와 같아야 합니다.

아래 placeholder는 설명용입니다. 실제 `.env`와 compose 파일에는 `<...>`를 그대로
넣지 말고 운영 환경의 실제 host/domain과 숫자 port로 바꿔 입력하세요.

| Placeholder | 의미 |
|-------------|------|
| `<DMZ_HOST>` | DMZ 서버 host 또는 domain |
| `<DMZ_WS_PORT>` | DMZ plain WS host port |
| `<DMZ_WSS_PORT>` | DMZ WSS host port |
| `<DMZ_HTTP_REDIRECT_PORT>` | WSS 사용 시 HTTP -> HTTPS redirect host port |
| `<ONPREM_HOST>` | internal/onprem 서버 host 또는 domain |
| `<ONPREM_HTTP_PORT>` | internal/onprem gateway HTTP host port |
| `<ONPREM_HTTPS_PORT>` | internal/onprem gateway HTTPS host port |

DMZ 서버와 internal/onprem 서버는 서로 다른 서버입니다. DMZ 외부 노출 port는 DMZ
서버의 compose 파일 `ports`에서 정하고, 모바일 클라이언트가 사용할 broker URL은
internal/onprem 서버의 `.env`에 있는 `PUBLIC_BROKER_WS_URL`에 설정합니다.

기본 실행은 plain WS입니다. 인증서가 없으면 `compose.podman.yml`을 사용하세요.
WSS는 `certs/server.crt`, `certs/server.key`가 준비된 경우에만
`compose.podman.wss.yml`을 명시적으로 선택합니다.

## 2. Plain WS 실행

Podman 기본 compose는 plain WS이며 rootless 환경을 고려해 기본값으로 `18080:80`만
publish합니다. 운영에서 다른 host port를 써야 하면 실행 전에 `compose.podman.yml`의
`dmz-mqtt-proxy.ports`를 먼저 수정합니다.

DMZ 서버의 `compose.podman.yml`:

```yaml
ports:
  - "<DMZ_WS_PORT>:80"
```

실제 입력 예:

```yaml
ports:
  - "28080:80"
```

internal/onprem 서버의 `.env`에는 모바일 클라이언트가 접근할 DMZ URL을 적습니다.

```env
PUBLIC_BROKER_WS_URL=ws://<DMZ_HOST>:<DMZ_WS_PORT>/mqtt
```

방화벽은 아래 방향을 허용해야 합니다.

- mobile/client -> `<DMZ_HOST>:<DMZ_WS_PORT>`
- DMZ 서버 -> `<ONPREM_HOST>:<ONPREM_HTTP_PORT>` 또는 `<ONPREM_HTTPS_PORT>`

internal broker port `1883`, broker WebSocket port `8080`, DB port `5432`는 외부에
열지 마세요.

각 서버에서 파일을 확인한 뒤 DMZ 서버에서 실행합니다.

```bash
grep -n 'ports:\|DMZ_SERVER_NAME\|INTERNAL_MQTT_UPSTREAM' .env compose.podman.yml
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

상태 확인:

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs -f
curl "http://<DMZ_HOST>:<DMZ_WS_PORT>/health"
```

## 3. WSS 실행

WSS는 명시적으로 `compose.podman.wss.yml`을 사용합니다. 이 compose는 rootless 환경을
고려해 기본값으로 `18080:80`, `18443:443`을 publish하며, `certs/server.crt`,
`certs/server.key`가 반드시 있어야 시작됩니다.

운영에서 다른 HTTPS host port를 써야 하면 실행 전에 `compose.podman.wss.yml`의
`ports`와 `DMZ_HTTPS_REDIRECT_ORIGIN`을 함께 수정합니다.

DMZ 서버의 `compose.podman.wss.yml`:

```yaml
ports:
  - "<DMZ_HTTP_REDIRECT_PORT>:80"
  - "<DMZ_WSS_PORT>:443"
environment:
  DMZ_HTTPS_REDIRECT_ORIGIN: https://${DMZ_SERVER_NAME}:<DMZ_WSS_PORT>
```

실제 입력 예:

```yaml
ports:
  - "28080:80"
  - "28443:443"
environment:
  DMZ_HTTPS_REDIRECT_ORIGIN: https://${DMZ_SERVER_NAME}:28443
```

internal/onprem 서버의 `.env`에는 모바일 클라이언트가 접근할 DMZ URL을 적습니다.

```env
PUBLIC_BROKER_WS_URL=wss://<DMZ_HOST>:<DMZ_WSS_PORT>/mqtt
```

방화벽은 아래 방향을 허용해야 합니다.

- mobile/client -> `<DMZ_HOST>:<DMZ_WSS_PORT>`
- mobile/client -> `<DMZ_HOST>:<DMZ_HTTP_REDIRECT_PORT>` (HTTP -> HTTPS redirect를 사용할 때)
- DMZ 서버 -> `<ONPREM_HOST>:<ONPREM_HTTP_PORT>` 또는 `<ONPREM_HTTPS_PORT>`

internal broker port `1883`, broker WebSocket port `8080`, DB port `5432`는 외부에
열지 마세요.

인증서를 준비합니다.

```bash
cp /path/to/server.crt certs/server.crt
cp /path/to/server.key certs/server.key
```

WSS compose를 실행하기 전에 인증서 파일이 실제로 있는지 확인합니다. 실패하면 WSS를
실행하지 말고 인증서를 먼저 배치하거나 plain WS compose를 사용하세요.

```bash
test -f certs/server.crt && test -f certs/server.key
```

각 서버에서 파일을 확인한 뒤 DMZ 서버에서 실행합니다.

```bash
grep -n 'ports:\|DMZ_HTTPS_REDIRECT_ORIGIN\|DMZ_SERVER_NAME\|INTERNAL_MQTT_UPSTREAM' .env compose.podman.wss.yml
podman compose --env-file .env -f compose.podman.wss.yml up -d --no-build
```

상태 확인:

```bash
podman compose --env-file .env -f compose.podman.wss.yml ps
podman compose --env-file .env -f compose.podman.wss.yml logs -f
curl -k "https://<DMZ_HOST>:<DMZ_WSS_PORT>/health"
```

## 4. Offline Image Flow

온라인 PC에서 Podman용 DMZ image archive를 만듭니다. export는 Docker CLI를
사용하지만, Podman compose 파일을 기준으로 archive를 만듭니다. DMZ는 WS/WSS 모두
같은 nginx 이미지를 사용하므로 WSS용 archive를 따로 만들 필요가 없습니다. archive는
mode별로 따로 만들지 않고, 실행할 때 선택하는 compose 파일만 `compose.podman.yml`
또는 `compose.podman.wss.yml`로 바꿉니다.

```bash
cd dmz
./scripts/export-compose-images-podman.sh
```

생성 파일:

```text
images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz
images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-dmz-podman-images-linux-amd64.images.txt
images/lucy-teamcloud-dmz-podman-images-linux-amd64.archive-images.txt
images/lucy-teamcloud-dmz-podman-images-linux-amd64.services.txt
```

폐쇄망 DMZ 서버에는 필요한 compose 파일, `nginx/`, `certs/`, `.env`, `images/`만
준비합니다. Podman용 archive만 로드하세요. load 후 실행 전에 DMZ 서버의 compose
`ports`가 실제 `<DMZ_WS_PORT>` 또는 `<DMZ_WSS_PORT>`로 치환되어 있는지 확인하세요.
internal/onprem 서버에서는 `.env`의 `PUBLIC_BROKER_WS_URL`이 같은 DMZ endpoint를
가리키는지 별도로 확인하세요.

```bash
./scripts/load-compose-images-podman.sh ./images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz

podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

WSS 운영이면 마지막 명령에서 `compose.podman.wss.yml`을 사용합니다.

```bash
podman compose --env-file .env -f compose.podman.wss.yml up -d --no-build
```

Podman Compose에서는 Docker Compose의 `--pull never` 옵션을 쓰지 마세요. 일부
`podman-compose` 버전은 `never`를 서비스명으로 해석합니다.

## 5. 중지

```bash
podman compose --env-file .env -f compose.podman.yml down
```

WSS로 실행했다면 `compose.podman.wss.yml`을 사용하세요.
