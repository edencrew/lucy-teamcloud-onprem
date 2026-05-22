# Lucy TeamCloud On-Premise 설치 및 운영 가이드

이 문서는 **Lucy TeamCloud On-Premise**를 폐쇄망 또는 인터넷 제한 환경에 설치하기 위한 가이드입니다.

설치 흐름은 크게 3단계입니다.

```text
1. 인터넷 가능한 PC에서 Docker 이미지 패키징
2. 폐쇄망 서버에서 이미지 로드
3. 폐쇄망 서버에서 사전 검증 후 서비스 실행
```

---

# 1. 파일 구조

권장 프로젝트 구조는 다음과 같습니다.

```text
lucy-teamcloud-onprem/
  docker-compose.yml
  docker-compose.offline.yml
  docker-compose.override.yml.example
  .env.example

  scripts/
    export-compose-images.sh
    load-compose-images.sh
    preflight-onprem.sh
    onprem-compose.sh
    init-secrets.sh

  images/
    ...

  license/
    license.json

  nginx/
    nginx.conf
    certs/

  postgres/
    initdb/
    data/

  git/
    data/

  secrets/
```

---

# 2. 주요 파일 설명

## 2.1 `docker-compose.yml`

기본 Docker Compose 파일입니다.

일반적인 온라인/개발 환경에서도 사용할 수 있도록 기존 동작을 최대한 유지합니다.

특히 `broker` 서비스는 기본 compose 파일에서는 직접 빌드합니다.

```yaml
broker:
  build:
    context: ./broker
```

즉, 기본 `docker-compose.yml`은 폐쇄망 전용 이미지명을 강제하지 않습니다.

---

## 2.2 `docker-compose.offline.yml`

폐쇄망 패키징 및 폐쇄망 실행을 위한 추가 compose 파일입니다.

이 파일은 `broker` 서비스를 폐쇄망에서 사용할 수 있도록 이미지명을 부여합니다.

```yaml
services:
  broker:
    image: lucy-teamcloud-onprem-broker:offline
    platform: ${TARGET_PLATFORM:-linux/amd64}
```

이 파일은 `docker-compose.yml`을 대체하지 않고, 함께 병합되어 사용됩니다.

```text
docker-compose.yml
+ docker-compose.offline.yml
```

`export-compose-images.sh`와 `preflight-onprem.sh`는 이 파일이 있으면 자동으로 포함합니다.

---

## 2.3 `scripts/export-compose-images.sh`

인터넷이 가능한 PC에서 실행하는 스크립트입니다.

역할:

```text
Docker Compose 설정 읽기
docker-compose.offline.yml 자동 포함
필요한 이미지 pull
broker 이미지 build
모든 이미지를 하나의 tar.gz 파일로 저장
특정 서비스 이미지만 부분 archive로 저장
sha256 체크섬 생성
이미지 목록 파일 생성
```

---

## 2.4 `scripts/load-compose-images.sh`

폐쇄망 서버에서 실행하는 스크립트입니다.

역할:

```text
이미지 tar.gz 파일 확인
sha256 체크섬 검증
gzip 무결성 검사
docker load 실행
로드된 이미지 확인
```

---

## 2.5 `scripts/preflight-onprem.sh`

폐쇄망 서버에서 `docker compose up` 전에 실행하는 사전 점검 스크립트입니다.

역할:

```text
Docker / Docker Compose 버전 확인
RAM / 디스크 공간 확인
.env 필수 값 확인
EXTERNAL_URL / BROKER_WS_URL 검증
라이센스 파일 확인
SSL 인증서 상태 확인
포트 충돌 확인
로컬 Docker 이미지 확인
이미지 아키텍처 확인
docker compose config 검증
최초 실행 후 변경하면 안 되는 값 검증
```

검증 통과 후 옵션으로 서비스 실행까지 할 수 있습니다.

```bash
./scripts/preflight-onprem.sh --compose-up
```

---

