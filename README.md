# Lucy TeamCloud On-Premise

이 브랜치는 최소 운영 구조만 제공합니다. 자동 환경 검증과 compose wrapper는
제공하지 않습니다. 운영자는 Docker 또는 Podman 환경을 직접 준비하고, 선택한
compose 파일로 서비스를 실행합니다.

## 설치 가이드

- Docker 환경: [README.docker.md](README.docker.md)
- Podman 환경: [README.podman.md](README.podman.md)

## 파일 구조

```text
compose.docker.yml   # Docker용 standalone compose
compose.podman.yml   # Podman용 standalone compose, SELinux :z mount 포함
compose.podman.init-secrets.yml
scripts/
  export-compose-images-docker.sh
  export-compose-images-podman.sh
  load-compose-images-docker.sh
  load-compose-images-podman.sh
```

## 공통 준비

```bash
cp .env.example .env
vi .env
cp /path/to/license.json license/license.json
```

`.env`의 `EXTERNAL_URL`, `BROKER_WS_URL`, `PUBLIC_BROKER_WS_URL`은 실제
사용자가 접속하는 host/port와 일치해야 합니다.

## Offline Image Flow

온라인 환경에서 대상 runtime에 맞는 이미지 archive를 생성합니다.

```bash
# Docker 서버용
./scripts/export-compose-images-docker.sh

# Podman 서버용
./scripts/export-compose-images-podman.sh
```

Docker용 archive와 Podman용 archive는 `init-secrets` 이미지명이 다르므로 서로 바꿔
쓰지 않습니다.

생성된 archive, checksum, image list 파일은 대상 폐쇄망 서버의 repo `images/`
디렉터리로 옮긴 뒤 load합니다.

폐쇄망 Docker 서버:

```bash
./scripts/load-compose-images-docker.sh ./images/lucy-teamcloud-onprem-docker-images-linux-amd64.tar.gz
docker compose --env-file .env -f compose.docker.yml up -d --pull never --no-build
```

폐쇄망 Podman 서버:

```bash
./scripts/load-compose-images-podman.sh ./images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz

podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets

podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

Podman Compose에서는 Docker Compose의 `--pull never` 옵션을 쓰지 마세요. 일부
`podman-compose` 버전은 `never`를 서비스명으로 해석합니다.

## 백업 대상

필수 백업:

- `.env`
- `license/license.json`
- `secrets/secrets.env`
- `postgres/data/`
- `git/data/`

권장 백업:

- `nginx/certs/`
- `broker/data/`
- `broker/logs/`
