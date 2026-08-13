# Lucy TeamCloud On-Premise Docker 설치 가이드

## 사전 요구사항

설치 서버:

- Docker 20.10 이상
- Docker Compose v2
- 최소 4GB RAM, 10GB 디스크 공간

폐쇄망 서버용 image bundle을 만드는 온라인 PC:

- 실행 중인 Docker daemon
- Docker Compose v2
- Docker Buildx
- Docker Engine API 1.48 이상(Docker Engine 28 이상)과 `docker save --platform` 지원

```bash
docker info
docker version
docker compose version
docker buildx version
docker save --help | grep -q -- '--platform'
```

`docker save --platform` 요구사항은
[Docker image save](https://docs.docker.com/reference/cli/docker/image/save/)와
[Docker Engine API version matrix](https://docs.docker.com/reference/api/engine/)를
참고하세요.

## 1. 환경 설정

이 문서는 TeamCloud 본체가 실행되는 internal/onprem 서버 기준입니다. DMZ 서버는
별도 서버이며 `dmz/README.docker.md`를 따릅니다.

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
| `DB_PASSWORD` | `DATABASE_URL`에 URL encoding 없이 삽입되므로 `[A-Za-z0-9._~-]` 문자만 사용 권장. `.env`의 따옴표는 URI encoding을 대신하지 않음 |
| Linux 서버 | `HOST_UID`, `HOST_GID`를 compose 실행 계정의 `id -u`, `id -g` 값으로 설정 |

### 1.4 운영 port 결정

Docker 기본 compose는 gateway를 `80:80`, `443:443`으로 publish합니다. 실제 운영에서
다른 host port를 써야 하면 서비스를 실행하기 전에 `compose.docker.yml`의 `gw.ports`와
`.env` URL을 함께 수정하세요. `.env`의 `EXTERNAL_URL` port만 바꿔도 Docker publish
port는 자동으로 바뀌지 않습니다.

아래 placeholder는 설명용입니다. 실제 `compose.docker.yml`과 `.env`에는 `<...>`를
그대로 넣지 말고 운영 환경의 실제 host/domain과 숫자 port로 바꿔 입력하세요.

| Placeholder | 의미 |
|-------------|------|
| `<ONPREM_HOST>` | internal/onprem 서버 host 또는 domain |
| `<ONPREM_HTTP_PORT>` | onprem gateway HTTP host port |
| `<ONPREM_HTTPS_PORT>` | onprem gateway HTTPS host port |
| `<DMZ_HOST>` | DMZ 서버 host 또는 domain |
| `<DMZ_WS_PORT>` | DMZ plain WS host port |
| `<DMZ_WSS_PORT>` | DMZ WSS host port |

gateway nginx는 컨테이너 내부에서 80/443을 listen합니다. host port를 바꿀 때도 오른쪽
컨테이너 port `:80`, `:443`은 유지하세요.

```yaml
services:
  gw:
    ports:
      - "<ONPREM_HTTP_PORT>:80"
      - "<ONPREM_HTTPS_PORT>:443"
```

실제 입력 예:

```yaml
ports:
  - "8080:80"
  - "8443:443"
```

HTTPS 운영 예:

```env
EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
```

HTTP만 쓰는 테스트 환경이면 `https/wss` 대신 `http/ws`를 쓰고
`<ONPREM_HTTP_PORT>`를 사용하세요.

방화벽은 단일 onprem 서버 구성 기준으로 client -> onprem gateway host port만
허용하면 됩니다. DB port `5432`, broker port `1883`, broker WebSocket port `8080`은
외부에 열지 마세요.

### 1.5 DMZ를 사용하는 경우

DMZ는 TeamCloud 전체가 아니라 MQTT-over-WebSocket `/mqtt`만 외부에 노출합니다.
TeamCloud 화면/API/Auth/Git 접속 주소는 onprem gateway URL로 유지하고, 외부
클라이언트가 broker에 붙는 주소만 DMZ URL로 분리합니다.

internal/onprem 서버의 `.env`에서는 `EXTERNAL_URL`과 `BROKER_WS_URL`을 onprem gateway
주소로 유지하고, `PUBLIC_BROKER_WS_URL`만 DMZ 서버 주소로 설정합니다. DMZ 서버의
port는 DMZ 서버의 compose 파일에서 별도로 설정합니다.

DMZ를 쓰지 않는 단일 서버 구성:

```env
EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
```

DMZ WSS를 사용하는 구성:

```env
EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<DMZ_HOST>:<DMZ_WSS_PORT>/mqtt
```

DMZ plain WS를 non-standard port로 사용하는 테스트 구성:

```env
EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>
BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
PUBLIC_BROKER_WS_URL=ws://<DMZ_HOST>:<DMZ_WS_PORT>/mqtt
```

onprem `compose.docker.yml`의 gateway port와 DMZ compose의 gateway port는 서로
다른 서버의 설정입니다. onprem port를 바꿨다고 DMZ port가 바뀌지 않고, DMZ port를
바꿨다고 onprem port가 바뀌지 않습니다.

DMZ 구성의 방화벽은 최소 아래 방향만 허용하세요.

- client -> internal/onprem 서버 UI/API gateway port
- mobile/client -> DMZ 서버 `/mqtt` gateway port
- DMZ 서버 -> internal/onprem 서버 `EXTERNAL_URL`/`BROKER_WS_URL` gateway port

internal broker port `1883`, broker WebSocket port `8080`, DB port `5432`는 DMZ나
외부 client에 직접 열지 마세요.

### 1.6 계정 정보 변경 불가 안내

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
않을 수 있습니다. 아래 절차는 `init-secrets`가 생성한 self-signed 인증서에만
사용하세요. 운영 인증서는 삭제하지 말고 새 인증서를 준비해 교체합니다.

```bash
rm -f nginx/certs/server.crt nginx/certs/server.key &&
docker compose --env-file .env -f compose.docker.yml rm -f init-secrets &&
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

## 4. 서비스 실행

### 4.1 Public망 최초 실행

```bash
docker compose --env-file .env -f compose.docker.yml up -d --build
```

### 4.2 폐쇄망 최초 실행

먼저 [Offline Image Bundle 생성](#7-offline-image-bundle-생성)에 따라 Docker용 bundle을
`<설치 루트>/images/`에 준비합니다. 세 파일은 같은 export에서 생성된 세트여야 합니다.
설치 루트에서 load한 뒤 최초 실행합니다.

```bash
./scripts/load-compose-images-docker.sh \
  ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz &&
docker compose --env-file .env -f compose.docker.yml \
  up -d --pull never --no-build
```

loader가 gzip, image 목록과 load된 image를 검증하고, `.sha256` 파일이 있으면
checksum도 확인합니다. loader가 실패하면 `&&` 뒤의 최초 실행은 진행되지 않습니다.

### 4.3 로그 확인

```bash
docker compose --env-file .env -f compose.docker.yml logs -f
docker compose --env-file .env -f compose.docker.yml logs -f tc-be
```

### 4.4 서비스 상태 확인

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

## 6. 이미지 버전 업데이트

아래 절차는 서비스 구성과 image repository는 그대로이고 `compose.docker.yml`의
`image:` tag만 바뀌는 **이미지 중심 릴리스**에만 사용합니다. 다음 중 하나라도
해당하면 업데이트를 중단하고 해당 릴리스의 migration 안내를 따르세요.

- service 또는 image 추가·삭제
- image repository 변경
- Compose의 `image:` tag 외 운영 설정 변경
- `.env`, 인증서, 시크릿 또는 데이터 migration 필요

기존 설치에서는 Compose 전체를 새 파일로 덮어쓰지 말고 변경된 `image:` tag만
반영합니다. `.env`, `license/`, `secrets/`, `nginx/certs/`, `postgres/data/`,
`git/data/`, `broker/data/`, `broker/logs/`와 기존 custom port는 수정하지 않습니다.

현재 배포 이미지는 `linux/amd64` 서버 기준입니다. 업데이트 전에 stack을 내릴 필요가
없으며 `down -v`는 사용하지 마세요.

### 6.1 Public망 Docker 서버

새 릴리스에서 변경된 tag만 기존 `compose.docker.yml`에 반영한 뒤 실행합니다.

```bash
docker compose --env-file .env -f compose.docker.yml config --quiet &&
docker compose --env-file .env -f compose.docker.yml pull --ignore-buildable &&
docker compose --env-file .env -f compose.docker.yml \
  up -d --pull never --no-build
```

일반 이미지 업데이트에서는 `init-secrets`를 다시 build하거나 실행하지 않습니다.
릴리스별 안내가 별도 변경을 요구할 때만 그 안내를 따르세요.

```bash
docker compose --env-file .env -f compose.docker.yml ps
docker compose --env-file .env -f compose.docker.yml logs --tail=100 tc-be
```

### 6.2 폐쇄망 Docker 서버

온라인 PC에서 배포할 정확한 release ref를 checkout한 뒤
[Offline Image Bundle 생성](#7-offline-image-bundle-생성)에 따라 Docker bundle을
생성합니다. 온라인 PC에는 운영 `.env`와 license가 필요하지 않습니다.

같은 export에서 생성된 다음 세 파일을 이름을 바꾸지 않고 폐쇄망 서버의
`<기존 설치 루트>/images/`에 함께 복사합니다.

```text
images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt
```

새 릴리스의 `compose.docker.yml`을 참고해 기존 Compose에서 변경된 `image:` tag만
수정합니다. compose tag와 bundle은 반드시 같은 릴리스에서 가져와야 합니다. 설치
루트에서 아래 명령을 실행하세요.

```bash
./scripts/load-compose-images-docker.sh \
  ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz &&
docker compose --env-file .env -f compose.docker.yml \
  up -d --pull never --no-build
```

loader가 gzip, image 목록과 load된 image를 검증하고, `.sha256` 파일이 있으면
checksum도 확인합니다. loader가 실패하면 `&&` 뒤의 `up`은 실행되지 않습니다.

```bash
docker compose --env-file .env -f compose.docker.yml ps
docker compose --env-file .env -f compose.docker.yml logs --tail=100 tc-be
```

## 7. Offline Image Bundle 생성

온라인 PC에서 배포할 정확한 release ref를 checkout하고 실행합니다. export 스크립트는
`.env.example`로 Compose를 해석하므로 운영 `.env`와 license는 필요하지 않습니다.

```bash
# 아래 값을 실제 배포 tag 또는 commit으로 바꾸세요.
RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
git checkout --detach "$RELEASE_REF" &&
./scripts/export-compose-images-docker.sh
```

기본 결과는 온라인 소스 루트의 `images/`에 생성됩니다. 파일 이름의 기준 부분을
`X`라고 할 때 다음 세 파일을 함께 전송합니다.

- `X.tar.gz`
- `X.tar.gz.sha256`
- `X.images.txt`

Docker 기본 `X`는 `lucy-teamcloud-onprem-docker-images-linux-amd64`입니다.
`X.tar.gz`와 `X.images.txt`는 load에 필요합니다. `X.tar.gz.sha256`은 손상 확인을 위해
함께 전송하는 것을 권장하며, 없으면 loader가 경고 후 진행합니다. 전송하는 파일은
같은 export에서 생성된 동일 stem의 파일이어야 하며 이름을 바꾸지 마세요.

다음 파일은 진단용이며 load에 필요하지 않습니다.

- `X.archive-images.txt`
- `X.services.txt`

폐쇄망 서버에서는 전송한 파일을 `<기존 설치 루트>/images/`에 둡니다. 이 디렉터리는
전송 archive 보관 위치입니다. Compose가 archive를 직접 읽는 것이 아니라 loader가
archive의 image를 Docker 로컬 image store에 등록하고, Compose가 동일한 이름과 tag의
로컬 image를 사용합니다.

Podman용 bundle은 Docker 설치에 사용하지 마세요. 실제 load와 실행은
[폐쇄망 최초 실행](#42-폐쇄망-최초-실행) 또는
[폐쇄망 Docker 서버 업데이트](#62-폐쇄망-docker-서버)를 따릅니다.

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
docker compose --env-file .env -f compose.docker.yml \
  up -d --pull never --no-build
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

`compose.docker.yml`의 `gw.ports`가 이미 다른 프로세스가 사용 중인 host port를
publish하면 gateway가 시작되지 않습니다. 운영 port를 바꿀 때는
[운영 port 결정](#14-운영-port-결정)의 순서대로 compose `gw.ports`와 `.env` URL을
같이 맞추세요.

## 10. 알려진 문제

### 이미지 export 중 `unknown flag: --platform` 오류

아래 오류가 나오면 이미지를 만드는 PC의 Docker가 오래된 상태입니다.

```text
unknown flag: --platform
See 'docker save --help'.
```

이미지 다운로드 문제가 아닙니다. Docker Desktop 또는 Docker Engine을 요구 버전으로
업데이트한 뒤 배포할 정확한 release ref에서 export를 다시 실행하세요.

```bash
(
  set -e
  docker save --help | grep -- --platform
  cd lucy-teamcloud-onprem
  RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
  git checkout --detach "$RELEASE_REF"
  ./scripts/export-compose-images-docker.sh
)
```

### 이미지 export 중 `does not provide the specified platform` 오류

아래 오류가 나오면 이미지를 만드는 PC에서 보조 이미지가 서버용 `linux/amd64`가 아닌
다른 환경으로 만들어진 상태입니다.

```text
does not provide the specified platform (linux/amd64)
```

Docker Desktop 또는 Docker Engine을 요구 버전으로 업데이트하고, `buildx`가 동작하는지
확인한 뒤 배포할 정확한 release ref에서 export를 다시 실행하세요.

```bash
(
  set -e
  docker buildx version
  cd lucy-teamcloud-onprem
  RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
  git checkout --detach "$RELEASE_REF"
  ./scripts/export-compose-images-docker.sh
)
```

### 브라우저 캐시와 OIDC code 만료

서버는 새 버전인데 브라우저가 이전 화면을 계속 보여주거나 로그인 중
`invalid_grant`, `authorization code expired`가 발생하면 브라우저 캐시 또는
service worker를 삭제하세요.

```text
Chrome DevTools -> Application -> Service Workers -> Unregister
Chrome DevTools -> Application -> Storage -> Clear site data
```

### Compose 실행 화면에서 `db-1 Error`만 보일 때

이미지 load가 `Load complete.`로 끝난 뒤 실행 화면에 아래처럼 보일 수 있습니다.

```text
Container lucy-teamcloud-onprem-db-1  Error
```

이 화면만으로는 정확한 원인을 알 수 없습니다. 이미지 load 실패로 판단하지 말고,
먼저 DB 컨테이너 로그를 확인하세요.

```bash
docker compose --env-file .env -f compose.docker.yml ps -a
docker compose --env-file .env -f compose.docker.yml logs --tail=100 db
```

로그에 `/docker-entrypoint-initdb.d/` 또는 `permission denied`가 보이면 아래
`postgres/initdb` 권한 문제 해결 절차를 진행하세요.

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
