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

## 사용

```bash
# AWS 자격(lucy-studio-dist 버킷 읽기)과 Docker 가 필요하다.
./build-dist.sh --variant onprem                 # appcast 최신 item 기준, 대용량 파일 실제 다운로드
./build-dist.sh --variant saas --build 323 --dummy-large   # onprem 피드가 아직 없을 때 saas 로 구조 검증
./verify.sh                                      # 방금 만든 이미지로 검증 스택 기동 → 검사 → 정리
```

`--dummy-large` 는 zip/msix/dmg/exe 를 받지 않고 같은 이름의 더미 파일을 만든다. 라우팅·헤더·Range 검증에는
충분하지만 Sparkle/App Installer 의 서명 검증(실제 업데이트)에는 쓸 수 없다. 실제 업데이트까지 보려면
`--dummy-large` 없이 만들고, 클라이언트에서 서버 주소를 이 호스트로 잡아 구버전 Studio 를 실행한다.

## 알아둘 것

- 이미지 안 nginx 는 `listen 80;` 과 `listen [::]:80;` 둘 다 켠다. alpine 의 busybox wget 이 `localhost` 를
  `::1` 로 먼저 풀어서, IPv4 만 listen 하면 compose healthcheck 가 영원히 `starting` 에 머문다.
- nginx 는 `Accept-Ranges: bytes` 를 200 응답에만 붙이고 206 에는 `Content-Range` 만 붙인다. 정상이다.
- appcast 는 최신 item 하나만 남긴다. 이전 버전 zip 이 이미지에 없으므로 남기면 깨진 참조가 된다.
