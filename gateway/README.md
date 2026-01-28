# gw-stack (Nginx GW + Certbot DNS-01 + Renewer)

이 리포는 **단일 Nginx GW 컨테이너**에서 다음을 통합 운영합니다.

- **HTTP(80) / HTTPS(443)** Reverse Proxy (SPA/API/웹서버)
- **WS / WSS** (WebSocket)
- **Stream(TCP)** Proxy (예: MQTT 1883, MQTTS 8883, SSH 2222 등)
- **Let’s Encrypt + Route53 DNS-01** 인증서 발급/갱신 자동화
- 인증서 갱신 시 **Nginx reload/restart 자동화**

> 핵심 설계 목표:  
> - 인증서가 발급되기 전에도 **GW가 죽지 않고**(최소 80 응답/차단) 떠 있어야 함  
> - Stream(TCP)도 운영 가능하되, 설정 오류/의존 서비스 DNS 문제로 **nginx 전체가 죽지 않게** 운영 가이드를 제공

---

## 0) 빠른 시작

### 0.1 준비물
- Docker / Docker Compose
- Route53 Hosted Zone (DNS 관리가 Route53에 있어야 DNS-01이 가능)
- EC2 보안그룹(Security Group)에서 필요한 포트 Inbound 허용

### 0.2 실행
```bash
docker compose up -d
docker logs -f gw-certbot
docker logs -f gw-nginx
````

### 0.3 정상 상태 확인

```bash
# certbot READY 마커 확인
docker exec gw-nginx ls -l /etc/letsencrypt/.gw-certbot-ready /etc/letsencrypt/.gw-cert-state

# nginx 설정 테스트
docker exec gw-nginx nginx -t

# 전체 설정 덤프(디버깅)
docker exec gw-nginx nginx -T | sed -n '1,160p'
```

---

## 0.4 .env 포맷(템플릿)

> 이 스택은 **nginx / certbot / renewer**가 같은 `.env`를 공유합니다.
> 즉, 인증서(LE) 발급/갱신 설정과 GW 정책(HTTP_STRICT 등)을 한 곳에서 관리합니다.

```dotenv
# ============================================================
# [필수] 인증서 이름 (letsencrypt live 디렉토리명)
# 예) /etc/letsencrypt/live/<CERT_NAME>/
# ============================================================
CERT_NAME=edencrew-wildcard

# ============================================================
# [필수] Let's Encrypt 계정용 이메일
# ============================================================
LE_EMAIL=ops@edencrew.io

# ============================================================
# [선택 - 권장(운영 안정)] 인증서 발급 도메인 명시
# - 명시하면 services conf 파싱에 의존하지 않아서 안정적
# - 여러 개면 콤마로 구분
# ============================================================
LE_DOMAINS=*.edencrew.io,*.dev.edencrew.io

# ============================================================
# [선택] LE_DOMAINS를 비우고 자동 파생을 쓰는 경우 보강용
# - stream은 server_name이 없으니 여기로 보강 가능
# ============================================================
# LE_EXTRA_DOMAINS=tunnel.dev.edencrew.io,git.dev.edencrew.io

# ============================================================
# [필수] Route53 DNS-01용 AWS Region
# ============================================================
AWS_REGION=ap-northeast-2
AWS_DEFAULT_REGION=ap-northeast-2

# ============================================================
# [선택] DNS 전파 대기 시간(초)
# - certbot 옵션 지원 여부에 따라 자동 감지해서 넣음
# ============================================================
DNS_PROPAGATION_SECONDS=60

# ============================================================
# [선택] cert 유효기간 임박 기준(일)
# - 이 값 이하로 남으면 재발급/갱신을 강제
# ============================================================
MIN_VALID_DAYS=10

# ============================================================
# [선택] 초기 발급 실패 시 재시도 간격(초)
# ============================================================
BOOTSTRAP_RETRY=60

# ============================================================
# [선택] 갱신 루프 주기
# - renewer 컨테이너의 sleep 주기
# ============================================================
RENEW_INTERVAL=12h

