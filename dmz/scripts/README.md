# DMZ Scripts Usage

모든 명령은 `dmz/` 디렉터리에서 실행합니다.

```bash
cd dmz
```

## 실행 스크립트

`dmz/scripts/`의 사용자 실행 entrypoint는 네 개입니다.

```text
scripts/export-compose-images.sh
scripts/load-compose-images.sh
scripts/preflight-dmz.sh
scripts/dmz-compose.sh
```

내부 구현 파일은 `scripts/lib/` 아래에 있으며 직접 실행하지 않습니다.

짧은 운영자용 안내는 `scripts/OPERATOR_QUICK_GUIDE.md`를 참고하세요.

## 1. 인터넷 가능 환경에서 이미지 패키징

DMZ 서버가 폐쇄망이면 인터넷 가능한 PC에서 먼저 이미지를 패키징합니다.

```bash
./scripts/export-compose-images.sh
```

기본 출력 위치:

```text
images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-dmz-images-linux-amd64.images.txt
images/lucy-teamcloud-dmz-images-linux-amd64.archive-images.txt
images/lucy-teamcloud-dmz-images-linux-amd64.explicit-images.txt
images/lucy-teamcloud-dmz-images-linux-amd64.services.txt
```

ARM64용으로 패키징하려면:

```bash
TARGET_PLATFORM=linux/arm64 ./scripts/export-compose-images.sh
```

## 2. 폐쇄망 DMZ 서버에서 이미지 로드

`dmz/` 폴더와 `dmz/images/`를 DMZ 서버로 복사한 뒤 실행합니다.

```bash
./scripts/load-compose-images.sh
```

archive 경로를 직접 지정할 수도 있습니다.

```bash
./scripts/load-compose-images.sh ./images/lucy-teamcloud-dmz-images-linux-amd64.tar.gz
```

이 스크립트는 이미지만 로드합니다. 컨테이너 시작은 `preflight-dmz.sh --compose-up` 또는
`dmz-compose.sh up`으로 분리되어 있습니다.

## 3. 사전 점검 후 실행

`.env`를 준비합니다.

```bash
cp .env.example .env
```

TLS 모드라면 인증서 파일도 준비합니다.

```text
certs/server.crt
certs/server.key
```

사전 점검 후 바로 실행:

```bash
./scripts/preflight-dmz.sh --compose-up
```

점검만 수행:

```bash
./scripts/preflight-dmz.sh
```

이미지 존재 확인을 건너뛰려면:

```bash
./scripts/preflight-dmz.sh --skip-image-check
```

## 4. 운영 명령

상태 확인:

```bash
./scripts/dmz-compose.sh ps
```

로그 확인:

```bash
./scripts/dmz-compose.sh logs
```

기동:

```bash
./scripts/dmz-compose.sh up
```

설정 변경 후 컨테이너 재생성:

```bash
./scripts/dmz-compose.sh recreate
```

전체 재시작:

```bash
./scripts/dmz-compose.sh restart-stack
```

중지:

```bash
./scripts/dmz-compose.sh down
```

`down`은 파일과 데이터는 보존하고 compose 컨테이너만 내립니다.

## 5. Docker/Podman 고정

기본값은 Docker/Podman 자동 감지입니다. 런타임을 명시하려면 `DMZ_RUNTIME`을 붙입니다.

```bash
DMZ_RUNTIME=docker ./scripts/preflight-dmz.sh --compose-up
DMZ_RUNTIME=podman ./scripts/preflight-dmz.sh --compose-up
```

운영 명령도 동일합니다.

```bash
DMZ_RUNTIME=docker ./scripts/dmz-compose.sh up
DMZ_RUNTIME=podman ./scripts/dmz-compose.sh up
```

Podman rootless 기본 포트는 `18080/18443`입니다.

```text
http://<dmz-host>:18080/health
https://<dmz-host>:18443/health
```

## 6. 도움말

```bash
./scripts/export-compose-images.sh --help
./scripts/load-compose-images.sh --help
./scripts/preflight-dmz.sh --help
./scripts/dmz-compose.sh --help
```
