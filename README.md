# Lucy TeamCloud On-Premise 설치 가이드

## 사전 요구사항

- Docker 20.10 이상 + Docker Compose v2.20 이상
- 또는 Podman 5.0 이상 + podman-compose 1.5 이상
- 최소 2GB RAM, 10GB 디스크 공간

## 1. 환경 설정

### 1.1 .env 파일 생성

`.env.example` 파일을 복사하여 `.env` 파일을 생성합니다.

```bash
cp .env.example .env
```

### 1.2 .env 파일 편집

```bash
# 외부에서 서비스에 접근할 때 사용하는 주소
# 프로토콜(http:// 또는 https://)을 반드시 포함하세요.
EXTERNAL_URL=https://your-domain.com

# MQTT 브로커 WebSocket 접속 주소 (브라우저가 브로커에 연결할 때 사용)
# 기본값은 EXTERNAL_URL 에 /mqtt 를 붙인 형태이며, nginx 의 /mqtt/ 리버스 프록시를 경유합니다.
# 별도 도메인/포트로 브로커를 노출하는 경우에만 변경하세요.
# EXTERNAL_URL 이 https 면 wss://, http 면 ws:// 를 사용해야 합니다.
BROKER_WS_URL=wss://your-domain.com/mqtt

# Lucy 서비스 관리자 계정
LUCY_ADMIN_EMAIL=admin@your-company.com
LUCY_ADMIN_PASSWORD=your-secure-password
LUCY_ADMIN_NAME=admin  # 변경 불가

# 데이터베이스 비밀번호
DB_ROOT_PASSWORD=your-db-root-password
DB_USERNAME=lucy
DB_PASSWORD=your-db-password

# 타임존
TZ=Asia/Seoul
```

### 1.3 주의사항

| 항목 | 주의사항 |
|------|----------|
| `EXTERNAL_URL` | `localhost`, `127.0.0.1` 사용 불가. 반드시 외부에서 접근 가능한 주소 입력 |
| `BROKER_WS_URL` | `EXTERNAL_URL` 의 스킴과 짝을 맞출 것 (`https` → `wss://`, `http` → `ws://`). 기본 경로는 `/mqtt` |
| `LUCY_ADMIN_NAME` | `admin`으로 고정, 변경하지 마세요 |
| 비밀번호 | 특수문자 포함 시 따옴표로 감싸세요 (예: `DB_PASSWORD="P@ss!word"`) |
| Linux 환경 | `HOST_UID`, `HOST_GID`를 `id` 명령어로 확인 후 설정 |

### 1.4 계정 정보 변경 불가 안내

> **중요: 아래 항목들은 최초 실행 시에만 적용됩니다. 서비스 실행 후에는 .env 파일을 수정해도 반영되지 않습니다.**

| 항목 | 최초 실행 후 변경 시 |
|------|---------------------|
| `LUCY_ADMIN_EMAIL` | 기존 관리자 계정과 불일치, 로그인 불가 |
| `LUCY_ADMIN_PASSWORD` | 기존 관리자 계정과 불일치, 로그인 불가 |
| `DB_USERNAME` | 데이터베이스 연결 실패, 서비스 중단 |
| `DB_PASSWORD` | 데이터베이스 연결 실패, 서비스 중단 |
| `DB_ROOT_PASSWORD` | PostgreSQL 접근 불가 |

**복구 방법이 없습니다.** 계정 정보를 분실하거나 변경한 경우:

1. 모든 데이터 삭제 후 재설치
   ```bash
   docker compose down -v
   rm -rf postgres/data git/data secrets/secrets.env
   # .env 파일 재설정 후
   docker compose up -d
   ```

2. 또는 백업본에서 복원

**권장:** 최초 설정 시 `.env` 파일을 안전한 곳에 백업해두세요.

## 2. 라이센스 파일 배치

발급받은 라이센스 파일을 `license/license.json` 경로에 배치합니다.

```bash
cp /path/to/your/license.json license/license.json
```

> **중요:** 라이센스 파일이 없으면 `tc-be` 가 시작 시 검증에 실패하여 즉시 종료됩니다.
> 라이센스 발급/갱신 문의는 support@edencrew.com 으로 연락하세요.

라이센스 갱신 시에는 파일 교체 후 `docker compose restart tc-be` 로 재시작합니다.

## 3. SSL 인증서 설정

