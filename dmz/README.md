# Lucy TeamCloud DMZ MQTT 프록시

이 디렉터리의 nginx 프록시는 외부 모바일 앱의 `/mqtt` 요청을 내부 TeamCloud 게이트웨이로
전달합니다. MQTT-over-WebSocket 연결만 중계하며 TeamCloud 본체와 별도로 운영합니다.

화면, 로그인(`/auth`), API(`/api`), Git(`/git`), Studio 다운로드(`/studio`)는 중계하지 않습니다.
외부 앱이 로그인하거나 API와 파일에 접근할 경로는 별도로 준비해야 합니다.
브로커 인증과 토픽 접근 제어도 추가하지 않으므로 내부 브로커의 보안 설정을 확인해야 합니다.

TC 서버가 DMZ 망에 있다는 이유만으로 이 프록시가 필요한 것은 아닙니다.
외부 앱에서 내부 브로커에 직접 접근할 수 없어 별도 공개 진입점이 필요할 때 사용합니다.
TeamCloud 본체가 아직 설치되지 않았다면 [본체 설치 안내](../README.md)부터 진행합니다.

| 런타임 | 설치 가이드 |
|--------|-------------|
| Docker | [README.docker.md](README.docker.md) |
| Podman | [README.podman.md](README.podman.md) |

## 1. 연결 흐름

```text
모바일 앱
  │  ws://<DMZ 주소>/mqtt   또는  wss://<DMZ 주소>/mqtt
  ▼
DMZ 서버: dmz-mqtt-proxy (nginx, 이 디렉터리)
  │  INTERNAL_MQTT_UPSTREAM + 원래 경로(/mqtt)   예) https://tc.internal.example/mqtt
  ▼
TeamCloud 서버: gateway nginx (루트 nginx/nginx.conf 의 location ^~ /mqtt)
  │  http://broker:8080 (컨테이너 내부 네트워크)
  ▼
broker (mosquitto WebSocket listener 8080)
```

DMZ nginx는 `INTERNAL_MQTT_UPSTREAM` 뒤에 경로를 붙이지 않고 들어온 요청 경로(`/mqtt`…)를
그대로 넘깁니다(`dmz/nginx/nginx.ws.conf.template:22-23`).

## 2. DMZ nginx가 응답하는 경로

`dmz/nginx/*.conf.template` 기준입니다.

| 모드 | 포트(컨테이너) | `/health` | `/mqtt`(접두어 일치) | 그 외 경로 |
|------|----------------|-----------|----------------------|------------|
| WS | 80 | `200 OK` (DMZ nginx 자체 응답) | 내부 TeamCloud 서버으로 전달 | `404` |
| WSS | 80 | `200 OK` | `301` → HTTPS로 이동 | `301` → HTTPS로 이동 |
| WSS | 443 | `200 OK` | 내부 TeamCloud 서버으로 전달 | `404` |

- `/health`는 DMZ nginx가 실행 중이라는 것만 알려 줍니다. 내부 TeamCloud나 브로커에
  닿는지는 확인하지 않습니다. WebSocket 연결은 업그레이드(101)로, MQTT 인증과 메시지
  송수신은 실제 클라이언트로 각각 확인합니다.
- WSS 모드의 80 포트는 리다이렉트만 합니다. WebSocket 클라이언트는 보통 301을 따라가지
  않으므로 WSS 모드에서 `ws://.../mqtt`는 동작하지 않는다고 보세요.
- 포트마다 server 블록이 하나뿐이라 `DMZ_SERVER_NAME`과 다른 Host로 들어와도 같은
  블록이 응답합니다. 즉 `DMZ_SERVER_NAME`은 접속 차단 기능이 아닙니다.

## 3. WS / WSS 선택

| 항목 | WS (기본) | WSS |
|------|-----------|-----|
| 클라이언트 URL | `ws://<DMZ 주소>[:포트]/mqtt` | `wss://<DMZ 주소>[:포트]/mqtt` |
| Docker Compose 파일 | `compose.docker.yml` | `compose.docker.wss.yml` |
| Podman Compose 파일 | `compose.podman.yml` | `compose.podman.wss.yml` |
| 기본 호스트 포트 (Docker) | `80` | `80`(리다이렉트), `443` |
| 기본 호스트 포트 (Podman) | `18080` | `18080`(리다이렉트), `18443` |
| 인증서 | 불필요 | `certs/server.crt`, `certs/server.key` 필수 |

평문 `ws://`는 암호화되지 않습니다. 공개망에서는 WSS를 권장합니다. WS와 WSS는 같은
nginx 이미지(`docker.io/library/nginx:1.26-alpine`)를 쓰므로 이미지 묶음은 하나면
되고, 실행할 때 Compose 파일만 고릅니다.

## 4. 공통 설정값 (`dmz/.env`)

`.env.example`을 복사해 만듭니다.

