# Lucy TeamCloud On-Premise Docker 설치 가이드

## 사전 요구사항

- Docker 20.10 이상
- Docker Compose v2
- 최소 4GB RAM, 10GB 디스크 공간

## 1. 환경 설정

### 1.1 `.env` 파일 생성

`.env.example` 파일을 복사하여 `.env` 파일을 생성합니다.

```bash
cp .env.example .env
```

### 1.2 `.env` 파일 편집

```bash
# 외부에서 서비스에 접근할 때 사용하는 주소
# 프로토콜(http:// 또는 https://)을 반드시 포함하세요.
EXTERNAL_URL=https://your-domain.com

# MQTT 브로커 WebSocket 접속 주소
# EXTERNAL_URL 이 https 면 wss://, http 면 ws:// 를 사용해야 합니다.
BROKER_WS_URL=wss://your-domain.com/mqtt
PUBLIC_BROKER_WS_URL=wss://your-domain.com/mqtt

# Lucy 서비스 관리자 계정
LUCY_ADMIN_EMAIL=admin@your-company.com
LUCY_ADMIN_PASSWORD=your-secure-password
LUCY_ADMIN_NAME=admin

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
| `BROKER_WS_URL` | `EXTERNAL_URL`의 스킴과 짝을 맞출 것 (`https` -> `wss://`, `http` -> `ws://`) |
| `PUBLIC_BROKER_WS_URL` | 외부 클라이언트가 접근하는 broker WebSocket URL |
| `LUCY_ADMIN_NAME` | `admin`으로 고정, 변경하지 마세요 |
| 비밀번호 | 특수문자 포함 시 따옴표로 감싸세요. 예: `DB_PASSWORD="P@ss!word"` |
| Linux 서버 | `HOST_UID`, `HOST_GID`를 compose 실행 계정의 `id -u`, `id -g` 값으로 설정 |