별도 작업 없이 첫 부팅 시 `init-secrets` 가 `.env` 의 `EXTERNAL_URL` 도메인으로
self-signed 인증서를 자동 발급해 `nginx/certs/server.{crt,key}` 에 둡니다.
브라우저에서는 자체 서명 경고가 뜨지만 BE-to-BE HTTPS 호출은 정상 동작합니다.

**운영 환경에서는 실제 인증서로 교체하세요:**

```bash
# 자동 발급된 인증서를 덮어쓰기
cp /path/to/your/certificate.crt nginx/certs/server.crt
cp /path/to/your/private.key nginx/certs/server.key

# 적용
docker compose restart gw
```

`init-secrets` 는 파일이 이미 있으면 건드리지 않으므로 (idempotent) 정식 인증서는
보존됩니다.

> **`EXTERNAL_URL` 도메인을 변경한 경우**: 기존 self-signed 인증서가 새 도메인과
> 매칭되지 않아 BE-to-BE 호출이 실패합니다. 다음 두 파일을 삭제 후 재기동하세요.
> ```bash
> rm nginx/certs/server.crt nginx/certs/server.key
> docker compose up -d
> ```

## 4. 서비스 실행

### 4.1 최초 실행

```bash
docker compose up -d
```

### 4.2 로그 확인

```bash
# 전체 로그
docker compose logs -f

# 특정 서비스 로그
docker compose logs -f tc-be
```

### 4.3 서비스 상태 확인

```bash
docker compose ps
```

> `init-secrets` 컨테이너는 첫 부팅 시 인스턴스별 시크릿(`secrets/secrets.env`)을 생성하고 종료되는 일회성 컨테이너입니다. 목록에 `Exited (0)` 상태로 남아 있는 것은 정상이며, 리소스를 점유하지 않습니다.

### 4.4 DMZ 모바일 MQTT 프록시

외부 모바일 디바이스가 폐쇄망 내부 broker에 직접 접근할 수 없는 경우,
`dmz/` standalone compose를 DMZ 서버에 배포해 MQTT-over-WebSocket만 프록시할 수 있습니다.

```text
Mobile App
  -> wss://<dmz-domain>/mqtt
  -> 또는 ws://<dmz-ip>/mqtt
  -> DMZ nginx
  -> https://<internal-teamcloud>/mqtt
  -> internal broker
```

DMZ 서버에서:

```bash
cd dmz
cp .env.example .env
```

`dmz/.env`에서 외부 도메인과 내부 TeamCloud nginx origin을 설정합니다.
`INTERNAL_MQTT_UPSTREAM`은 DMZ 서버에서 접근 가능해야 하며, `/mqtt` path를 붙이지
않습니다.

```env
DMZ_SERVER_NAME=mqtt.company.com
DMZ_ENABLE_TLS=1
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

DMZ 공개 TLS 인증서를 배치합니다.

```text
dmz/certs/server.crt
dmz/certs/server.key
```

도메인/인증서 없이 IP와 plain WebSocket만 사용할 경우에는 다음처럼 설정합니다.

```env
DMZ_SERVER_NAME=203.0.113.10
DMZ_ENABLE_TLS=0
INTERNAL_MQTT_UPSTREAM=https://10.0.0.10
```

이 경우 모바일 접속 주소는 다음과 같습니다.

```text
ws://203.0.113.10/mqtt
```

WSS 모드로 프록시를 실행합니다.

```bash
docker compose --env-file .env up -d
```

plain WS/IP 모드로 실행할 때는 443을 열지 않는 override 파일을 함께 사용합니다.

```bash
docker compose -f docker-compose.yml -f docker-compose.ws.yml --env-file .env up -d
```

`dmz/scripts/` 아래 운영 스크립트는 parent on-prem `scripts/`에 의존하지 않는
standalone 스크립트입니다. DMZ 서버에서는 다음 흐름을 사용할 수 있습니다.

```bash
cd dmz
./scripts/download-compose-images.sh      # 인터넷 가능 환경에서 dmz/images 생성
./scripts/load-images-and-up.sh           # 폐쇄망 DMZ 서버에서 load 후 실행
./scripts/restart-after-env-change.sh     # dmz/.env 변경 후 재생성
```

이 스크립트들은 `DMZ_ENABLE_TLS=0`이면 `docker-compose.ws.yml`을 자동 포함합니다.

모바일 앱이나 API가 broker URL을 내부 설정에서 받아간다면 내부 on-prem `.env`의
`BROKER_WS_URL`을 DMZ 주소로 설정합니다.

```env
BROKER_WS_URL=wss://mqtt.company.com/mqtt
```

plain WS/IP 모드:

```env
BROKER_WS_URL=ws://203.0.113.10/mqtt
```

방화벽은 WSS 모드에서는 외부에서 DMZ `443`만 열고, plain WS 모드에서는 DMZ `80`만
엽니다. DMZ에서 내부 TeamCloud nginx `443`만 접근하게 제한하세요. 내부 broker의
`1883`, `8080`, `8081`, `8888`은 인터넷에 직접 노출하지 않습니다.

> **보안 주의:** DMZ proxy는 인증/ACL을 추가하지 않습니다. 현재 broker 이미지는
> anonymous 접속을 허용하므로, 운영 환경에서 외부 모바일을 받기 전 broker 인증과
> topic ACL 강화가 별도로 필요합니다. `ws://` plain 모드는 TLS 없이 통신하므로 공개
> 운영망이 아니라 통제된 사설망 또는 임시 검증 용도로만 사용하세요.

