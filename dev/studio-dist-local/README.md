# studio-dist-local — lucy-studio-dist 로컬 검증 도구

온프렘 패키지의 `studio-dl` 서비스가 쓰는 `lucy-studio-dist` 이미지 계약(Notion
"온프렘 번들 — Studio 자체 제공 작업계획서와 Studio 측 계약" 3.1 / 3.4)을 그대로 구현한
참조 구현과, S3 의 Studio 피드로 이미지를 만들어 gw 라우팅까지 검증하는 스크립트다.

정식 이미지는 Studio CI(project_lucy `studio/dist-image/`)가 만든다. 여기 있는
`Dockerfile`, `nginx.conf`, `entrypoint.sh` 는 그 구현의 출발점으로 그대로 가져가도 된다.
이 디렉터리는 온프렘 패키지 배포 대상이 아니며 compose 가 참조하지 않는다.

## 파일

| 파일 | 역할 |
|------|------|
| `Dockerfile` | nginx:1.26-alpine + `dist/`(웹 루트) + `templates/`(피드 템플릿, 웹 루트 밖) |
| `nginx.conf` | MIME(`application/appinstaller`, `application/msix` 등), 피드 no-cache, 패키지 immutable, `/healthz` |
| `entrypoint.sh` | `STUDIO_BASE_URL` 검사 후 `__STUDIO_BASE_URL__` 치환해 피드 생성, nginx 기동 |
| `build-dist.sh` | S3 `lucy-studio-dist` 의 피드/패키지로 `dist/`, `templates/`, `latest.json` 을 만들고 이미지 빌드 |
| `compose.verify.yml` | 패키지의 `nginx/nginx.conf` 를 쓰는 gw + studio-dl + 더미 upstream 스택 |
| `verify.sh` | 체크리스트의 HTTP 항목 자동 검사 (렌더링, MIME, Cache-Control, Range 206, sha256) |
| `compose.verify.volume.yml` | `verify.sh --volume` 용 덮어쓰기. studio-dl 을 패키지 구성(공식 nginx + `studio-dl/nginx.conf`)으로 바꾸고 named volume 을 더미 tc-be(rw)·studio-dl(ro)에 붙인다 |

## 사용

```bash
# AWS 자격(lucy-studio-dist 버킷 읽기)과 Docker 가 필요하다.
./build-dist.sh --variant onprem                 # appcast 최신 item 기준, 대용량 파일 실제 다운로드
./build-dist.sh --variant saas --build 323 --dummy-large   # onprem 피드가 아직 없을 때 saas 로 구조 검증
./verify.sh                                      # 방금 만든 이미지로 검증 스택 기동 → 검사 → 정리
./verify.sh --volume                             # 패키지 studio-dl 구성으로 같은 검사 + current 교체 반영 확인
```

`build-dist.sh` 는 TC 업로드 테스트용 번들(`html/` + `templates/`)도 `.work/lucy-studio-<variant>-<version>.<build>.tar.gz`
로 남긴다. 로컬 onprem 스택에 `../../scripts/studio-upload.sh` 로 올려 볼 수 있다(TC 는 `--variant onprem` 번들만 받는다).

`--dummy-large` 는 zip/msix/dmg/exe 를 받지 않고 같은 이름의 더미 파일을 만든다. 라우팅·헤더·Range 검증에는
충분하지만 Sparkle/App Installer 의 서명 검증(실제 업데이트)에는 쓸 수 없다. 실제 업데이트까지 보려면
`--dummy-large` 없이 만들고, 클라이언트에서 서버 주소를 이 호스트로 잡아 구버전 Studio 를 실행한다.

## 알아둘 것

- 이미지 안 nginx 는 `listen 80;` 과 `listen [::]:80;` 둘 다 켠다. alpine 의 busybox wget 이 `localhost` 를
  `::1` 로 먼저 풀어서, IPv4 만 listen 하면 compose healthcheck 가 영원히 `starting` 에 머문다.
- nginx 는 `Accept-Ranges: bytes` 를 200 응답에만 붙이고 206 에는 `Content-Range` 만 붙인다. 정상이다.
- appcast 는 최신 item 하나만 남긴다. 이전 버전 zip 이 이미지에 없으므로 남기면 깨진 참조가 된다.

## 볼륨 서빙형 (TC 릴리스 업로드)

온프렘 패키지는 이제 lucy-studio-dist 이미지를 쓰지 않는다. studio-dl 은 공식 `nginx:1.26-alpine` 에 패키지의
`studio-dl/nginx.conf` 를 붙인 것이고, tc-be 가 공유 볼륨에 `releases/<releaseId>/html` 을 풀고 `current` 상대
심링크를 rename(2) 으로 교체하면 그 `current` 를 root 로 서빙한다(TC 리포 `doc/onprem-studio-release/`, ADR-0005).
피드 렌더링은 TC 가 하므로 entrypoint 와 `STUDIO_BASE_URL` 이 없다. 이 디렉터리의 `Dockerfile`·`entrypoint.sh`·
`nginx.conf` 는 이전 파일 내장형 참조 구현으로 남아 있다.

- `studio-dl/nginx.conf` 는 여기 `nginx.conf` 와 규칙이 같고 `root` 만 `/srv/studio/current` 다.
- 첫 업로드 전에는 `current` 가 없어 `/healthz` 외 모든 경로가 404 다. healthcheck 는 그래도 통과한다.
- nginx 는 요청마다 심링크를 따라가므로 교체가 재기동 없이 반영된다(`verify.sh --volume` 마지막 항목).
- macOS Docker Desktop 의 bind mount 에서는 호스트 쪽 심링크 교체가 컨테이너에 늦게 반영돼 500 이 난다.
  검증은 패키지와 같이 named volume 으로 한다.
