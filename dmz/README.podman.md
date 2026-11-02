# Lucy TeamCloud DMZ MQTT 프록시 — Podman 설치 가이드

이 프록시가 무엇이고 언제 필요한지, 설정값의 의미는 [README.md](README.md)를 먼저
읽으세요. 요약하면 외부 모바일 앱용 `/mqtt` WebSocket 경로만 내부 TeamCloud로
전달하는 별도 nginx입니다. TeamCloud 본체 설치는 [../README.md](../README.md)를 따릅니다.

예시 값(실제 환경의 값으로 바꾸세요):

| 항목 | 예시 |
|------|------|
| DMZ 공개 이름 | `mqtt.example.com` |
| 내부 TeamCloud 게이트웨이 | `https://tc.internal.example:18443` (TeamCloud를 Podman 기본값으로 띄운 경우) |

## 0. 준비물

| 어디서 | 필요한 것 |
|--------|-----------|
| DMZ 서버 | Podman, `podman compose`가 동작하는 Compose 실행 도구(`podman compose version`으로 확인), `curl` |
| DMZ 서버 | TeamCloud 설치에 쓴 것과 같은 릴리스의 `dmz/` 디렉터리 전체 |
| 온라인 PC (폐쇄망일 때만) | Docker Engine + Compose 플러그인(`docker save --platform` 지원). Podman용 묶음도 내보내기 스크립트는 Docker CLI를 씁니다 |
| WSS일 때 | `mqtt.example.com`용 인증서·개인키 (PEM) |

- 아래 명령은 Bash 셸에서 실행합니다. 각 PC/서버에서 소스를 푼 실제 경로를 먼저 지정하고,
  이후 같은 셸을 사용하세요. 새 셸에서는 이 두 줄을 다시 실행합니다.

```bash
DMZ_ROOT='/absolute/path/to/lucy-teamcloud-onprem/dmz'
cd "$DMZ_ROOT"
```
- 이미지 적재와 실행은 같은 OS 사용자, 같은 모드(rootless 또는 `sudo`)로 합니다.
  Podman은 사용자·모드마다 이미지 저장소가 달라서, 다른 사용자로 적재한 이미지는 보이지
  않습니다. 이 문서는 rootless(일반 사용자) 기준입니다.
- Compose 파일은 SELinux용 `:z` 마운트 옵션을 이미 포함합니다.
- Compose 서비스 이름은 `dmz-mqtt-proxy`, 프로젝트 이름은 `lucy-teamcloud-dmz`입니다.

## 1. `.env` 작성 (DMZ 서버)

```bash
cd "$DMZ_ROOT"
cp -n .env.example .env   # 신규 설치만: 기존 .env는 덮어쓰지 않음
vi .env
```

```env
# 공개 주소: scheme·경로·포트 없이
DMZ_SERVER_NAME=mqtt.example.com
# 내부 주소: http:// 또는 https:// 로 시작, 기본이 아닌 포트 포함, /mqtt 붙이지 않음 (ws:// 아님)
INTERNAL_MQTT_UPSTREAM=https://tc.internal.example:18443
# WSS일 때 컨테이너 안 인증서 경로 (기본값 유지)
DMZ_TLS_CERTIFICATE=/etc/nginx/certs/server.crt
DMZ_TLS_CERTIFICATE_KEY=/etc/nginx/certs/server.key
```

DMZ 서버가 arm64라면 `TARGET_PLATFORM=linux/arm64`를 추가합니다(기본 `linux/amd64`).
이때 이미지 내보내기뿐 아니라 아래 전송·불러오기 파일명의 `linux-amd64`도 모두 `linux-arm64`로 바꿉니다.
이 선택은 nginx 프록시에만 해당하며 TC 본체 이미지의 arm64 지원을 의미하지 않습니다.

## 2. 모드 고르기

아래에서 WS 또는 WSS 중 하나만 따라갑니다. 이후 모든 명령에서 같은 Compose
파일을 씁니다.

| 모드 | Compose 파일 | 기본 호스트 포트 | 모바일 앱 URL (루트 `.env`의 `PUBLIC_BROKER_WS_URL`) |
|------|--------------|----------------|-------------------------------------------------------|
| WS | `compose.podman.yml` | `18080` | `ws://mqtt.example.com:18080/mqtt` |
| WSS | `compose.podman.wss.yml` | `18080`(리다이렉트), `18443` | `wss://mqtt.example.com:18443/mqtt` |

rootless Podman은 보통 1024 미만 포트를 열 수 없어서 기본값이 18080/18443입니다.
80/443으로 공개하려면 호스트 정책 변경이나 앞단 포트 포워딩이 필요하므로 서버
관리자와 정합니다. 이 문서에서 호스트 설정은 바꾸지 않습니다.

