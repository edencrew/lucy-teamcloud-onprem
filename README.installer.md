# TeamCloud 오프라인 설치 안내 (v0.0.22, linux/amd64)

## 미릴리스 kit_format=2

새 형식은 제품 패키지와 대상 바이너리의 capability 선언/해시를 확인합니다.
최초 TUI 설치 후 `bin/teamcloudctl`로 verify → stage → load → plan → apply를 진행합니다.
apply에는 버전·신원·백업 파일 해시에 묶인 백업 확인 파일이 필요합니다.
base/템플릿/이미지는 릴리스 소유이고 ROOT의 env·local·데이터·비밀값은 보존합니다.
관리자 준비는 `ops admin-prep --account <운영계정> --ports 18080,18443 --firewalld` 출력으로 분리합니다.
운영 계정으로 설치하며 user socket/unit을 활성화합니다. 설치기 전체를 root로 실행하지 않습니다.
현재 소스·검증·미완료 항목은 [README.infra-redesign.md](README.infra-redesign.md)에 있습니다.
공개 버전/산출물은 이번 작업으로 바뀌지 않았습니다.

---

## 공개 v0.0.22 기존 키트 안내 (보존)

아래 고정 JSON·런타임 미변경 설명과 다운로드 링크는 기존 공개 키트에 적용됩니다.
새 format 2 키트는 위 설명과 현재 재설계 기록을 사용합니다.

폐쇄망 Linux 서버에 TeamCloud 서버를 신규 설치하는 절차입니다. Docker 또는 Podman이
미리 준비된 서버에서 진행합니다. 설치에 필요한 구성 파일과 컨테이너 이미지는 키트에 들어 있어
별도로 소스를 받거나 이미지를 내려받고 빌드할 필요가 없습니다. Go와 Python도 필요하지 않습니다.
Studio 클라이언트 배포는 선택 사항이며, 필요한 경우 별도 Studio 번들을 준비합니다.

준비물은 아래 두 가지뿐입니다.

1. 사용할 런타임에 맞는 **오프라인 설치 키트** 한 개와 그 체크섬 파일
2. 발급받은 **라이선스 파일** (`license.json`)

> 키트 형식: `KIT-INFO.txt`에 `kit_format=2`가 있는 키트는 `product/teamcloud-initial.tar.gz`
> (SHA-256 = `product_sha256`)만으로 최초 TUI 설치를 합니다. 이후 업데이트는 설치된 ctl
> (`teamcloud-installer ops ...`)과 업데이트 패키지로만 하며 비밀/인증서를 재생성하지 않습니다.
> 빌드 측: `scripts/package-offline-installer.sh ... --manifest-tool <빌드 호스트용 설치기>
> --compose-binary <빌드 호스트용 Compose>` — 커밋에 split init 파일이 없으면 키트를 만들지 않습니다.

---

## 1. 어떤 파일을 받아야 하나요

