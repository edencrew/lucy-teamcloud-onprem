# DMZ 운영자용 스크립트 빠른 안내

모든 명령은 `dmz/` 폴더에서 실행합니다.

```bash
cd dmz
```

## 처음 설치 또는 재기동

이미지를 먼저 불러옵니다.

```bash
./scripts/load-compose-images.sh
```

설정과 환경을 점검한 뒤 DMZ proxy를 시작합니다.

```bash
./scripts/preflight-dmz.sh --compose-up
```

## 상태 확인

```bash
./scripts/dmz-compose.sh ps
```

health endpoint 확인:

```bash
curl -k https://<dmz-host>/health
curl http://<dmz-host>/health
```

Podman rootless 기본 포트:

```bash
curl -k https://<dmz-host>:18443/health
curl http://<dmz-host>:18080/health
```

## 로그 확인

전체 로그:

```bash
./scripts/dmz-compose.sh logs
```

proxy 로그:

```bash
./scripts/dmz-compose.sh logs dmz-mqtt-proxy
```

## 재시작

전체 재시작:

```bash
./scripts/dmz-compose.sh restart-stack
```

컨테이너만 재시작:

```bash
./scripts/dmz-compose.sh restart dmz-mqtt-proxy
```

## 설정 변경 적용

`.env` 또는 인증서 설정을 바꾼 뒤 컨테이너를 재생성합니다.

```bash
./scripts/dmz-compose.sh recreate
```

## 중지

파일과 설정을 보존하고 컨테이너만 내립니다.

```bash
./scripts/dmz-compose.sh down
```

## 이미지 교체

새 이미지 압축 파일을 받은 경우:

```bash
./scripts/load-compose-images.sh ./images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
./scripts/dmz-compose.sh recreate
```

## Docker/Podman 고정

기본값은 자동 감지입니다. 런타임을 고정해야 하면 명령 앞에 붙입니다.

```bash
DMZ_RUNTIME=docker ./scripts/preflight-dmz.sh --compose-up
DMZ_RUNTIME=podman ./scripts/preflight-dmz.sh --compose-up
```

운영 명령도 같은 방식입니다.

```bash
DMZ_RUNTIME=docker ./scripts/dmz-compose.sh ps
DMZ_RUNTIME=podman ./scripts/dmz-compose.sh ps
```

## 주의

- `docker compose down -v`는 실행하지 마세요. compose volume이 삭제될 수 있습니다.
- `DMZ_ENABLE_TLS=1`이면 `certs/server.crt`, `certs/server.key`가 필요합니다.
- `INTERNAL_MQTT_UPSTREAM`에는 `/mqtt` path를 붙이지 마세요.
- 문제가 나면 먼저 `ps`, `logs`, `/health` 결과를 확인하세요.
