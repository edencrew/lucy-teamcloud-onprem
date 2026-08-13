# Lucy TeamCloud On-Premise Podman 설치 가이드

## 사전 요구사항

설치 서버:

- Podman
- `podman compose` 또는 `podman-compose`
- 최소 4GB RAM, 10GB 디스크 공간
- SELinux 사용 환경에서는 bind mount relabel 지원 필요

폐쇄망 bundle을 만드는 온라인 PC:

- 실행 중인 Docker daemon
- Docker Compose v2와 Buildx
- Docker API 1.48 이상(Docker Engine 28 이상)
- `docker save --platform` 지원

```bash
docker info
docker version
docker compose version
docker buildx version
docker save --help | grep -- --platform
```

Podman용 bundle도 온라인 PC에서는 Docker CLI로 생성합니다. 자세한 호환성은
[Docker image save](https://docs.docker.com/reference/cli/docker/image/save/)와
[Docker API version matrix](https://docs.docker.com/reference/api/engine/)를 확인하세요.

## 1. 환경 설정

이 문서는 TeamCloud 본체가 실행되는 internal/onprem 서버 기준입니다. DMZ 서버는
별도 서버이며 `dmz/README.podman.md`를 따릅니다.

`.env.example` 파일을 복사하여 `.env` 파일을 생성합니다.

```bash
cp .env.example .env
```

### 1.1 운영 port 결정

Podman 기본 compose는 rootless 환경을 고려해 gateway를 `18080:80`, `18443:443`으로
publish합니다. 실제 운영에서 다른 host port를 써야 하면 서비스를 실행하기 전에
`compose.podman.yml`의 `gw.ports`와 `.env` URL을 함께 수정하세요. `.env`의
`EXTERNAL_URL` port만 바꿔도 Podman publish port는 자동으로 바뀌지 않습니다.

아래 placeholder는 설명용입니다. 실제 `compose.podman.yml`과 `.env`에는 `<...>`를
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
  - "28080:80"
  - "28443:443"
```

HTTPS 운영 예:

```env
EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
```

rootless Podman에서 80/443 같은 privileged port를 쓰려면 OS 설정을 직접 조정해야
합니다. 특별한 이유가 없으면 `18080`, `18443`처럼 unprivileged port를 사용하세요.

방화벽은 단일 onprem 서버 구성 기준으로 client -> onprem gateway host port만
허용하면 됩니다. DB port `5432`, broker port `1883`, broker WebSocket port `8080`은
외부에 열지 마세요.

### 1.2 `.env` URL 예시

HTTP 예시:

```env
EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>
BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
PUBLIC_BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
```

HTTPS 예시:

```env
EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt
```

### 1.3 DMZ를 사용하는 경우

DMZ는 TeamCloud 전체가 아니라 MQTT-over-WebSocket `/mqtt`만 외부에 노출합니다.
TeamCloud 화면/API/Auth/Git 접속 주소는 onprem gateway URL로 유지하고, 외부
클라이언트가 broker에 붙는 주소만 DMZ URL로 분리합니다.

internal/onprem 서버의 `.env`에서는 `EXTERNAL_URL`과 `BROKER_WS_URL`을 onprem gateway
주소로 유지하고, `PUBLIC_BROKER_WS_URL`만 DMZ 서버 주소로 설정합니다. DMZ 서버의
port는 DMZ 서버의 compose 파일에서 별도로 설정합니다.

DMZ를 쓰지 않는 단일 서버 구성:

```env
EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>
BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
PUBLIC_BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
```

DMZ WSS를 사용하는 구성:

```env
EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>
BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
PUBLIC_BROKER_WS_URL=wss://<DMZ_HOST>:<DMZ_WSS_PORT>/mqtt
```

DMZ plain WS를 사용하는 테스트 구성:

```env
EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>
BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt
PUBLIC_BROKER_WS_URL=ws://<DMZ_HOST>:<DMZ_WS_PORT>/mqtt
```

onprem `compose.podman.yml`의 gateway port와 DMZ compose의 gateway port는 서로
다른 서버의 설정입니다. onprem port를 바꿨다고 DMZ port가 바뀌지 않고, DMZ port를
바꿨다고 onprem port가 바뀌지 않습니다.

DMZ 구성의 방화벽은 최소 아래 방향만 허용하세요.

- client -> internal/onprem 서버 UI/API gateway port
- mobile/client -> DMZ 서버 `/mqtt` gateway port
- DMZ 서버 -> internal/onprem 서버 `EXTERNAL_URL`/`BROKER_WS_URL` gateway port

internal broker port `1883`, broker WebSocket port `8080`, DB port `5432`는 DMZ나
외부 client에 직접 열지 마세요.

Linux 서버에서는 compose 실행 계정의 UID/GID를 확인해 `.env`에 설정합니다.

```bash
id
```

```env
HOST_UID=1000
HOST_GID=1000
```

아래 값들은 최초 실행 후 변경하지 마세요.

- `LUCY_ADMIN_EMAIL`
- `LUCY_ADMIN_PASSWORD`
- `LUCY_ADMIN_NAME`
- `DB_ROOT_PASSWORD`
- `DB_USERNAME`
- `DB_PASSWORD`

`DB_PASSWORD`는 PostgreSQL `DATABASE_URL`에 URL encoding 없이 포함됩니다. `.env`의
따옴표는 URI encoding을 대신하지 않으므로 `[A-Za-z0-9._~-]` 범위의 값을 사용하세요.

## 2. 라이센스 파일 배치

```bash
cp /path/to/your/license.json license/license.json
```

라이센스 파일이 없으면 `tc-be`가 시작 시 검증에 실패하여 종료됩니다.

## 3. 서비스 최초 실행

Podman Compose는 일회성 `init-secrets` 완료 대기를 안정적으로 처리하지 못하는 버전이
있습니다. 최초 설치에서는 `init-secrets`를 직접 한 번 실행한 뒤 전체 서비스를
올립니다.

### 3.1 public망 최초 설치

온라인 설치 서버에서는 로컬 `init-secrets` 이미지를 먼저 만들고, 나머지 이미지를
registry에서 받은 뒤 `init-secrets`와 전체 서비스를 순서대로 실행합니다.

```bash
podman build -t localhost/lucy-teamcloud-onprem-init-secrets:offline ./init-secrets &&
podman compose --env-file .env -f compose.podman.yml pull &&
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets &&
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

### 3.2 폐쇄망 최초 설치

[Offline Image Bundle 생성](#5-offline-image-bundle-생성)에 따라 동일한 export에서 나온
bundle 파일을 `<설치 루트>/images/`에 배치합니다. load부터 Compose 실행까지
같은 OS 사용자와 같은 rootless/rootful mode를 사용하세요. 기존 설치 루트로 이동한 뒤
아래 명령을 실행합니다.

```bash
./scripts/load-compose-images-podman.sh \
  ./images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz &&
podman compose --env-file .env -f compose.podman.init-secrets.yml \
  run --rm init-secrets &&
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

loader가 gzip, image 목록과 load된 image를 검증하고, `.sha256` 파일이 있으면
checksum도 확인합니다. loader 또는 `init-secrets`가 실패하면 `&&` 뒤의 명령은
진행되지 않습니다. `--no-build`는 pull을 금지하는 옵션이 아니므로 필요한 bundle을
같은 사용자 context에 먼저 load하는 것이 폐쇄망 실행의 전제입니다.

최초 실행 후 상태와 로그를 확인합니다.

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs -f
podman compose --env-file .env -f compose.podman.yml logs -f tc-be
```

중지:

```bash
podman compose --env-file .env -f compose.podman.yml down
```

운영 환경에서 `down -v`는 사용하지 마세요.

## 4. 이미지 버전 업데이트

이 절차는 서비스와 image repository가 그대로이고 기존 Compose의 `image:` tag만
바뀌는 이미지 중심 릴리스에만 적용합니다. 서비스나 image의 추가·삭제, repository
변경, 또는 다른 운영 파일 변경이 있으면 즉시 중단하고 해당 릴리스의 migration
안내를 따르세요.

이미지 중심 업데이트에서는 새 Compose 전체를 덮어쓰지 않습니다. 기존 설치의 `.env`,
`license/license.json`, `secrets/`, `nginx/certs/`, `postgres/data/`, `git/data/`,
`broker/data/`, `broker/logs/`, custom gateway port를 그대로 유지하고, 변경된 `image:`
tag만 기존 `compose.podman.yml`에 반영합니다. 업데이트 전에 stack을 내리지 않습니다.

현재 배포 이미지는 `linux/amd64` 서버 기준입니다. arm64 서버 native 실행은 현재
지원하지 않습니다.

### 4.1 public망 Podman 서버

새 릴리스에서 바뀐 `image:` tag만 기존 `compose.podman.yml`에 반영한 뒤 실행합니다.

```bash
podman compose --env-file .env -f compose.podman.yml config >/dev/null &&
podman compose --env-file .env -f compose.podman.yml pull &&
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

일반적인 이미지 업데이트에서는 `init-secrets` 이미지를 build하거나 `init-secrets`를
다시 실행하지 않습니다. 산출물이 없거나 릴리스 안내가 명시한 경우에만 별도로
처리하세요. `--no-build`는 pull을 금지하지 않으므로 위 `pull`이 성공한 뒤 기동합니다.

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs --tail=100 tc-be
```

### 4.2 폐쇄망 Podman 서버

온라인 PC에서 배포할 정확한 release ref를 checkout한 뒤
[Offline Image Bundle 생성](#5-offline-image-bundle-생성)에 따라 Podman용 bundle을
생성합니다. 운영 서버용 `.env`와 license는 export PC에 필요하지 않습니다.

같은 export에서 생성된 아래 세 파일을 이름을 바꾸지 않고 함께
`<기존 설치 루트>/images/`에 복사합니다.

```text
lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz
lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz.sha256
lucy-teamcloud-onprem-podman-images-linux-amd64.images.txt
```

새 릴리스의 변경된 `image:` tag만 기존 `compose.podman.yml`에 반영합니다. 새 Compose
전체를 복사하지 마세요. compose tag와 bundle은 반드시 같은 릴리스에서 가져와야
합니다. 그 다음 설치 루트에서 아래 명령을 실행합니다.

```bash
./scripts/load-compose-images-podman.sh \
  ./images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz &&
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

loader가 gzip, image 목록과 load된 image를 검증하고, `.sha256` 파일이 있으면
checksum도 확인합니다. loader가 실패하면 `&&` 뒤의 `up`은 실행되지 않습니다. load와
Compose는 같은 OS 사용자와 같은 rootless/rootful mode에서 실행하세요. 일반적인 이미지
업데이트에서는 `init-secrets`를 다시 실행하지 않습니다.

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs --tail=100 tc-be
```

Docker용 archive는 Podman 설치에 사용하지 마세요. 전체 stack을 미리 내리거나
`down -v`를 실행하지 않습니다.

## 5. Offline Image Bundle 생성

온라인 PC의 소스 루트에서 배포할 정확한 release ref를 checkout한 뒤 export합니다.
export 스크립트는 Docker CLI로 `compose.podman.yml`과
`compose.podman.init-secrets.yml`을 함께 읽고, `init-secrets` 이미지를 `linux/amd64`로
build합니다. 운영 서버용 `.env`와 license는 필요하지 않습니다.

```bash
# 아래 값을 실제 배포 tag 또는 commit으로 바꾸세요.
RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
git checkout --detach "$RELEASE_REF" &&
./scripts/export-compose-images-podman.sh
```

기본 출력 위치는 `<소스 루트>/images/`입니다. archive 기준 이름을 `X`라고 할 때
다음 세 파일을 함께 전송합니다.

```text
X.tar.gz
X.tar.gz.sha256
X.images.txt
```

`X.tar.gz`와 `X.images.txt`는 load에 필요합니다. `X.tar.gz.sha256`은 손상 확인을 위해
함께 전송하는 것을 권장하며, 없으면 loader가 경고 후 진행합니다.
`X.archive-images.txt`와 `X.services.txt`는 진단용 선택 파일입니다. 전송하는 파일은
같은 export에서 생성된 동일한 `X` stem의 세트여야 하며 이름을 바꾸지 마세요.

폐쇄망 서버에서는 전송한 파일을 `<설치 루트>/images/`에 보관합니다. 이 디렉터리는
전송 archive 보관 위치이며 Compose가 archive를 직접 참조하지 않습니다. loader가
archive의 실제 이미지를 같은 사용자 context의 Podman local image store에 등록합니다.

최초 설치는 [폐쇄망 최초 설치](#32-폐쇄망-최초-설치), 기존 설치 업데이트는
[폐쇄망 Podman 서버](#42-폐쇄망-podman-서버)의 load와 실행 절차를 따르세요.
Docker용 archive는 Podman 설치에 사용하지 마세요. Podman용 bundle에는
`localhost/lucy-teamcloud-onprem-init-secrets:offline` 이미지가 포함됩니다.

Podman Compose에서는 Docker Compose의 `--pull never` 옵션을 쓰지 마세요. 일부
`podman-compose` 버전은 `never`를 서비스명으로 해석합니다. `--no-build`도 pull을
금지하지 않으므로 폐쇄망에서는 같은 릴리스의 compose tag와 bundle, 성공한 load를
실행 전제조건으로 둡니다.

## 6. 인증서와 시크릿

서비스 실행 전에 수동으로 실행한 `init-secrets`가 다음 파일을 생성합니다.

- `secrets/secrets.env`
- `nginx/certs/server.crt`
- `nginx/certs/server.key`

운영 인증서를 사용하는 경우 파일을 직접 교체한 뒤 gateway를 재시작합니다.

```bash
cp /path/to/server.crt nginx/certs/server.crt
cp /path/to/server.key nginx/certs/server.key
podman compose --env-file .env -f compose.podman.yml restart gw
```

`EXTERNAL_URL` host를 바꾼 경우 기존 self-signed 인증서와 맞지 않을 수 있습니다.
아래 절차는 `init-secrets`가 생성한 self-signed 인증서에만 사용하세요. 운영 인증서는
삭제하지 말고 새 인증서를 준비해 교체합니다.

```bash
rm -f nginx/certs/server.crt nginx/certs/server.key &&
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets &&
podman compose --env-file .env -f compose.podman.yml restart gw
```

## 7. Podman 운영 메모

`compose.podman.yml`은 bind mount에 SELinux relabel 옵션 `:z`를 포함합니다.
SELinux를 사용하는 rootless Podman 환경에서는 이 옵션을 유지하세요.

rootless Podman에서 80/443 같은 privileged port를 쓰려면 OS 설정을 직접 조정해야
합니다. 기본값인 18080/18443 사용을 권장합니다.

Podman에서 volume 디렉터리 소유자가 host UID와 다르게 보일 수 있습니다. 이는 user
namespace 매핑의 결과일 수 있으므로 임의로 `chown`하기 전에 컨테이너 로그와
SELinux label을 먼저 확인하세요.

## 8. 백업 대상

필수 백업:

- `.env`
- `license/license.json`
- `secrets/secrets.env`
- `postgres/data/`
- `git/data/`

권장 백업:

- `nginx/certs/`
- `broker/data/`
- `broker/logs/`

백업 예시:

```bash
podman compose --env-file .env -f compose.podman.yml down
tar -czvf backup-$(date +%Y%m%d).tar.gz \
  .env license/license.json secrets nginx/certs postgres/data git/data broker/data broker/logs
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

## 9. 문제 해결

Compose config:

```bash
podman compose --env-file .env -f compose.podman.yml config
```

서비스별 로그:

```bash
podman compose --env-file .env -f compose.podman.yml logs -f tc-be
podman compose --env-file .env -f compose.podman.yml logs -f gw
```

컨테이너 상태:

```bash
podman compose --env-file .env -f compose.podman.yml ps -a
podman ps -a
```

Podman 시작 전에 host의 `/etc/resolv.conf`가 존재하는지도 확인하세요.

## 10. 알려진 문제

### 이미지 export 중 `unknown flag: --platform` 오류

아래 오류가 나오면 이미지를 만드는 PC의 Docker가 오래된 상태입니다.

```text
unknown flag: --platform
See 'docker save --help'.
```

Podman용 archive export도 온라인 PC에서는 Docker CLI를 사용합니다. 이미지 다운로드
문제가 아니므로 Docker Desktop 또는 Docker Engine을 요구 버전으로 업데이트한 뒤,
배포할 정확한 release ref에서 export를 다시 실행하세요.

```bash
(
  set -e
  docker save --help | grep -- --platform
  cd lucy-teamcloud-onprem
  RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
  git checkout --detach "$RELEASE_REF"
  ./scripts/export-compose-images-podman.sh
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
  ./scripts/export-compose-images-podman.sh
)
```

### `init-secrets` 산출물이 없을 때

다음 파일이 없으면 서비스 기동을 중단하고 `init-secrets`를 먼저 실행하세요.

```bash
ls -l secrets/secrets.env nginx/certs/server.crt nginx/certs/server.key
```

폐쇄망 환경:

```bash
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets &&
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

`compose.podman.init-secrets.yml`은 네트워크가 필요 없는 일회성 컨테이너이므로
`network_mode: none`으로 실행합니다. 그래도 사용 중인 `podman-compose`가 네트워크를
만들려고 하며 실패하면 아래 fallback으로 산출물만 먼저 생성할 수 있습니다.

```bash
podman run --network none --rm --env-file .env \
  -v "$PWD/secrets:/secrets:z" \
  -v "$PWD/nginx/certs:/certs:z" \
  localhost/lucy-teamcloud-onprem-init-secrets:offline
```

### `netavark`, `ip_tables`, `iptables nat` 오류

다음 오류는 이미지 로드 문제가 아니라 host Podman 네트워크 준비 문제입니다.

```text
netavark: code: 3, msg: modprobe: ERROR: could not insert 'ip_tables': Operation not permitted
iptables: can't initialize iptables table `nat'
```

`init-secrets`는 네트워크 없이 실행되도록 분리되어 있습니다. 전체 stack 실행에서 같은
오류가 나면 실제 서비스 네트워크를 만들 수 없는 상태입니다. 다음 읽기 전용 정보만
수집하세요.

```bash
podman info --debug
lsmod | grep -E 'ip_tables|iptable_nat|nf_nat|br_netfilter'
```

host kernel module, iptables/nftables, Podman/netavark와 rootless 네트워크 정책은
플랫폼 관리자 범위입니다. 이 가이드에서 host 설정을 변경하지 말고 수집한 결과와 함께
확인을 요청하세요.

### `db`, `tc-fe` 같은 service name을 찾지 못할 때

`auth-be`가 `db:5432`에 접속하지 못하거나 `gw`가 `tc-fe:80`을 찾지 못하면 앱보다
Podman network DNS를 먼저 확인하세요.

```bash
podman info | grep -i network -A10
podman network ls
podman network inspect lucy-teamcloud-onprem_internal-network | grep -i dns
```

정상 기대값은 `networkBackend: netavark`와 `dns_enabled: true`입니다. 값이 다르거나
`aardvark-dns` 상태가 의심되면 위 출력을 보존하고 플랫폼 관리자에게 netavark,
aardvark-dns, `/etc/containers/containers.conf`를 확인해 달라고 요청하세요. 승인된
maintenance 절차 없이 기존 네트워크를 삭제하거나 재생성하지 않습니다.

### `aardvark-dns runs in a different netns`

이 메시지는 이전 rootless Podman 세션의 runtime state가 남았거나
`/run/user/<uid>/netns`가 정리된 상태에서 발생할 수 있습니다. 다음 상태를 읽기 전용으로
수집하세요.

```bash
id
printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-<unset>}"
podman info --debug
podman ps -a
podman network ls
podman network inspect lucy-teamcloud-onprem_internal-network
```

광범위한 컨테이너 삭제나 사용자 프로세스 종료, runtime state 재번호 부여는 관련 없는
Podman workload에도 영향을 줄 수 있으므로 이 가이드에서 수행하지 않습니다. 수집한
결과를 플랫폼 관리자에게 전달하고 승인된 복구 절차를 따르세요.

### SSH 세션 종료 후 컨테이너가 내려갈 때

rootless Podman을 SSH 세션에서 직접 실행하면 보안 정책이나 logind 설정에 따라
`/run/user/<uid>`가 정리되면서 컨테이너가 종료될 수 있습니다.

```bash
loginctl show-user "$(whoami)" -p Linger -p RuntimePath -p State
```

장기 운영 계정은 직접 SSH 로그인 계정이어야 하며, `su - <user>`로 들어간 shell에서
rootless Podman을 장기 운영하지 마세요. linger, systemd user service, rootful Podman,
Docker 중 승인된 운영 방식을 플랫폼 관리자에게 확인하세요. 이 가이드에서 logind
설정을 변경하지 않습니다.

### `/etc/resolv.conf`가 없을 때

다음 오류는 애플리케이션 문제가 아니라 host OS 준비 문제입니다.

```text
failed to stat resolv.conf path: lstat /etc/resolv.conf: no such file or directory
```

다음 읽기 전용 정보로 파일과 symlink 상태를 확인하세요.

```bash
ls -l /etc/resolv.conf
readlink -f /etc/resolv.conf
```

파일이 없거나 깨진 symlink이면 OS 관리자가 배포판의 resolver 관리 방식에 맞게
복구해야 합니다. 이 가이드에서 `/etc/resolv.conf`를 생성하거나 덮어쓰지 않습니다.

### privileged port 또는 unsafe port 문제

rootless Podman은 기본적으로 host의 80/443 같은 privileged port를 publish할 수
없습니다. `compose.podman.yml`은 기본값으로 `18080:80`, `18443:443`을 사용합니다.
포트를 바꾸면 [운영 port 결정](#11-운영-port-결정)의 순서대로 `.env`의 URL도 같은
port로 맞추세요.

Chrome은 일부 port를 `ERR_UNSAFE_PORT`로 차단합니다. 예를 들어 `10080` 대신
`18080`처럼 브라우저가 허용하는 port를 사용하세요.

### 컨테이너 내부 80 bind 권한

`auth-be`, `tc-be`는 Podman 환경에서 내부 port 80 bind 권한 문제를 피하기 위해
`user: "0:0"`으로 실행합니다. `git`은 내부 `18080`을 사용합니다. 이 설정을 임의로
제거하면 `listen EACCES: permission denied 0.0.0.0:80` 오류가 날 수 있습니다.

### bind mount 권한과 SELinux

`compose.podman.yml`은 bind mount에 `:z`를 포함하지만, 이는 SELinux label 처리입니다.
파일 소유권 문제까지 모두 해결하는 것은 아닙니다. `postgres/data`, `git/data`,
`broker/data`, `broker/logs`에서 permission denied가 발생하면 먼저 정확한 경로와
서비스 로그를 확인하세요.

```bash
podman compose --env-file .env -f compose.podman.yml ps -a
podman compose --env-file .env -f compose.podman.yml logs --tail=100 db git broker
ls -ldZ postgres/data git/data broker/data broker/logs
```

이미지별 UID/GID와 user namespace 매핑을 확인하지 않은 `chown`은 상태를 악화시킬 수
있습니다. 위 결과를 보존하고 플랫폼 관리자에게 소유권과 SELinux 정책 확인을
요청하세요.

### `podman-compose ps -q <service>` 미지원

일부 `podman-compose` 버전은 Docker Compose처럼 `ps -q db` 형식을 지원하지 않습니다.
디버깅할 때는 compose 로그와 `podman ps --filter name=...`를 사용하세요.

### port env interpolation

일부 `podman-compose` 버전은 `ports` 항목에서 `${HTTP_PORT}` 같은 env interpolation을
제대로 처리하지 못합니다. 이 repo는 port env를 사용하지 않고
`compose.podman.yml`에 고정 port를 둡니다. 포트를 변경하려면 compose 파일의
`ports`와 `.env` URL을 함께 수정하세요.

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
podman compose --env-file .env -f compose.podman.yml ps -a
podman compose --env-file .env -f compose.podman.yml logs --tail=100 db
```

로그에 `/docker-entrypoint-initdb.d/` 또는 `permission denied`가 보이면 아래
`postgres/initdb` 권한 문제 해결 절차를 진행하세요.

### `postgres/initdb` permission denied

다음 오류는 host 파일 권한 또는 SELinux label 문제입니다.

```text
ls: cannot open directory '/docker-entrypoint-initdb.d/': Permission denied
```

정확한 파일 mode와 SELinux label을 먼저 확인하세요.

```bash
namei -l postgres/initdb/01-create-user.sh
ls -ldZ postgres postgres/initdb postgres/initdb/01-create-user.sh
getenforce
```

packaged script의 실행 bit가 사라진 것이 확인된 경우에만 설치 루트 안의 정확한 경로를
복구합니다.

```bash
chmod 755 postgres postgres/initdb postgres/initdb/01-create-user.sh
```

Compose mount에는 `:ro,z`가 있으므로 임의의 광범위한 `chcon`을 실행하지 마세요. mode를
복구한 뒤에도 SELinux denial이 계속되면 위 진단 결과와 audit log를 플랫폼 관리자에게
전달하세요.