## 2.6 `scripts/onprem-compose.sh`

설치 후 운영자가 사용하는 Docker Compose 래퍼 스크립트입니다.

역할:

```text
사전 검증 후 서비스 시작
데이터를 보존하는 전체 중지
서비스 재시작/재생성
이미지 archive 로드 후 태그 검증 및 재생성
상태/로그/config/image 목록 확인
```

기본 `down` 명령은 데이터를 보존하며 `docker compose down -v`를 실행하지 않습니다.

예:

```bash
./scripts/onprem-compose.sh up
./scripts/onprem-compose.sh restart broker
./scripts/onprem-compose.sh recreate broker
./scripts/onprem-compose.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
./scripts/onprem-compose.sh down
```

---

## 2.7 `scripts/init-secrets.sh`

사용자가 직접 실행하는 스크립트가 아닙니다.

`docker compose up` 시 `init-secrets` 컨테이너에서 자동으로 실행됩니다.

역할:

```text
secrets/secrets.env 자동 생성
nginx/certs/server.crt 자동 생성
nginx/certs/server.key 자동 생성
```

이미 파일이 있으면 덮어쓰지 않습니다.

---

# 3. 사전 요구사항

폐쇄망 서버에는 다음이 필요합니다.

```text
Docker 20.10 이상
Docker Compose v2.20 이상
최소 4GB RAM
최소 10GB 디스크 여유 공간
```

권장 사양:

```text
RAM 8GB 이상
디스크 여유 공간 30GB 이상
```

Docker Compose v2.20 이상이 필요한 이유는 `docker-compose.override.yml`에서 `!override` 태그를 사용할 수 있기 때문입니다.

---

# 4. 설치 전체 흐름

## 4.1 인터넷 가능한 PC에서 이미지 패키징

인터넷 가능한 PC에서 실행합니다.

```bash
./scripts/export-compose-images.sh
```

기본적으로 `linux/amd64` 플랫폼용 이미지를 준비합니다.

x86_64 Linux 서버라면 그대로 사용하면 됩니다.

```bash
./scripts/export-compose-images.sh
```

ARM64 서버용 이미지를 만들려면 다음처럼 실행합니다.

```bash
TARGET_PLATFORM=linux/arm64 ./scripts/export-compose-images.sh
```

실행이 완료되면 `images/` 디렉토리에 다음 파일들이 생성됩니다.

```text
images/
  lucy-teamcloud-onprem-images-linux-amd64.tar.gz
  lucy-teamcloud-onprem-images-linux-amd64.tar.gz.sha256
  lucy-teamcloud-onprem-images-linux-amd64.images.txt
  lucy-teamcloud-onprem-images-linux-amd64.archive-images.txt
  lucy-teamcloud-onprem-images-linux-amd64.explicit-images.txt
  lucy-teamcloud-onprem-images-linux-amd64.services.txt
```

특정 서비스 이미지만 새로 패키징하려면 `--update-service`를 사용합니다.
이 경우 tar.gz에는 선택한 서비스 이미지들만 들어가지만, `*.images.txt`와
`*.services.txt`는 전체 Compose stack 기준으로 생성됩니다. 폐쇄망 서버에는
선택하지 않은 기존 이미지가 이미 있어야 합니다.

```bash
./scripts/export-compose-images.sh --update-service tc-fe
./scripts/export-compose-images.sh --update-service tc-fe --update-service auth-fe
```

생성된 `images/` 디렉토리를 폐쇄망 서버로 복사합니다.

세부 옵션은 다음 명령어로 확인할 수 있습니다.

```bash
./scripts/export-compose-images.sh --help
```

---

## 4.2 폐쇄망 서버로 파일 복사

폐쇄망 서버에는 최소한 다음 파일과 디렉토리가 있어야 합니다.

```text
docker-compose.yml
docker-compose.offline.yml
.env
license/license.json

scripts/
  load-compose-images.sh
  preflight-onprem.sh
  onprem-compose.sh
  init-secrets.sh

images/
  *.tar.gz
  *.tar.gz.sha256
  *.images.txt
  *.services.txt
```