두 키트 모두 [GitHub Release v0.0.22](https://github.com/edencrew/lucy-teamcloud-onprem/releases/tag/v0.0.22)에 첨부되어 있습니다. 인터넷이 되는 PC에서 받아 승인된 매체로 반입합니다.

| 런타임 | 오프라인 설치 키트 | 체크섬 |
| --- | --- | --- |
| Docker | [`teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz) | [`.sha256`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-docker.tar.gz.sha256) |
| Podman | [`teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz) | [`.sha256`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/teamcloud-offline-v0.0.22-linux-amd64-podman.tar.gz.sha256) |

서버에서 쓸 런타임에 맞는 키트 **하나만** 있으면 됩니다. 키트 안에는 설치기, Compose 실행 파일, 설치용 구성 파일, 해당 런타임의 컨테이너 이미지 전체가 들어 있습니다. 이미지가 런타임별로 다르므로 Podman 키트를 Docker 서버에, Docker 키트를 Podman 서버에 쓰지 않습니다.

> **주의:** 같은 Release에 있는 약 14MB 크기의 `teamcloud-installer-v0.0.22-linux-amd64.tar.gz`(+ `.sha256`)는 실행 도구(설치기 바이너리, docker-compose, 문서, 라이선스 고지)만 든 설치기 압축 파일입니다. 구성 파일과 이미지가 없으므로 이 파일만으로는 폐쇄망 설치를 끝낼 수 없습니다. 반드시 이름이 `teamcloud-offline-...` 로 시작하는 키트를 받으세요.

라이선스 파일은 키트와 Release 어디에도 들어 있지 않습니다. 별도로 전달받은 파일을 사용합니다. 키트에는 실제 운영용 `.env`, 비밀값, 데이터, 인증서도 들어 있지 않습니다.

**문서 버전 안내:** Release의 "Source code" 압축 파일은 태그 `v0.0.22` 시점의 고정 사본이고, 설치 안내 문서는 그 뒤에도 별도로 보완될 수 있습니다. 최신 오프라인 설치 안내는 Release에 따로 첨부한 [`README.installer.md`](https://github.com/edencrew/lucy-teamcloud-onprem/releases/download/v0.0.22/README.installer.md)를 확인하세요. 키트 안의 `README.installer.md`는 키트를 게시할 때의 문서 사본입니다. 문서가 다르더라도 키트의 구성 파일과 `KIT-INFO.txt`의 소스 커밋은 바뀌지 않으며, 설치는 받은 키트 그대로 진행합니다.

## 2. 서버 준비 상태 확인

설치기는 서버 설정을 바꾸지 않습니다. 아래 항목은 서버 관리자가 미리 갖춰 두어야 합니다.

공통

- Rocky Linux 9 등 x86_64(amd64) Linux, `bash`, `tar`, `gzip`, `sha256sum`, `curl`
- 설치할 사용자 계정으로 SSH 터미널 접속 가능 (`ssh -t` 사용, 대화형 화면이 필요합니다)
- 여유 디스크: 키트 크기의 3배 이상 권장 (키트 + 압축 해제본 + 이미지 적재 공간)
- 사용할 포트(기본 18080, 18443)가 비어 있고, 필요한 경우 방화벽이 열려 있을 것
- SELinux, 방화벽, 서브 UID/GID(`/etc/subuid`, `/etc/subgid`) 설정은 설치기가 고치지 않습니다

**Docker 로 설치할 경우**

- Docker Engine 이 설치·실행 중이고, 설치 사용자가 `docker` 명령을 sudo 없이 쓸 수 있을 것
  ```bash
  docker info >/dev/null && echo OK
  ```
- `docker compose` 플러그인이 있으면 그것을 쓰고, 없으면 키트에 든 `docker-compose-linux-amd64` 를 자동으로 씁니다.

**Podman 으로 설치할 경우**

- `podman` 이 설치되어 있고, 설치 사용자로 `podman info` 가 성공할 것
- 같은 사용자·같은 모드(rootless 또는 root)·같은 이미지 저장소의 **Podman API Unix 소켓이 이미 열려 있을 것**
  - 경로는 시스템마다 다르므로 아래 명령으로 실제 소켓을 확인합니다.
  ```bash
  SOCK="$(podman info --format '{{.Host.RemoteSocket.Path}}')" &&
  SOCK="${SOCK#unix://}" &&
  test -n "$SOCK" && test -S "$SOCK" && ls -l "$SOCK"
  ```
- 소켓이 없으면 서버 관리자에게 `podman.socket` 활성화를 요청하세요. 설치기는 소켓/서비스를 시작하거나 `sudo`, `loginctl`, 권한 변경을 하지 않습니다.
- `podman-compose`(Python) 나 Docker 는 필요 없습니다. 키트의 `docker-compose-linux-amd64` 가 Podman 소켓에 접속합니다.
- rootless 로 설치했다면 이후 상태 조회·운영도 **같은 사용자, 같은 로그인 환경**에서 하세요. 다른 사용자나 `sudo` 로 실행하면 다른 저장소를 보게 됩니다.

## 3. 폴더 배치

아래 예시는 설치 사용자의 홈 아래를 사용합니다. 경로는 바꿔도 되지만, **설치 경로(TARGET)는 아직 없는 새 경로**여야 하고 그 상위 폴더는 미리 있어야 합니다.

```text
~/teamcloud-media/                         ← 반입한 파일을 두는 곳
    teamcloud-offline-v0.0.22-linux-amd64-<runtime>.tar.gz
    teamcloud-offline-v0.0.22-linux-amd64-<runtime>.tar.gz.sha256
    license.json                           ← 발급 라이선스
~/teamcloud-kit/                           ← 키트를 푸는 곳 (새로 만듦)
    teamcloud-offline-v0.0.22-linux-amd64-<runtime>/
        README.installer.md                ← 이 문서
        KIT-INFO.txt                       ← 버전/런타임/플랫폼/소스 커밋
        SHA256SUMS                         ← 키트 내부 파일 체크섬
        teamcloud-installer                ← 설치기
        docker-compose-linux-amd64         ← 동봉 Compose
        licenses/                          ← 오픈소스 라이선스 고지
        source/                            ← 설치용 구성 파일 (--source 로 지정)
            compose.*.yml, .env.example, nginx/, git/, auth/, tc/, broker/, postgres/,
            init-secrets/, studio-dl/, scripts/
            images/
                lucy-teamcloud-onprem-<runtime>-images-linux-amd64.tar.gz
                lucy-teamcloud-onprem-<runtime>-images-linux-amd64.tar.gz.sha256
                lucy-teamcloud-onprem-<runtime>-images-linux-amd64.images.txt
~/teamcloud/                               ← 설치 경로의 상위 폴더 (미리 만듦)
    runtime/                               ← 설치 경로 TARGET (설치기가 새로 만듦)
```

`<runtime>` 은 `docker` 또는 `podman` 입니다. 아래 명령에서는 변수로 지정해 두고 사용합니다.
`RT` 는 반입한 키트 이름의 런타임과 같아야 합니다. 아래 예시는 Docker 기준이며, **Podman 키트로 설치할 때는 첫 줄을 `RT=podman` 으로 바꿔 실행합니다.**

```bash
RT=docker            # Podman 이면 RT=podman
case "$RT" in docker|podman) ;; *) printf '런타임을 확인하세요\n' >&2; false ;; esac
KIT=teamcloud-offline-v0.0.22-linux-amd64-$RT
TARGET="$HOME/teamcloud/runtime"
```

새 셸을 열면 위 변수 설정을 다시 실행합니다. 아래 명령은 같은 셸에서 순서대로 진행합니다.

## 4. 체크섬 확인과 압축 해제

```bash
cd ~/teamcloud-media &&
sha256sum -c "$KIT.tar.gz.sha256"            # "OK" 가 나와야 합니다
```

`OK` 가 아니면 파일이 손상된 것입니다. 진행하지 말고 파일을 다시 받으세요.

압축을 풀기 전에 내용물에 절대 경로, `..`, 링크가 없는지 확인합니다. 아래 두 명령은 **아무것도 출력하지 않아야** 합니다.

```bash
tar -tzf "$KIT.tar.gz" | grep -v "^$KIT/" ; tar -tzf "$KIT.tar.gz" | grep -E '(^/|(^|/)\.\.(/|$))'
tar -tvzf "$KIT.tar.gz" | grep -v '^[-d]'
```

새 폴더에 풉니다. 이미 같은 폴더가 있으면 지우거나 덮어쓰지 말고 다른 이름의 빈 폴더를 사용하세요.

```bash
mkdir ~/teamcloud-kit &&
tar -xzf ~/teamcloud-media/"$KIT.tar.gz" -C ~/teamcloud-kit --no-same-owner &&
cd ~/teamcloud-kit/"$KIT" &&
sha256sum -c --quiet SHA256SUMS &&
cat KIT-INFO.txt &&
./teamcloud-installer --version
```

내부 체크섬 검사가 끝나고 `KIT-INFO.txt`의 런타임·버전·플랫폼이 선택한 키트와 같아야 합니다.
설치기 버전은 `teamcloud-installer 0.0.22`여야 합니다. 중간에 실패하면 다음 절로 넘어가지 않습니다.

## 5. 라이선스 파일 확인

라이선스 파일은 설치 화면에서 경로만 지정하면 설치기가 `TARGET/license/license.json` 으로 복사합니다. 먼저 일반 파일인지(링크가 아닌지) 확인하고 권한을 정리합니다.

```bash
LIC="$HOME/teamcloud-media/license.json"
test -f "$LIC" && test ! -L "$LIC" &&
chmod 600 "$LIC" &&
ls -l "$LIC"                               # 설치 사용자 소유인지 확인
```

라이선스 파일은 키트 폴더 안에 두지 말고, 메일·메신저 등으로 다시 보내지 마세요.

## 6. 설치 경로의 상위 폴더 준비

```bash
test ! -L "$HOME/teamcloud" &&
mkdir -p "$HOME/teamcloud" &&
test ! -e "$TARGET" && test ! -L "$TARGET" &&
printf '설치 화면에 입력할 경로: %s\n' "$TARGET"
```

설치기는 **새 설치만** 지원합니다. TARGET 이 이미 있으면 점검 단계에서 멈춥니다. 홈 디렉터리 자체, 시스템 경로(`/etc`, `/usr`, `/var/lib/docker` 등), 키트의 `source/` 와 겹치는 경로는 쓸 수 없습니다.

## 7. 설치기 실행

키트 폴더에서 런타임과 소스 경로를 명시해 실행합니다. 설치 화면의 설치 대상 경로는
위에서 출력한 `TARGET` 값으로 바꿉니다. 기본값을 그대로 두면 키트 폴더 아래에 설치될 수 있습니다.

```bash
cd ~/teamcloud-kit/"$KIT" &&
./teamcloud-installer --runtime "$RT" --source "$PWD/source"
```

- `--runtime` 은 키트 종류와 같아야 합니다. 다르면 이미지 번들 점검에서 멈춥니다.
- 이미지 번들 경로는 `source/images/` 의 파일로 자동 입력됩니다.
- SSH 로 접속했다면 `ssh -t` 로 접속하고, 파이프나 리다이렉션 없이 실행하세요.

### 화면 조작

| 키 | 동작 |
| --- | --- |
| ↑ / ↓ | 항목 이동 |
| Enter | 항목 편집 시작 / 편집 값 확정 (선택형 항목은 다음 값으로 변경) |
| ← / → | 선택형 항목 값 변경 (https/http, generate/supplied 등) |
| Esc | 편집 취소, 점검 결과 화면에서는 입력 화면으로 돌아가기 |
| Tab, PgDn | 다음 페이지 (마지막 페이지에서는 사전 점검 시작) |
| Shift+Tab, PgUp | 이전 페이지 |
| r | 설치 전 점검 실행 또는 다시 점검 |
| q | 입력 화면에서 종료 (설치하지 않음) |

비밀번호 항목은 화면에 가려지며, 빈 값으로 Enter 를 누르면 기존 값이 유지됩니다.

### 입력 항목

| 항목 | 설명 / 제약 |
| --- | --- |
| 소스 경로 | `--source` 로 지정한 `.../source`. 그대로 둡니다 |
| 설치 경로 (TARGET) | 예: `/home/<사용자>/teamcloud/runtime`. 절대 경로, 존재하지 않는 새 경로 |
| 이미지 번들 | `source/images/lucy-teamcloud-onprem-<runtime>-images-linux-amd64.tar.gz` (자동 입력) |
| 라이선스 파일 | 예: `/home/<사용자>/teamcloud-media/license.json`. 일반 파일, 올바른 JSON |
| 호스트 | 사용자가 접속할 DNS 이름 또는 IPv4. IPv6 는 지원하지 않습니다 |
| 스킴 | `https`(기본) 또는 `http` |
| HTTP 포트 / HTTPS 포트 | 1024~65535, 서로 달라야 함. 기본 18080 / 18443 |
| 관리자 이름 | `admin` 고정 |
| 관리자 이메일 | 첫 로그인 계정. 이메일 형식 |
| 관리자 비밀번호 | 8자 이상 ASCII. 공백, `'` `"` `\` `` ` `` `$` 사용 불가 |
| DB 사용자 | 소문자 또는 `_`로 시작, 이후 소문자·숫자·`_`만, 최대 63자 (기본 `lucy`) |
| DB 비밀번호 / DB root 비밀번호 | 8자 이상, 영문·숫자와 `. _ ~ -` 만 |
| 시간대 | 예: `Asia/Seoul` |
| HOST UID / HOST GID | 숫자. 기본은 설치 사용자의 UID/GID. 특별한 이유가 없으면 그대로 둡니다 |
| 대상 플랫폼 | `linux/amd64` (이 키트는 amd64 전용) |
| 인증서 방식 | `generate`: 자체 서명 인증서 자동 생성 / `supplied`: 보유한 인증서 사용 |
| 인증서 파일 / 키 파일 | `supplied` 일 때만. PEM 형식 CRT/KEY 의 절대 경로 |
| 런타임 | `--runtime` 으로 지정한 값 |

UID/GID 자동 입력은 바인드 마운트·subuid 매핑·SELinux 권한 문제를 해결하지 않습니다.
관리자 이메일의 예시 기본값은 실제 사용할 주소로 바꿉니다. 비밀번호는 승인된 방법으로 보관하세요.

접속 주소는 `스킴://호스트:포트` 로 정해집니다. 예를 들어 https, 호스트 `teamcloud.example.local`, HTTPS 포트 18443 이면

- 웹: `https://teamcloud.example.local:18443`
- 실시간(MQTT over WebSocket): `wss://teamcloud.example.local:18443/mqtt`

웹과 MQTT 는 같은 포트를 씁니다. 이 설치기는 DMZ 프록시 구성을 다루지 않습니다.

### 사전 점검과 설치

1. 마지막 페이지에서 Tab 을 누르면 **사전 점검**이 실행됩니다. 런타임 연결, 소스 파일, 설치 경로, 라이선스, 인증서, 포트, 디스크, 이미지 번들(SHA-256, gzip 전체 검사, 이미지 목록과 Compose 구성 비교)을 확인합니다. 번들 검사는 수 분 걸릴 수 있습니다.
2. 오류가 있으면 Esc 로 돌아가 고친 뒤 다시 점검합니다(r).
3. 모두 통과하면 Enter → 확인 화면에서 **`INSTALL`** 을 정확히 입력하고 Enter.

설치 중 하는 일

- **Docker**: TARGET 생성 → 필요한 구성 파일만 복사 → 라이선스 복사 → 이미지 적재 → `.env`, `compose.installer.json`(권한 0600) 작성 → 서비스 시작 → 상태 확인.
  정상 결과는 `init-secrets` 가 `Exited (0)`, 나머지 **9개**(auth-be, auth-fe, broker, db, git, gw, studio-dl, tc-be, tc-fe)가 running/healthy 이고 `gateway /health: HTTP 200` 입니다.
- **Podman**: 위와 같고, 추가로 `compose.installer.init-secrets.json` 을 작성해 `init-secrets` 를 `run --rm` 으로 한 번 실행합니다. 이 컨테이너는 실행 후 지워지는 것이 정상이며, 결과물(`secrets/secrets.env`, `nginx/certs/` 인증서)이 생겼는지 확인한 뒤 본 서비스 **9개**를 시작합니다.

설치 결과 화면은 q 또는 Esc 로 닫습니다.

## 8. 설치 후 확인

### 상태 조회

```bash
cd ~/teamcloud-kit/"$KIT" &&
./teamcloud-installer --status "$TARGET"
echo $?                                    # 0 이면 ready
```

- 런타임은 설치 시 기록된 값을 자동으로 사용합니다.
- Docker 는 `docker compose` 플러그인이 있으면 그것을, 없으면 키트의 `docker-compose-linux-amd64` 를 씁니다.
- Podman 은 설치한 사용자와 같은 사용자로 실행해야 하며, 출력의 `런타임: Podman (...)` 줄에 실제 사용 중인 소켓 경로가 표시됩니다.
- 설치 결과의 상세 구성은 TARGET 의 `compose.installer.json`(Podman 은 `compose.installer.init-secrets.json` 포함)에 있습니다. 비밀값이 들어 있으므로 복사·전송하지 마세요.

### 로그 확인

아래 명령도 설치할 때와 같은 사용자와 Docker 컨텍스트 또는 Podman 모드·소켓으로 실행합니다.
소스 YAML이 아니라 설치 경로의 생성 JSON을 사용합니다.

Docker:

```bash
KIT_DIR="$HOME/teamcloud-kit/$KIT"
"$KIT_DIR/docker-compose-linux-amd64" --project-directory "$TARGET" --env-file "$TARGET/.env" -f "$TARGET/compose.installer.json" ps &&
"$KIT_DIR/docker-compose-linux-amd64" --project-directory "$TARGET" --env-file "$TARGET/.env" -f "$TARGET/compose.installer.json" logs --tail 100 tc-be
```

Podman:

```bash
KIT_DIR="$HOME/teamcloud-kit/$KIT"
SOCK="$(podman info --format '{{.Host.RemoteSocket.Path}}')" &&
SOCK="${SOCK#unix://}" &&
test -n "$SOCK" && test -S "$SOCK" &&
DOCKER_HOST="unix://$SOCK" "$KIT_DIR/docker-compose-linux-amd64" --project-directory "$TARGET" --env-file "$TARGET/.env" -f "$TARGET/compose.installer.json" ps &&
DOCKER_HOST="unix://$SOCK" "$KIT_DIR/docker-compose-linux-amd64" --project-directory "$TARGET" --env-file "$TARGET/.env" -f "$TARGET/compose.installer.json" logs --tail 100 tc-be
```

`--status`는 컨테이너 상태를 확인합니다. HTTP 응답, 인증서 신뢰, 로그인과 MQTT 동작까지 검사하지는 않습니다.

kit-format-2 ROOT의 `teamcloudctl status --root <ROOT> --runtime podman`(= `ops status`)은 위 레거시 `--status`와 별개인
읽기 전용 관찰입니다. 기존 `active-release`/`pending-apply` 줄을 유지하고 receipt identity, active release, 서비스별
`running=`/`health=`, 로컬 `127.0.0.1:<게시 포트>/health` gateway 응답(TLS 검증 유지, redirect 미추종)을 따로 표시합니다.
healthcheck 미정의·조회 실패·timeout·인증서 검증 실패는 정상으로 보지 않습니다. 로그인/MQTT/SSH logout/reboot는
`unverified:`로 남습니다. exit 0=`result: OBSERVED-OK`(관찰 항목만), 1=`FAILED`, 3=`UNKNOWN`(부분 관찰), 2=사용법 오류.

로그를 공유할 때는 비밀번호·토큰·개인키 등 비밀값을 가립니다.

### 웹 접속과 인증서

브라우저에서 `https://<호스트>:<HTTPS 포트>` 로 접속해 관리자 이메일/비밀번호로 로그인합니다.

`generate` 로 설치했다면 자체 서명 인증서이므로 브라우저 경고가 나옵니다. 서버에서 실제 신뢰 확인은 다음처럼 합니다.

```bash
T=~/teamcloud/runtime
curl --cacert "$T/nginx/certs/server.crt" "https://<호스트>:<HTTPS 포트>/health"
```

인증서 오류 없이 응답이 오면 인증서의 호스트 이름이 맞는 것입니다. 사용자 PC 에서 경고 없이 쓰려면 이 인증서(`server.crt`)를 사내 정책에 따라 신뢰 저장소에 등록하세요. `supplied` 로 설치했다면 지정한 인증서가 사용됩니다.

### MQTT(실시간) 확인

`/health` 가 200 이어도 MQTT 브로커가 끝까지 동작한다는 뜻은 아닙니다. 로그인 후 실시간 갱신이 필요한 화면을 열어 실제로 반영되는지 확인하고, 클라이언트가 `wss://<호스트>:<HTTPS 포트>/mqtt` (http 설치면 `ws://...`)로 접속되는지 확인하세요.

### Studio

설치 직후 `https://<호스트>:<포트>/studio/` 아래 주소가 **404 인 것이 정상**입니다. Studio 배포 파일은 설치기가 넣지 않습니다.

Studio 를 사용하려면 별도로 발급받은 Studio 번들 파일과 조직 owner 의 PAT(api 권한)가 필요하며, owner 승인 후 아래처럼 올립니다. 업로드 스크립트는 설치 시 TARGET 에 복사되어 있습니다.

```bash
cd ~/teamcloud/runtime
CACERT=nginx/certs/server.crt bash scripts/studio-upload.sh "/경로/studio-번들.tar.gz" "https://<호스트>:<HTTPS 포트>"
```

PAT 는 화면에서 입력합니다(화면에 표시되지 않음). `업로드 완료` 메시지 후 `https://<호스트>:<포트>/studio/latest.json` 의 version/build 를 확인하고, 사용한 PAT 는 TeamCloud 웹에서 폐기하세요.

## 9. 문제가 생겼을 때

- 설치기는 실패 시 **자동 정리, 롤백, 재시도를 하지 않습니다.** 만들어진 파일과 컨테이너는 원인 확인을 위해 그대로 남습니다.
- 실패 화면과 `--status` 출력(비밀값은 가려짐)을 그대로 보관해 담당자에게 전달하세요.
- 같은 TARGET 으로 다시 설치할 수 없습니다. 임의로 컨테이너·볼륨·폴더를 지우고 재시도하지 말고, 원인을 확인한 뒤 정리 방법을 담당자와 협의하세요. 새로 설치해 볼 때는 다른 새 TARGET 을 사용합니다.
- 자주 보는 원인
  - 포트 사용 중 → 다른 포트를 입력하거나 사용 중인 프로세스를 관리자와 확인
  - Podman 소켓 없음 → 관리자에게 같은 사용자의 `podman.socket` 활성화 요청
  - 이미지 번들 오류 → 4장의 체크섬 확인부터 다시 (키트 재반입)
  - 볼륨 쓰기 권한/SELinux 거부 → 서버 관리자 확인 필요 (설치기가 고치지 않음)

## 10. 참고 사항

- 이 키트는 linux/amd64 전용입니다.
- 대상 서버에는 인터넷 연결이 필요 없습니다.
- Rocky Linux 9 실서버에서의 최종 인수 검증 결과를 이 문서가 보장하지는 않습니다. 운영 반영 전 시험 서버에서 먼저 설치해 보세요.
- `licenses/` 폴더에 동봉 소프트웨어의 라이선스 고지가 있습니다.

---

## 부록: 키트 제작 (배포 담당자 전용)

> 이 절은 인터넷이 되는 빌드 PC 에서 키트를 만드는 담당자용입니다. 폐쇄망 설치 작업자는 읽을 필요가 없습니다.

준비물: onprem Git 저장소(정확한 릴리스 커밋 포함), 기존 설치기 아카이브(평면 파일 9개 + `SHA256SUMS`), 해당 커밋에서 **새로 내보낸** 런타임별 이미지 번들(`.tar.gz`, `.tar.gz.sha256`, `.images.txt`), `docker compose`.

로컬 제작본은 Git에서 제외한 `release-assets/v0.0.22/` 아래 별도 출력 디렉터리에 보관합니다. 기존 제작본과 공개 Release 파일은 덮어쓰지 않습니다.

```bash
INSTALLER_ARCHIVE=/path/to/teamcloud-installer-v0.0.22-linux-amd64.tar.gz
scripts/package-offline-installer.sh \
  --runtime docker \
  --source-repo /path/to/lucy-teamcloud-onprem --commit b796b24b43115cc115e76e348e701de8cffed52f \
  --installer-archive "$INSTALLER_ARCHIVE" \
  --image-bundle /path/to/export-docker/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz \
  --output-dir /path/to/dist
```

Podman 키트는 `--runtime podman` 과 Podman 번들로 한 번 더 실행합니다. 로컬에 태그가 없어도 위 커밋이 있으면 됩니다. 태그까지 대조하려면 `--ref v0.0.22`를 추가합니다.
스크립트는 커밋 내용을 `git archive` 로 꺼내므로 작업 트리의 `.env`, 라이선스, 인증서, 데이터, 오래된 `images/` 는 들어가지 않습니다. 이미지 목록이 해당 커밋의 Compose 이미지 집합과 다르거나, 체크섬·gzip·설치기 아카이브 검증이 실패하거나, 출력 파일이 이미 있으면 멈춥니다. 자세한 옵션은 `--help` 를 보세요.


## Optional Devora candidate

See [Devora installation](devora/README.md) and the exact [installer/kit interface](devora/INTERFACE.md). Devora is OFF by default; supply both `--devora-env /absolute/operator.env` and `--devora-media /absolute/media` only with prepared media and a real BE image. Operator env is never included in the kit. LLM and embedding servers are external endpoints; this option installs BE, dedicated PostgreSQL and Redis only. Local source integration is separate from real image, Podman, authentication and model acceptance.

Manual entrypoints (scripts ship as 0644; invoke with `bash`, never `./`):
`bash devora/prepare-media.sh <docker|podman> --be-repo DIR --be-image REF --out EMPTY_DIR` on the connected build host, and
`bash devora/manage.sh <docker|podman> <validate|load|bootstrap|start|stop|status> --env-file /absolute/operator.env --media-dir /absolute/media` on the target.
Keep the operator env at 0600 and outside the kit; do not paste it or its values into logs or tickets.
