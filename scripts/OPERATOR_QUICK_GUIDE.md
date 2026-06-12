# 운영자용 스크립트 빠른 안내

모든 명령은 프로젝트 폴더에서 실행합니다.

```bash
cd lucy-teamcloud-onprem
```

## 처음 설치 또는 재기동

이미지를 먼저 불러옵니다.

```bash
./scripts/load-compose-images.sh
```

설정과 환경을 점검한 뒤 서비스를 시작합니다.

```bash
./scripts/preflight-onprem.sh --compose-up
```

## Online CI 실행

OpenStack CI처럼 registry 접근이 가능한 테스트 환경에서는 image archive를 로드하지 않고
preflight가 필요한 이미지를 pull/build하도록 실행할 수 있습니다.

```bash
ONPREM_RUNTIME=podman ONPREM_IMAGE_MODE=online \
  ./scripts/preflight-onprem.sh --skip-resource-check --compose-up
```

## 상태 확인

```bash
./scripts/onprem-compose.sh ps
```

## 로그 확인

전체 로그:

```bash
./scripts/onprem-compose.sh logs
```

특정 서비스 로그:

```bash
./scripts/onprem-compose.sh logs tc-be
./scripts/onprem-compose.sh logs auth-be
./scripts/onprem-compose.sh logs gw
./scripts/onprem-compose.sh logs broker
```

## 재시작

전체 재시작:

```bash
./scripts/onprem-compose.sh restart-stack
```

특정 서비스만 재시작:

```bash
./scripts/onprem-compose.sh restart tc-be
```

## 중지

데이터를 보존하고 컨테이너만 내립니다.

```bash
./scripts/onprem-compose.sh down
```

## 이미지 교체

새 이미지 압축 파일을 받은 경우:

```bash
./scripts/onprem-compose.sh replace-images ./images/lucy-teamcloud-onprem-images-linux-amd64.tar.gz
```

## 주의

- `docker compose down -v`는 실행하지 마세요. 데이터가 삭제될 수 있습니다.
- `.env`의 관리자 계정과 DB 비밀번호는 최초 설치 후 임의로 바꾸지 마세요.
- 문제가 나면 먼저 `ps`와 `logs` 결과를 확인하세요.