---

## 4.3 폐쇄망 서버에서 이미지 로드

폐쇄망 서버에서 실행합니다.

```bash
./scripts/load-compose-images.sh
```

이 스크립트는 `images/` 디렉토리 안의 이미지 파일을 자동으로 찾아 검증 후 로드합니다.

특정 파일을 직접 지정할 수도 있습니다.

```bash
./scripts/load-compose-images.sh ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
```

실행 후 이미지가 로드되었는지 확인하려면 다음 명령어를 사용할 수 있습니다.

```bash
docker images
```

세부 옵션은 다음 명령어로 확인할 수 있습니다.

```bash
./scripts/load-compose-images.sh --help
```

---

## 4.4 폐쇄망 서버에서 실행 전 검증

이미지 로드가 끝나면 서비스를 실행하기 전에 사전 검증을 수행합니다.

```bash
./scripts/preflight-onprem.sh
```

검증이 모두 통과하면 다음 명령으로 서비스를 실행할 수 있습니다.

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.offline.yml \
  up -d --pull never --no-build
```

또는 검증 후 바로 실행하려면 다음 명령을 사용합니다.

```bash
./scripts/preflight-onprem.sh --compose-up
```

세부 옵션은 다음 명령어로 확인할 수 있습니다.

```bash
./scripts/preflight-onprem.sh --help
```

---

## 4.5 운영 유틸 스크립트

설치 후에는 `onprem-compose.sh`로 일반 운영 작업을 수행할 수 있습니다.

일반 시작:

```bash
./scripts/onprem-compose.sh up
```

전체 스택을 데이터 보존 방식으로 재시작:

```bash
./scripts/onprem-compose.sh restart-stack
```

preflight resource check를 건너뛰고 전체 스택을 재시작:

```bash
./scripts/onprem-compose.sh restart-stack --skip-resource-check
```

특정 서비스만 재시작:

```bash
./scripts/onprem-compose.sh restart broker
```

특정 서비스 컨테이너를 재생성:

```bash
./scripts/onprem-compose.sh recreate broker
```

preflight resource check를 건너뛰고 특정 서비스 컨테이너를 재생성:

```bash
./scripts/onprem-compose.sh recreate --skip-resource-check broker
```

`check`, `up`, `restart`, `recreate`, `restart-stack`, `replace-images`는
`--skip-resource-check`, `--skip-port-check`, `--skip-image-check`, `--skip-arch-check`,
`--allow-cert-host-mismatch`, `--allow-immutable-change`를 preflight 옵션으로 받아
서비스 인자와 분리해 `preflight-onprem.sh`에 전달합니다.

이미지 archive 교체 후 재생성:

```bash
./scripts/onprem-compose.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
```

`replace-images`는 archive 옆의 `*.images.txt`와 `*.services.txt`를 함께 사용합니다.
`*.services.txt` 기준으로 `.install-state/compose-image-tags.override.yml`을 생성한 뒤,
그 override를 포함한 Compose image 목록이 `*.images.txt`와 정확히 일치할 때만 이미지를
로드하고 컨테이너를 재생성합니다.

저장된 image tag override 확인:

```bash
./scripts/onprem-compose.sh image-override
```

저장된 image tag override 삭제:

```bash
./scripts/onprem-compose.sh clear-image-override
```

삭제해도 서비스 데이터와 Docker volume은 삭제되지 않습니다.

상태 및 로그 확인:

```bash
./scripts/onprem-compose.sh ps
./scripts/onprem-compose.sh logs broker
./scripts/onprem-compose.sh images
```

---

# 5. `.env` 설정

## 5.1 `.env` 파일 생성

처음 설치할 때 `.env.example`을 복사하여 `.env` 파일을 만듭니다.

```bash
cp .env.example .env
```

---

## 5.2 필수 설정값

`.env` 파일에서 최소한 다음 값을 설정해야 합니다.

```env
EXTERNAL_URL=https://your-domain.com
BROKER_WS_URL=wss://your-domain.com/mqtt

