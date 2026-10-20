# Lucy TeamCloud On-Premise

이 브랜치는 최소 운영 구조만 제공합니다. 자동 환경 검증과 compose wrapper는
제공하지 않습니다. 운영자는 Docker 또는 Podman 환경을 직접 준비하고, 선택한
compose 파일로 서비스를 실행합니다.

## 설치 가이드

- Docker 환경: [README.docker.md](README.docker.md)
- Podman 환경: [README.podman.md](README.podman.md)

## 파일 구조

```text
compose.docker.yml   # Docker용 standalone compose
compose.podman.yml   # Podman용 standalone compose, SELinux :z mount 포함
compose.podman.init-secrets.yml
studio-dl/nginx.conf # studio-dl(공식 nginx)이 업로드된 Studio 릴리스를 서빙하는 설정
dmz/
  compose.docker.yml      # Docker용 plain WS 기본 compose
  compose.docker.wss.yml  # Docker용 WSS compose
  compose.podman.yml      # Podman용 plain WS 기본 compose
  compose.podman.wss.yml  # Podman용 WSS compose
  README.docker.md
  README.podman.md
scripts/
  export-compose-images-docker.sh
  export-compose-images-podman.sh
  load-compose-images-docker.sh
  load-compose-images-podman.sh
  studio-upload.sh         # Studio 번들을 TC 에 업로드
images/                    # export 시 생성되는 image bundle 디렉터리, Git에는 포함되지 않음
```

## 최초 설치 준비

아래 작업은 **최초 설치할 때만** 수행합니다. 기존 설치의 버전을 업데이트할 때는
`.env`를 다시 만들거나 license, secrets, 인증서, 데이터 파일을 교체하지 않습니다.

```bash
cp .env.example .env
vi .env
cp /path/to/license.json license/license.json
```

`.env`의 `EXTERNAL_URL`, `BROKER_WS_URL`, `PUBLIC_BROKER_WS_URL`은 실제
사용자가 접속하는 host/port와 일치해야 합니다.

상세 README의 `<ONPREM_HOST>`, `<ONPREM_HTTP_PORT>`, `<ONPREM_HTTPS_PORT>`,
`<DMZ_HOST>`, `<DMZ_WS_PORT>`, `<DMZ_WSS_PORT>`는 설명용 placeholder입니다. 실제
`.env`와 compose 파일에는 운영 환경의 실제 host/domain과 숫자 port로 바꿔 입력하세요.

## 기존 폐쇄망 설치의 이미지 버전 업데이트

이 절차는 서비스와 image repository는 그대로이고 compose의 `image:` tag만 바뀌는
**이미지 중심 릴리스**에만 사용합니다. 서비스나 image가 추가/삭제되거나 image
repository 또는 다른 운영 파일이 바뀌면 이 절차를 중단하고 해당 릴리스의 migration
안내를 따르세요.

업데이트 작업은 온라인 PC와 폐쇄망 설치 서버로 나뉩니다.

1. 온라인 PC에서 배포할 정확한 release ref를 checkout하고 대상 runtime용 image
   bundle을 생성합니다. 온라인 PC에는 운영 `.env`와 license가 필요하지 않습니다.
2. 같은 export에서 생성된 archive, `.images.txt`, `.sha256` 파일을 폐쇄망 서버의
   `<기존 설치 루트>/images/`로 함께 복사합니다.
3. 폐쇄망 서버의 기존 compose 전체를 교체하지 말고 새 릴리스에서 변경된 `image:`
   tag만 수정합니다. 기존 `.env`, license, secrets, 인증서, 데이터와 custom port는
   그대로 유지합니다.
4. compose에 반영한 tag와 같은 릴리스에서 생성한 bundle을 runtime별 loader로
   load합니다. 서로 다른 릴리스의 compose tag와 bundle 파일을 섞지 마세요.
5. loader가 gzip과 image를 검증하고, `.sha256`이 있으면 checksum도 확인한 뒤에만
   `up -d`를 실행하고
   상태와 `tc-be` 로그를 확인합니다. 업데이트 전에 stack을 내릴 필요가 없으며
   `down -v`는 사용하지 않습니다.

실제 load와 재기동 명령은 runtime별 가이드를 따릅니다.