# ============================================================
# [선택] HTTP(80) 정책
# - true  : 80은 무조건 444(완전 차단)
# - false : 80은 443으로 redirect (기본)
# ============================================================
HTTP_STRICT=false

# ============================================================
# [선택] 인증서 준비 전(READY 없음) 80 처리 정책
# - 503 : 안내 메시지(기본)
# - 444 : 완전 차단
# ============================================================
CERT_PENDING_HTTP=503

# ============================================================
# [선택] upstream에서 host.docker.internal을 사용할 때만
# - nginx 서비스에 extra_hosts를 켜고 이 값으로 upstream 구성
# ============================================================
# GITEA_UPSTREAM=host.docker.internal:3000
```

### .env 운영 팁

* 운영에서는 `LE_DOMAINS`를 **명시**하는 편이 가장 안전합니다.
  (services/services-http 파싱 결과가 바뀌어 인증서 도메인이 의도치 않게 변하는 문제 예방)
* stream-only 서비스(SSH/MQTT)는 `server_name`이 없으므로, 도메인이 “인증서에 꼭 들어가야 하는” 경우만 `LE_EXTRA_DOMAINS`로 추가하세요.

---

## 1) 구성 요소(서비스)

### 1.1 gw-nginx

* 80/443: HTTP/HTTPS Reverse Proxy
* stream: TCP Proxy (1883/8883/2222 등)
* 인증서 준비 상태에 따라 동적으로 설정이 바뀜

  * READY 없으면 443 서비스 설정을 최소화하고(또는 pending 메시지), 80은 기본 정책으로 처리

### 1.2 gw-certbot (certbot/dns-route53)

* Route53 DNS-01로 인증서 발급/갱신
* 도메인 목록은 아래 규칙으로 결정:

  1. `.env`의 `LE_DOMAINS`가 있으면 그 값을 사용(명시)
  2. 없으면 `nginx-conf/services` + `nginx-conf/services-http`의 `server_name`을 파싱하여 자동 생성
  3. 추가 도메인이 더 필요하면 `.env`의 `LE_EXTRA_DOMAINS`로 보강
* READY 마커(`/etc/letsencrypt/.gw-certbot-ready`)를 생성해 nginx가 443/stream tls를 활성화할 수 있게 함

### 1.3 gw-renewer (docker cli)

* 주기적으로 `certbot renew` 수행
* 인증서 파일 hash가 변하면 nginx reload(실패 시 restart)

---

## 2) 디렉토리 구조

```
.
├─ docker-compose.yaml
├─ .env
├─ gw-data/
│  ├─ letsencrypt/        # certbot state + live certs + READY/STATE 파일
│  └─ nginx/              # nginx 로그 디렉토리
└─ nginx-conf/
   ├─ services/           # HTTPS 서비스 conf (server { listen 443 ssl; ... })
   ├─ services-http/      # HTTP 예외/화이트리스트 conf (server { listen 80; ... })
   └─ stream-src/
      ├─ always/          # 항상 로드할 stream(TCP) conf
      └─ tls/             # 인증서 READY일 때만 로드할 stream(TCP+TLS terminate) conf
