# studio-dist-local — Studio 다운로드 서버 로컬 테스트

이 도구는 개발 PC에서 Studio 다운로드 서버의 라우팅과 응답 헤더를 테스트합니다.
고객 서버 설치·업데이트에는 사용하지 않습니다. 운영 패키지의 Compose도 이 디렉터리를
참조하지 않습니다. 운영 배포는 [Studio 릴리스 업로드](../../README.md#studio-릴리스-업로드)를 따릅니다.

## 무엇을 검증하나

| 모드 | 대상 |
|------|------|
| `./verify.sh --volume` (현재 패키지 구성) | 공식 `nginx:1.26-alpine` + 패키지의 `studio-dl/nginx.conf` + 네임드 볼륨. tc-be가 업로드 뒤 하는 일(`releases/<releaseId>/html` 설치, `current` 상대 심링크 교체)을 흉내 내고 gw(`nginx/nginx.conf`) 경유 `/studio/` 라우팅·헤더를 검사 |
| `./verify.sh` (이전 방식) | 피드를 이미지에 내장하던 이전 `lucy-studio-dist` 참조 구현(`Dockerfile`, `entrypoint.sh`, `nginx.conf`). 현재 패키지는 이 이미지를 쓰지 않음 |

두 모드 모두 tc-be, auth, git, 브로커 등은 nginx 더미 컨테이너이며 실제 TC 업로드 API는 검사하지 않습니다.

## 파일

| 파일 | 역할 |
|------|------|
| `build-dist.sh` | S3 버킷(기본 `lucy-studio-dist`, `BUCKET`으로 변경)의 피드·패키지로 `dist/`, `templates/`, `dist/latest.json`을 만들고 이전 방식 이미지를 빌드. TC 업로드 테스트용 번들도 생성 |
| `verify.sh` | 검증 스택 기동 → HTTP 검사 → 정리 |
| `compose.verify.yml` | gw + studio-dl + 더미 내부 서버. 프로젝트 이름 `studio-dist-verify`, 호스트 포트 `28080`/`28443` |
| `compose.verify.volume.yml` | `--volume` 덮어쓰기. 단독으로 쓰지 않고 항상 `compose.verify.yml` 뒤에 `-f`로 겹쳐 씀. studio-dl을 패키지 구성으로 바꾸고 네임드 볼륨을 더미 tc-be(rw)·studio-dl(ro)에 연결 |
| `Dockerfile`, `entrypoint.sh`, `nginx.conf` | 이전 방식 참조 구현. 패키지의 `studio-dl/nginx.conf`는 이 `nginx.conf`와 규칙이 같고 `root`만 `/srv/studio/current` |

## 준비물 (개발 PC)

- Docker 데몬과 Docker Compose v2(`compose.verify.volume.yml`의 `!reset` 태그를 지원하는 버전)
- `bash`, `curl`, `python3`
- `build-dist.sh`: AWS CLI와 해당 버킷 읽기 권한이 있는 자격 증명. `--dummy-large` 없이 실행하면 대용량 파일을 실제로 내려받음
- 저장소 루트의 `nginx/certs/server.crt`, `server.key`: gw 설정이 443을 listen하므로 필요합니다.
  로컬 스택을 한 번 띄워 `init-secrets`가 만든 파일이나 개발용 자체 서명 인증서를 둡니다.
- 호스트 포트 `28080`, `28443`이 비어 있어야 함

## 실행

실행 전 확인: `build-dist.sh`는 이 디렉터리의 `.work/`, `dist/`, `templates/`를 지우고
다시 만듭니다. `verify.sh`는 `studio-dist-verify` 로컬 스택을 시작하며 정리 때 해당 프로젝트의
볼륨까지 제거합니다. 보관할 파일이 없는 개발용 사본에서만 실행하세요. 운영 서버 금지입니다.

실행 위치: 개발 PC, 이 디렉터리(`dev/studio-dist-local`). 두 스크립트는 자기 위치 기준으로
경로를 찾으므로 다른 현재 디렉터리에서 `dev/studio-dist-local/verify.sh`로 불러도 됩니다.

1. 검증용 산출물 만들기(둘 중 하나)

   ```bash
   ./build-dist.sh --variant onprem   # 대용량 파일 실제 다운로드
   ```

   온프레미스 피드가 없고 구조만 검사할 때는 위 명령 대신 다음을 씁니다.

   ```bash
   ./build-dist.sh --variant saas --build 323 --dummy-large
   ```

   `--dummy-large`는 zip/msix를 같은 이름의 무작위 더미로 만듭니다. 라우팅·헤더·Range 검증에는
   충분하지만 Sparkle/App Installer 서명 검증(실제 업데이트)에는 쓸 수 없습니다. DMG·설치 exe·Windows zip은
   항상 더미이며, 버전은 `VERSION` 환경변수(기본 `0.0.34`)로 정합니다.

2. 검증

   ```bash
   ./verify.sh --volume   # 현재 패키지 구성
   ```

   이전 방식 이미지를 검사하려는 개발자만 대신 `./verify.sh`를 실행합니다.

   마지막 줄 `PASS=<n> FAIL=0`이고 종료 코드가 0이면 성공입니다. `--volume`은 첫 업로드 전 404,
   `current` 교체가 재기동 없이 반영되는지도 확인합니다.

## 생성·정리되는 항목

| 스크립트 | 만들거나 바꾸는 것 |
|----------|--------------------|
| `build-dist.sh` | 시작할 때 이 디렉터리의 `.work/`, `dist/`, `templates/`를 지우고 다시 만듦. Docker 이미지 `lucy-studio-dist:local-<variant>-<version>.<build>`(`--tag`로 변경) 빌드, `.work/image.txt`에 기록. 업로드 테스트용 번들 `.work/lucy-studio-<variant>-<version>.<build>.tar.gz` |
| `verify.sh` | 프로젝트 `studio-dist-verify` 컨테이너를 띄우고 필요 시 nginx 이미지를 이미지 다운로드. `--volume`은 `.work/stage/`를 지우고 다시 만듦. 정상 종료 시 `docker compose ... down -v`로 이 프로젝트의 컨테이너·네트워크·볼륨만 제거 |

`verify.sh`는 `set -e`로 동작하므로 compose 기동 단계 등에서 중간에 실패하면 마지막 정리 단계에
도달하지 못하고 종료할 수 있습니다. 정리가 항상 실행된다고 가정하지 말고, 실패 뒤에는 이 디렉터리에서
실행했던 모드와 같은 파일 조합으로 정리합니다.

```bash
docker compose -f compose.verify.yml -f compose.verify.volume.yml down -v   # --volume 모드였을 때만
```

이전 방식 모드였다면 위 명령 대신 다음을 실행합니다.

```bash
docker compose -f compose.verify.yml down -v
```

## TC 업로드 테스트

`.work/lucy-studio-onprem-<version>.<build>.tar.gz`(최상위 `html/`, `templates/`)를 로컬 온프레미스 스택에
[`scripts/studio-upload.sh`](../../scripts/studio-upload.sh)로 올려 볼 수 있습니다. TC는 `--variant onprem`
번들만 받습니다. 실제 업데이트까지 보려면 `--dummy-large` 없이 만들고, 구버전 Studio의 서버 주소를 그
로컬 TC로 잡아 실행합니다.

## 알아둘 것

- 첫 업로드 전에는 `current`가 없어 `/healthz` 외 모든 경로가 404입니다. healthcheck는 통과합니다.
- nginx는 요청마다 심링크를 따라가므로 `current` 교체가 재기동 없이 반영됩니다.
- macOS Docker Desktop의 바인드 마운트는 호스트 쪽 심링크 교체를 늦게 반영해 500이 날 수 있어, 검증은 네임드 볼륨으로 합니다.
- 이미지 nginx는 `listen 80`과 `listen [::]:80`을 모두 켭니다. alpine busybox wget이 `localhost`를 `::1`로 먼저 풀기 때문에 IPv4만 listen하면 healthcheck가 `starting`에 머뭅니다.
- Range 요청의 206 응답에는 `Accept-Ranges` 없이 `Content-Range`만 붙습니다. 정상입니다.
- appcast는 최신 item 하나만 남깁니다. 이전 버전 zip이 없으므로 남기면 깨진 참조가 됩니다.