### 2-A. WS

포트를 바꾸려면 `compose.podman.yml`의 `ports`만 수정합니다(예: `"28080:80"`). 이 경우
URL은 `ws://mqtt.example.com:28080/mqtt`가 됩니다.

### 2-B. WSS

인증서를 정해진 이름으로 둡니다. 적재·실행할 사용자 소유로 둡니다.

```bash
cp -n /path/to/your.crt certs/server.crt   # 서버 인증서 + 중간 인증서(체인) 순서
cp -n /path/to/your.key certs/server.key
chmod 600 certs/server.key
test -f certs/server.crt && test -f certs/server.key && echo OK
openssl x509 -in certs/server.crt -noout -subject -issuer -dates -ext subjectAltName
```

`subjectAltName`에 `mqtt.example.com`이 있고 유효기간이 남아 있어야 합니다. 파일이
없으면 nginx가 시작하지 못하므로 여기서 멈추고 인증서를 먼저 준비하세요.

HTTPS 포트를 바꾸려면 `compose.podman.wss.yml`에서 두 곳을 함께 수정합니다.

```yaml
    ports:
      - "28080:80"
      - "28443:443"
    environment:
      DMZ_HTTPS_REDIRECT_ORIGIN: https://${DMZ_SERVER_NAME}:28443
```

이 경우 URL은 `wss://mqtt.example.com:28443/mqtt`입니다.

## 3. 설정 확인

Compose 실행 도구마다 정적 검사 기능이 달라서, 시작 전에 값만 눈으로 확인합니다.

```bash
grep -n 'DMZ_SERVER_NAME\|INTERNAL_MQTT_UPSTREAM\|TARGET_PLATFORM' .env
grep -n -A3 'ports:' compose.podman.yml        # WSS면 compose.podman.wss.yml
```

`INTERNAL_MQTT_UPSTREAM`이 `http://` 또는 `https://`로 시작하고 `/mqtt`가 없어야 합니다.

## 4-A. 실행 — 인터넷 연결 가능한 DMZ 서버

WS:

```bash
podman compose --env-file .env -f compose.podman.yml pull
podman compose --env-file .env -f compose.podman.yml up -d
```

WSS:

```bash
podman compose --env-file .env -f compose.podman.wss.yml pull
podman compose --env-file .env -f compose.podman.wss.yml up -d
```

5절(상태 확인)로 갑니다.

## 4-B. 실행 — 폐쇄망 DMZ 서버

### ① 온라인 PC (Docker 필요): 이미지 묶음 만들기

```bash
cd "$DMZ_ROOT"
./scripts/export-compose-images-podman.sh
# arm64 서버용이면: TARGET_PLATFORM=linux/arm64 ./scripts/export-compose-images-podman.sh
```

WS·WSS 공용 묶음 하나가 `images/`에 생깁니다.

```text
images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz
images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-dmz-podman-images-linux-amd64.images.txt
images/lucy-teamcloud-dmz-podman-images-linux-amd64.archive-images.txt
images/lucy-teamcloud-dmz-podman-images-linux-amd64.services.txt
```

마지막에 `[INFO] Export complete.`가 나오면 성공입니다. Podman 적재 스크립트는
`lucy-teamcloud-dmz-podman-images-*` 이름만 찾으므로 Docker용 묶음을 쓰지 마세요.
TeamCloud 본체 이미지 묶음과도 다른 파일입니다.

### ② DMZ 서버로 옮길 것

`dmz/` 디렉터리 전체(Compose 파일, `nginx/`, `certs/`, `scripts/`, `.env.example`)와
`images/`의 위 파일들. 특히 `.tar.gz`, `.tar.gz.sha256`, `.images.txt`는 반드시 함께
옮깁니다. `.sha256`이 없으면 스크립트가 경고만 하고 체크섬 검사를 건너뜁니다.
필수 파일이 하나라도 없으면 불러오지 말고 다시 전달받으세요. `.archive-images.txt`와
`.services.txt`는 진단용 선택 파일이며 전송 필수는 아닙니다. `.env`와 인증서는 1·2절대로
DMZ 서버에서 작성·배치합니다. 다른 설치의 `.env`나 인증서로 덮어쓰지 않습니다.

### ③ DMZ 서버: 이미지 적재 (실행할 사용자로)

`images/`는 Git에 없으므로 직접 만듭니다. 아래 `<BUNDLE_DIR>`은 전달받은 세 파일이 있는
디렉터리입니다. 새 설치 기준이며 기존 파일이 있으면 릴리스·체크섬을 먼저 확인합니다.

