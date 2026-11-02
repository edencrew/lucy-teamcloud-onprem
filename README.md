# Lucy TeamCloud On-Premise

미릴리스 설치기 재설계의 범위·검증은 [README.infra-redesign.md](README.infra-redesign.md)에 있습니다.
설치기의 미출시 변경과 검증 범위는 [설치기 변경 검토](README.installer-contract.md)에
정리했습니다. 공개 설치본에 이미 적용된 기능을 설명하는 문서는 아닙니다.
새 format 2 키트는 최초 TUI 설치 후 ROOT의 `bin/teamcloudctl`로 운영합니다.
기존 공개 v0.0.22 JSON 설치는 채택 검증 전까지 기존 절차와 파일을 보존합니다.

Lucy TeamCloud(TC)를 고객 서버에 설치하고 운영하기 위한 Compose 설정과 스크립트입니다.
Docker나 Podman 중 서버에서 사용하는 런타임의 안내서를 따르면 됩니다.

현재 설치기와 TC 안내서는 Linux amd64(`linux/amd64`) 기준입니다. arm64 TC 설치는
아직 확인하지 않았습니다. 이 문서에서 이미지 번들은 폐쇄망에 반입할 이미지 묶음,
릴리스는 함께 배포하는 소스와 이미지의 버전을 뜻합니다.

서비스 구성은 다음과 같습니다.

- Docker: `compose.docker.yml`은 상시 서비스 base, `compose.docker.init-secrets.yml`은 일회성 초기화 전용
- Podman: `compose.podman.yml`에 상시 서비스 9개, `compose.podman.init-secrets.yml`에 초기화 서비스 1개
- 상시 서비스: `gw`(nginx 게이트웨이), `db`(PostgreSQL), `git`(Gitea), `broker`(Mosquitto),
  `auth-be`, `auth-fe`, `tc-be`, `tc-fe`, `studio-dl`(Studio 다운로드 파일 제공)

## 배치 방식 고르기

| 배치 | 언제 | 따를 문서 |
|------|------|-----------|
| TC 본체 직접 설치 | TC 서버 한 대가 화면·API·`/mqtt`를 모두 제공. TC 본체를 DMZ 망 서버에 두는 경우도 여기에 해당 | 이 문서 + Docker/Podman 안내서 |
| TC 본체 + 별도 DMZ MQTT 프록시 | TC 본체는 내부망에 두고, 외부 모바일 클라이언트용 MQTT-over-WebSocket(`/mqtt`)만 DMZ 서버의 프록시로 노출 | TC 본체: Docker/Podman 안내서, DMZ 서버: [dmz/README.md](dmz/README.md) |

DMZ 프록시는 TC 전체를 중계하지 않습니다. 화면·API·Auth·Git 주소(`EXTERNAL_URL`)는 TC
본체 게이트웨이를 그대로 쓰고, 외부 클라이언트가 브로커에 붙는 주소(`PUBLIC_BROKER_WS_URL`)만
DMZ 주소로 바꿉니다. URL 예시는 각 런타임 안내서의 "4.3 호스트 포트와 URL" 절에 있습니다.
DMZ 프록시 구성은 수동 설치에서만 설정할 수 있으며 TUI는 지원하지 않습니다.

## 작업 고르기