LUCY_ADMIN_EMAIL=admin@your-company.com
LUCY_ADMIN_PASSWORD=your-secure-password
LUCY_ADMIN_NAME=admin

DB_ROOT_PASSWORD=your-db-root-password
DB_USERNAME=lucy
DB_PASSWORD=your-db-password

TZ=Asia/Seoul
```

---

## 5.3 `EXTERNAL_URL`

외부 사용자가 Lucy TeamCloud에 접속할 주소입니다.

반드시 프로토콜을 포함해야 합니다.

올바른 예:

```env
EXTERNAL_URL=https://teamcloud.company.com
```

또는 포트를 사용하는 경우:

```env
EXTERNAL_URL=https://teamcloud.company.com:8443
```

사용하면 안 되는 값:

```env
EXTERNAL_URL=http://localhost
EXTERNAL_URL=http://127.0.0.1
EXTERNAL_URL=http://0.0.0.0
```

---

## 5.4 `BROKER_WS_URL`

브라우저가 MQTT WebSocket 브로커에 접속할 주소입니다.

일반적으로 `EXTERNAL_URL` 뒤에 `/mqtt`를 붙입니다.

HTTPS를 사용하는 경우:

```env
EXTERNAL_URL=https://teamcloud.company.com
BROKER_WS_URL=wss://teamcloud.company.com/mqtt
```

HTTP를 사용하는 경우:

```env
EXTERNAL_URL=http://teamcloud.company.com
BROKER_WS_URL=ws://teamcloud.company.com/mqtt
```

규칙:

| EXTERNAL_URL | BROKER_WS_URL |
|---|---|
| `https://...` | `wss://.../mqtt` |
| `http://...` | `ws://.../mqtt` |

---

## 5.5 관리자 계정

```env
LUCY_ADMIN_EMAIL=admin@your-company.com
LUCY_ADMIN_PASSWORD=your-secure-password
LUCY_ADMIN_NAME=admin
```

`LUCY_ADMIN_NAME`은 반드시 `admin`으로 유지해야 합니다.

```env
LUCY_ADMIN_NAME=admin
```

변경하지 마세요.

---

## 5.6 데이터베이스 계정

```env
DB_ROOT_PASSWORD=your-db-root-password
DB_USERNAME=lucy
DB_PASSWORD=your-db-password
```

비밀번호에 특수문자가 포함되어 있으면 따옴표로 감싸는 것을 권장합니다.

```env
DB_PASSWORD="P@ss!word"
```

---

## 5.7 Linux 권한 설정

Linux 서버에서는 필요에 따라 다음 값을 설정할 수 있습니다.

```env
HOST_UID=1000
HOST_GID=1000
```

현재 사용자 UID/GID는 다음 명령어로 확인할 수 있습니다.

```bash
id
```

또는 각각 확인하려면:

```bash
id -u
id -g
```

`preflight-onprem.sh`는 runtime 디렉터리를 이 UID/GID 기준으로 준비합니다.
단, 다음 자동 생성 산출물은 `root:root`여도 허용합니다.

```text
git/data/gitea/.admin-created
git/data/ssh/
secrets/secrets.env
nginx/certs/server.crt
nginx/certs/server.key
```

`git/data/ssh/`는 디렉터리와 그 하위 항목을 포함합니다. 이 목록 밖의 root-owned
파일이나 디렉터리는 계속 실패 또는 보정 대상입니다.

---

# 6. 최초 실행 후 변경하면 안 되는 값

아래 값들은 최초 실행 후 변경하면 안 됩니다.

```text
LUCY_ADMIN_EMAIL
LUCY_ADMIN_PASSWORD
DB_USERNAME
DB_PASSWORD
DB_ROOT_PASSWORD
```