```bash
cd "$DMZ_ROOT" && mkdir -p images &&
cp -n "<BUNDLE_DIR>/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz" \
      "<BUNDLE_DIR>/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz.sha256" \
      "<BUNDLE_DIR>/lucy-teamcloud-dmz-podman-images-linux-amd64.images.txt" images/
```

```bash
cd "$DMZ_ROOT"
./scripts/load-compose-images-podman.sh ./images/lucy-teamcloud-dmz-podman-images-linux-amd64.tar.gz
podman image inspect docker.io/library/nginx:1.26-alpine --format '{{.Id}}'
```

체크섬·gzip 검사 후 `OK   docker.io/library/nginx:1.26-alpine`와
`[INFO] Load complete.`가 나오면 성공입니다. 이미지가 `localhost/nginx:1.26-alpine`
으로 들어온 경우 스크립트가 `docker.io/library/nginx:1.26-alpine` 태그를 붙여 줍니다.
`[ERROR]`가 나오면 멈추고 파일을 다시 옮기세요(`--skip-*` 옵션으로 넘기지 마세요).

### ④ DMZ 서버: 실행

WS:

```bash
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

WSS:

```bash
podman compose --env-file .env -f compose.podman.wss.yml up -d --no-build
```

`--no-build`는 이미지 빌드를 막는 옵션일 뿐, 이미지 다운로드를 막지는 않습니다. 이미지가
③에서 같은 이름으로 적재돼 있어야 레지스트리에 접근하지 않습니다. Docker용
`--pull never`는 쓰지 마세요(일부 `podman-compose` 버전은 `never`를 서비스 이름으로
해석합니다).

## 5. 상태 확인

아래에서 `compose.podman.yml`은 WSS라면 `compose.podman.wss.yml`로 바꿉니다.

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs --tail 100 dmz-mqtt-proxy
```

- 상태가 `Up ... (healthy)`이면 nginx가 실행 중이고 컨테이너 내부 `/health`가 응답한 것입니다.
  Compose 실행 도구 버전에 따라 health 표시가 없을 수 있으니 7절 ①로도 확인합니다.
- 계속 재시작되거나 로그에 `nginx: [emerg]`가 있으면 설정 오류입니다. 자주 나오는 원인:
  `invalid URL prefix`(내부 서버에 `ws://` 사용), `host not found in upstream`(프록시 컨테이너에서
  이름 해석 불가), `cannot load certificate`(WSS 인증서 경로·파일·권한).
- `--tail` 옵션을 지원하지 않는 Compose 실행 도구라면 `podman logs --tail 100 <컨테이너 이름>`을
  씁니다(이름은 `ps` 결과).

## 6. TeamCloud 쪽 설정

TeamCloud 서버의 루트 `.env`에서 `PUBLIC_BROKER_WS_URL`을 2절 표의 모바일 앱 URL로
맞추고, [../README.md](../README.md)의 절차로 반영합니다. 방화벽은 모바일 앱 → DMZ 호스트
포트, DMZ 서버 → `INTERNAL_MQTT_UPSTREAM`의 포트를 허용해야 합니다.

## 7. 진단 (단계별, 읽기 전용)