## 5. 서비스 종료

```bash
docker compose down
```

데이터는 로컬 디렉토리(`postgres/data/`, `git/data/`)에 보존됩니다.

## 6. 업데이트 및 재실행

### 6.1 이미지 업데이트

```bash
# 최신 이미지 가져오기
docker compose pull

# 서비스 재시작
docker compose up -d
```

### 6.2 설정 변경 후 재시작

`.env` 파일이나 설정 파일 변경 후:

```bash
docker compose up -d
```

## 7. 데이터 저장 위치 (볼륨 마운트)

| 경로 | 설명 | 백업 권장 |
|------|------|----------|
| `./postgres/data/` | 데이터베이스 | **필수** |
| `./git/data/` | Git 저장소 데이터 | **필수** |
| `./secrets/secrets.env` | 인스턴스별 자동 생성 시크릿 (JWT 키, OIDC, Gitea 내부) | **필수** |
| `./license/license.json` | 라이센스 파일 (고객 제공) | 권장 |
| `./nginx/certs/` | SSL 인증서 | 권장 |

> **`secrets/secrets.env` 분실 시 영향**: 첫 부팅 시 자동 재생성되지만 기존에 발급된 모든 사용자 토큰/세션이 무효화되어 전원 재로그인이 필요하고, Gitea의 2FA 백업코드 등 일부 암호화된 데이터는 복호화가 불가능해집니다. 백업을 반드시 보관하세요.

### 백업 예시

```bash
# 서비스 중지 후 백업 권장
docker compose down

# 데이터 백업
tar -czvf backup-$(date +%Y%m%d).tar.gz postgres/data git/data secrets

# 서비스 재시작
docker compose up -d
```

## 8. 문제 해결

### 서비스가 시작되지 않을 때

```bash
# 로그 확인
docker compose logs -f

# 컨테이너 상태 확인
docker compose ps -a
```

### 데이터베이스 연결 오류

1. `.env` 파일의 `DB_USERNAME`, `DB_PASSWORD` 확인
2. `postgres/data/` 폴더 권한 확인 (Linux)

### 포트 충돌

기본 포트(80, 443)가 사용 중인 경우 `docker-compose.override.yml`로 호스트 포트를 변경하세요.
원본 `docker-compose.yml`은 직접 수정하지 않으므로 업데이트 시 충돌이 없습니다.

**1. 예제 파일 복사:**

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

**2. `docker-compose.override.yml`에서 호스트 포트 값 수정 (예: 8080/8443):**

```yaml
services:
  gw:
    ports: !override
      - "8080:80"
      - "8443:443"
```

> `!override` 태그는 원본 `docker-compose.yml`의 `ports` 리스트를 대체합니다. (없으면 두 리스트가 합쳐져 80/443 매핑이 함께 남아 충돌이 발생합니다. Docker Compose v2.20.0+ 필요.)

**3. `.env` 파일의 `EXTERNAL_URL`에도 포트 반영:**

```bash
# 기본 포트 사용 시
EXTERNAL_URL=https://your-domain.com

# 8443 포트 사용 시
EXTERNAL_URL=https://your-domain.com:8443
```

**4. 적용:**

```bash
docker compose up -d
```

`docker compose`는 두 파일을 자동으로 병합합니다 (별도 `-f` 옵션 불필요).

> **주의:** `EXTERNAL_URL`과 실제 포트가 일치하지 않으면 서비스 간 통신 및 리디렉션이 실패합니다.

## 9. 지원

문제가 해결되지 않으면 support@edencrew.com 으로 문의하세요.