| 하려는 일 | 경로 |
|-----------|------|
| 폐쇄망에 처음 설치, 설치 키트와 라이선스만 반입 | [README.installer.md](README.installer.md) |
| 새 서버에 처음 설치, 명령을 직접 실행 | [최초 설치 준비](#최초-설치-준비) → Docker [4. 수동 설치](README.docker.md#4-수동-설치) 또는 Podman [4. 수동 설치](README.podman.md#4-수동-설치) |
| 이미 설치된 TC의 이미지 버전 올리기 | [기존 설치 업데이트](#기존-설치-업데이트) (TUI는 업데이트를 하지 않음) |
| 사내 Studio 새 버전 배포 | [Studio 릴리스 업로드](#studio-릴리스-업로드) |
| DMZ MQTT 프록시 설치 | [dmz/README.md](dmz/README.md) |
| 개발 PC에서 Studio 서빙만 검증 | [dev/studio-dist-local/README.md](dev/studio-dist-local/README.md) — 운영 설치용이 아님 |

## 파일과 이미지 위치

안내서 전체에서 아래 네 역할을 구분합니다. 수동 설치에서는 소스 사본을 설치 루트로
사용할 수 있지만, TUI의 소스와 새 설치 경로는 서로 달라야 합니다.

| 이름 | 무엇 | 예시 |
|------|------|------|
| 소스 루트(`SOURCE_DIR`) | 이 저장소를 배포할 릴리스 태그로 체크아웃하거나 Release "Source code" 압축 파일을 푼 곳. 온라인 PC에서 이미지 번들을 만들 때, TUI의 `--source`로 쓸 때 사용 | `/opt/src/lucy-teamcloud-onprem-0.0.22` |
| 설치 루트(`INSTALL_ROOT`) | 서버에서 실제로 Compose를 실행하는 디렉터리. `.env`, `license/`, `secrets/`, `nginx/certs/`, `postgres/data/` 등 운영 상태가 여기 쌓임. 모든 운영 명령은 여기서 실행 | `/opt/lucy-teamcloud-onprem` |
| 이미지 압축 파일 | 온라인 PC에서 만든 이미지 번들 세 파일. 서버에서는 `<INSTALL_ROOT>/images/`에 둠. Compose가 직접 읽지 않음 | `images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz` |
| 엔진 이미지 저장소 | Docker 데몬 또는 Podman(실행한 OS 사용자·rootless/rootful 모드별) 내부의 이미지 저장소. 로더가 압축 파일을 여기에 등록하고 Compose는 여기서 이미지를 찾음 | `docker image ls`, `podman image ls`로 확인 |

수동 설치에서는 릴리스 소스를 서버로 옮긴 사본이 곧 설치 루트가 됩니다. TUI는 소스
루트를 읽어 별도의 새 설치 루트를 만듭니다.

## TUI 설치기

폐쇄망 신규 설치는 [README.installer.md](README.installer.md)를 따릅니다. Docker 또는 Podman이
준비된 서버에 해당 런타임의 오프라인 키트와 체크섬, 발급 라이선스를 반입하면 됩니다.
소스와 이미지가 키트에 들어 있어 설치 서버에서 다운로드하거나 빌드하지 않습니다.

두 키트는 [Release v0.0.22](https://github.com/edencrew/lucy-teamcloud-onprem/releases/tag/v0.0.22)에
첨부되어 있습니다. 서버 런타임과 같은 키트 하나를 받으며, 다른 런타임의 키트를 섞어 쓰지 않습니다.

| 런타임 | 오프라인 설치 키트 | 체크섬 | 포함 내용 |
|--------|--------------------|--------|-----------|
| Docker | [`teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz) | [`.sha256`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz.sha256) | Docker용 설치기·Compose 실행 파일·배포 소스·컨테이너 이미지 |
| Podman | [`teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz) | [`.sha256`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz.sha256) | Podman용 설치기·Compose 실행 파일·배포 소스·컨테이너 이미지 |

같은 Release의 `teamcloud-installer-v0.0.22-linux-amd64.tar.gz`(+ `.sha256`)는 실행 도구만 든
약 14MB 설치기 압축 파일로, 그 파일과 라이선스만으로는 폐쇄망 설치를 끝낼 수 없습니다. 이 파일은
소스와 이미지 번들을 따로 준비하는 런타임별 안내서의 기존 절차에서 씁니다. 발급 라이선스
(`license.json`)는 키트와 Release에 들어 있지 않으므로 별도로 전달받습니다.

Release의 "Source code" 압축 파일은 태그 `v0.0.22` 시점의 고정 사본이며, 설치 안내 문서는
그 뒤에 따로 보완될 수 있습니다. 최신 오프라인 설치 안내는 Release에 첨부한
[`README.installer.md`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/README.installer.md)를
봅니다. 키트 안의 문서는 게시 시점의 사본이며, 문서가 달라도 키트의 소스 커밋은 바뀌지 않습니다.

TUI는 신규 설치만 지원하며 기존 설치의 업데이트·이관과 별도 DMZ 프록시를 구성하지 않습니다.
설치 후에는 생성된 `compose.installer.json`(Podman은 초기화 JSON 포함)을 사용합니다.
수동 YAML 명령을 그대로 실행하거나 생성 JSON을 덮어쓰지 않습니다.

## 최초 설치 준비

수동 Compose 경로로 처음 설치할 때만 하는 준비입니다. TUI 경로와 기존 설치 업데이트에서는
하지 않습니다. 실제 명령은 런타임별 안내서의 해당 절에 있습니다.

1. 온라인 PC에서 배포할 릴리스 태그의 소스를 준비하고, 폐쇄망이면 이미지 번들을 만듭니다.
2. 소스 사본을 설치 서버의 `INSTALL_ROOT`로 옮깁니다. 폐쇄망이면 번들 세 파일을
   `<INSTALL_ROOT>/images/`에 둡니다.
3. `INSTALL_ROOT`에서 `.env.example`을 `.env`로 복사해 값을 정하고, 발급받은
   라이선스를 `license/license.json`으로 둡니다.
4. 필요하면 Compose 파일의 `gw.ports`(호스트 포트)를 바꿉니다. `.env`의 URL만 바꿔서는
   publish 포트가 바뀌지 않습니다.
5. 런타임 안내서의 "최초 기동"을 온라인/폐쇄망 중 하나만 실행합니다.

| 결정할 값 | 요점 |
|-----------|------|
| `EXTERNAL_URL` | 사용자가 브라우저로 접속하는 `http(s)://host[:port]`. `localhost`/`127.0.0.1` 금지 |
| `BROKER_WS_URL`, `PUBLIC_BROKER_WS_URL` | `/mqtt`로 끝나는 `ws(s)://` 주소. DMZ 프록시를 쓰면 `PUBLIC_BROKER_WS_URL`만 DMZ 주소 |
| 호스트 포트 | Docker 기본 `80`/`443`, Podman 기본 `18080`/`18443` |
| 관리자·DB 계정 | 최초 기동 뒤 바꾸면 로그인·DB 연결이 깨집니다. `DB_PASSWORD`는 `[A-Za-z0-9._~-]` 문자만 권장(URI encoding 없이 `DATABASE_URL`에 들어감) |

- Docker: [README.docker.md — 4. 수동 설치](README.docker.md#4-수동-설치)
- Podman: [README.podman.md — 4. 수동 설치](README.podman.md#4-수동-설치)

## 기존 설치 업데이트

아래는 수동 Compose로 설치한 서버의 이미지 태그 전용 업데이트입니다. TUI 설치의
생성 JSON을 원본 YAML로 바꾸거나, 원본 YAML의 명령을 그대로 실행하면 안 됩니다.

- Docker: [README.docker.md — 6. 이미지 버전 업데이트](README.docker.md#6-이미지-버전-업데이트)
- Podman: [README.podman.md — 6. 이미지 버전 업데이트](README.podman.md#6-이미지-버전-업데이트)

공통 원칙:

- 이 빠른 절차는 서비스 목록과 이미지 경로가 그대로이고 `image:` 태그만 바뀐 경우에만
  씁니다. 서비스·이미지 추가/삭제, 이미지 경로 변경, Compose의 다른 설정·`.env`·인증서·데이터
  변경이 필요한 릴리스는 해당 릴리스의 이관 안내를 따릅니다. 새 Compose 파일로 통째로
  덮어쓰지 않습니다.
- `.env`, `license/`, `secrets/`, `nginx/certs/`, `postgres/data/`, `git/data/`, `broker/`의 데이터와
  기존 사용자 지정 포트는 그대로 둡니다. 최초 설치용 `cp .env.example .env`를 다시 하지 않습니다.
- Compose의 태그와 불러오는 번들은 같은 릴리스에서 나온 것이어야 합니다.
- 업데이트를 위해 스택을 먼저 내릴 필요가 없습니다. `down -v`는 쓰지 않습니다.

## 폐쇄망 이미지 번들 만들기

폐쇄망 서버(또는 TUI)에 줄 이미지 번들을 인터넷이 되는 온라인 PC에서 만듭니다.
Podman 서버용 번들도 온라인 PC에서는 Docker로 만듭니다. 온라인 PC에는 운영 `.env`와
라이선스가 필요 없습니다(스크립트가 `.env.example`로 Compose를 해석).

온라인 PC 요구사항: 실행 중인 Docker 데몬, Docker Compose v2, Docker Buildx,
`docker save --platform`을 지원하는 Docker(Engine API 1.48 이상, 보통 Docker Engine 28 이상).
[docker 이미지 save](https://docs.docker.com/reference/cli/docker/image/save/) 참고.

실행 위치: 온라인 PC, 소스 루트. 아래 확인이 모두 성공해야 다음으로 갑니다.

```bash
docker info >/dev/null
docker compose version
docker buildx version
docker save --help | grep -q -- '--platform' && echo "save --platform OK"
```

실행 위치: 온라인 PC, Git 체크아웃한 소스 루트. 배포할 태그로 바꾼 뒤 대상 런타임의
스크립트 하나만 실행합니다. Release "Source code" 압축 파일을 풀어 쓴다면 `git checkout`
줄은 빼고 그 디렉터리에서 스크립트만 실행합니다.

```bash
git checkout --detach v0.0.22   # 배포할 release tag로 바꾸세요
```

그다음 아래에서 대상 런타임 하나만 실행합니다.

Docker 서버용:

```bash
./scripts/export-compose-images-docker.sh
```

Podman 서버용:

```bash
./scripts/export-compose-images-podman.sh
```

스크립트는 Compose의 이미지를 `linux/amd64`로 내려받고 `init-secrets` 이미지를 빌드한 뒤
하나의 gzip 압축 파일로 저장합니다. 결과는 `<소스 루트>/images/`에 생깁니다.

| 파일 | 서버로 옮길지 |
|------|---------------|
| `X.tar.gz` | 필수 |
| `X.images.txt` | 필수(로더가 이미지 목록 검증에 사용) |
| `X.tar.gz.sha256` | 정상 운영 절차상 필수. 없으면 다시 전달받고 중단(로더 자체는 경고 후 진행 가능) |
| `X.archive-images.txt`, `X.services.txt` | 진단용, 옮기지 않아도 됨 |

`X`는 Docker용 `lucy-teamcloud-onprem-docker-images-linux-amd64`, Podman용
`lucy-teamcloud-onprem-podman-images-linux-amd64`입니다. 같은 내보내기 작업에서 나온 파일을 이름을
바꾸지 말고 함께 옮깁니다. 두 번들은 `init-secrets` 이미지 이름이 달라
(`lucy-teamcloud-onprem-init-secrets:offline` / `localhost/lucy-teamcloud-onprem-init-secrets:offline`)
서로 바꿔 쓸 수 없고, 로더가 다른 런타임의 번들을 거부합니다.

서버에서는 세 파일을 같은 디렉터리(`<INSTALL_ROOT>/images/`)에 두고 런타임 안내서의 로더로 engine
이미지 저장소에 등록합니다. 로더는 압축 파일 옆의 `X.tar.gz.sha256`과 `X.images.txt`를 찾고, 상대 압축 파일
경로는 릴리스 루트 기준으로 해석합니다. 체크섬은 파일 손상 여부만 확인하며 릴리스 버전 일치를
판단하지 않습니다. 이미지 내보내기 오류(`unknown flag: --platform`, `does not provide the specified platform`)는
[README.docker.md의 이미지 내보내기 오류](README.docker.md#export-오류-온라인-pc)를 보세요.

## 백업과 상태 파일

설치 루트의 다음 경로가 운영 상태입니다. 자세한 백업 절차는 런타임 안내서의
"백업과 복구" 절에 있습니다.

| 경로 | 내용 | 백업 |
|------|------|------|
| `.env`, `license/license.json` | 설정, 라이선스 | 필수 |
| `secrets/secrets.env` | `init-secrets`가 만든 인스턴스 시크릿. 잃으면 기존 데이터와 맞지 않음 | 필수 |
| `postgres/data/` | PostgreSQL 데이터. 실행 중 파일 복사는 일관성을 보장하지 않으므로 스택을 멈춘 뒤 복사 | 필수 |
| `git/data/` | Gitea 저장소 | 필수 |
| `nginx/certs/` | TLS 인증서(자동 생성 또는 운영 인증서) | 권장 |
| `broker/data/`, `broker/logs/`, `auth/logs/`, `tc/logs/` | 브로커 상태와 로그 | 선택 |
| 운영 Compose: 수동 설치는 `compose.*.yml`, TUI는 `compose.installer.json`(Podman은 init JSON도 포함) | 사용자 지정 포트 등 실제 운영 설정. TUI에 원본 YAML 명령을 적용하지 않음 | 필수 |
| 네임드 볼륨 `studio-release` | 업로드한 Studio 릴리스. 원본 번들을 다시 올리면 복구됨 | 원본 번들을 보관 |

## Studio 릴리스 업로드

사내 Studio 새 버전은 Edencrew가 전달한 Studio 번들(`.tar`/`.tar.gz`/`.zip`, 약 1.1GB)을 TC에
업로드해 배포합니다. Studio 버전마다 이미지를 바꾸지 않습니다. TC(`tc-be`)가 번들을 검증해
네임드 볼륨 `studio-release`에 풀고, `studio-dl`이 그 내용을 `/studio/`로 서빙하면 사내
Studio가 다음 실행 때 스스로 업데이트합니다. 설치 직후 첫 업로드 전에는 `/studio/*`가
404이므로 기동 뒤 바로 업로드합니다.

### 올리기

1. PAT 발급: 조직 owner 계정으로 TC 웹의 액세스 토큰 화면에서 scope `api`, 만료 당일로
   토큰을 만듭니다. `api` 토큰은 그 계정의 API 전체를 쓸 수 있으므로 업로드 후 바로 폐기합니다.
2. 업로드 — 실행 위치: `bash`, `curl`이 있고 TC 주소에 접속되는 PC 또는 서버, 설치 루트
   (`scripts/studio-upload.sh`가 있는 곳). 스크립트가 PAT를 화면에 보이지 않게 입력받습니다.

   ```bash
   ./scripts/studio-upload.sh "/path/to/lucy-studio-onprem-<version>.<build>.tar.gz" "https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>"
   ```

   자체 서명 인증서를 쓰면 그 인증서를 신뢰하도록 지정합니다(설치 루트에서 실행할 때의 경로).

   ```bash
   CACERT=nginx/certs/server.crt ./scripts/studio-upload.sh "/path/to/<번들 파일>" "https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>"
   ```

   TC 주소를 생략하면 셸 환경변수 `EXTERNAL_URL`(`.env` 파일은 읽지 않음)을 쓰고, 없으면
   입력을 받습니다. 서버가 압축 해제와 해시 검증을 하므로 응답까지 몇 분 걸릴 수 있습니다.
   HTTP 201이면 성공, 그 외에는 응답 본문을 출력하고 실패로 끝납니다.
3. 확인: 응답의 `version`·`build`가 올린 번들과 같고, `https://<TC 주소>/studio/latest.json`이
   같은 값을 돌려주는지 봅니다.
4. PAT 폐기: 액세스 토큰 화면에서 지웁니다.

업로드는 위 스크립트를 권장합니다. 내부적으로 `Content-Type: application/octet-stream`과
`-T` 스트리밍을 사용하고, PAT는 명령 인자가 아니라 curl 설정의 표준입력으로 전달합니다.
토큰을 명령행에 직접 붙여 넣거나 `set -x`를 켜지 마세요.

### 되돌리기

TC는 활성 버전과 직전 버전 1개를 보관합니다. 새 버전에 문제가 있으면 직전 버전을 다시
활성화합니다.

```bash
TC_URL='https://teamcloud.example.com'   # 실제 접속 주소
read -rsp 'owner PAT (api scope): ' TC_PAT; printf '\n'
# 사설 CA라면 curl에 --cacert /path/to/ca.crt를 추가합니다.
# 목록에서 active가 false인 releaseId를 확인합니다.
printf 'header = "Authorization: Bearer %s"\n' "$TC_PAT" |
  curl --fail-with-body -K - "$TC_URL/api/v1/onprem/studio-releases"
unset TC_PAT
```

확인한 보관본을 다시 활성화할 때만 실행합니다.

```bash
TC_RELEASE_ID='REPLACE_WITH_RELEASE_ID'
read -rsp 'owner PAT (api scope): ' TC_PAT; printf '\n'
printf 'header = "Authorization: Bearer %s"\n' "$TC_PAT" |
  curl --fail-with-body -K - -X POST "$TC_URL/api/v1/onprem/studio-releases/$TC_RELEASE_ID/activate"
unset TC_PAT
```

이미 새 버전으로 업데이트한 PC는 되돌아가지 않습니다(Studio는 다운그레이드하지 않음). 되돌리기는
아직 업데이트하지 않은 PC와 신규 설치로 퍼지는 것을 막는 수단입니다. 방금 내린 버전도 보관되므로
다시 activate해 앞으로 돌아갈 수 있습니다.

### 오류

| 응답 | 원인 → 조치 |
|------|-------------|
| 403 | owner가 아님 → owner 계정의 PAT로 다시 |
| 409 `STUDIO_RELEASE_BUSY` | 다른 업로드·되돌리기 진행 중 → 끝난 뒤 다시 |
| 409 `STUDIO_RELEASE_BUILD_DOWNGRADE` | 서빙 중인 것보다 낮은 빌드 → 되돌리기는 activate로 |
| 413 | 4GiB 초과. 본문이 nginx HTML이면 게이트웨이 한도(`nginx/nginx.conf`의 `/api/v1/onprem/studio-releases` location, `client_max_body_size 4g`) |
| 415 | `Content-Type: application/octet-stream` 누락 |
| 400 `STUDIO_BUNDLE_REJECTED`, `..._MANIFEST_FILE_MISMATCH` | 형식 오류 또는 반입 중 손상 → 원본 해시 확인 후 다시 반입 |
| 400 `STUDIO_RELEASE_INVALID_MANIFEST` | SaaS용 번들 등 → 온프렘용 번들인지 확인 |
| 400 `STUDIO_RELEASE_INVALID_BASE_URL` | `.env`의 `EXTERNAL_URL`이 http(s) 주소가 아님 |
| 503 `STUDIO_RELEASE_STORAGE_NOT_CONFIGURED` | Compose에 `studio-release` 볼륨이 없음(구버전 패키지) → 릴리스 이관 안내 확인 |

업로드는 됐는데 Studio가 업데이트를 못 찾으면 `/studio/macos/appcast.xml`과
`/studio/windows/LucyStudio.appinstaller` 안의 URL이 실제 접속 주소로 시작하는지 봅니다.
`EXTERNAL_URL`을 바꿨다면 `tc-be`를 재시작하면 피드가 새 주소로 다시 만들어집니다.

### 저장 위치

업로드한 릴리스는 네임드 볼륨 `studio-release`(Compose 프로젝트 이름이 붙어
`lucy-teamcloud-onprem_studio-release`)에 있습니다. 활성 + 직전 버전 분량이 쌓이고, 업로드
중에는 번들 크기만큼 더 씁니다. 볼륨 자체는 백업하지 않는 대신 원본 번들을 보관해 두세요.
`down -v`나 볼륨 삭제를 하면 지워지고, 다시 업로드할 때까지 `/studio/*`가 404가 됩니다.

## 공식 도구 참고

- [Docker 이미지 save](https://docs.docker.com/reference/cli/docker/image/save/)와 [Engine API 버전표](https://docs.docker.com/reference/api/engine/): 이미지 내보내기 PC의 `--platform` 요구사항
- [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/): `--pull never`와 `--no-build`의 차이
- [Podman compose](https://docs.podman.io/en/latest/markdown/podman-compose.1.html): 외부 Compose 실행 도구와 지원 옵션
- [Docker rootless](https://docs.docker.com/engine/security/rootless/): 사용자 네임스페이스와 사전 준비
- [nginx WebSocket proxying](https://nginx.org/en/docs/http/websocket.html): 업그레이드 헤더와 101 응답


## Optional Devora candidate

See [Devora installation](devora/README.md) and the exact [installer/kit interface](devora/INTERFACE.md). Devora is OFF by default; supply both `--devora-env /absolute/operator.env` and `--devora-media /absolute/media` only with prepared media and a real BE image. Operator env is never included in the kit. LLM and embedding servers are external endpoints; this option installs BE, dedicated PostgreSQL and Redis only. Local source integration is separate from real image, Podman, authentication and model acceptance.