결과 해석표는 [README.md 6절](README.md#6-진단-결과-읽는-법)에 있습니다.

### ① 클라이언트 쪽 → DMZ

모바일 앱과 같은 망의 PC에서:

```bash
# WS
curl -sS -o /dev/null -w '%{http_code}\n' http://mqtt.example.com:18080/health
# WSS (공인 인증서)
curl -sS -o /dev/null -w '%{http_code}\n' https://mqtt.example.com:18443/health
# WSS (사설 CA) — 검증을 끄지 말고 CA 파일 지정
curl -sS --cacert /path/to/ca.crt -o /dev/null -w '%{http_code}\n' https://mqtt.example.com:18443/health
```

`200`이 정상입니다. 인증서 오류가 나면 서버가 내보내는 인증서를 봅니다.

```bash
openssl s_client -connect mqtt.example.com:18443 -servername mqtt.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### ② DMZ 서버 → 내부 TeamCloud

DMZ 서버에서 `INTERNAL_MQTT_UPSTREAM`과 같은 주소로:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://tc.internal.example:18443/health
```

`200`이면 게이트웨이 nginx에 닿습니다(브로커까지 확인된 것은 아님). 내부 인증서가
자체 서명 인증서라 실패하면 `--cacert`로 내부 CA를 지정하세요. DMZ nginx 자체는 내부
인증서를 검증하지 않으므로 이 단계의 인증서 오류는 연결 실패 원인이 아닐 수 있습니다.

### ③ WebSocket 업그레이드 (MQTT 서브프로토콜)

먼저 DMZ를 통해, 실패하면 DMZ 서버에서 내부 TeamCloud 서버에 직접 같은 요청을 보내 어느
구간 문제인지 나눕니다.

```bash
# DMZ 경유 (WS: http://...:18080, WSS: https://...:18443)
TC_CURL_EXIT=0
curl -sS -i -N --http1.1 --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Protocol: mqtt' \
  https://mqtt.example.com:18443/mqtt || TC_CURL_EXIT=$?
printf 'curl exit=%s\n' "$TC_CURL_EXIT"

# DMZ 서버에서 내부 upstream 직접
TC_CURL_EXIT=0
curl -sS -i -N --http1.1 --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Protocol: mqtt' \
  https://tc.internal.example:18443/mqtt || TC_CURL_EXIT=$?
printf 'curl exit=%s\n' "$TC_CURL_EXIT"
```

- WebSocket 업그레이드 성공: `HTTP/1.1 101 Switching Protocols`가 보이고 5초 뒤
  `curl exit=28`. MQTT 인증이나 메시지 송수신 성공을 뜻하지 않으며 실제 앱으로 별도 확인합니다.
- 실패: 응답 없이 `curl exit=28`(핸드셰이크 없음), `502`, `404`, `301` 등.

### ④ 읽기 전용 확인

```bash
# 컨테이너 안에서 실제로 렌더링된 nginx 설정
podman compose --env-file .env -f compose.podman.yml exec dmz-mqtt-proxy cat /etc/nginx/nginx.conf
podman compose --env-file .env -f compose.podman.yml logs --tail 200 dmz-mqtt-proxy
```

`proxy_pass`가 `http://` 또는 `https://`로 시작하는지, `server_name`이 공개 이름인지
봅니다. 인증서 읽기 오류(`Permission denied`)는 파일 소유자·SELinux 라벨 문제일 수
있으니 `ls -lZ certs/`로 확인만 하고 조치는 관리자와 정합니다. 진단 중에 DNS
resolver·`/etc/hosts`·방화벽·sysctl을 바꾸거나 컨테이너를 지우지 마세요.

## 8. 설정 변경·재시작·업그레이드

`.env`, `certs/`, 포트를 바꾼 Compose 파일은 운영 자산입니다. 작업 전에 복사해 둡니다.

```bash
cp -p .env .env.bak
cp -rp certs certs.bak
cp -p compose.podman.yml compose.podman.yml.bak   # WSS면 compose.podman.wss.yml
```

| 바꾼 것 | 반영 명령 |
|---------|-----------|
| 인증서 교체, `nginx/` 템플릿 | `podman compose --env-file .env -f <Compose 파일> restart dmz-mqtt-proxy` (시작 시 설정을 다시 만듭니다) |
| `.env` 값, Compose `ports`, 이미지 | `podman compose --env-file .env -f <Compose 파일> up -d --no-build` 후 새 설정·이미지가 적용됐는지 `ps`·로그로 확인. 재생성되지 않으면 Compose 실행 도구 지원 옵션을 관리자와 확인 |
| WS ↔ WSS 전환 | 기존 파일로 `down` 후 새 Compose 파일로 `up -d --no-build` |

### 이미지만 업그레이드

먼저 릴리스 안내에서 이미지 전용 변경인지 확인합니다. 아래 diff는 확인 보조용입니다.
운영 중 추가한 포트 등 기존 커스텀 차이는 릴리스의 구조 변경과 구분하세요. 판단이
어려우면 이전·새 릴리스의 원본 파일을 비교하거나 배포 담당자에게 확인합니다.

```bash
diff compose.podman.yml /path/to/new-release/dmz/compose.podman.yml
```

- 서비스와 이미지 경로는 같고 태그만 바뀌었으면: 지금 파일의 `image:` 태그만
  새 값으로 고칩니다. 인터넷이면 `pull`, 폐쇄망이면 새 릴리스로 4-B ①~③을 반복한 뒤
  `up -d --no-build`를 실행합니다. 이미지 전용 업데이트 전에 `down`하지 않습니다.
  `.env`, `certs/`, 포트 설정은 그대로 둡니다.
- 이미지 경로나 환경 변수·템플릿·볼륨·명령 등 구조가 바뀌었으면: 이미지 전용 절차를
  중단하고 해당 릴리스의 이관 안내와 관리자 작업 계획을 따릅니다. 운영 Compose를
  통째로 덮거나 `.env`를 다시 만들지 않습니다.

## 9. 중지

```bash
podman compose --env-file .env -f compose.podman.yml down
```

WSS라면 `compose.podman.wss.yml`을 씁니다. 이 프록시는 영속 네임드 볼륨이 없고 `.env`·`certs/`는
호스트 파일이라 `down`으로 지워지지 않습니다. `down -v`, `podman system prune`은
쓰지 않습니다.