이 값들은 최초 실행 시 데이터베이스와 내부 서비스 초기화에 사용됩니다.

최초 실행 후 변경하면 다음 문제가 발생할 수 있습니다.

```text
관리자 로그인 불가
데이터베이스 연결 실패
서비스 기동 실패
```

`preflight-onprem.sh`는 이 값들의 변경 여부를 감지하기 위해 `.install-state/immutable.env.sha256` 파일을 생성합니다.

검증이 성공한 뒤에만 생성되며, 이후 값이 바뀌면 경고 또는 실패 처리됩니다.

---

# 7. 라이센스 파일

발급받은 라이센스 파일을 아래 위치에 배치합니다.

```text
license/license.json
```

예:

```bash
cp /path/to/license.json license/license.json
```

라이센스 파일이 없으면 `tc-be` 서비스가 시작되지 않습니다.

라이센스 갱신 시에는 파일을 교체한 뒤 다음 명령으로 재시작합니다.

```bash
docker compose restart tc-be
```

라이센스 관련 문의:

```text
support@edencrew.com
```

---

# 8. SSL 인증서

## 8.1 기본 동작

별도 인증서가 없으면 첫 부팅 시 `init-secrets` 컨테이너가 self-signed 인증서를 자동 생성합니다.

생성 위치:

```text
nginx/certs/server.crt
nginx/certs/server.key
```

브라우저에서는 자체 서명 인증서 경고가 표시될 수 있습니다.

운영 환경에서는 실제 인증서로 교체하는 것을 권장합니다.

---

## 8.2 운영 인증서로 교체

실제 인증서가 있다면 아래 파일을 교체합니다.

```bash
cp /path/to/your/certificate.crt nginx/certs/server.crt
cp /path/to/your/private.key nginx/certs/server.key
```

적용:

```bash
docker compose restart gw
```

`init-secrets.sh`는 인증서 파일이 이미 있으면 덮어쓰지 않습니다.

---

## 8.3 도메인 변경 시 주의

`EXTERNAL_URL` 도메인을 변경한 경우 기존 self-signed 인증서와 도메인이 맞지 않을 수 있습니다.

이 경우 기존 인증서를 삭제한 뒤 다시 실행합니다.

```bash
rm nginx/certs/server.crt nginx/certs/server.key
docker compose \
  -f docker-compose.yml \
  -f docker-compose.offline.yml \
  up -d --pull never --no-build
```

---

# 9. 서비스 실행

## 9.1 권장 실행 방식

폐쇄망 서버에서는 다음 순서로 실행합니다.

```bash
./scripts/onprem-compose.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
```

`replace-images`는 이미지 로드, 사전 검증, 컨테이너 재생성을 한 번에 수행합니다.

이미지를 이미 로드했고 tag override가 필요하지 않다면 다음처럼 실행할 수 있습니다.

```bash
./scripts/onprem-compose.sh up
```

또는 기존 preflight 흐름을 사용할 수 있습니다.

```bash
./scripts/preflight-onprem.sh
./scripts/preflight-onprem.sh --compose-up
```

---

## 9.2 왜 `--pull never --no-build`를 사용하나요?

폐쇄망 서버에서는 외부 registry에 접근할 수 없습니다.

따라서 실행 시 Docker가 이미지를 pull하거나 broker를 다시 build하지 않도록 해야 합니다.

```bash
--pull never
```

외부 이미지 pull 방지

```bash
--no-build
```

로컬 build 방지

이미지는 이미 `load-compose-images.sh`를 통해 로드되어 있어야 합니다.

---

# 10. 서비스 상태 확인

## 전체 컨테이너 상태

```bash
docker compose ps
```

## 전체 로그 확인

```bash
docker compose logs -f
```

## 특정 서비스 로그 확인

```bash
docker compose logs -f tc-be
docker compose logs -f auth-be
docker compose logs -f gw
docker compose logs -f broker
```

---

# 11. 서비스 종료

```bash
docker compose down
```