Docker 기본 compose는 gateway를 `80:80`, `443:443`으로 publish합니다. `.env`의
`EXTERNAL_URL` port를 바꿔도 Docker publish port는 자동으로 바뀌지 않습니다. 다른
host port를 쓰려면 [gateway port mapping](#gateway-port-mapping)에 맞춰
`compose.docker.yml`의 `gw.ports`와 `.env` URL을 함께 수정하세요.

### 1.4 계정 정보 변경 불가 안내

아래 항목들은 최초 실행 시에만 적용됩니다. 서비스 실행 후 `.env` 파일을 수정해도
기존 데이터베이스와 관리자 계정에는 반영되지 않습니다.

| 항목 | 최초 실행 후 변경 시 |
|------|---------------------|
| `LUCY_ADMIN_EMAIL` | 기존 관리자 계정과 불일치, 로그인 불가 |
| `LUCY_ADMIN_PASSWORD` | 기존 관리자 계정과 불일치, 로그인 불가 |
| `DB_USERNAME` | 데이터베이스 연결 실패, 서비스 중단 |
| `DB_PASSWORD` | 데이터베이스 연결 실패, 서비스 중단 |
| `DB_ROOT_PASSWORD` | PostgreSQL 접근 불가 |

계정 정보를 분실하거나 변경해야 하면 백업본에서 복원하거나 새 환경으로 재설치하세요.

## 2. 라이센스 파일 배치

발급받은 라이센스 파일을 `license/license.json` 경로에 배치합니다.

```bash
cp /path/to/your/license.json license/license.json
```

라이센스 파일이 없으면 `tc-be`가 시작 시 검증에 실패하여 종료됩니다. 라이센스
발급/갱신 문의는 `support@edencrew.com`으로 연락하세요.

라이센스 갱신 시에는 파일 교체 후 `tc-be`를 재시작합니다.

```bash
docker compose --env-file .env -f compose.docker.yml restart tc-be
```

## 3. SSL 인증서 설정

별도 작업 없이 첫 부팅 시 `init-secrets`가 `.env`의 `EXTERNAL_URL` 도메인으로
self-signed 인증서를 자동 발급해 `nginx/certs/server.crt`,
`nginx/certs/server.key`에 둡니다.

운영 환경에서는 실제 인증서로 교체하세요.

```bash
cp /path/to/your/certificate.crt nginx/certs/server.crt
cp /path/to/your/private.key nginx/certs/server.key
docker compose --env-file .env -f compose.docker.yml restart gw
```

`init-secrets`는 파일이 이미 있으면 건드리지 않으므로 정식 인증서는 보존됩니다.

`EXTERNAL_URL` 도메인을 변경한 경우 기존 self-signed 인증서가 새 도메인과 맞지
않을 수 있습니다. 필요하면 인증서 파일과 기존 `init-secrets` 컨테이너를 삭제한 뒤
재기동하세요.

```bash
rm -f nginx/certs/server.crt nginx/certs/server.key
docker compose --env-file .env -f compose.docker.yml rm -f init-secrets
docker compose --env-file .env -f compose.docker.yml up -d --build
```

## 4. 서비스 실행

### 4.1 최초 실행

```bash
docker compose --env-file .env -f compose.docker.yml up -d --build
```

### 4.2 로그 확인

```bash
docker compose --env-file .env -f compose.docker.yml logs -f
docker compose --env-file .env -f compose.docker.yml logs -f tc-be
```

### 4.3 서비스 상태 확인

```bash
docker compose --env-file .env -f compose.docker.yml ps
```

`init-secrets` 컨테이너는 첫 부팅 시 인스턴스별 시크릿을 생성하고 종료되는
일회성 컨테이너입니다. `Exited (0)` 상태로 남아 있는 것은 정상입니다.

## 5. 서비스 종료

```bash
docker compose --env-file .env -f compose.docker.yml down
```

데이터는 로컬 디렉터리(`postgres/data/`, `git/data/`)에 보존됩니다. 운영
환경에서 `down -v`는 사용하지 마세요.

## 6. 업데이트 및 재실행

```bash
docker compose --env-file .env -f compose.docker.yml pull
docker compose --env-file .env -f compose.docker.yml up -d --build
```

`.env` 파일이나 설정 파일 변경 후에도 같은 명령으로 재시작합니다.

## 7. Offline Image Flow

온라인 환경에서 이미지 archive를 만듭니다.

```bash
./scripts/export-compose-images-docker.sh
```

생성된 Docker용 파일들을 폐쇄망 Docker 서버의 repo `images/` 디렉터리로 옮깁니다.

```text
images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt
images/lucy-teamcloud-onprem-docker-images-linux-amd64.archive-images.txt
images/lucy-teamcloud-onprem-docker-images-linux-amd64.services.txt
```

폐쇄망 Docker 서버에서 로드하고 실행합니다.

```bash
./scripts/load-compose-images-docker.sh ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

Podman용 archive는 Docker 설치에 사용하지 마세요. Docker용 archive에는
`lucy-teamcloud-onprem-init-secrets:offline` 이미지가 포함됩니다.

offline 실행에서는 `--build`를 붙이지 마세요. archive 안에 이미 빌드된
`lucy-teamcloud-onprem-init-secrets:offline` 이미지가 포함됩니다.

## 8. 데이터 저장 위치

| 경로 | 설명 | 백업 권장 |
|------|------|----------|
| `./postgres/data/` | 데이터베이스 | 필수 |
| `./git/data/` | Git 저장소 데이터 | 필수 |
| `./secrets/secrets.env` | 인스턴스별 자동 생성 시크릿 | 필수 |
| `./license/license.json` | 라이센스 파일 | 필수 |
| `./nginx/certs/` | SSL 인증서 | 권장 |
| `./broker/data/`, `./broker/logs/` | broker 데이터와 로그 | 권장 |

백업 예시:

```bash
docker compose --env-file .env -f compose.docker.yml down
tar -czvf backup-$(date +%Y%m%d).tar.gz \
  .env license/license.json secrets nginx/certs postgres/data git/data broker/data broker/logs
docker compose --env-file .env -f compose.docker.yml up -d --build
```

## 9. 문제 해결

로그와 상태를 먼저 확인합니다.

```bash
docker compose --env-file .env -f compose.docker.yml logs -f
docker compose --env-file .env -f compose.docker.yml ps -a
docker compose --env-file .env -f compose.docker.yml config
```

### 데이터베이스 연결 오류

1. `.env` 파일의 `DB_USERNAME`, `DB_PASSWORD`를 확인합니다.
2. `postgres/data/`가 기존 데이터로 초기화된 상태라면 DB 계정 값을 변경할 수 없습니다.

### 포트 충돌

`compose.docker.yml`은 기본적으로 `80:80`, `443:443`을 publish합니다. 포트를
바꾸려면 `compose.docker.yml`의 `gw.ports`와 `.env`의 `EXTERNAL_URL`,
`BROKER_WS_URL`, `PUBLIC_BROKER_WS_URL`을 같은 host/port로 맞추세요.

예:

```yaml
services:
  gw:
    ports:
      - "8080:80"
      - "8443:443"
```

```env
EXTERNAL_URL=https://your-domain.com:8443
BROKER_WS_URL=wss://your-domain.com:8443/mqtt
PUBLIC_BROKER_WS_URL=wss://your-domain.com:8443/mqtt
```

## 10. 알려진 문제

### 브라우저 캐시와 OIDC code 만료

서버는 새 버전인데 브라우저가 이전 화면을 계속 보여주거나 로그인 중
`invalid_grant`, `authorization code expired`가 발생하면 브라우저 캐시 또는
service worker를 삭제하세요.

```text
Chrome DevTools -> Application -> Service Workers -> Unregister
Chrome DevTools -> Application -> Storage -> Clear site data
```

### `postgres/initdb` permission denied

다음 오류는 host 파일 권한 또는 SELinux label 문제입니다.

```text
ls: cannot open directory '/docker-entrypoint-initdb.d/': Permission denied
```

운영자는 initdb 파일이 컨테이너에서 읽히도록 권한을 맞춰야 합니다.

```bash
chmod 755 postgres postgres/initdb
chmod 644 postgres/initdb/*
```

SELinux Enforcing 환경에서는 label도 확인하세요.

```bash
sudo chcon -Rt container_file_t postgres/initdb postgres/data
```

### broker 8080 host port 충돌

`compose.docker.yml`은 broker WebSocket port로 host `8080`을 publish합니다. 충돌하면
사용 중인 프로세스를 확인하고 host port만 변경하세요.

```bash
ss -ltnp 'sport = :8080'
```

컨테이너 내부 port는 그대로 두고 왼쪽 host port만 바꿉니다.

```yaml
services:
  broker:
    ports:
      - "1883:1883"
      - "18081:8080"
```

### gateway port mapping

gateway nginx는 컨테이너 내부에서 80/443을 listen합니다. host port를 바꿀 때도
오른쪽 컨테이너 port는 유지하세요.

```yaml
services:
  gw:
    ports:
      - "8080:80"
      - "8443:443"
```