| 변수 | 역할 | 넣는 값 |
|------|------|---------|
| `DMZ_SERVER_NAME` | 공개 주소. 모바일 앱이 접속하는 DMZ 호스트 이름 또는 IP | 프로토콜·경로·포트 없이. 예) `mqtt.example.com` |
| `INTERNAL_MQTT_UPSTREAM` | 내부 주소. DMZ 서버에서 닿는 TeamCloud 게이트웨이의 접속 주소 | `http://` 또는 `https://` + 호스트 + (기본 포트가 아니면) `:포트`. `/mqtt`를 붙이지 않음 |
| `DMZ_TLS_CERTIFICATE` | WSS 인증서의 컨테이너 안 경로 | 기본값 `/etc/nginx/certs/server.crt` 유지 권장 |
| `DMZ_TLS_CERTIFICATE_KEY` | WSS 개인키의 컨테이너 안 경로 | 기본값 `/etc/nginx/certs/server.key` 유지 권장 |
| `TARGET_PLATFORM` (선택) | 이미지 플랫폼. `.env.example`에는 없고 Compose 기본값은 `linux/amd64` | arm64 서버라면 `linux/arm64` 추가 |

`INTERNAL_MQTT_UPSTREAM` 주의:

- nginx `proxy_pass`에 그대로 들어가므로 `http://` 또는 `https://`만 씁니다.
  `ws://`, `wss://`를 넣으면 nginx 설정 검사(`nginx -t`)가 실패해 컨테이너가 뜨지
  않습니다. WebSocket 업그레이드는 nginx가 HTTP 위에서 처리합니다.
- 호스트 이름은 nginx 시작 시 프록시 컨테이너의 DNS 환경에서 해석됩니다. 호스트의
  curl이 성공해도 컨테이너가 같은 주소에 닿는다는 보장은 없습니다. 컨테이너에서 이름을
  해석하지 못하면 시작이 실패합니다(`host not found in upstream`).
- `https://`일 때 DMZ nginx는 내부 인증서를 검증하지 않습니다
  (`proxy_ssl_verify off`, 템플릿 주석: 내부 자체 서명 인증서 대비). SNI로는
  `INTERNAL_MQTT_UPSTREAM`의 호스트 이름을 보냅니다. Host 헤더는 모바일 앱이 보낸
  값(DMZ 주소)이 그대로 전달됩니다. 루트 게이트웨이 nginx에는 `server_name` 제한이
  없으므로 이 Host로도 `/mqtt`가 라우팅됩니다.

## 5. 예시: TeamCloud 설정과 DMZ 설정 맞추기

아래는 설정 예시입니다. 호스트 이름은 실제 환경에 맞게 바꿉니다. TeamCloud는 Docker 기본
포트(80/443)로, DMZ는 WSS로 운영한다고 가정합니다.

| 위치 | 변수 | 예시 값 | 누가 쓰는가 |
|------|------|---------|-------------|
| TeamCloud 서버 루트 `.env` | `EXTERNAL_URL` | `https://tc.internal.example` | 내부 사용자의 TeamCloud 접속 주소 |
| TeamCloud 서버 루트 `.env` | `BROKER_WS_URL` | `wss://tc.internal.example/mqtt` | 내부망에서 TeamCloud 게이트웨이로 직접 붙는 브로커 주소 |
| TeamCloud 서버 루트 `.env` | `PUBLIC_BROKER_WS_URL` | `wss://mqtt.example.com/mqtt` | 모바일 앱에 알려 줄 DMZ 주소 |
| DMZ 서버 `dmz/.env` | `DMZ_SERVER_NAME` | `mqtt.example.com` | DMZ 공개 이름 |
| DMZ 서버 `dmz/.env` | `INTERNAL_MQTT_UPSTREAM` | `https://tc.internal.example` | DMZ → TeamCloud 게이트웨이 |

두 브로커 URL은 이 저장소의 Compose에서 `tc-be` 환경 변수로 전달됩니다. 내부용·외부용
주소를 위와 같이 맞춘 뒤 실제 앱이 받은 접속 URL과 MQTT 송수신도 확인하세요. 앱의 URL
선택 로직 자체는 이 저장소에 포함되어 있지 않습니다.

규칙:

- `PUBLIC_BROKER_WS_URL` = DMZ 모드의 프로토콜(`ws`/`wss`) + `DMZ_SERVER_NAME` + (기본이
  아닌 경우) DMZ 호스트 포트 + `/mqtt`.
- `INTERNAL_MQTT_UPSTREAM` = `EXTERNAL_URL`과 같은 게이트웨이 접속 주소(경로 없이). DMZ 서버에서
  그 이름이 해석되지 않으면 DMZ에서 닿는 IP/이름과 게이트웨이 호스트 포트를 씁니다.
- TeamCloud를 Podman 기본값으로 띄웠다면 게이트웨이 호스트 포트는 `18080`(HTTP)/`18443`(HTTPS)
  이므로 예) `INTERNAL_MQTT_UPSTREAM=http://tc.internal.example:18080`.
- 루트 `.env`를 바꾸는 방법과 반영(재시작) 절차는 [../README.md](../README.md)를 따르세요.

### 포트별 역할