- Docker: [README.docker.md의 버전 업데이트 절차](README.docker.md#6-이미지-버전-업데이트)
- Podman: [README.podman.md의 버전 업데이트 절차](README.podman.md#4-이미지-버전-업데이트)

## Offline Image Bundle 생성

온라인 PC에서 대상 runtime에 맞는 image bundle을 생성합니다. 두 export 스크립트 모두
Podman이 아니라 다음 기능을 갖춘 Docker 환경을 사용합니다.

- 실행 중인 Docker daemon
- Docker Compose v2
- Docker Buildx
- Docker Engine API 1.48 이상(Docker Engine 28 이상)과 `docker save --platform` 지원

기능 확인:

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

배포할 정확한 release ref를 checkout한 소스 루트에서 대상 runtime 명령 하나만
실행합니다.

```bash
# 아래 값을 실제 배포 tag 또는 commit으로 바꾸세요.
RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
git checkout --detach "$RELEASE_REF" &&
./scripts/export-compose-images-docker.sh
```

```bash
# 아래 값을 실제 배포 tag 또는 commit으로 바꾸세요.
RELEASE_REF='REPLACE_WITH_RELEASE_TAG_OR_COMMIT'
git checkout --detach "$RELEASE_REF" &&
./scripts/export-compose-images-podman.sh
```

Docker용 archive와 Podman용 archive는 `init-secrets` 이미지명이 다르므로 서로 바꿔
쓰지 않습니다.

export 결과는 온라인 소스 루트의 `images/`에 생성됩니다. 파일 이름의 기준 부분을
`X`라고 할 때 다음 세 파일을 함께 전송합니다.

- `X.tar.gz`
- `X.tar.gz.sha256`
- `X.images.txt`

Docker의 `X`는 `lucy-teamcloud-onprem-docker-images-linux-amd64`, Podman의 `X`는
`lucy-teamcloud-onprem-podman-images-linux-amd64`입니다. `X.tar.gz`와 `X.images.txt`는
load에 필요합니다. `X.tar.gz.sha256`은 손상 확인을 위해 함께 전송하는 것을 권장하며,
없으면 loader가 경고 후 진행합니다. 세 파일을 전송할 때는 같은 export에서 생성된
이름 그대로 옮기세요. `X.archive-images.txt`와 `X.services.txt`는 진단용 파일이며
load에 필요하지 않습니다.

폐쇄망 서버에서는 기존 설치 루트 아래에 `images/`를 준비합니다.

```bash
# 아래 값을 실제 기존 설치 루트의 절대 경로로 바꾸세요.
INSTALL_ROOT='/absolute/path/to/lucy-teamcloud-onprem'
cd "$INSTALL_ROOT" && mkdir -p images
```

`images/`는 compose가 직접 읽는 디렉터리가 아닙니다. runtime별 loader가 archive를
Docker 또는 Podman의 로컬 image store에 등록하고, compose는 같은 이름과 tag의 로컬
image를 사용합니다. load와 재기동은 runtime별 최초 설치 또는 버전 업데이트 절차에서
수행합니다.

## 백업 대상

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

## Studio 릴리스 업로드

사내 Studio 의 새 버전은 Edencrew 가 전달한 Studio 번들 파일(`.tar` / `.tar.gz` / `.zip`, 약 1.1GB)을
TC 에 올려 배포합니다. TC 가 번들을 검증해 `studio-release` 볼륨에 풀고, `/studio/` 가 그 버전을
서빙하면 사내 Studio 가 다음 실행 때 자동으로 업데이트합니다.

Studio 배포는 이 업로드 방식으로만 하며, Studio 버전마다 패키지 이미지를 바꾸지 않습니다. `studio-dl` 은 공식
nginx 이미지에 `studio-dl/nginx.conf` 를 붙인 것이라 별도 Studio 이미지를 반입할 필요가 없습니다. 패키지를
설치하거나 이 방식으로 처음 바꾼 뒤 **첫 업로드 전까지는 `/studio/*` 가 404** 이므로, 기동 후 바로 번들을 올립니다.

> **주의**: 지금 패키지가 고정한 `tc-be` 이미지(`onprem-prod-0.0.21`)에는 업로드 API 가 없어 업로드 경로가
> 404 를 냅니다. 업로드 API 가 들어간 `tc-be` 이미지가 발행되면 그 tag 로 올린 패키지를 써야 합니다.

### 올리기

1. **PAT 발급**: 조직 **owner** 계정으로 TC 웹 → 액세스 토큰 화면에서 scope **`api`**, 만료 **당일**로
   토큰을 만듭니다. `api` scope 토큰은 그 계정의 API 전체를 쓸 수 있으므로 업로드 후 바로 폐기합니다.
2. **업로드**: 스크립트가 토큰을 숨김 입력으로 묻습니다.
   ```bash
   ./scripts/studio-upload.sh /path/to/lucy-studio-onprem-0.0.35.360.tar.gz https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
   # 자체 서명 인증서면
   CACERT=nginx/certs/server.crt ./scripts/studio-upload.sh <번들 파일> https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>
   ```
   TC 주소를 생략하면 환경변수 `EXTERNAL_URL` 을 쓰고, 그것도 없으면 입력을 받습니다.
   업로드 후 서버가 압축 해제와 해시 검증을 하므로 응답까지 몇 분 걸릴 수 있습니다.
3. **확인**: 응답의 `version`·`build` 가 올린 번들과 같은지, `https://<TC 주소>/studio/latest.json` 이
   같은 값을 돌려주는지 봅니다.
4. **PAT 폐기**: 액세스 토큰 화면에서 지웁니다.

직접 `curl` 로 올릴 때는 `Content-Type: application/octet-stream` 을 반드시 붙입니다(없으면 415).
`--data-binary @파일` 은 파일 전체를 메모리에 올리므로 `-T` 로 보냅니다.

```bash
curl --fail-with-body -X POST "https://<TC 주소>/api/v1/onprem/studio-releases" \
  -H "Authorization: Bearer <PAT>" \
  -H "Content-Type: application/octet-stream" \
  -T lucy-studio-onprem-0.0.35.360.tar.gz
```

### 되돌리기

새 버전에 문제가 있으면 **직전 버전 1개**로 되돌릴 수 있습니다.

```bash
# 보관본 확인: releases[] 에서 active 가 false 인 releaseId
curl -H "Authorization: Bearer <PAT>" "https://<TC 주소>/api/v1/onprem/studio-releases"

curl -X POST -H "Authorization: Bearer <PAT>" \
  "https://<TC 주소>/api/v1/onprem/studio-releases/<releaseId>/activate"
```

이미 새 버전으로 업데이트한 PC 는 돌아오지 않습니다(Studio 자동 업데이트는 다운그레이드하지 않음).
되돌리기는 아직 업데이트하지 않은 PC 와 신규 설치를 지키는 확산 중단 수단입니다. 방금 내린 버전도 보관되므로
다시 activate 해 앞으로 돌아갈 수 있습니다.

### 오류

| 응답 | 원인 → 조치 |
|------|-------------|
| 403 | owner 가 아님 → owner 계정의 PAT 로 다시 |
| 409 `STUDIO_RELEASE_BUSY` | 다른 업로드·되돌리기 진행 중 → 끝난 뒤 다시 |
| 409 `STUDIO_RELEASE_BUILD_DOWNGRADE` | 서빙 중인 것보다 낮은 빌드 → 되돌리기는 activate 로 |
| 413 | 4GiB 초과. 본문이 nginx HTML 이면 gw 한도(`nginx/nginx.conf` 의 업로드 location) |
| 415 | `Content-Type: application/octet-stream` 누락 |
| 400 `STUDIO_BUNDLE_REJECTED`, `..._MANIFEST_FILE_MISMATCH` | 형식 오류 또는 반입 중 손상 → 원본 해시 확인 후 다시 반입 |
| 400 `STUDIO_RELEASE_INVALID_MANIFEST` | SaaS 용 번들 등 → 온프렘용 번들인지 확인 |
| 400 `STUDIO_RELEASE_INVALID_BASE_URL` | `.env` 의 `EXTERNAL_URL` 이 http(s) 주소가 아님 |
| 503 `STUDIO_RELEASE_STORAGE_NOT_CONFIGURED` | compose 에 `studio-release` 볼륨이 없음(구버전 패키지) |

업로드는 됐는데 Studio 가 업데이트를 못 찾으면 `/studio/macos/appcast.xml` 과
`/studio/windows/LucyStudio.appinstaller` 안의 URL 이 실제 접속 주소로 시작하는지 봅니다. `EXTERNAL_URL` 을
바꿨다면 `tc-be` 를 재기동하면 피드가 새 주소로 다시 만들어집니다.

### 저장 위치

업로드한 릴리스는 named volume `studio-release` 에 있습니다(활성 + 직전 버전 2개 분량, 업로드 중에는 일시적으로
번들 크기만큼 더). 번들을 다시 올리면 복구되므로 백업 대상은 아니지만, `down -v` 를 하면 지워집니다.

## DMZ MQTT Proxy

DMZ 서버에서 모바일 클라이언트용 MQTT-over-WebSocket만 외부에 노출해야 하면
`dmz/` 디렉터리의 가이드를 사용합니다.

- Docker 환경: [dmz/README.docker.md](dmz/README.docker.md)
- Podman 환경: [dmz/README.podman.md](dmz/README.podman.md)
