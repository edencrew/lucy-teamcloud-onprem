# Lucy TeamCloud DMZ MQTT Proxy

DMZ compose는 외부 모바일 클라이언트가 접근하는 MQTT-over-WebSocket 경로만
노출합니다. TeamCloud 전체 화면, 인증, API, Git 경로는 프록시하지 않습니다.

```text
Mobile app
  -> ws://<dmz-domain>/mqtt
  -> DMZ nginx
  -> http(s)://<internal-teamcloud>/mqtt
  -> internal broker
```

## 설치 가이드

- Docker 환경: [README.docker.md](README.docker.md)
- Podman 환경: [README.podman.md](README.podman.md)

DMZ 기본 실행은 plain WS입니다. 인증서가 없는 환경에서는 기본 compose
(`compose.docker.yml`, `compose.podman.yml`)를 사용하세요. WSS는
`certs/server.crt`, `certs/server.key`가 준비된 경우에만 `.wss.yml` compose를
명시적으로 선택합니다.

DMZ 서버와 internal/onprem 서버는 서로 다른 서버입니다. DMZ gateway port는 `.env`로
바뀌지 않으므로, 각 runtime 가이드의 실행 섹션에서 DMZ 서버 compose `ports`를 먼저
운영 port로 맞추세요. 모바일 클라이언트가 사용할 broker URL은 internal/onprem 서버
`.env`의 `PUBLIC_BROKER_WS_URL`에 같은 DMZ endpoint로 설정합니다.

문서의 `<DMZ_HOST>`, `<DMZ_WS_PORT>`, `<DMZ_WSS_PORT>`, `<ONPREM_HOST>`,
`<ONPREM_HTTP_PORT>`, `<ONPREM_HTTPS_PORT>`는 placeholder입니다. 실제 `.env`와
compose 파일에는 운영 환경의 실제 host/domain과 숫자 port로 바꿔 입력하세요.

## 파일 구조

```text
compose.docker.yml        # Docker용 plain WS 기본 compose
compose.docker.wss.yml    # Docker용 WSS compose
compose.podman.yml        # Podman용 plain WS 기본 compose, SELinux :z mount 포함
compose.podman.wss.yml    # Podman용 WSS compose, SELinux :z mount 포함
scripts/
  export-compose-images-docker.sh
  export-compose-images-podman.sh
  load-compose-images-docker.sh
  load-compose-images-podman.sh
```

## 공통 설정

```bash
cd dmz
cp .env.example .env
vi .env
```

`INTERNAL_MQTT_UPSTREAM`은 DMZ 서버에서 접근 가능한 내부 TeamCloud nginx 주소입니다.
내부 onprem gateway가 non-standard port를 쓰면 port까지 포함하세요. `/mqtt`를 붙이지
마세요. DMZ nginx가 들어온 `/mqtt` 요청 경로를 그대로 보존합니다.

기본 compose는 plain WS입니다. WSS 모드는 `compose.*.wss.yml`을 명시적으로 선택하고,
`certs/server.crt`, `certs/server.key`를 준비해야 합니다.

## 운영 주의사항

- 외부에는 DMZ gateway port만 노출하고, 내부 broker port `1883`, `8080`과 DB port `5432`는 노출하지 마세요.
- internal/onprem `.env`의 `PUBLIC_BROKER_WS_URL`은 모바일 클라이언트가 접근 가능한 DMZ URL과 일치해야 합니다.
- 방화벽은 mobile/client -> DMZ gateway port, DMZ 서버 -> internal/onprem gateway port 방향을 허용해야 합니다.
- DMZ는 `/mqtt`만 proxy합니다. TeamCloud UI/Auth/API/Git 경로는 onprem gateway로 접근해야 합니다.
- 이 proxy는 broker 인증이나 topic ACL을 추가하지 않습니다. 공개망 운영에는 별도 broker hardening이 필요합니다.
- plain `ws://`는 TLS 없이 전송됩니다. 공개망 운영에는 WSS compose를 사용하세요.