| 포트 | 위치 | 역할 | 외부 공개 |
|------|------|------|-----------|
| 브로커 `1883`(MQTT TCP), `8080`(WebSocket) | TeamCloud 서버 컨테이너 내부 | 브로커 listener (`broker/mosquitto.conf`) | 하지 않음 |
| 게이트웨이 호스트 포트 (Docker `80`/`443`, Podman `18080`/`18443`) | TeamCloud 서버 | 게이트웨이 nginx가 `/mqtt`를 `broker:8080`으로 전달 | 내부 사용자·DMZ 서버 등 승인된 경로만 허용 |
| DMZ 호스트 포트 (Docker `80`/`443`, Podman `18080`/`18443`) | DMZ 서버 | 모바일 앱의 진입점 | 모바일 앱에 공개 |

- TeamCloud 게이트웨이에 여러 호스트 포트를 같은 컨테이너 포트 80에 연결하는 것(예:
  `"80:80"`과 `"8081:80"`)은 Compose상 가능합니다. 하지만 어떤 포트에서 `/health`가
  `200`이어도 MQTT 연결까지 확인된 것은 아닙니다. `/health`는 게이트웨이 nginx가
  직접 응답할 뿐입니다.
- DMZ와 TeamCloud를 같은 호스트에 둘 경우 기본 포트가 겹칩니다(Docker 80/443,
  Podman 18080/18443). 이 경우 DMZ Compose의 `ports`를 다른 값으로 바꿔야 합니다.

### 방화벽 방향

- 모바일 앱 → DMZ 서버 DMZ 호스트 포트
- DMZ 서버 → TeamCloud 서버 게이트웨이 호스트 포트 (`INTERNAL_MQTT_UPSTREAM`의 포트)
- 브로커 `1883`/`8080`, DB `5432`는 외부에 열지 않습니다.

## 6. 진단 결과 읽는 법

명령은 각 런타임 가이드의 "진단" 절에 있습니다. 순서대로 확인합니다.

1. 클라이언트 쪽 → DMZ `/health`
2. DMZ 서버 → 내부 TeamCloud 서버 `/health`
3. DMZ `/mqtt`에 WebSocket 업그레이드 요청(`Sec-WebSocket-Protocol: mqtt`)

| 3단계 결과 | 의미 |
|------------|------|
| `HTTP/1.1 101 Switching Protocols` 후 curl 종료 코드 `28` | WebSocket 업그레이드 성공. 열린 세션이 시간 제한으로 끝난 것. MQTT 인증·메시지 송수신은 별도 확인 |
| curl 종료 코드 `28`, 응답 0바이트 | 실패. 핸드셰이크 자체가 안 됨(방화벽·경로·포트) |
| `502 Bad Gateway` | DMZ nginx가 내부 TeamCloud 서버에 연결하지 못함(주소·포트·방화벽·프로토콜) |
| `404` | 경로 오타, 다른 서비스에 도달했거나 내부 TeamCloud 서버의 404. DMZ와 내부 서버에 직접 요청해 구간을 나눔 |
| `301` | WSS 모드에서 80(또는 18080) 포트로 접속함 |
| `400` 등 4xx | 요청 헤더 문제. 내부 TeamCloud 서버에 직접 같은 요청을 보내 DMZ 문제인지 구분 |

## 7. 문제 해결 원칙

- 먼저 읽기 전용으로 확인합니다: WebSocket 엔드포인트, 인증서, Compose 로그,
  컨테이너 안의 렌더링된 `nginx.conf`.
- 진단 중에 호스트 설정(DNS resolver, `/etc/hosts`, sysctl, 방화벽 규칙)을 바꾸지 말고,
  컨테이너·이미지·볼륨을 지우거나 일괄 재시작/kill 하지 마세요. 원인이 호스트·네트워크
  쪽이면 관리자에게 요청합니다.
- TLS 검증을 끄는 옵션(`curl -k` 등)을 정상 확인 절차로 쓰지 마세요. 사설 CA라면
  `--cacert`로 CA 파일을 지정합니다.
- `down -v`, `system prune`, `volume rm` 같은 삭제 명령은 이 절차에 없습니다.

## 8. 파일 구성

```text
dmz/
  .env.example               # 설정 예시 (복사해서 .env 작성)
  compose.docker.yml         # Docker, WS
  compose.docker.wss.yml     # Docker, WSS
  compose.podman.yml         # Podman, WS (SELinux :z 마운트)
  compose.podman.wss.yml     # Podman, WSS (SELinux :z 마운트)
  nginx/nginx.ws.conf.template
  nginx/nginx.wss.conf.template
  certs/                     # WSS 인증서를 두는 곳 (server.crt, server.key)
  scripts/export-compose-images-{docker,podman}.sh   # 온라인 PC: 이미지 묶음 생성
  scripts/load-compose-images-{docker,podman}.sh     # 폐쇄망 DMZ 서버: 이미지 적재
```

설치 후에는 위 진단 순서에 따라 연결을 확인하고 실제 앱에서 MQTT 메시지를 주고받아 보세요.