데이터는 로컬 디렉토리에 남아 있습니다.

```text
postgres/data/
git/data/
secrets/
```

---

# 12. 업데이트

## 12.1 인터넷 가능한 PC에서 새 이미지 패키징

새 버전 이미지가 필요한 경우 인터넷 가능한 PC에서 다시 실행합니다.

```bash
./scripts/export-compose-images.sh
```

특정 서비스 이미지만 새로 교체할 경우에는 부분 archive를 만들 수 있습니다.

```bash
./scripts/export-compose-images.sh --update-service tc-fe
```

부분 archive는 선택한 서비스 이미지들만 포함하지만, image manifest는 전체 stack 기준입니다.
폐쇄망 서버에 선택하지 않은 이미지가 이미 있는 상태에서 사용해야 합니다.

새로 생성된 `images/` 파일을 폐쇄망 서버로 옮깁니다.

---

## 12.2 폐쇄망 서버에서 새 이미지 로드

```bash
./scripts/onprem-compose.sh replace-images ./images/<new-image-archive>.tar.gz
```

이 명령은 새 archive의 `*.services.txt`를 기준으로 image tag override를 저장하고,
archive를 로드한 뒤 새 태그로 컨테이너를 재생성합니다.

---

## 12.3 특정 서비스만 재생성

```bash
./scripts/onprem-compose.sh recreate broker
```

저장된 image tag override가 있으면 `recreate`도 해당 태그를 사용합니다.

---

# 13. 데이터 저장 위치

| 경로 | 설명 | 백업 권장 |
|---|---|---|
| `postgres/data/` | 데이터베이스 데이터 | 필수 |
| `git/data/` | Git 저장소 데이터 | 필수 |
| `secrets/secrets.env` | 인스턴스별 자동 생성 시크릿 | 필수 |
| `license/license.json` | 라이센스 파일 | 권장 |
| `nginx/certs/` | SSL 인증서 | 권장 |
| `.env` | 설치 환경 설정 | 필수 |
| `.install-state/immutable.env.sha256` | 최초 설정값 변경 감지용 파일 | 권장 |
| `.install-state/compose-image-tags.override.yml` | 설치 서버에서 사용할 image tag override | 권장 |

---

# 14. 백업

서비스를 중지한 뒤 백업하는 것을 권장합니다.

```bash
docker compose down
```

백업 예시:

```bash
tar -czvf backup-$(date +%Y%m%d).tar.gz \
  .env \
  postgres/data \
  git/data \
  secrets \
  license \
  nginx/certs \
  .install-state
```

백업 후 다시 실행:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.offline.yml \
  up -d --pull never --no-build
```

---

# 15. 초기화

주의: 아래 작업은 데이터를 삭제합니다.

```bash
docker compose down -v
rm -rf postgres/data git/data secrets/secrets.env .install-state
```

그 뒤 `.env`를 다시 설정하고 실행합니다.

```bash
./scripts/preflight-onprem.sh --compose-up
```

운영 데이터가 있는 환경에서는 신중하게 실행해야 합니다.

---

# 16. 포트 변경

기본적으로 `gw`는 80, 443 포트를 사용합니다.

이미 해당 포트를 사용 중이라면 `docker-compose.override.yml`을 생성하여 포트를 변경합니다.

예제 파일 복사:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

예:

```yaml
services:
  gw:
    ports: !override
      - "8080:80"
      - "8443:443"