```

---

## 3) Nginx 로딩/생성 규칙 (중요)

gw-nginx는 entrypoint에서 다음을 수행합니다.

### 3.1 메인 nginx.conf 생성

* `/etc/nginx/nginx.conf`를 직접 생성

  * `http { ... include /etc/nginx/conf.d/*.conf; }`
  * `stream { ... include /etc/nginx/stream.d/*.conf; }`

### 3.2 공통 include 파일 생성 (http) — 상세

gw-nginx는 `/etc/nginx/conf.d/` 아래에 “공통 include 파일”들을 런타임에 생성합니다.
목적은 다음 3가지입니다.

1. 서비스 conf를 최대한 얇게(도메인/경로/upstream만) 유지
2. 모든 서비스에 공통 정책(헤더/타임아웃/WS)을 일관되게 적용
3. 운영/장애 분석 시 “모든 서비스가 같은 룰”을 따른다는 전제가 생김

아래 include들은 `nginx-conf/services/*.conf` 또는 `nginx-conf/services-http/*.conf`에서 `include`로 끌어다 씁니다.

---

#### 3.2.1 `/etc/nginx/conf.d/00_maps.conf` : WS 업그레이드 map

**역할**

* WebSocket 프록시에서 필수인 `Connection: upgrade` 처리를 안정화합니다.
* `Upgrade` 헤더가 있을 때만 `Connection=upgrade`, 없으면 `close`로 처리합니다.

**핵심 개념**

```nginx
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
```

**왜 필요한가**

* WS는 HTTP/1.1 업그레이드 프로토콜이라 `Upgrade`/`Connection` 헤더가 필수입니다.
* 하지만 모든 요청이 WS가 아니므로, 업그레이드가 없는 요청에까지 `Connection: upgrade`를 강제하면 이상 동작/혼동이 생길 수 있습니다.
* map으로 “있을 때만 upgrade” 하도록 강제하면 안전합니다.

---

#### 3.2.2 `/etc/nginx/conf.d/05_resolver.conf` : Docker DNS resolver

**역할**

* Docker 네트워크에서 서비스 이름(`teamcloud-api`, `teamcloud-network-gitea` 등)을 DNS로 해석하도록 resolver를 지정합니다.

**핵심 개념**

```nginx
resolver 127.0.0.11 ipv6=off valid=10s;
```

**왜 필요한가**

* 컨테이너는 재기동/교체로 IP가 바뀌기 때문에 이름 기반 해석이 필수입니다.
* 특히 stream은 DNS 해석 실패가 `nginx -t` 실패로 이어져 GW 전체가 죽을 수 있으므로(템플릿 가이드를 반드시 따르기), resolver 지정은 기본 안정장치입니다.

---

#### 3.2.3 `/etc/nginx/conf.d/10_proxy_headers.inc` : 공통 proxy headers

**역할**

* upstream이 “원 요청 정보(Host/원 IP/프로토콜)”를 알 수 있게 표준 헤더를 세팅합니다.
* WS 업그레이드 헤더도 함께 처리합니다.

**포함되는 헤더**

* 표준 프록시:

  * `Host`
  * `X-Real-IP`
  * `X-Forwarded-For`
  * `X-Forwarded-Proto`
  * `X-Forwarded-Host`
  * `X-Forwarded-Port`
* WebSocket:

  * `Upgrade`
  * `Connection` (00_maps.conf로 만든 `$connection_upgrade` 사용)
* `proxy_http_version 1.1` (WS 포함)

**왜 필요한가**

* upstream이 TLS 종료 지점을 모르면 리다이렉트/URL 생성/로그가 깨지기 쉽습니다.
* 사용자 원 IP가 필요할 때가 많고(보안/감사/레이트리밋), `X-Forwarded-*`는 사실상 표준입니다.

---

#### 3.2.4 `/etc/nginx/conf.d/11_proxy_timeouts.inc` : 일반 HTTP timeout

**역할**

* 일반 HTTP reverse proxy에 대한 타임아웃을 통일합니다.

**기본 값**

* `proxy_connect_timeout 10s;`
* `proxy_send_timeout 60s;`
* `proxy_read_timeout 60s;`

**왜 필요한가**

* 서비스마다 기본값이 섞이면 “어느 레이어에서 끊기는지” 분석이 어려워집니다.
* 공통값을 두면 장애 분석/튜닝이 쉬워집니다.

---

#### 3.2.5 `/etc/nginx/conf.d/12_proxy_timeouts_ws.inc` : WS timeout

**역할**

* WebSocket/SSE 같이 “롱 커넥션”을 위한 타임아웃을 제공합니다.

**기본 값**

* `proxy_connect_timeout 10s;`
* `proxy_send_timeout 1h;`
* `proxy_read_timeout 1h;`

**왜 필요한가**

* WS에 일반 HTTP timeout(60s)을 쓰면 “유휴 상태에서 주기적으로 끊김” 문제가 자주 발생합니다.
* 반대로 무제한은 장애 시 정리가 안 되므로, 운영 친화적인 긴 값(예: 1h)을 둡니다.

---

#### 3.2.6 `/etc/nginx/conf.d/30_policy_http_proxy.inc` : 일반 reverse proxy 정책

**역할**

* 일반 HTTP reverse proxy에 필요한 공통 설정을 “한 번에 적용”하는 묶음입니다.

**구성**

* `include 10_proxy_headers.inc;`
* `include 11_proxy_timeouts.inc;`
* `proxy_buffering off;`

**왜 proxy_buffering off인가**

* GW 성격상 “실시간 응답/스트리밍/긴 요청”과 섞여 운영될 가능성이 큽니다.
* buffering은 때때로 지연/메모리 사용/예상치 못한 체감을 만들 수 있어, 기본은 off로 두고 필요한 서비스만 별도로 override 하는 방식이 안전합니다.

**사용 예**

```nginx
location / {
  include /etc/nginx/conf.d/30_policy_http_proxy.inc;
  proxy_pass http://teamcloud-api:8080;
}
```

---

#### 3.2.7 `/etc/nginx/conf.d/31_policy_http_ws_proxy.inc` : websocket reverse proxy 정책

**역할**

* WebSocket reverse proxy에 필요한 공통 설정을 “한 번에 적용”하는 묶음입니다.

**구성**

* `include 10_proxy_headers.inc;`
* `include 12_proxy_timeouts_ws.inc;`
* `proxy_buffering off;`

**사용 예**

```nginx
location /ws/ {
  include /etc/nginx/conf.d/31_policy_http_ws_proxy.inc;
  proxy_pass http://teamcloud-ws:3001;
}
```

---

### 3.3 Stream enable 규칙 (stream-src → stream.d)

* `nginx-conf/stream-src/always/*.conf` → `/etc/nginx/stream.d/*.conf` 복사
* 인증서 준비(READY + cert/key 존재) 시:

  * `/etc/nginx/stream.d/20_tls_stream.inc` 생성
  * `nginx-conf/stream-src/tls/*.conf` → `/etc/nginx/stream.d/*.conf` 복사

### 3.4 HTTP/HTTPS policy: READY 기반

* READY 없으면:

  * 80: 기본 정책(503 안내 또는 444 차단) + `services-http` 예외만 포함
  * 443: 서비스 활성화 전(기본 server 최소)
* READY 있으면:

  * 80: redirect 또는 444 차단(환경변수로 선택)
  * 443: `services/*.conf` 로드 + TLS include 활성화

---

## 4) 현재 오픈 포트 / 프로토콜

| Port | 프로토콜    | 사용 용도                                    |
| ---- | ------- | ---------------------------------------- |
| 80   | HTTP    | 기본 정책(redirect/차단), 예외 허용은 services-http |
| 443  | HTTPS   | 서비스 Reverse Proxy (WSS 포함)               |
| 1883 | TCP     | MQTT (stream)                            |
| 8883 | TCP+TLS | MQTTS (stream + TLS terminate)           |
| 2222 | TCP     | SSH (Gitea 등) stream proxy               |

> 주의: Docker publish(ports) + AWS Security Group Inbound가 둘 다 열려야 외부에서 접근됩니다.

---

## 5) nginx-conf 정의 규칙 (파일 배치 기준)

### 5.1 `nginx-conf/services/` (HTTPS 443)

* 각 파일은 보통 아래 형태를 권장:

  * `server { listen 443 ssl; server_name ...; include 20_tls_server.inc; location ... proxy_pass ... }`
* 여기에 선언된 `server_name`은 certbot이 도메인 자동 파생에 사용될 수 있음

### 5.2 `nginx-conf/services-http/` (HTTP 80 예외/화이트리스트)

* 기본 정책이 redirect/차단이므로 **정말 필요한 것만** 80에서 허용
* 예: health check, 특정 서비스의 plain http, 인증서 발급 전 필요한 경로 등

### 5.3 `nginx-conf/stream-src/always/` (Stream TCP 항상 로드)

* 1883 MQTT, 2222 SSH 같은 “항상 열려야 하는 TCP 포트”
* **권장**: Stream은 설정 실수로 nginx 전체가 죽기 쉬우므로 아래 템플릿을 따를 것

### 5.4 `nginx-conf/stream-src/tls/` (Stream TCP+TLS terminate)

* 8883 같이 “TCP 레벨에서 TLS terminate 후 upstream은 plain TCP” 인 케이스
* 반드시 `include /etc/nginx/stream.d/20_tls_stream.inc;` 사용

---

## 6) 신규 서비스 추가 가이드 (템플릿 포함)

아래는 “새 서비스를 추가할 때” 유형별로 어디에 어떤 파일을 만들고, 어떤 설정을 추가해야 하는지 정리한 템플릿입니다.

### 6.0 공통 체크리스트

* [ ] 대상 서비스 컨테이너가 gw-nginx와 **같은 Docker network**에서 이름 해석 가능해야 함 (`tc-transit` 권장)
* [ ] 도메인 추가 시 인증서에 포함되어야 함

  * HTTPS는 services/services-http의 `server_name`으로 자동 파생 가능
  * Stream-only는 server_name이 없으므로 `LE_EXTRA_DOMAINS` 또는 `LE_DOMAINS`로 보강
* [ ] Stream 포트 추가 시

  * [ ] `docker-compose.yaml`의 `ports:`에 publish 추가
  * [ ] AWS SG Inbound 오픈
  * [ ] `nginx-conf/stream-src/*`에 conf 추가

---

## 6.1 HTTPS (일반 Reverse Proxy)

**파일 위치**

* `nginx-conf/services/10_app_https.conf`

**템플릿**

```nginx
server {
  listen 443 ssl;
  server_name app.dev.edencrew.io;

  include /etc/nginx/conf.d/20_tls_server.inc;

  location / {
    include /etc/nginx/conf.d/30_policy_http_proxy.inc;
    proxy_pass http://teamcloud-app:8080;
  }
}
```

---

## 6.2 HTTPS + WSS (WebSocket)

WSS는 443에서 path 기반으로 처리합니다.

**파일 위치**

* `nginx-conf/services/20_ws_https.conf`

**템플릿**

```nginx
server {
  listen 443 ssl;
  server_name ws.dev.edencrew.io;

  include /etc/nginx/conf.d/20_tls_server.inc;

  location /api/ {
    include /etc/nginx/conf.d/30_policy_http_proxy.inc;
    proxy_pass http://teamcloud-api:8080;
  }

  location /ws/ {
    include /etc/nginx/conf.d/31_policy_http_ws_proxy.inc;
    proxy_pass http://teamcloud-ws:3001;
  }
}
```

---

## 6.3 HTTP (80) 예외 허용 (권장: 최소화)

**파일 위치**

* `nginx-conf/services-http/10_http_whitelist.conf`

**템플릿**

```nginx
server {
  listen 80;
  server_name plain.dev.edencrew.io;

  location / {
    include /etc/nginx/conf.d/30_policy_http_proxy.inc;
    proxy_pass http://teamcloud-plain:8080;
  }
}
```

---

## 6.4 WS (80 WebSocket) - 비권장(운영은 WSS 권장)

**파일 위치**

* `nginx-conf/services-http/20_ws_plain.conf`

**템플릿**

```nginx
server {
  listen 80;
  server_name ws-plain.dev.edencrew.io;

  location /ws/ {
    include /etc/nginx/conf.d/31_policy_http_ws_proxy.inc;
    proxy_pass http://teamcloud-ws:3001;
  }
}
```

---

## 6.5 Stream TCP (예: MQTT 1883)

**파일 위치**

* `nginx-conf/stream-src/always/42_mqtt_1883.conf`

**권장 템플릿(변수 기반: 런타임 해석)**

```nginx
server {
  listen 1883;

  # 런타임 해석을 위해 변수 기반 proxy_pass 사용
  # (업스트림 이름이 startup 시점에 DNS 해석 실패하면 nginx가 죽을 수 있음)
  set $upstream teamcloud-network-mqtt:1883;
  proxy_pass $upstream;

  proxy_connect_timeout 10s;
  proxy_timeout 1h;
}
```

---

## 6.6 Stream TCP + TLS Terminate (예: MQTTS 8883)

**파일 위치**

* `nginx-conf/stream-src/tls/43_mqtt_8883_tls.conf`

**템플릿**

```nginx
server {
  listen 8883 ssl;

  # cert READY일 때 gw-nginx가 생성해줌
  include /etc/nginx/stream.d/20_tls_stream.inc;

  set $upstream teamcloud-network-mqtt:1883;
  proxy_pass $upstream;

  proxy_connect_timeout 10s;
  proxy_timeout 1h;
}
```

---

## 6.7 Stream SSH (예: Gitea SSH 2222)

**파일 위치**

* `nginx-conf/stream-src/always/11_gitea_ssh_2222.conf`

**템플릿**

```nginx
server {
  listen 2222;

  set $upstream teamcloud-network-gitea:22;
  proxy_pass $upstream;

  proxy_connect_timeout 10s;
  proxy_timeout 1h;
}
```

### 6.7.1 (중요) SSH는 도메인(server_name)으로 분기 불가

* `git.dev.edencrew.io:2222` 와 `tunnel.dev.edencrew.io:2222`를 “같은 포트(2222)에서 도메인으로” 라우팅하는 것은 불가능합니다.
* 대신 아래 중 하나로 해결해야 합니다.

#### 옵션 A) 포트를 분리

* `git.dev:2222` (Gitea)
* `tunnel.dev:2223` (Tunnel/SSHD)

가장 단순하고 확실합니다.

#### 옵션 B) IP를 분리(EIP 2개) + `$server_addr`로 분기

* `git.dev.edencrew.io`는 EIP-A로
* `tunnel.dev.edencrew.io`는 EIP-B로
* Nginx는 목적지 IP(`$server_addr`)를 보고 upstream을 선택

예시:

```nginx
map $server_addr $ssh_upstream {
  default       teamcloud-network-gitea:22;
  10.0.1.10     teamcloud-network-gitea:22;    # git.dev가 가리키는 내부 IP
  10.0.1.11     teamcloud-tunnel-sshd:22;      # tunnel.dev가 가리키는 내부 IP
}

server {
  listen 2222;
  proxy_pass $ssh_upstream;
  proxy_connect_timeout 10s;
  proxy_timeout 1h;
}
```

---

## 7) 인증서 도메인 구성 규칙

### 7.1 `.env`에서 명시하는 경우 (권장: 운영 안정)

* `LE_DOMAINS=*.edencrew.io,*.dev.edencrew.io` 처럼 명시하면 가장 확실합니다.

### 7.2 자동 파생(services/services-http의 server_name)

* `.env`에 `LE_DOMAINS`가 없을 때:

  * `nginx-conf/services/*` + `nginx-conf/services-http/*`를 grep/awk로 파싱해 도메인 목록을 구성합니다.

### 7.3 Stream-only 도메인

* stream은 `server_name`이 없으므로 자동 파생이 안 됩니다.
* 필요하면 `.env`에 `LE_EXTRA_DOMAINS=...`로 추가하세요.

---

## 8) 운영 점검 / 트러블슈팅

### 8.1 인증서 READY 확인

```bash
docker exec gw-nginx ls -l /etc/letsencrypt/.gw-certbot-ready
docker exec gw-nginx cat /etc/letsencrypt/.gw-cert-state || true
```

### 8.2 Nginx 설정 전체 확인

```bash
docker exec gw-nginx nginx -T > /tmp/nginx-T.txt
sed -n '1,200p' /tmp/nginx-T.txt
```

### 8.3 자주 발생하는 문제

#### (A) `host not found in upstream "...:22"`로 컨테이너가 죽음

원인:

* stream에서 upstream 호스트를 startup 시점에 해석하려다 실패하면 `nginx -t`가 실패하고 컨테이너가 종료될 수 있습니다.

해결:

* stream conf를 **변수 기반**으로 작성하세요.

  * `set $upstream name:port; proxy_pass $upstream;`

#### (B) 인증서 발급이 안 됨

* Route53 권한(IAM) 확인
* `docker logs gw-certbot` 확인
* `.env`의 `AWS_REGION`, `AWS_DEFAULT_REGION`, `LE_EMAIL`, `CERT_NAME` 확인
