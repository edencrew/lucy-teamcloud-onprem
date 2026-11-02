# Lucy TeamCloud On-Premise — Docker 설치·운영 안내서

미릴리스 format 2에서는 `compose.docker.yml`이 상시 서비스 base이고,
`compose.docker.init-secrets.yml`은 최초 bootstrap 전용입니다.
새 소스의 수동 최초 설치는 두 파일을 명시하여 bootstrap한 뒤 base를 기동합니다.
업데이트에는 init 파일을 사용하지 않습니다. 구 공개 키트의 JSON·init 상태 설명은 레거시 보존 절차입니다.
현재 구현·검증 범위는 [README.infra-redesign.md](README.infra-redesign.md)를 봅니다.

## 빠른 이동

| 하려는 일 | 이동 |
|-----------|------|
| 설치 방법(TUI 또는 수동) 고르기 | [2.4 설치 방법 고르기](#24-설치-방법-고르기) |
| 대화형 화면으로 신규 설치 | [3. TUI 신규 설치](#3-tui-신규-설치) |
| 명령을 직접 실행해 신규 설치 | [4. 수동 설치](#4-수동-설치) |
| TUI 설치의 상태·로그 보기 | [3.10 설치 후 상태와 로그](#310-설치-후-상태와-로그) |
| 수동 설치의 운영·업데이트·백업 | [5. 운영](#5-운영), [6. 이미지 버전 업데이트](#6-이미지-버전-업데이트), [7. 백업과 복구](#7-백업과-복구) |
| 문제 해결, 검증 범위 | [9. 문제 해결](#9-문제-해결), [10. 테스트 현황](#10-테스트-현황) |

## 1. 대상과 범위

- 대상: Docker Engine으로 TC 본체를 설치·운영하는 관리자. TC 본체를 DMZ 망 서버에 두는
  경우도 이 문서를 따릅니다. 별도 DMZ MQTT 프록시 서버는 [dmz/README.md](dmz/README.md)를 봅니다.
- 다루는 것: 신규 설치(TUI 또는 수동 중 하나), 수동 설치의 이미지 버전 업데이트·운영·백업, 문제 해결.
- 이 안내서는 `linux/amd64` 설치 기준입니다. 실제 서버 동작은 별도 확인이 필요합니다
  ([10장](#10-테스트-현황)). 소스 Compose 템플릿은 `compose.docker.yml` 하나이며 10개 서비스
  (일회성 `init-secrets` + 상시 9개)로 구성됩니다.

명령 블록마다 실행 위치를 적었습니다. 서버 명령은 모두 설치에 쓸 같은 OS 계정으로 실행합니다.
이 계정은 `docker` 명령을 쓸 수 있어야 합니다(`docker info`가 성공).

## 2. 공통 준비와 설치 방법 고르기

### 2.1 온라인 PC (이미지 번들을 만들 때)

TUI 설치와 수동 폐쇄망 설치에는 같은 릴리스로 만든 Docker용 이미지 번들 세 파일이 필요합니다.

- 배포할 릴리스 태그(예: `v0.0.22`)의 소스
- 실행 중인 Docker 데몬, Docker Compose v2, Docker Buildx, `docker save --platform` 지원
  Docker(보통 Docker Engine 28 이상, Engine API 1.48 이상)
- 운영 `.env`와 라이선스는 필요 없습니다.

번들 만드는 방법은 [루트 README의 폐쇄망 이미지 번들 만들기](README.md#폐쇄망-이미지-번들-만들기)에
있습니다. Docker 서버에는 `export-compose-images-docker.sh`로 만든 Docker용 번들만 씁니다.
같은 내보내기 작업에서 나온 아래 세 파일을 이름 그대로 함께 옮깁니다.

- `lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz`
- `lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256`
- `lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt`

### 2.2 설치 서버

- Linux amd64, Docker Engine(로컬 `unix://` endpoint), 최소 4GB RAM, 10GB 이상 여유 디스크
  (데이터 증가분 별도)
- Edencrew에서 발급받은 `license.json`
- 같은 릴리스의 소스, 그리고 TUI 설치 또는 수동 폐쇄망 설치라면 Docker용 번들 세 파일

실행 위치: 설치 서버, 설치에 쓸 계정. 아래 명령은 상태를 바꾸지 않습니다.

```bash
docker info >/dev/null && echo "daemon OK"
docker context show
docker version --format '{{.Server.Version}} API {{.Server.APIVersion}}'
```

수동 설치를 고른 경우에만 Compose v2 플러그인(`up --pull`과 `pull --ignore-buildable` 지원)이 필요하며,
아래가 모두 성공해야 합니다. TUI는 플러그인이 없으면 동봉 Compose를 쓰므로 이 확인이 필요 없습니다.

```bash
docker compose version
docker compose up --help | grep -q -- '--pull' && echo "up --pull OK"
docker compose pull --help | grep -q -- '--ignore-buildable' && echo "pull --ignore-buildable OK"
```

rootless Docker: 일반 계정의 rootless 데몬은 기본적으로 1024 미만 포트(80/443)를 publish하지
못합니다. 수동 설치라면 4.3대로 `gw`를 높은 호스트 포트(예: 8080/8443)로 바꾸고 `.env` URL도 같은 포트로
맞춥니다. TUI는 1024 미만 포트를 받지 않습니다. 낮은 포트가 꼭 필요하면 호스트 설정 변경은 서버 관리자가
결정합니다. 이 문서 때문에 docker 컨텍스트를 바꾸거나 `sudo`로 rootful 데몬을 쓰지 않습니다.

### 2.3 미리 정할 값

| 값 | 요점 |
|----|------|
| 접속 호스트 | 클라이언트가 실제로 쓰는 DNS 이름 또는 IPv4. `localhost`/`127.0.0.1` 금지. TUI는 IPv6를 받지 않음 |
| 프로토콜과 호스트 포트 | `https` 권장. HTTP와 HTTPS 포트는 서로 달라야 함 |
| MQTT 주소 | 기본은 같은 게이트웨이의 `ws(s)://<host>:<port>/mqtt`. DMZ 프록시를 쓰면 외부 클라이언트용 주소(`PUBLIC_BROKER_WS_URL`)만 DMZ 주소 |
| 관리자 이메일/password | 이메일이 로그인 ID. 비밀번호를 보관할 승인된 방법을 먼저 정함 |
| DB 계정 | 최초 기동 뒤 바꾸면 로그인·DB 연결이 깨짐. DB 비밀번호는 `[A-Za-z0-9._~-]` 문자만 |
| TLS 인증서(선택) | 운영 `crt`/`key`. 없으면 `init-secrets`가 자체 서명 인증서를 만들어 브라우저 경고가 남 |

### 2.4 설치 방법 고르기

신규 설치에서 TUI와 수동 절차는 둘 중 하나를 고르는 대안입니다. 한 설치에 두 방법을 섞지 않습니다.

| 항목 | TUI 신규 설치 ([3장](#3-tui-신규-설치)) | 수동 설치 ([4장](#4-수동-설치)) |
|------|------------------------------------------|---------------------------------------|
| 용도 | 새 서버의 새 설치 경로에 처음 설치 | 처음 설치(온라인 또는 폐쇄망) |
| 이미지 준비 | 서버가 인터넷에 연결되어 있어도 항상 번들 불러오기 | 온라인 이미지 다운로드/빌드 또는 번들 불러오기 |
| 서버에 필요한 것 | Docker Engine, 같은 릴리스 소스, 번들, 라이선스. Compose 플러그인·Go·Python 설치 불필요 | Docker Engine, Compose v2 플러그인, 소스 사본, 라이선스, (폐쇄망) 번들 |
| 운영 기준 파일 | 설치 경로의 생성 `compose.installer.json` | 설치 루트의 `compose.docker.yml` |
| 이후 업데이트 | 지원하지 않음. 생성 JSON 기준의 별도 계획을 서버 소유자 승인으로 세움 | [6장](#6-이미지-버전-업데이트)의 이미지 전용 업데이트 |
| 웹·MQTT 분리 포트 | 지원하지 않음 | 지원 |

운영 기준을 섞지 않습니다. TUI로 설치한 서버에는 5~7장의 `compose.docker.yml` 명령을 실행하지
않고, 새 Compose로 생성 JSON을 덮어쓰지 않습니다. 수동 설치 서버를 TUI로 다시 설치하지도 않습니다
(TUI는 기존 설치·기존 설치 경로를 거부합니다).

## 3. TUI 신규 설치

폐쇄망에 오프라인 키트와 라이선스만 반입하는 설치는 [README.installer.md](README.installer.md)를
따릅니다. 아래는 실행 파일·소스·이미지 번들을 각각 준비하는 기존 배포 방식의 절차입니다.

TeamCloud 설치기 `v0.0.22`(Linux amd64)로 Docker에 처음 설치하는 절차입니다. 3.1부터
순서대로 진행하며, 4장의 수동 설치 단계(`.env` 작성, 라이선스 복사, 기동)는 실행하지 않습니다.

### 3.1 설치기 동작 범위

설치기는 새 설치 경로를 만들고 소스에서 필요한 파일만 복사합니다. 원본 소스는 바꾸지 않습니다.
생성하는 파일은 `.env`와 `compose.installer.json`이며 권한은 모두 0600입니다.
이미지 번들은 설치 경로의 `images/`로 복사한 뒤 Docker 이미지 저장소에 불러옵니다.
인터넷이 연결되어 있어도 이미지를 내려받거나 빌드하지 않습니다.

현재 구성은 초기화용 `init-secrets` 1개와 상시 서비스 9개(`studio-dl` 포함)입니다.
기동 후에는 컨테이너 상태와 게이트웨이 `/health` 응답을 확인합니다.

기존 설치의 업데이트나 이관에는 쓸 수 없습니다. Docker와 Compose를 설치하거나 데몬을 켜지 않으며,
권한·SELinux·방화벽 설정도 바꾸지 않습니다. 실패하면 생성한 파일과 컨테이너를 남기고 멈춥니다.
자동 삭제·롤백·재시도는 하지 않습니다.

DMZ 망 서버에 TC 본체를 직접 설치할 수는 있지만, 별도 MQTT 프록시는 구성하지 않습니다.
프록시가 필요하면 [DMZ 안내서](dmz/README.md)를 따릅니다.

### 3.2 준비물

| 준비물 | 어디서 | 설명 |
|--------|--------|------|
| 설치기 압축 파일과 `.sha256` | [Release v0.0.22](https://github.com/edencrew/lucy-teamcloud-onprem/releases/tag/v0.0.22) 또는 승인된 전달 채널 | 이 절차에 필요한 첨부 파일은 `teamcloud-installer-v0.0.22-linux-amd64.tar.gz`와 `teamcloud-installer-v0.0.22-linux-amd64.tar.gz.sha256` 두 개입니다. 같은 Release의 `teamcloud-offline-...` 키트는 [README.installer.md](README.installer.md) 절차용입니다 |
| 온프레미스 소스 `v0.0.22` | 같은 Release의 Source code 또는 태그 체크아웃 | Compose·템플릿·스크립트. 설치기에 내장되어 있지 않으므로 `--source`로 지정합니다 |
| Docker용 이미지 번들 세 파일 | 프로젝트 소유자 또는 [2.1](#21-온라인-pc-이미지-번들을-만들-때) | 같은 릴리스(`v0.0.22`)·Docker용·`linux/amd64`. 세 파일을 같은 디렉터리에 둡니다. `.sha256`이 없으면 설치기가 거부합니다 |
| 발급 `license.json` | Edencrew | 일반 파일(심볼릭 링크 불가), 올바른 JSON |
| 접속 정보, 관리자 계정 | [2.3](#23-미리-정할-값) | 호스트(DNS 또는 IPv4), 프로토콜, 포트, 관리자 이메일과 비밀번호 보관 방법 |
| 동작 중인 Docker | 서버 관리자 | 설치기는 Docker를 설치하거나 켜지 않습니다 |

선택: 운영 TLS 인증서 `crt`/`key`, 화면 미리보기용 `--demo`.

설치기 압축 파일에는 설치기, 공식 Go로 작성된 독립 실행형 Compose(`docker-compose-linux-amd64`), 라이선스 고지,
내부 `SHA256SUMS`, 게시 당시의 문서 사본이 들어 있습니다. 동봉 문서는 설치 실행에 필요하지 않으며,
절차는 이 안내서를 기준으로 합니다.

### 3.3 경로 변수

서로 다른 네 위치를 씁니다. 기본값은 root 권한 없이 쓸 수 있는 실행 사용자의 홈 아래입니다.
서버 관리자가 실행 사용자 소유로 미리 만들어 준 다른 경로가 있으면 변수 값만 바꿉니다. 이후 모든
명령이 이 변수를 쓰므로 새 셸을 열 때마다 이 블록을 다시 실행합니다. `HOME`은 바꾸지 않습니다.

```bash
TC_STAGE="$HOME/tc-staging"                           # 작업용 staging 상위
TC_SOURCE="$TC_STAGE/lucy-teamcloud-onprem-0.0.22"    # --source (같은 release 소스)
TC_INSTALLER="$TC_STAGE/installer"                    # installer 추출 경로
TC_TARGET="$HOME/teamcloud"                           # 새 target (mkdir 금지)
```

| 경로 | 변수 (기본값) | 누가 만드나 | 비고 |
|------|---------------|-------------|------|
| 작업 상위 경로 | `TC_STAGE` (`$HOME/tc-staging`) | 운영자 | 3.5 첫 명령으로 만듦. 다운로드는 그 아래 새 `download/`에 둠 |
| 소스 (`--source`) | `TC_SOURCE` | 운영자 | 읽기 전용으로 사용. `.env`를 만들거나 `cp .env.example .env` 하지 않음 |
| 설치기 추출 경로 | `TC_INSTALLER` | 운영자(새 빈 디렉터리) | 실행 파일과 동봉 Compose가 같은 디렉터리에 있어야 함 |
| 새 설치 경로 | `TC_TARGET` (`$HOME/teamcloud`) | 설치기 | 존재하면 안 됨. `mkdir` 하지 않음(빈 디렉터리도 거부) |

- 설치 경로 상위 디렉터리는 이미 있고 실행 사용자가 쓸 수 있어야 합니다. 상위 경로에 심볼릭 링크가
  있거나, 설치 경로가 소스와 겹치거나, 설치 경로가 `/`·홈 디렉터리 자체(또는 그 상위)이거나 `/usr`,
  `/etc`, `/var/lib/docker` 같은 시스템 경로 아래면 거부됩니다.
- TUI의 설치 경로 기본값은 `<소스의 상위>/teamcloud-runtime`입니다. TUI에서 `TC_TARGET` 값으로 바꿉니다.
- 번들은 설치 경로 `images/`로 복사되고(원본은 그대로), 불러온 뒤 이미지는 Docker 데이터 경로의
  이미지 저장소에 들어갑니다. 여유 공간이 번들 크기의 3배보다 작으면 설치 전 점검에서 경고합니다.

### 3.4 Docker 엔진과 기존 설치 확인

실행 위치: 설치 서버, 설치할 사용자, TUI를 실행할 같은 셸 환경. 3.3 변수 블록을 먼저 실행합니다.
아래 명령은 아무것도 바꾸지 않습니다.

```bash
uname -m; id -u; id -g
test -e "$TC_TARGET" && echo "TARGET EXISTS: choose another" || echo "target free"
ls -ld "$(dirname "$TC_TARGET")"; df -h "$(dirname "$TC_TARGET")"; ss -ltn
docker context show
docker version --format '{{.Server.Version}} API {{.Server.APIVersion}}'
docker ps -a --filter label=com.docker.compose.project=lucy-teamcloud-onprem --format '{{.Names}}'
docker volume ls --filter label=com.docker.compose.project=lucy-teamcloud-onprem --format '{{.Name}}'
```

- `uname -m`은 `x86_64`, 설치 경로 확인은 `target free`여야 합니다.
- Docker endpoint는 로컬 `unix://` 소켓이어야 합니다. 원격 TCP/SSH 컨텍스트는 거부됩니다.
  `DOCKER_HOST`가 설정되어 있으면 설치기도 그것을 씁니다. rootless 컨텍스트를 `default`로 바꾸거나
  `sudo`로 전환하지 않습니다.
- 기존 `lucy-teamcloud-onprem` 컨테이너나 볼륨이 보이면 신규 설치를 할 수 없습니다. 삭제하지 말고
  서버 관리자에게 알립니다. 비어 있어도 최종 판정은 TUI 설치 전 점검에서 합니다.
- Compose 플러그인은 필수가 아닙니다. 설치기는 `--compose-binary` 지정값 → `docker compose`
  플러그인 → 설치기 옆 동봉 독립 실행형 Compose 순으로 찾습니다. 플러그인이 없는 서버에서 동봉
  Compose를 쓰는 것도 지원 경로입니다.

### 3.5 설치기 다운로드와 검증

실행 위치: 설치 서버 또는 다운로드 PC. 작업 상위 경로를 만들고(관리자가 준비한 경로면 이미 있으므로
건너뜀), 그 아래 새 다운로드 디렉터리에 두 첨부 파일을 받습니다. 서버가 GitHub에 접속하지 못하면 다른
PC에서 받아 두 파일을 함께 서버의 `"$TC_STAGE/download"`로 옮깁니다.

```bash
test -d "$TC_STAGE" || mkdir "$TC_STAGE"
```

```bash
mkdir "$TC_STAGE/download" && cd "$TC_STAGE/download" &&
curl -fLO https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-installer-v0.0.22-linux-amd64.tar.gz &&
curl -fLO https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-installer-v0.0.22-linux-amd64.tar.gz.sha256
```

`mkdir`가 실패하면(이미 있음/권한 없음) 뒤 명령은 실행되지 않습니다. 기존 내용을 덮지 말고 원인을
확인합니다.

풀기 전에 압축 파일을 검증합니다. 공개 해시는
`df1f8ae7154fabb8467167c55355aa0d1b866c9ca8682870b19bf1e15bf24652`(14,395,996 bytes)입니다.

```bash
cd "$TC_STAGE/download" &&
sha256sum -c teamcloud-installer-v0.0.22-linux-amd64.tar.gz.sha256 &&
tar -tvzf teamcloud-installer-v0.0.22-linux-amd64.tar.gz
```

`OK`가 나와야 하고, 목록은 정확히 9개 항목, 모두 일반 파일(줄 맨 앞 `-`), 이름에 `/`가 없는 평면
구조이며 `teamcloud-installer`, `docker-compose-linux-amd64`, `SHA256SUMS`, 라이선스 고지 2개, 문서
4개여야 합니다. 하나라도 다르면 실행 파일을 찾아 헤매지 말고 중단합니다. 확인되면 새 빈
디렉터리에만 풀고 내부 체크섬과 버전을 확인합니다.

```bash
mkdir "$TC_INSTALLER" &&
tar -xzf "$TC_STAGE/download/teamcloud-installer-v0.0.22-linux-amd64.tar.gz" -C "$TC_INSTALLER" &&
cd "$TC_INSTALLER" &&
sha256sum -c SHA256SUMS &&
./teamcloud-installer --version
```

`mkdir`에 `-p`를 쓰지 않으므로 이미 있으면 여기서 멈추고 아무것도 풀지 않습니다. 모든 항목이 `OK`이고
`--version`이 정확히 `teamcloud-installer 0.0.22`여야 합니다. 외부 `.sha256`은 전송 무결성, 내부
`SHA256SUMS`는 추출 후 일관성 확인이며 둘 다 서명이 아닙니다. 출처는 공식 Release 또는 승인된 전달
채널로 확인합니다.

### 3.6 소스, 이미지 번들, 라이선스 배치

소스는 태그 `v0.0.22`(commit `b796b24b43115cc115e76e348e701de8cffed52f`)로 고정합니다. 최신
`main`을 쓰지 않습니다. A와 B 중 하나로 준비합니다.

A. Release 자동 생성 Source code 압축 파일을 새 디렉터리에 받습니다.

```bash
mkdir "$TC_STAGE/source-download" && cd "$TC_STAGE/source-download" &&
curl -fL -o onprem-v0.0.22.tar.gz https://github.com/edencrew/lucy-teamcloud-onprem/archive/refs/tags/v0.0.22.tar.gz &&
tar -tzf onprem-v0.0.22.tar.gz | cut -d/ -f1 | sort -u
```

마지막 출력은 `lucy-teamcloud-onprem-0.0.22` 한 줄이어야 합니다. 그다음 소스 경로가 아직 없을 때만
풉니다(이미 있으면 멈추고 덮어쓰지 않음).

```bash
test ! -e "$TC_SOURCE" &&
tar -xzf "$TC_STAGE/source-download/onprem-v0.0.22.tar.gz" -C "$TC_STAGE" &&
ls -d "$TC_SOURCE"
```

B. 태그 체크아웃. 대상이 이미 있으면 git이 거부합니다. `rev-parse` 출력이
`b796b24b43115cc115e76e348e701de8cffed52f`여야 합니다.

```bash
git clone --branch v0.0.22 --depth 1 https://github.com/edencrew/lucy-teamcloud-onprem.git "$TC_SOURCE" &&
git -C "$TC_SOURCE" rev-parse HEAD
```

소스에 `studio-dl/nginx.conf`와 `scripts/studio-upload.sh`가 있어야 현재 서비스 구성입니다. 태그 소스에는
설치기 문서가 없을 수 있으며 정상입니다.

`images/`는 git에서 제외되므로 소스에 없습니다. 소스가 준비된 뒤 직접 만들고 번들 세 파일을
복사한 뒤 해시를 확인합니다. `<BUNDLE_DIR>`은 전달받은 세 파일이 있는 디렉터리로 바꿉니다. 다른
위치에 둘 경우 TUI의 이미지 번들 필드에 그 실제 경로를 입력합니다.

```bash
mkdir -p "$TC_SOURCE/images" &&
cp -n "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz" \
      "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256" \
      "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt" \
      "$TC_SOURCE/images/" &&
cd "$TC_SOURCE/images" &&
sha256sum -c lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256
```

`license.json`은 예를 들어 `$TC_STAGE/license.json`에 두고 실행 사용자만 읽게 합니다. 내용을
출력하거나 공유하지 않습니다.

```bash
test -f "$TC_STAGE/license.json" && test ! -L "$TC_STAGE/license.json" &&
chmod 600 "$TC_STAGE/license.json" && echo "license ok"
```

### 3.7 TUI 실행

실행 위치: 설치 서버, 설치할 사용자. 터미널은 96열 × 28행 이상, SSH는 `ssh -t`로 접속합니다.
파이프나 리다이렉션 없이 실행합니다. 선택: `./teamcloud-installer --demo`로 화면만 먼저 볼 수
있습니다(파일·런타임 접근 없음, 설치 불가).

```bash
cd "$TC_INSTALLER" &&
./teamcloud-installer --runtime docker --source "$TC_SOURCE"
```

`--source`를 생략하면 현재 디렉터리가 소스로 잡히므로 항상 지정합니다. `--runtime`을 생략해도
Docker지만 명시합니다. TUI의 설치 대상 경로에는 `echo "$TC_TARGET"`으로 확인한 절대 경로(기본
`$HOME/teamcloud`의 실제 값)를 입력합니다.

### 3.8 입력 필드와 조작

| 페이지 | 필드 | 기본값 | 운영자가 할 일 |
|--------|------|--------|----------------|
| 런타임/경로 | 런타임, 소스 | `--runtime`, `--source` 값 | `docker`와 `TC_SOURCE` 경로인지 확인 |
| | 설치 대상 경로 | `<소스 상위>/teamcloud-runtime` | 존재하지 않는 새 절대 경로(`TC_TARGET`)로 변경 |
| | 이미지 번들 | `<소스>/images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz` | 다른 위치면 변경 |
| | 라이선스 파일 | 비어 있음 | 절대 경로 입력(예: `TC_STAGE` 아래 `license.json`의 실제 경로) |
| 접속/인증서 | 호스트 | 비어 있음 | 클라이언트가 쓰는 DNS 이름 또는 IPv4 |
| | 스킴, HTTP/HTTPS 포트 | `https`, `18080`/`18443` | 1024–65535, 서로 다르게. 각각 `gw`의 80/443으로 게시 |
| | 인증서 모드 | `generate` | `supplied`면 CRT/KEY 절대 경로 입력 |
| 계정/DB | 관리자 이름 | `admin` (고정) | 표시 이름이며 로그인 ID 아님 |
| | 관리자 이메일 | `admin@edencrew.com` (예시) | 실제 로그인 이메일로 변경 |
| | 관리자 비밀번호 | 비어 있음 | 8자 이상 ASCII, 공백·따옴표·`\`·`` ` ``·`$` 불가 |
| | DB 사용자 | `lucy` | 소문자·숫자·`_` |
| | DB/DB root 비밀번호 | 비어 있음 | 8자 이상 `[A-Za-z0-9._~-]` |
| 시스템 | TZ | `Asia/Seoul` | 필요하면 변경 |
| | 호스트 UID/GID | 실행 사용자 값 | 보통 그대로 |
| | 대상 플랫폼 | 실행 파일 아키텍처(`linux/amd64`) | 그대로. 번들·엔진과 같아야 함 |

- 자동 생성 값: `EXTERNAL_URL=<scheme>://<host>:<port>`,
  `BROKER_WS_URL`=`PUBLIC_BROKER_WS_URL`=`ws(s)://<host>:<port>/mqtt`. 웹과 MQTT는 같은 게이트웨이
  포트를 씁니다. 외부 NAT 포트가 게시 포트와 다르거나 웹·MQTT 포트를 나눠야 하면 TUI로 표현할 수
  없으니 생성 파일을 고치지 말고 중단·문의합니다.
- 자동 UID/GID는 권한 해결책이 아닙니다. 바인드 마운트 쓰기 권한, SELinux 레이블은 설치기가
  검사하거나 고치지 않으며 서버 관리자 책임입니다.
- `g`는 현재 비밀번호 필드, `G`는 비밀번호 3개를 24자 무작위로 만듭니다. 생성값은 화면에 보이지
  않으므로 보관 방법이 없으면 직접 정한 값을 입력합니다.

| 키 | 동작 |
|----|------|
| `↑`/`↓` | 필드 이동 |
| `Enter` | 편집 시작/저장, 선택형 값 순환(비밀번호 편집에서 빈 `Enter` = 변경 없음) |
| `←`/`→` | 선택형 값 변경 |
| `Tab`/`PgDn`, `Shift+Tab`/`PgUp` | 다음/이전 페이지(마지막 페이지에서 `Tab` = 설치 전 점검) |
| `r` | 설치 전 점검 실행 |
| `Esc` | 편집 취소, 검토 화면에서 입력으로 복귀, 설치 중 취소 |
| `q` | 종료 |

### 3.9 설치 전 점검과 설치 시작

1. `r`로 설치 전 점검을 실행합니다. 입력값, Docker·Compose, 기존 `lucy-teamcloud-onprem` 컨테이너·볼륨,
   소스 파일, 설치 경로, 라이선스·인증서, 번들 sha256·gzip·이미지 목록, 엔진 아키텍처, 포트 사용 여부를
   확인합니다. 번들 전체 해시 계산으로 시간이 걸릴 수 있습니다. 소스와 설치 경로에 쓰지 않으며 임시
   디렉터리만 만들고 지웁니다.
2. 오류가 있으면 `Esc`로 돌아가 고친 뒤 다시 `r`을 누릅니다. 경고는 읽고 판단합니다.
3. 통과하면 `Enter` → 확인 화면에 정확히 `INSTALL` 입력 → `Enter`.

| 단계 | 성공 시 | 실패 시 |
|------|---------|---------|
| 사전 재확인 | 엔진·설치 경로·기존 프로젝트 상태가 설치 전 점검과 같음 | 아무것도 만들지 않음 |
| 대상 디렉터리 생성, 파일 복사 | 설치 경로, 하위 디렉터리, 허용 파일, `license/license.json`, 번들 3개 | 부분 설치 경로 보존 |
| `.env` 작성, Compose 해석 | `.env`, `compose.installer.json` | 부분 설치 경로 보존 |
| 이미지 로드 | Docker 이미지 저장소에 이미지 불러오기 | 서비스 시작 안 함 |
| 서비스 시작 | `up -d --pull never --no-build` | 로그 확인 후 문의 |
| 상태 확인 | 전체 ready + 게이트웨이 `/health` 200 | 문제 서비스 로그 30줄(비밀값 가림) 표시 |

- `--pull never`가 레지스트리 이미지 다운로드를, `--no-build`가 빌드를 막습니다. `init-secrets`는 서비스 시작
  단계에서 한 번 실행되어 `secrets/secrets.env`와, 없을 때만 자체 서명 인증서를 만듭니다.
- 설치 성공 기준: `init-secrets` `Exited (0)` + 나머지 9개 running(healthcheck가 있으면 healthy)
  + 게이트웨이 `/health` 200. 앞 단계가 실패하면 뒤 단계는 실행되지 않습니다.
- 불러오기와 up 직전마다 엔진 실행 환경을 다시 확인해, 설치 전 점검 이후 데몬·컨텍스트가 바뀌었으면 멈춥니다.

### 3.10 설치 후 상태와 로그

설치 후 운영 기준은 소스 YAML이 아니라 설치 경로의 생성 `compose.installer.json`입니다.

실행 위치: 설치 서버, 설치 때와 같은 OS 사용자·같은 Docker 컨텍스트. 3.3 변수 블록을 먼저 실행합니다.

```bash
cd "$TC_INSTALLER" &&
./teamcloud-installer --status "$TC_TARGET"
echo "exit=$?"
```

- 종료 코드 0 = ready, 1 = 미준비/실패, 2 = 사용법 오류. 설치 때 `--compose-binary`를 썼다면 여기도
  같이 씁니다.
- `--status`는 컨테이너 상태만 봅니다. `/health`, TLS, 로그인, MQTT는 다시 검사하지 않습니다.

서비스 상태·로그는 설치 경로에서 생성 JSON으로 봅니다(읽기 전용). Compose 플러그인이 없는 서버(동봉 Compose):

```bash
cd "$TC_TARGET" &&
"$TC_INSTALLER/docker-compose-linux-amd64" --env-file .env -f compose.installer.json ps &&
"$TC_INSTALLER/docker-compose-linux-amd64" --env-file .env -f compose.installer.json logs --tail 100 tc-be
```

Compose 플러그인이 있는 서버:

```bash
cd "$TC_TARGET" &&
docker compose --env-file .env -f compose.installer.json ps &&
docker compose --env-file .env -f compose.installer.json logs --tail 100 tc-be
```

설치 직후 `/studio/*` 404는 정상입니다. 설치기는 `scripts/studio-upload.sh`를 설치 경로에 복사만 하고
업로드하지 않습니다. owner PAT와 Edencrew 발급 번들을 준비해
[루트 README의 Studio 릴리스 업로드](README.md#studio-릴리스-업로드)를 따르며, 스크립트는 설치 경로에서
실행합니다.

TUI 설치의 재시작·업데이트·백업 명령은 이 안내서가 제공하지 않습니다. 5~7장의 원칙(데이터 보존,
`down -v` 금지, 정지 후 백업)은 같지만, 명령은 생성 JSON 기준으로 서버 소유자 승인 아래 따로 계획합니다.

### 3.11 실패했을 때

- 설치기는 정리하지 않습니다. 부분 설치 경로와 이미 시작된 컨테이너가 남을 수 있습니다. `down`,
  `prune`, 삭제를 하지 말고 화면의 오류·로그를 담당자에게 전달합니다.
- 같은 설치 경로로 다시 실행하면 "이미 존재" 오류가 납니다. 기존 컨테이너·볼륨이 남아 있으면 다음
  설치 전 점검도 거부합니다. 원인을 고치기 전에 새 경로로 반복하지 않습니다.
- 자주 보는 원인: Docker 연결 실패·원격 컨텍스트, 번들 런타임 불일치(Podman용 번들), 포트 사용 중,
  권한·SELinux로 init 산출물 생성 실패(서버 관리자에게 확인 요청).
- 종료 코드: 0 성공, 1 점검·설치·상태 실패, 2 사용법·터미널 오류, 130 신호 중단.

### 3.12 설치 후 확인과 주의사항

설치 전에 대상 서버, 실행 계정, 새 설치 경로, 준비 파일과 접속 설정을
담당자에게 승인받습니다. 관리자 계정의 비밀번호는 직접 입력하거나 승인된 보안 저장소에서
가져옵니다. 로그인에 필요한 값을 보관할 방법이 없다면 설치를 시작하지 않습니다.

이 절차에서는 `sudo`로 전환하거나 Docker 컨텍스트를 바꾸지 않습니다. Docker·Compose·Python 설치,
데몬 시작,
`chown`·`chmod 777`·SELinux·firewalld 변경도 하지 않습니다. 필요한 서버 설정은
관리자에게 요청합니다. 소스 `compose.docker.yml`로 TUI 설치를 다시 기동하거나,
`down`·`prune`·삭제·롤백을 실행하지 않습니다. Studio 업로드도 별도 승인 후 진행합니다.

다음 문제가 있으면 설치를 멈추고 원인을 확인합니다.

- Docker 연결 실패 또는 `unix://`가 아닌 엔드포인트
- 이미 존재하는 설치 경로 또는 기존 프로젝트의 컨테이너·볼륨
- 체크섬, 압축 파일 목록, `--version`, 소스 커밋 불일치
- 승인된 값으로 해결할 수 없는 설치 전 점검 오류, 권한·SELinux·방화벽 문제

원인을 해결하지 못한 채 두 차례 실패하면 반복 실행하지 않습니다. 비밀번호·토큰·개인키,
`license.json`, `.env`, `secrets/` 내용은 출력하거나 대화·로그·작업 기록에 남기지 않습니다.
문의를 위해 로그를 전달할 때도 비밀값을 가립니다.

TUI 성공과 `/health` 200 응답은 기동을 확인한 결과입니다. 실제 사용 여부는 아래 항목을
따로 점검해야 합니다.

| 항목 | 방법 | 통과 기준 |
|------|------|-----------|
| 서비스 | `--status` | `exit=0`, `init-secrets` `Exited (0)` + 9개 running/healthy |
| 게이트웨이 응답 | `curl -k -s -o /dev/null -w '%{http_code}\n' "https://127.0.0.1:<HTTPS 포트>/health"`(http면 `http://…:<HTTP 포트>`, `-k` 제외) | 200. `-k`는 인증서 검증을 끄므로 전송 확인일 뿐 |
| TLS | `-k` 없이 `curl --cacert "<신뢰할 CA 파일>"`로 `EXTERNAL_URL`의 호스트·포트 `/health` 호출 + 클라이언트 브라우저 | 검증 성공. 자체 서명 인증서라면 경고가 정상이며 신뢰 여부를 그대로 기록 |
| 로그인 | 관리자 이메일로 실제 브라우저 로그인 | 사용자가 확인 |
| MQTT | 실제 클라이언트가 `wss://<host>:<port>/mqtt`에 연결해 메시지 송수신 | 101 응답 후 실제 메시지 송수신까지 확인 |
| Studio | 업로드 전 `/studio/*` 404 정상. `studio-dl` `/healthz`는 릴리스 배포 여부와 무관 | 업로드는 별도 승인 후 |

작업을 인계하거나 오류를 문의할 때는 실행 계정과 모드, 설치기·소스 버전, 파일 체크섬,
소스·설치기·설치 경로, 실패 단계와 `--status` 종료 코드, 위 점검 결과를 남깁니다.
로그인이나 MQTT 송수신을 확인하지 않았다면 확인하지 않았다고 적고, 필요한 관리자 작업을
함께 전달합니다. 비밀값은 포함하지 않습니다.

## 4. 수동 설치

TUI 대신 명령을 직접 실행하는 별도의 신규 설치 방법입니다. TUI로 설치했다면 이 장을 실행하지
않습니다. 기존 설치를 업데이트할 때도 이 장을 건너뜁니다. `.env`, 라이선스, 시크릿, 인증서를 다시
만들지 않습니다.

### 4.1 설치 루트

릴리스 소스 사본을 둘 절대 경로를 정합니다. 수동 설치에서는 이 소스 사본이 곧 설치 루트입니다.
이 문서에서는 `/opt/lucy-teamcloud-onprem`을 예로 씁니다. 이후 서버 명령은 모두 이 디렉터리에서
실행합니다.

실행 위치: 설치 서버. 새 셸을 열 때마다 다시 이동합니다.

```bash
INSTALL_ROOT=/opt/lucy-teamcloud-onprem   # 실제 경로로 바꾸세요
cd "$INSTALL_ROOT" && ls compose.docker.yml .env.example scripts/load-compose-images-docker.sh
```

`ls`가 세 파일을 모두 보여야 올바른 위치입니다. 폐쇄망이면 번들 세 파일을
`$INSTALL_ROOT/images/`에 둡니다. `images/`는 git에서 제외되므로 직접 만듭니다. `<BUNDLE_DIR>`은
전달받은 세 파일이 있는 디렉터리입니다. `cp -n`은 같은 이름의 기존 파일을 덮어쓰지 않습니다.

```bash
cd "$INSTALL_ROOT" && mkdir -p images &&
cp -n "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz" \
      "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz.sha256" \
      "<BUNDLE_DIR>/lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt" images/ &&
ls -l images/
```

### 4.2 `.env` 만들기

실행 위치: 설치 서버, `INSTALL_ROOT`. `.env`가 이미 있으면 덮어쓰지 않도록 `-n`을 씁니다.

```bash
cp -n .env.example .env
vi .env
```

| 변수 | 정할 값 |
|------|---------|
| `EXTERNAL_URL` | 사용자가 접속하는 `http(s)://host[:port]`. `localhost`/`127.0.0.1` 금지. 기본 포트(80/443)가 아니면 포트를 포함 |
| `BROKER_WS_URL` | TC 본체 게이트웨이의 `/mqtt`. `https`면 `wss://`, `http`면 `ws://` |
| `PUBLIC_BROKER_WS_URL` | 외부 클라이언트가 붙는 `/mqtt`. DMZ 프록시가 없으면 `BROKER_WS_URL`과 같은 값 |
| `LUCY_ADMIN_EMAIL`, `LUCY_ADMIN_PASSWORD` | 관리자 계정. 최초 기동 때만 적용 |
| `LUCY_ADMIN_NAME` | `admin` 그대로 둡니다 |
| `DB_ROOT_PASSWORD`, `DB_USERNAME`, `DB_PASSWORD` | DB 계정. 최초 기동 때만 적용 |
| `TZ` | 예: `Asia/Seoul` |
| `HOST_UID`, `HOST_GID` | Gitea 컨테이너 사용자 UID/GID(기본 1000). 보통 설치 계정의 `id -u`, `id -g` |

주의:

- `DB_PASSWORD`는 `DATABASE_URL=postgresql://<user>:<password>@db:5432/...`에 URI encoding 없이
  그대로 들어갑니다. `@ : / ? # %` 같은 문자가 있으면 연결 주소가 깨집니다. `.env`에서 따옴표로
  감싸도 URI encoding이 되지 않으므로 `[A-Za-z0-9._~-]` 문자만 쓰세요.
- `HOST_UID`/`HOST_GID`는 Gitea 프로세스의 UID/GID만 정합니다. 다른 서비스의 파일 권한,
  SELinux, 마운트된 디스크의 접근 문제를 해결하지 않습니다.
- 관리자·DB 값은 최초 기동 뒤 `.env`에서 바꿔도 기존 DB와 계정에 반영되지 않고 로그인이나
  DB 연결이 실패할 수 있습니다. `.env`만 고치는 것은 비밀번호 변경이 아닙니다. 바꿔야 하면 해당
  서비스가 지원하는 방법으로 서버 관리자 승인 아래 진행하고, 일상적인 계정 변경을 위해 데이터를
  지우거나 재설치하지 않습니다.

### 4.3 호스트 포트와 URL

기본 `compose.docker.yml`은 게이트웨이를 호스트 `80`, `443`으로 publish합니다. 다른 포트를 쓰려면
최초 기동 전에 `compose.docker.yml`의 `gw.ports` 왼쪽(호스트 포트)만 바꾸고, `.env`의 URL도
같은 포트로 맞춥니다. 오른쪽 컨테이너 포트 `:80`, `:443`은 바꾸지 않습니다. `.env`만 바꿔서는
publish 포트가 바뀌지 않습니다.

```yaml
# compose.docker.yml — 예: 8080/8443을 쓰는 경우
  gw:
    ports:
      - "8080:80"
      - "8443:443"
```

아래 `<...>`는 설명용 placeholder이며 실제 파일에는 호스트/domain과 숫자 포트를 넣습니다.

| 구성 | `.env` |
|------|--------|
| HTTPS, DMZ 프록시 없음 | `EXTERNAL_URL=https://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>`<br>`BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt`<br>`PUBLIC_BROKER_WS_URL=wss://<ONPREM_HOST>:<ONPREM_HTTPS_PORT>/mqtt` |
| HTTP(테스트), DMZ 프록시 없음 | `EXTERNAL_URL=http://<ONPREM_HOST>:<ONPREM_HTTP_PORT>`<br>`BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt`<br>`PUBLIC_BROKER_WS_URL=ws://<ONPREM_HOST>:<ONPREM_HTTP_PORT>/mqtt` |
| HTTPS + DMZ WSS 프록시 | 위 HTTPS의 앞 두 줄 그대로, `PUBLIC_BROKER_WS_URL=wss://<DMZ_HOST>:<DMZ_WSS_PORT>/mqtt` |
| HTTP + DMZ plain WS(테스트) | 위 HTTP의 앞 두 줄 그대로, `PUBLIC_BROKER_WS_URL=ws://<DMZ_HOST>:<DMZ_WS_PORT>/mqtt` |

- 포트가 80(http)/443(https)이면 URL에서 `:<port>`를 생략해도 됩니다.
- DMZ 서버의 포트는 DMZ 서버 Compose에서 따로 정합니다. TC 본체 포트와 서로 영향이 없습니다.
- 방화벽: 클라이언트 → TC 게이트웨이 호스트 포트만 엽니다. DMZ 프록시를 쓰면 클라이언트 → DMZ `/mqtt` 포트,
  DMZ 서버 → TC 게이트웨이 포트를 추가합니다. DB `5432`, 브로커 `1883`/`8080`은 publish되지 않으며
  열 필요가 없습니다.

#### 웹과 MQTT를 서로 다른 포트로 공개하려면

수동 설치에서는 가능합니다. 예를 들어 웹은 `8443`, MQTT는 `9443`을 쓰되 둘 다 게이트웨이의
HTTPS 포트 `443`으로 연결합니다. 브로커의 내부 `8080` 포트를 바꾸거나 공개하지 않습니다.
최초 기동 전의 설정 예시이며, 운영 중 변경은 별도 설정 변경 작업으로 계획하세요.

```yaml
  gw:
    ports:
      - "8080:80"
      - "8443:443"
      - "9443:443"
```

```dotenv
EXTERNAL_URL=https://teamcloud.example.com:8443
BROKER_WS_URL=wss://teamcloud.example.com:9443/mqtt
PUBLIC_BROKER_WS_URL=wss://teamcloud.example.com:9443/mqtt
```

두 TLS 포트에 같은 호스트 인증서를 사용합니다. HTTPS 화면에서 평문 `ws://`를 쓰면 브라우저가
차단할 수 있으므로 `wss://`를 맞춥니다. TUI는 이 분리 구성을 입력받지 않습니다.

### 4.4 license 배치

실행 위치: 설치 서버, `INSTALL_ROOT`.

```bash
cp /path/to/license.json license/license.json
```

라이선스가 없거나 잘못되면 `tc-be`가 시작 중 종료합니다. 발급·갱신 문의: `support@edencrew.com`.

### 4.5 최초 기동: 온라인 서버

온라인(4.5)과 폐쇄망(4.6) 중 하나만 실행합니다. 첫 기동에서 `init-secrets`가
`secrets/secrets.env`와, 없을 때만 자체 서명 `nginx/certs/server.crt`/`server.key`를 만들고
`Exited (0)`으로 끝납니다. 이미 있는 파일은 건드리지 않으므로 운영 인증서를 미리
`nginx/certs/`에 넣어 두어도 됩니다.

실행 위치: 설치 서버, `INSTALL_ROOT`. 레지스트리에 접속 가능한 서버에서 필요한 이미지를 받고
`init-secrets` 이미지를 빌드한 뒤 전체를 시작합니다.

`init-secrets`는 `compose.docker.init-secrets.yml`로 분리되어 있어 최초 설치(또는 `secrets/`·인증서
누락) 때만 명시적으로 먼저 실행합니다. 업데이트에서는 실행하지 않습니다.

```bash
docker compose --env-file .env -f compose.docker.yml -f compose.docker.init-secrets.yml run --rm --build init-secrets
docker compose --env-file .env -f compose.docker.yml up -d
```

### 4.6 최초 기동: 폐쇄망 서버

실행 위치: 설치 서버, `INSTALL_ROOT`. 먼저 번들을 Docker 이미지 저장소에 등록합니다.

```bash
./scripts/load-compose-images-docker.sh ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
```

로더는 압축 파일과 같은 디렉터리의 sidecar를 씁니다: `<archive>.sha256`(예: `X.tar.gz.sha256`)이
있으면 체크섬을 검사하고(없으면 경고 후 진행), gzip 무결성을 검사하고, 같은 stem의
`X.images.txt`로 Docker용 목록인지 확인한 뒤 `docker load` 후 목록의 모든 이미지가 있는지 확인합니다.
체크섬은 파일 손상만 검사하며 릴리스 버전이 맞는지는 판단하지 않습니다. 상대 압축 파일 경로는
현재 디렉터리가 아니라 릴리스 루트(`PROJECT_ROOT`를 지정하지 않으면 `scripts/`의 상위 디렉터리)
기준으로 해석됩니다. 마지막에 `Load complete.`가 나와야 성공이며, `[ERROR]`로 끝나면 다음
단계로 가지 말고 원인(파일 누락·손상, Podman용 번들 사용 등)을 해결합니다.

불러오기가 성공한 뒤에만 시작합니다. `--pull never`는 레지스트리 접근을 막고, `--no-build`는 빌드를
막습니다. 최초 설치(또는 `secrets/`·인증서 누락) 때만 bootstrap 을 먼저 실행하며, 업데이트에서는
실행하지 않습니다.

```bash
docker compose --env-file .env -f compose.docker.yml -f compose.docker.init-secrets.yml run --rm --no-deps init-secrets
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

### 4.7 성공 확인

실행 위치: 설치 서버, `INSTALL_ROOT`.

```bash
docker compose --env-file .env -f compose.docker.yml ps -a
docker compose --env-file .env -f compose.docker.yml logs --tail=100 tc-be
```

- `init-secrets`는 `Exited (0)`, 나머지 9개는 `Up`이고 `db`, `auth-be`, `tc-be`, `studio-dl`은
  `(healthy)`가 정상입니다. healthcheck가 끝날 때까지 1~2분 걸릴 수 있습니다.
- 브라우저에서 `EXTERNAL_URL`에 접속해 관리자 계정으로 로그인합니다. 자체 서명 인증서면
  브라우저 경고가 나옵니다. 실제 클라이언트의 `/mqtt` 연결과 메시지 송수신도 따로 확인합니다
  ([3.12](#312-설치-후-확인과-주의사항)의 설치 후 확인 표와 같은 기준).
- 이어서 [Studio 릴리스 업로드](README.md#studio-릴리스-업로드)를 합니다. 첫 업로드 전 `/studio/*`
  404는 정상입니다.

## 5. 운영

이 장의 명령은 수동 설치(`compose.docker.yml`)에만 적용합니다. TUI 설치는
[3.10](#310-설치-후-상태와-로그)을 봅니다.

모든 명령: 실행 위치: 설치 서버, `INSTALL_ROOT`, 설치한 계정.

| 작업 | 명령 |
|------|------|
| 상태 | `docker compose --env-file .env -f compose.docker.yml ps -a` |
| 로그 | `docker compose --env-file .env -f compose.docker.yml logs --tail=200 <서비스>` |
| 서비스 하나 재시작 | `docker compose --env-file .env -f compose.docker.yml restart <서비스>` |
| 정지(컨테이너 유지) | `docker compose --env-file .env -f compose.docker.yml stop` |
| 다시 시작 | `docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build` |
| 컨테이너 제거 | `docker compose --env-file .env -f compose.docker.yml down` (바인드 마운트 데이터와 `studio-release` 볼륨은 남음) |

`down -v`는 쓰지 않습니다. `studio-release` 볼륨이 지워져 Studio를 다시 업로드해야 합니다.

`.env` 값을 바꾼 경우 `restart`로는 반영되지 않습니다. 위 "다시 시작" 명령으로 컨테이너를
다시 만들어야 합니다. 단 관리자·DB 계정 값은 `.env`만으로 바꾸지 않습니다(4.2 참고).

### 5.1 license 갱신

새 `license.json`을 `license/license.json`에 덮어쓴 뒤 `tc-be`만 재시작합니다.

```bash
cp /path/to/new-license.json license/license.json
docker compose --env-file .env -f compose.docker.yml restart tc-be
```

### 5.2 운영 인증서 교체

`nginx/certs/server.crt`, `server.key`를 교체하고 `gw`를 재시작합니다. `auth-be`, `tc-be`도 이
인증서를 신뢰 CA로 읽으므로 함께 재시작합니다.

```bash
cp /path/to/server.key nginx/certs/server.key
cp /path/to/server.crt nginx/certs/server.crt && echo "copied"
docker compose --env-file .env -f compose.docker.yml restart gw auth-be tc-be
```

### 5.3 `EXTERNAL_URL` host를 바꾼 뒤 self-signed 인증서 다시 만들기

`init-secrets`가 만든 자체 서명 인증서이고, 호스트 변경이 계획된 경우에만 씁니다. 운영 인증서
갱신은 이 절차가 아니라 5.2로 교체합니다. `secrets/secrets.env`는 건드리지 않습니다(이미 있으므로
`init-secrets`가 그대로 둡니다). `.env`의 URL을 고친 뒤 진행합니다.

실행 위치: 설치 서버. 먼저 두 파일이 일반 파일(symlink 아님)인지, 자체 서명인지 확인합니다.
`subject`와 `issuer`가 같아야 합니다. 하나라도 실패하거나 다르면 멈추고 서버 관리자와 확인합니다.

```bash
cd "$INSTALL_ROOT" && test -f compose.docker.yml &&
test -f nginx/certs/server.crt && test ! -L nginx/certs/server.crt &&
test -f nginx/certs/server.key && test ! -L nginx/certs/server.key &&
openssl x509 -in nginx/certs/server.crt -noout -subject -issuer
```

확인되면 두 파일만 새 private 백업 디렉터리로 이동(삭제 아님)하고 다시 만듭니다. `mkdir`은 이미
있는 디렉터리면 실패하므로 기존 백업을 덮어쓰지 않습니다.

```bash
cd "$INSTALL_ROOT" &&
CERT_BACKUP="$HOME/teamcloud-cert-backup-$(date +%Y%m%d-%H%M%S)" &&
umask 077 && mkdir "$CERT_BACKUP" &&
mv nginx/certs/server.crt nginx/certs/server.key "$CERT_BACKUP/" &&
docker compose --env-file .env -f compose.docker.yml rm -f init-secrets &&
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build &&
ls -l nginx/certs/server.crt nginx/certs/server.key &&
docker compose --env-file .env -f compose.docker.yml restart gw auth-be tc-be
```

subject와 issuer 비교만으로 이 인증서의 출처가 증명되는 것은 아닙니다. 기존 설치 기록으로
init-secrets가 만든 인증서임을 확인해야 합니다. 중간에 실패하면 백업과 실패 산출물을 보존하고
중단합니다. 새 파일이 일부 만들어졌을 수 있으므로 백업 파일을 무조건 덮어쓰지 말고, 관리자가
원래 인증서·키 쌍의 복구를 확인한 뒤 4.6의 시작 명령과 `restart gw auth-be tc-be`를 실행합니다.

## 6. 이미지 버전 업데이트

이 장은 수동 설치(`compose.docker.yml`)의 이미지 태그 전용 업데이트입니다. TUI는 업데이트를 지원하지
않으므로 TUI 설치에는 이 명령을 실행하지 않고, 생성 JSON 기준의 별도 계획을 서버 소유자 승인으로
세웁니다.

### 6.1 이 절차를 써도 되는지 먼저 확인

새 릴리스의 Compose와 운영 파일을 지금 릴리스와 비교합니다. Compose `image:` 줄의 태그만
달라야 이 절차를 씁니다. 다음 중 하나라도 해당하면 중단하고 스택을 건드리지 않은 채 그 릴리스의
이관 안내를 따릅니다. Compose가 태그만 바뀌었어도 마찬가지입니다.

- 서비스 또는 이미지 추가·삭제, 이미지 경로(태그 앞부분) 변경
- `image:` 외 Compose 설정 변경
- 다른 운영 파일 변경: `.env.example`, `nginx/nginx.conf`, `studio-dl/nginx.conf`,
  `init-secrets/Dockerfile`, `init-secrets/docker-entrypoint.sh`, `postgres/initdb/01-create-user.sh`,
  `git/app.ini`, `git/gitea-entrypoint.sh`, `auth/auth-entrypoint.sh`, `tc/tc-entrypoint.sh`,
  `broker/mosquitto.conf`, `scripts/`의 불러오기·이미지 내보내기 스크립트
- `.env`, 인증서, 시크릿 또는 데이터 이관 필요

비교 방법은 릴리스 changelog를 우선 보고, 필요하면 이전 릴리스와 새 릴리스의 깨끗한 소스끼리
비교합니다(Git이 없는 서버라면 온라인 PC에서). 운영 중인 설치 루트의 `git/`, `auth/`, `broker/`
디렉터리는 데이터·로그가 섞여 있으므로 통째로 diff하지 않습니다. 설치 루트와 비교하는 것은 Compose
파일 하나입니다.

실행 위치: 설치 서버. 새 릴리스 소스를 설치 루트와 다른 곳에 두고 `NEW_SRC`로 지정합니다.

```bash
NEW_SRC="/opt/src/lucy-teamcloud-onprem-<새버전>"   # 실제 경로로 바꾸세요
diff "$INSTALL_ROOT/compose.docker.yml" "$NEW_SRC/compose.docker.yml"
```

`diff`가 아무것도 출력하지 않고 끝나면(종료 코드 0) 같은 파일입니다. 차이가 있으면 종료 코드 1과 함께
다른 줄을 출력하며, 이 경우 그 줄이 `image:` 태그뿐인지 눈으로 확인합니다. 이전에 바꾼 사용자 지정 포트
(`ports` 줄) 차이는 예상된 로컬 차이이며 이관 대상이 아닙니다. 2 이상은 파일이 없는 등 비교 실패입니다.

통과하면 설치 루트의 `compose.docker.yml`에서 바뀐 `image:` 태그만 편집기로 고칩니다. 새 파일로
통째로 덮어쓰지 않습니다. `.env`, `license/`, `secrets/`, `nginx/certs/`, `postgres/data/`,
`git/data/`, `broker/`, 사용자 지정 포트는 건드리지 않습니다. 최초 설치용 `cp .env.example .env`를 다시
하지 않습니다. 스택을 미리 내릴 필요가 없습니다.

아래 6.2와 6.3 중 하나만 실행합니다.

### 6.2 온라인 서버

실행 위치: 설치 서버, `INSTALL_ROOT`. 각 명령이 성공했을 때만 다음 명령으로 갑니다.

```bash
docker compose --env-file .env -f compose.docker.yml config --quiet
docker compose --env-file .env -f compose.docker.yml pull --ignore-buildable
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

`config --quiet`는 수정한 파일 문법을 확인합니다(출력 없음이 정상). `pull --ignore-buildable`은
빌드 대상인 `init-secrets`를 제외한 이미지를 받습니다. `up`은 태그가 바뀐 서비스만 다시 만듭니다.
`init-secrets` 이미지는 다시 빌드하지 않으며, 실행되더라도 기존 시크릿·인증서는 그대로 둡니다.

### 6.3 폐쇄망 서버

1. 온라인 PC에서 새 릴리스 태그로 Docker용 번들을 만듭니다
   ([폐쇄망 이미지 번들 만들기](README.md#폐쇄망-이미지-번들-만들기)).
2. 세 파일을 이름 그대로 설치 서버의 `$INSTALL_ROOT/images/`에 복사합니다. 이전 릴리스의 같은
   이름 파일은 새 파일로 교체됩니다.
3. 실행 위치: 설치 서버, `INSTALL_ROOT`. 불러오기 전에, 수정한 Compose가 가리키는 이미지와 받은
   `.images.txt`가 같은지 비교합니다. 중복을 제거한 두 목록의 이름·태그가 모두 같아야 합니다.
   `init-secrets`도 예외가 아니며, 다르면 불러오지 않고 번들을 다시 받습니다. 그 다음 불러오기가 `Load complete.`로
   끝난 뒤에만 `up`을 실행합니다.

```bash
cd "$INSTALL_ROOT" &&
docker compose --env-file .env -f compose.docker.yml config --images | LC_ALL=C sort -u &&
LC_ALL=C sort -u images/lucy-teamcloud-onprem-docker-images-linux-amd64.images.txt
```

```bash
./scripts/load-compose-images-docker.sh ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
```

```bash
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

### 6.4 업데이트 확인

```bash
docker compose --env-file .env -f compose.docker.yml ps -a
docker compose --env-file .env -f compose.docker.yml images
docker compose --env-file .env -f compose.docker.yml logs --tail=100 tc-be
```

`images` 출력의 태그가 새 릴리스 값이고, 4.7의 상태 기준을 만족하면 완료입니다. 화면이 이전
버전처럼 보이면 9장의 브라우저 캐시 항목을 봅니다.

이전 버전으로 되돌리기: 이미지 태그만 이전 값으로 바꿔 `up`하는 방식이 안전하다고 가정하지 않습니다.
새 버전이 한 번이라도 기동했다면 DB·Gitea 데이터가 새 버전 형식으로 바뀌었을 수 있고, 이전 이미지가
그 데이터를 다룰 수 있는지는 릴리스마다 다릅니다. 해당 릴리스 안내가 태그 되돌리기를 호환된다고
명시한 경우에만 그 방법을 쓰고, 그렇지 않으면 업데이트 전 백업을 7.3 기준으로 복원하는 계획을
서버 관리자와 세웁니다.

## 7. 백업과 복구

### 7.1 무엇을

| 경로 | 비고 |
|------|------|
| `.env`, `license/license.json`, `secrets/secrets.env` | 필수. 시크릿을 잃으면 기존 데이터를 쓸 수 없음 |
| `postgres/data/`, `git/data/` | 필수 |
| 운영 Compose: 수동 설치는 `compose.docker.yml`, TUI 설치는 생성된 `compose.installer.json` | 권장(사용자 지정 포트 등). 운영에 실제로 쓰는 Compose를 백업하고, 복원·운영 때도 같은 파일을 씁니다 |
| `nginx/certs/`, 직접 수정한 `nginx/` 설정 | 권장(운영 인증서, 로컬 설정) |
| `broker/data/`, `broker/logs/`, `auth/logs/`, `tc/logs/` | 선택 |
| 네임드 볼륨 `studio-release` | 백업 대신 원본 Studio 번들을 보관해 두었다가 다시 업로드 |

아래 명령은 수동 YAML 설치용입니다. TUI 설치는 같은 원칙(정지 후 복사, 설치 루트 밖 접근이 제한된 경로,
실패 시 중단)으로 설치 경로와 생성 JSON을 써서 별도로 계획합니다.

### 7.2 정지 후 백업

PostgreSQL이 실행 중일 때 `postgres/data/`를 복사하면 일관된 백업이 보장되지 않습니다.
서비스를 멈춘 상태에서 복사합니다. 정지하는 동안 서비스가 중단됩니다.

실행 위치: 설치 서버. 먼저, 멈추기 전에 설치 루트 밖의 private 백업 디렉터리를 정하고 쓸 수
있는지 확인합니다. 예시는 현재 계정 home 아래 하위 디렉터리입니다(`HOME` 변수 자체는 바꾸지 않습니다).

```bash
BACKUP_DIR="$HOME/teamcloud-backups"   # 설치 루트 밖, 이 계정만 읽는 위치
umask 077 && mkdir -p "$BACKUP_DIR" && test -w "$BACKUP_DIR" &&
INSTALL_ROOT="$(cd "$INSTALL_ROOT" && pwd -P)" &&
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)" &&
case "$BACKUP_DIR/" in "$INSTALL_ROOT"/*) echo "STOP: 설치 루트 안입니다"; false ;; esac &&
BACKUP_FILE="$BACKUP_DIR/teamcloud-$(date +%Y%m%d-%H%M%S).tar.gz" &&
test ! -e "$BACKUP_FILE" && echo "backup target OK: $BACKUP_FILE"
```

`backup target OK`가 나왔을 때만 다음을 실행합니다. 정지·압축·목록 확인이 하나라도 실패하면 그
자리에서 멈춥니다.

```bash
cd "$INSTALL_ROOT" &&
docker compose --env-file .env -f compose.docker.yml stop &&
tar -czf "$BACKUP_FILE" .env compose.docker.yml license/license.json secrets nginx/certs postgres/data git/data broker/data &&
tar -tzf "$BACKUP_FILE" >/dev/null && echo "backup OK: $BACKUP_FILE"
```

`backup OK`를 확인한 뒤에만 다시 시작합니다.

```bash
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

실패하면 스택은 멈춘 상태로 남습니다. 그 압축 파일은 불완전하므로 쓰지 않습니다. 원인을 정리하기
전에 운영을 재개할지는 서버 관리자가 결정하고, 승인되면 위 시작 명령을 실행합니다.
`tar`가 `Permission denied`로 실패하면 컨테이너가 만든 파일을 현재 계정이 읽지 못하는 것이므로,
서버 관리자와 백업 실행 계정을 정한 뒤 다시 받습니다. `chown`이나 `chmod`로 데이터 소유권을 바꾸지
마세요.

### 7.3 복구

복구는 데이터를 덮어쓰는 작업이므로 모든 서버에 그대로 붙여 넣을 수 있는 명령은 제공하지 않습니다.
서버 관리자와 다음을 확인한 계획을 세운 뒤 진행합니다.

- 대상: 백업을 만든 것과 같은 릴리스(같은 이미지 태그)의 설치 루트. 다른 릴리스로 복원하려면 그
  릴리스 안내가 해당 데이터 버전과의 호환을 명시해야 합니다.
- 격리: 승인된 대상 설치 루트에서 `docker compose --env-file .env -f compose.docker.yml down`으로
  스택이 멈춰 있고, 다른 프로세스가 그 데이터 경로를 쓰지 않아야 합니다. 가능하면 운영 루트가 아닌
  별도 경로에 먼저 풀어 내용을 확인합니다.
- 기존 데이터: `tar -tzf "<백업 파일>"`로 백업에 든 정확한 경로를 확인하고, 대상에 같은 경로가
  있으면 삭제하지 않고 보존합니다. 보존 위치가 이미 존재하는지 먼저 확인하고, 경로를 일괄로
  `mv`/`rm`하지 않습니다.
- 확인: 복원 후 4.6의 `up -d --pull never --no-build`로 시작하고 4.7로 확인한 뒤 Studio 번들을
  다시 업로드합니다.

## 8. Offline Image Bundle

생성 방법과 파일 설명은 [루트 README의 폐쇄망 이미지 번들 만들기](README.md#폐쇄망-이미지-번들-만들기)에
있습니다. `images/`는 압축 파일 보관 위치일 뿐이고, Compose는 로더(수동 설치) 또는 설치기(TUI)가
Docker 이미지 저장소에 등록한 같은 이름·태그의 이미지를 사용합니다.

## 9. 문제 해결

아래 진단 명령은 상태를 바꾸지 않습니다. 실행 위치: 설치 서버, `INSTALL_ROOT`(수동 설치). TUI
설치는 [3.10](#310-설치-후-상태와-로그)의 명령을 설치 경로에서 실행하고, 실패 대응은
[3.11](#311-실패했을-때)을 봅니다.

```bash
docker compose --env-file .env -f compose.docker.yml ps -a
docker compose --env-file .env -f compose.docker.yml config --quiet
docker compose --env-file .env -f compose.docker.yml logs --tail=200 "<서비스>"
```

| 증상 | 확인 | 조치 |
|------|------|------|
| `tc-be`가 바로 종료 | `logs tc-be`에 라이선스 오류 | `license/license.json` 위치·파일 확인 후 `restart tc-be` |
| `auth-be`/`tc-be`가 DB 연결 실패 | `logs auth-be tc-be` | `DB_PASSWORD`에 URI 특수문자가 있는지, 최초 기동 뒤 DB 값을 바꿨는지 확인. 바꿨다면 원래 값으로 되돌림 |
| `Container ...-db-1 Error`만 보임 | `logs --tail=100 db` | 불러오기 실패로 단정하지 말고 DB 로그를 봄 |
| DB 로그에 `/docker-entrypoint-initdb.d/: Permission denied` | `ls -l postgres/initdb/`, `getenforce`(SELinux 사용 시) | 아래 initdb 항목 |
| `gw` 시작 실패, `port is already allocated` | `ss -ltnp` 로 호스트 포트 사용 확인 | 다른 포트를 쓰려면 4.3대로 `gw.ports`와 `.env`를 함께 바꾸고 다시 시작 |
| `gw`가 인증서 파일 오류 | `ls -l nginx/certs/` | `init-secrets` 로그 확인. 운영 인증서면 파일 이름이 `server.crt`/`server.key`인지 확인 |
| 폐쇄망에서 `pull access denied` 또는 레지스트리 접속 시도 | `docker image ls` | 불러오기가 성공했는지, Compose 태그와 번들이 같은 릴리스인지 확인. 시작 명령에 `--pull never`가 있는지 확인 |
| 새 버전인데 이전 화면, 로그인 중 `invalid_grant`/`authorization code expired` | — | 브라우저의 Service Worker 등록 해제와 사이트 데이터 삭제(DevTools → Application) |
| `/studio/*` 404 | `curl -k https://<TC 주소>/studio/latest.json` | 첫 업로드 전이면 정상. [Studio 릴리스 업로드](README.md#studio-릴리스-업로드) |

### `postgres/initdb` Permission denied

DB 컨테이너가 `postgres/initdb/01-create-user.sh`를 읽지 못하는 경우입니다. 먼저 읽기 전용으로 확인합니다.

```bash
ls -ld postgres postgres/initdb
ls -l postgres/initdb/01-create-user.sh
```

패키지 파일의 읽기 권한이 사라진 것이 확인된 경우에만 이 세 경로만 복구합니다.

```bash
chmod 755 postgres postgres/initdb
chmod 644 postgres/initdb/01-create-user.sh
```

SELinux Enforcing 서버라면 label 변경은 서버 관리자 승인 범위입니다. `ls -lZ postgres/initdb`
결과와 audit log를 전달하고, 이 문서에서 SELinux 설정을 바꾸지 않습니다. 첫 기동이 initdb
단계에서 실패해 `postgres/data/`가 반쯤 만들어졌다면 DB 초기화가 다시 실행되지 않을 수 있으니,
데이터가 없는 신규 설치인지 확인한 뒤 관리자와 함께 처리합니다.

### export 오류 (온라인 PC)

| 메시지 | 원인 | 조치 |
|--------|------|------|
| `unknown flag: --platform` | 온라인 PC의 Docker가 `docker save --platform`을 지원하지 않음 | Docker Desktop/Engine을 업데이트한 뒤 같은 릴리스 태그에서 이미지 내보내기 재실행 |
| `does not provide the specified platform (linux/amd64)` 또는 `Built image has wrong platform` | Buildx가 없거나 다른 플랫폼으로 빌드됨 | `docker buildx version` 확인, Docker 업데이트 후 재실행 |
| `Docker buildx is required` | Buildx 없음 | Docker Buildx 설치 후 재실행 |

### Tutorial 01 이 빈 프로젝트로 클론될 때 (v0.0.16 ~ v0.0.25 로 최초 설치한 환경)

증상: 시스템 프로젝트 `Tutorial 01` 을 Studio 에서 열면 내용이 없다. `tc/logs/tc-be.log` 에
`Failed to seed project "Tutorial 01": ... Failed to connect to git:80` 이 있다. 같은 부팅의 `GitUserSetup`
실패(Gitea 401)는 관리자 계정 생성 전에 첫 호출이 나간 1회성 경합으로 자동 재시도되며, 이 문제의 원인이 아니다.

원인: 패키지가 Gitea `HTTP_PORT` 를 18080 으로 바꾸면서 `git/gitea-entrypoint.sh` 의 `ROOT_URL` 에 포트를
넣지 않아, Gitea 가 돌려준 clone 주소(DB `ProjectGitRepository.cloneUrl`)가 80 포트를 가리켰다. tc-be 의
시드 push 만 이 주소를 썼고 사용자 리포(Git Proxy 경유)는 영향이 없다. 현재 패키지는
`ROOT_URL=http://git:18080/` 이고, tc-be 도 수정판부터는 push 주소를 `GIT_HOST` 로 조립해 설정에 무관하다.

복구 (기존 설치, 1회):

```bash
# 1. 패키지의 git/gitea-entrypoint.sh 를 현재 버전으로 교체한 뒤 git 재기동 (ROOT_URL 이 app.ini 에 반영된다)
docker compose --env-file .env -f compose.docker.yml restart git
docker exec <git 컨테이너> grep ROOT_URL /data/gitea/conf/app.ini    # ROOT_URL = http://git:18080/

# 2. 이미 저장된 clone 주소 정정 (<DB_USERNAME> 은 .env 의 값)
docker exec -it <db 컨테이너> psql -U <DB_USERNAME> -d lucy_teamcloud -c \
  "UPDATE \"ProjectGitRepository\" SET \"cloneUrl\" = regexp_replace(\"cloneUrl\", '^http://git/', 'http://git:18080/') WHERE \"cloneUrl\" LIKE 'http://git/%';"

# 3. tc-be 재기동 → 부팅마다 force push 하므로 자동 복구
docker compose --env-file .env -f compose.docker.yml restart tc-be
grep -E 'force-pushed|Failed to seed' tc/logs/tc-be.log
```

참고: 현재 패키지는 `git` 서비스 healthcheck 가 관리자 계정 마커(`git/data/gitea/.admin-created`)까지 확인하므로,
계정 생성이 실패하면 tc-be 가 기동하지 않고 `dependency failed to start` 로 드러난다. `git` 컨테이너 로그에서
원인(비밀번호 정책, DB 연결 등)을 확인하고 `up -d` 를 다시 실행하면 된다.

## 10. 테스트 현황

v0.0.22 설치기는 Go 테스트, 정적 빌드, Compose 설정 해석, 화면 미리보기를 확인했습니다.
공개 배포 파일의 다운로드와 체크섬도 확인했으며 해시는 3.5에 있습니다.
문서의 명령은 저장소 설정·스크립트와 대조하고 문법을 검사했습니다.

실제 Rocky Linux 9 서버에서 설치를 끝내고 TLS 신뢰, 브라우저 로그인, MQTT 메시지 송수신,
Studio 업로드까지 확인한 것은 아닙니다. rootless 포트와 바인드 마운트 권한,
SELinux, 방화벽, 인증서와 NAT·DNS 경로는 설치할 서버에서 따로 점검해야 합니다.
설치기가 이 설정을 대신 바꾸지는 않습니다.

배포 압축 파일에는 게시 당시 문서가 들어 있습니다. 동봉 문서는 실행에 필요하지 않으며,
내용이 다르면 이 안내서를 기준으로 합니다.