```

`!override`를 사용하려면 Docker Compose v2.20 이상이 필요합니다.

포트를 변경한 경우 `.env`의 `EXTERNAL_URL`에도 포트를 반영해야 합니다.

```env
EXTERNAL_URL=https://your-domain.com:8443
BROKER_WS_URL=wss://your-domain.com:8443/mqtt
```

적용 전 검증:

```bash
./scripts/preflight-onprem.sh
```

---

# 17. 문제 해결

## 17.1 preflight 실패

먼저 다음 명령을 실행합니다.

```bash
./scripts/preflight-onprem.sh
```

`FAIL`로 표시된 항목을 수정해야 합니다.

예:

```text
FAIL EXTERNAL_URL still looks like a placeholder
```

해결:

```env
EXTERNAL_URL=https://실제-도메인-또는-IP
BROKER_WS_URL=wss://실제-도메인-또는-IP/mqtt
```

---

## 17.2 이미지가 없다는 오류

예:

```text
Local image missing
```

해결:

```bash
./scripts/load-compose-images.sh
```

이미지를 다시 로드한 뒤 검증합니다.

```bash
./scripts/preflight-onprem.sh
```

---

## 17.3 이미지 아키텍처 불일치

예:

```text
Image platform mismatch
```

서버 CPU 아키텍처와 이미지 플랫폼이 맞지 않는 상태입니다.

서버 확인:

```bash
uname -m
```

| 결과 | 필요한 플랫폼 |
|---|---|
| `x86_64` | `linux/amd64` |
| `aarch64` | `linux/arm64` |
| `arm64` | `linux/arm64` |

인터넷 가능한 PC에서 올바른 플랫폼으로 다시 패키징합니다.

```bash
TARGET_PLATFORM=linux/amd64 ./scripts/export-compose-images.sh
```

또는:

```bash
TARGET_PLATFORM=linux/arm64 ./scripts/export-compose-images.sh
```

---

## 17.4 포트 충돌

예:

```text
Host port is already in use: 80
```

해결 방법:

```text
기존 서비스를 중지하거나
docker-compose.override.yml로 포트를 변경
```

포트 변경 후 다시 검증합니다.

```bash
./scripts/preflight-onprem.sh
```

---

## 17.5 라이센스 오류

`license/license.json` 파일이 있는지 확인합니다.

```bash
ls -l license/license.json
```

JSON 형식이 올바른지 확인합니다.

```bash
jq empty license/license.json
```

`jq`가 없다면:

```bash
python3 -m json.tool license/license.json
```

---

## 17.6 브로커 `/vernemq/data/generated.configs` 권한 오류

예:

```text
Error creating /vernemq/data/generated.configs: permission denied
```

`broker/data` bind mount 소유권과 컨테이너 내부 `vernemq` 실행 UID가 맞지 않는 상태입니다.

먼저 preflight로 runtime 디렉터리 소유권을 준비합니다.

```bash
./scripts/preflight-onprem.sh
```

운영 계정의 UID/GID를 명시하려면 `.env`에 다음 값을 설정합니다.

```env
HOST_UID=1000
HOST_GID=1000
```

값을 생략한 경우 브로커 entrypoint는 `/vernemq/data`의 현재 소유자를 기준으로 `vernemq`
사용자 UID/GID를 맞춥니다.

---

## 17.7 브로커 `ulimit -n` 경고

예:

```text
WARNING: ulimit -n is 1024; 65536 is the recommended minimum.
```

`broker` 서비스는 Compose 설정에서 `nofile` soft/hard limit을 `65536`으로 지정합니다.
이 경고가 계속 보이면 서버 또는 Docker daemon의 ulimit 정책이 컨테이너 설정을 제한하는지
확인해야 합니다.

---

# 18. 스크립트 도움말

각 스크립트의 자세한 옵션은 `--help`로 확인할 수 있습니다.

```bash
./scripts/export-compose-images.sh --help
./scripts/load-compose-images.sh --help
./scripts/preflight-onprem.sh --help
./scripts/onprem-compose.sh --help
```

---

# 19. 지원

문제가 해결되지 않으면 로그와 함께 문의하세요.

```text
support@edencrew.com
```

문의 시 함께 전달하면 좋은 정보:

```text
./scripts/preflight-onprem.sh 실행 결과
docker compose ps -a 결과
docker compose logs --tail=200 결과
.env에서 비밀번호를 제거한 설정 내용
Docker / Docker Compose 버전
서버 CPU 아키텍처
```
