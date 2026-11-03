# Devora (선택 add-on) — 실무 안내

TeamCloud(TC) on-prem용 선택 Devora BE입니다. BE commit
`e196ad2aa8c3a5a1f130e443e6173af180304cee`(tree `1528a3b84799db085aad24b6edf7b4c081b483e7`)에
고정되어 있고 공개 BE tag는 없습니다. 별도 Compose project(`devora`)로 자체 postgres
(pgvector/pgvector:pg16), redis(redis/redis-stack-server:7.4.0-v3), api를 실행하며 TC와 공유하는 것은
없습니다. TC-only 설치에는 영향이 없습니다. 정밀한 설치기 계약은 [INTERFACE.md](INTERFACE.md)가
기준이며 이 문서는 사람이 따라 하는 순서만 요약합니다. 이 문서는 미릴리스 로컬 통합 source 기준이며
공개 Release나 production 지원을 뜻하지 않습니다.

경계 용어:

- **source**: 이 저장소의 `devora/` 파일(`manage.sh`, compose 파일 등). 대상 서버에서 수정하지 않습니다.
- **config**: 운영자가 준비하는 env 파일(`.env.example` 기반, `0600`)과 선택 CA bundle.
- **binary/media**: 검증된 kit의 product archive와 `devora-media`(image archive, `db/init`, `docs`, `SHA256SUMS`).
- **runtime**: 설치 계정의 Podman image storage·named volume·container. 대상 서버에서 build/pull하지 않습니다.

## 빠른 이동

| 하려는 일 | 이동 |
|-----------|------|
| 미디어 만들기(온라인 빌드 호스트) | [1. 온라인 준비](#1-온라인-준비-연결된-빌드-호스트) |
| 운영자 입력·CA·파일 권한 | [2. 운영자 입력](#2-운영자-입력) |
| TC 첫 조직 만들기 | [3. TC 첫 조직 초기화](#3-tc-첫-조직-초기화) |
| TC-only 설치 뒤 Devora 따로 올리기 | [4. 단계별 standalone 설치](#4-단계별-standalone-설치) |
| JWKS·provider·timeout 점검 | [5. JWKS 직접 200 확인](#5-jwks-직접-200-확인), [6. LLM·embedding provider](#6-llmembedding-provider와-timeout) |
| 준비 완료 판단·검증 현황 | [7. 준비 완료 관문](#7-준비-완료-관문), [8. 검증 현황](#8-검증-현황) |

## 1. 온라인 준비 (연결된 빌드 호스트)

```bash
bash devora/prepare-media.sh docker --be-repo /path/to/be-clone --be-image REGISTRY/devora-be:e196ad2 --out /empty/dir
```

이미 빌드된 BE image 재사용(`podman`도 동일):

```bash
bash devora/prepare-media.sh docker --existing-image --be-repo DIR --be-image REF --out EMPTY_DIR
```

- 모든 ref(BE, pgvector, redis)가 로컬에 있어야 합니다. linux/amd64, OCI label
  `org.opencontainers.image.revision` = 고정 BE commit, `app/commit_sha.txt`를 확인하며 build/pull/retag는 하지 않습니다.
  기본 모드는 기존 BE ref를 거부하고 없음이 확인된 의존 image만 pull합니다.
- Inventory/`be_image_id`는 저장된 image config의 sha256이며 Docker index/platform-manifest `.Id`가 아닙니다.
  읽을 수 없는 save는 실패로 처리합니다(없음으로 취급하지 않음). Docker `--platform`은 CLI가 지원할 때만 씁니다.
- 기본 build 모드: 정확한 commit의 `git archive` → `docker buildx build --platform linux/amd64
  --build-arg SOURCE_COMMIT=<commit> -f source/Dockerfile --load -t "$BE_IMAGE" source` → arch와
  `app/commit_sha.txt` 확인 → BE image(Podman은 `podman save -m`, multi-image archive) + pgvector + redis 저장 → `db/init` 001-003,
  `docs` 복사 → `PROVENANCE.txt`, `SHA256SUMS` 작성. bit 재현 빌드가 아니므로(uv.lock 미사용, floating
  dependency/HF revision) 저장 image checksum을 고정합니다.
- 대상 서버에서는 build/pull하지 않습니다. Docker 같은 daemon 수용 결과는 실제 Podman, 새 store, 앱 설치를 인증하지 않습니다.

## 2. 운영자 입력

- `.env.example`을 복사해 모든 `CHANGE_ME`를 실제 값으로 바꿉니다. 외부 LLM(LiteLLM)·embedding
  endpoint는 미리 있어야 합니다(기동 시 1024차원 embedding 확인). OIDC JWKS는 HTTPS/RS256과 실제 CA 신뢰가 필요합니다.
- `WEB_SEARCH_ENABLED=false`는 egress 차단이 아닙니다. 요청은 `use_web=none`으로 두고 실제 network policy를 적용합니다.
- 선택 사설 CA: 호스트에 승인된 사설 root + 공개 root를 합친 일반 PEM bundle을 직접 준비하고
  `DEVORA_CA_BUNDLE_FILE=/opt/example/ca/combined-ca.pem`을 설정합니다(기본 pool을 대체). `manage.sh`는
  읽기 전용(`z`, 공유 SELinux label)으로 `api`에 mount해 `SSL_CERT_FILE`로 씁니다. root나 추가 도구(Python/jq/openssl)는
  쓰지 않습니다. 경로 안전성과 PEM 인증서 형태(개인키 없음)만 확인하며 인증서를 검증·생성·복사하지 않고,
  이미 있다고 가정하지도 않습니다. 비워 두면 동작이 바뀌지 않습니다. 자세한 계약은 [INTERFACE.md](INTERFACE.md)를 봅니다.
- 권한: secret env `0600`, 실행용 SQL/docs 파일 `0644`, 미디어 디렉터리(상위 포함) `0755`.
  container UID 추측, chown, `0777`은 쓰지 않습니다. 설치기는 이 비밀이 아닌 미디어만 읽기 가능한 mode로 복사합니다.
- rootless Podman 데이터 소유권: `compose.podman.yml`의 postgres는 `keep-id` 매핑으로 새 데이터를 설치 계정 소유로
  만듭니다(redis·api는 기본 rootless userns 유지). 이는 **새 빈 volume** 기준입니다. 이전 매핑으로 만든 기존 데이터의
  자동 이전·재귀 chown은 하지 않으며 미해결입니다. 범위와 수동 이전 원칙은
  [README.infra-redesign.md](../README.infra-redesign.md#3x-rootless-영속-데이터-소유권-일부-linux-검증-미출시)를 봅니다.
- 입력 원본 env와 설치기가 복사한 env는 다를 수 있습니다. standalone 실행에는 실제로 제공·승인된 env 파일을 씁니다.

## 3. TC 첫 조직 초기화

OIDC 로그인 성공은 시스템 초기화가 아닙니다. 초기화 전에는 API가 `503 System is not initialized`를 돌려줄 수 있습니다.

1. 일반 화면의 `/initialize`에서 첫 조직을 만들어도 됩니다.
2. API로 할 때는 실제 OIDC 로그인으로 받은 정상 access token으로
   `POST /api/v1/system/initialize`를 호출합니다. body 필드:
   - `orgName`: 비어 있지 않은 소문자·숫자·하이픈
   - `orgDisplayName`: 비어 있지 않은 표시 이름
3. 성공 응답은 `201`입니다(예전 문서의 `200`과 다르며, 소스와 실험실 시험 모두 `201`).
   응답 body의 `organization.id`가 서버가 만든 조직 UUID입니다.
4. 이어서 `GET /api/v1/me/orgs`로 확인합니다. 이 응답은 배열이며, 만든 조직에 해당하는 항목의 `id`가
   POST의 `organization.id`와 같아야 합니다. 그 값이 실제 `DEPLOYMENT_ORG_ID`입니다.
5. `409`(이미 초기화됨)면 멈춥니다. 다시 초기화하지 말고 `GET /api/v1/me/orgs`로 기존 조직을 확인합니다.
   `403`(`License not initialized`/`License has expired` 등 license 미적재·만료, 또는 on-prem 환경이 아님)이면
   멈추고 license·배포 환경을 관리자와 확인합니다.

하지 말 것: UUID 지어내기, 가짜 JWT, DB 직접 쓰기, 일반 `POST /orgs`(on-prem에서는 잘못된 SaaS 경로),
token이나 token이 든 body를 문서·로그에 남기기.

## 4. 단계별 standalone 설치

현재 확인된 순서는 "TC-only 설치 → 사용자 승인 후 Devora 별도 실행"입니다. Devora를 포함한 통합 TUI 설치는
시험하지 않았습니다.

1. kit-format2 TUI로 TC-only를 설치하고 [3장](#3-tc-첫-조직-초기화)으로 첫 조직을 만듭니다.
2. 두 가지를 구분합니다.
   - Devora **product 파일**(`manage.sh`, compose 파일 등): 검증된 kit의 `product/teamcloud-initial.tar.gz`
     안의 소문자 `payload/devora/` 경로(대소문자 구분)에 있습니다. 미디어가 아닙니다.
   - Devora **미디어**(image archive, `db/init`, `docs`, `SHA256SUMS` 등): 별도로 검증·복사한 kit의 `devora-media`입니다.
   kit 원본에는 `source/devora`가 없습니다. marker/receipt/JSON을 손으로 만들어 빈 곳을 메우지 않습니다.

   product 파일은 새로 승인된 빈 디렉터리에만 풉니다(기존 설치 덮어쓰기, archive 수정, 넓은 chmod/chown 금지).

```bash
# 예시 경로: 실제 승인된 값으로 바꿉니다.
TC_ROOT=/opt/example/teamcloud
KIT_DIR=/opt/example/kit                       # 이미 checksum 검증한 kit
DEVORA_DIR=/opt/example/devora-product         # 새 승인 디렉터리(아직 없어야 함)
ENV_FILE=/opt/example/devora/devora.env        # 실제 제공·승인된 env(0600)
MEDIA_DIR=/opt/example/devora/media            # 검증 후 복사한 devora-media

test ! -e "$DEVORA_DIR" && mkdir -m 0755 "$DEVORA_DIR" &&
tar -tzf "$KIT_DIR/product/teamcloud-initial.tar.gz" | grep '^payload/devora/' &&
tar -xzf "$KIT_DIR/product/teamcloud-initial.tar.gz" -C "$DEVORA_DIR" \
  --strip-components=2 --no-same-owner --no-overwrite-dir --keep-old-files 'payload/devora/' &&
ls -la "$DEVORA_DIR"
```

   목록이 위 `tar -tzf` 출력의 파일과 정확히 같은지 확인합니다. 다르면 멈춥니다.

3. 실행 신원: TC와 같은 OS 사용자, 같은 rootless/rootful 모드, 같은 image storage와 socket.
   Compose provider는 추측하지 말고 현재 설치기가 둔 고정 binary `$TC_ROOT/bin/teamcloud-compose`를
   `DEVORA_COMPOSE_BINARY`로 지정합니다. socket은 실제 `podman info` 값을 씁니다.

```bash
SOCK=$(podman info --format '{{.Host.RemoteSocket.Path}}') &&
SOCK=${SOCK#unix://} &&
test -n "$SOCK" && test -S "$SOCK" &&
export DOCKER_HOST="unix://$SOCK" &&
export DEVORA_COMPOSE_BINARY="$TC_ROOT/bin/teamcloud-compose" &&
test -x "$DEVORA_COMPOSE_BINARY" &&
bash "$DEVORA_DIR/manage.sh" podman validate --env-file "$ENV_FILE" --media-dir "$MEDIA_DIR" &&
bash "$DEVORA_DIR/manage.sh" podman load --env-file "$ENV_FILE" --media-dir "$MEDIA_DIR" &&
bash "$DEVORA_DIR/manage.sh" podman bootstrap --env-file "$ENV_FILE" --media-dir "$MEDIA_DIR"
```

   어느 단계든 실패하면 그 자리에서 멈추고 다음 단계를 실행하지 않습니다.

4. `bootstrap`은 새 빈 volume에서 한 번만 합니다. 이후는 `start`/`stop`/`status`만 씁니다.
   `load`는 inventory ref가 다른 ID/platform으로 이미 있으면 적재 전에 실패합니다(tag 이동 방지). script는 volume을
   지우지 않으며 script 파일은 mode 0644이므로 항상 `bash`로 실행합니다.

명령 형식: `bash devora/manage.sh <docker|podman> <validate|load|bootstrap|start|stop|status> --env-file F --media-dir D`.

읽기 전용 상태·로그(같은 provider, env, project `devora`, `compose.podman.yml`; `manage.sh`에는 logs action이 없음):

```bash
bash "$DEVORA_DIR/manage.sh" podman status --env-file "$ENV_FILE" --media-dir "$MEDIA_DIR"
DEVORA_ENV_FILE="$ENV_FILE" DEVORA_MEDIA_DIR="$MEDIA_DIR" \
  "$DEVORA_COMPOSE_BINARY" -p devora --env-file "$ENV_FILE" -f "$DEVORA_DIR/compose.podman.yml" ps
DEVORA_ENV_FILE="$ENV_FILE" DEVORA_MEDIA_DIR="$MEDIA_DIR" \
  "$DEVORA_COMPOSE_BINARY" -p devora --env-file "$ENV_FILE" -f "$DEVORA_DIR/compose.podman.yml" logs --tail=200 api
```

수명주기 경계:

- TC unit/`teamcloudctl`은 나중에 따로 올린 standalone Devora를 같은 unit에 등록하지 않습니다.
  late add-on 지원이나 `add-devora` 명령은 없습니다(미지원).
- standalone Devora는 위 `manage.sh`로 독립 관리합니다. 로그아웃·재부팅 후 자동 기동이 필요하면 별도로 승인된
  user unit 계획을 따로 세웁니다. 이 저장소는 그 unit helper를 제공하지 않으며, SSH 세션에서 bootstrap이 됐다고
  로그아웃/재부팅 유지가 증명되지는 않습니다.

## 5. JWKS 직접 200 확인

고정된 Devora는 기본 AsyncHTTPX를 쓰며 redirect를 따라가지 않습니다. 시험에서는 metadata가 알린 JWKS 경로가
`307`로 다른 경로로 넘어갔고, 잘못된 URI 설정은 `/v1/auth/me`에서 `502 AUTH_UNAVAILABLE`을 냈습니다.
어떤 JWKS 경로도 보편 정답으로 고정하지 마십시오. 실제 metadata를 보고, 검증된 CA로 `-L` 없이 확인합니다.

discovery URL은 issuer 뒤에 `/.well-known/openid-configuration`을 붙여 만들지 않습니다. 실제 provider의
metadata endpoint는 issuer와 독립적이므로 운영자가 확인한 URL을 그대로 씁니다.

```bash
DISCOVERY_URL=https://idp.example.com/OPERATOR-CONFIRMED-DISCOVERY-PATH   # issuer 연결 금지
CA=/opt/example/ca/combined-ca.pem
curl -sS --cacert "$CA" "$DISCOVERY_URL"            # jwks_uri 값을 눈으로 확인
JWKS_URL=https://idp.example.com/PATH-FROM-METADATA # 위 jwks_uri
curl -sS --cacert "$CA" -D jwks.headers -o jwks.json -w '%{http_code}\n' "$JWKS_URL"
grep -i '^location:' jwks.headers                   # 3xx일 때 대상 확인
cat jwks.json                                       # 공개 JWKS: "keys"가 비어 있지 않고 "kty":"RSA" 확인
```

- `200`이고 `keys`에 RSA 키가 있으면 그 URL을 씁니다.
- `3xx`면 `Location` 값을 직접 봅니다. 대상이 HTTPS이고 허용 host이며, 그 URL에 위 명령을 다시 실행해
  직접 `200`과 비어 있지 않은 RSA `keys`가 나오는지 확인합니다. 그 뒤 `OIDC_JWKS_URI`를 그 직접 URL로, host
  allowlist를 그 실제 대상 host로 설정합니다.
- 실제 token의 `iss`/`aud`/`typ`는 그대로 유지·설정합니다(다른 환경 값을 복사하지 않음).
- follow-redirect 활성화, `curl -k`, TLS/인증 완화는 해결책이 아닙니다. 인증 서버의 광고 경로 수정은 범위 밖입니다.

## 6. LLM·embedding provider와 timeout

- 고정 BE는 `use_rag=false`여도 기동 시 실제 1024차원 embedding이 필요합니다.
- `LITELLM_BASE_URL`(`/v1`) 하나와 key 하나로 chat과 embedding을 함께 씁니다. Responses 전용 endpoint는 호환되지 않습니다.
  실제 provider에서 chat, embedding, SSE와 usage 옵션을 확인합니다.
- BE embedding 호출은 30초 timeout 안에 끝나야 합니다. "실행 중"만 보지 말고, 서비스가 보내는 요청 형태로 짧은
  차원 probe를 cold/warm 따로 재십시오.
- 시험 관찰(권장값 아님): CPU 2개 기본 설정에서 cold embedding이 30초를 넘었고, 같은 weight의 provider alias·thread·
  keep-alive 조정 후 1초 미만이었습니다. 특정 `num_thread`/CPU/`KEEP_ALIVE` 값이나 보편 benchmark로 쓰지 마십시오.
  BE timeout이나 model 기동 수정은 범위 밖입니다.

## 7. 준비 완료 관문

각 관문을 따로 기록합니다. health `200`은 인증 증거가 아닙니다. 원시 token은 로그에 남기지 않습니다.

1. TC health
2. 실제 TLS 로그인
3. 실제 조직(`GET /api/v1/me/orgs`)
4. Devora health/`readyz`(인증 없음, 기동 확인만)
5. 실제 TC token으로 `/v1/auth/me`
6. 실제 TC token과 정식 frontend가 쓰는 **`POST /v1/assist` SSE**로 모델 응답을 확인합니다.
   요청 body는 고정 BE의 API 문서와 실제 클라이언트를 따르며 이 문서에서 임의로 만들지 않습니다.

legacy `/v1/chat`·stream 경로는 지원 검증 경로가 아니며 이 검증에 쓰지 않습니다. 시험에서 모델 호출은 성공했으나
해당 경로의 lock 연결 공백으로 fenced checkpoint가 active lock 없음 오류(`502`)를 냈습니다. lock 관련 flag를 끄거나
backend를 고쳐 성공 처리하지 않습니다. 제품 수정은 BE 쪽에서 보류 상태입니다.

인증 성공과 관리자 권한도 다릅니다. 시험에서 TC `org-owner`는 Devora `USER`로 관찰됐고 로그에는
`org-admin`의 `ADMIN` 매핑이 나타났습니다. owner가 자동으로 ADMIN이라고 가정하지 말고 실제 응답 권한을
기록합니다. 권한 매핑 변경은 이 설치 절차의 범위가 아니며 BE 쪽에서 보류 상태입니다.

- 같은 provider/env/project로 [4장](#4-단계별-standalone-설치)의 `status`·`ps`·`logs`를 봅니다.
  재시작은 `stop`/`start`이며 bootstrap을 다시 하지 않습니다.
- SSH 로그아웃·재접속과 별도로 승인된 재부팅 뒤에는 실제 등록된 TC unit, 그리고 별도 Devora unit이 **있다면** 그 unit의
  상태, Devora container ID·status·health·시작 시각을 전후 비교합니다. 별도 unit이 제공되거나 TC unit에 등록된다고
  가정하지 않습니다. 하지 않았으면 미검증으로 기록합니다.
- 폐쇄망에서는 pull/build 금지, 인증/TLS 우회 금지, SELinux 비활성화 금지.

## 8. 검증 현황

2026-11-03 격리 실험실 관찰(UTC, Rocky Linux 9 계열·rootless Podman·SELinux Enforcing 시험 환경 한정,
당시 미릴리스 kit-format2 시험 kit 사용). 공개 Release나 production 수용이 아닙니다.

- TC-only TUI로 TC 9개 서비스 설치. 일반 HTTPS OIDC 로그인, `POST /api/v1/system/initialize` `201`로 실제 조직 생성.
- 정식 `payload/devora` product 파일과 검증된 `devora-media`를 사용한 standalone helper의 **bootstrap exit 0**과
  SQL 초기화·SELinux Enforcing 동작을 확인했습니다. `load` 호출은 외부 보조 도구의 240초 제한으로 끝났으며
  제품 helper의 성공 종료 코드는 수집하지 못했습니다. 관련 프로세스 종료와 세 이미지의 ID/platform이 inventory와
  일치함을 확인한 뒤 bootstrap으로 진행했습니다. validate→load→bootstrap 전체를 exit 0으로 판정한 것은 아닙니다.
  `DEVORA_CA_BUNDLE_FILE` → `SSL_CERT_FILE`의 실제 TLS 검증도 확인했습니다.
- JWKS: metadata가 알린 경로는 `307`, `Location` 대상은 직접 `200`, RSA 키 1개.
- 실제 model gateway(CPU 2개 관찰): embedding 1024, chat, SSE 통과. 관찰값이며 CPU/thread/`KEEP_ALIVE` 권장값이 아닙니다.
- 직접 JWKS URI로 교정한 뒤 `/health`·`/readyz`·`/v1/auth/me`가 각각 `200`.
- 로그아웃: 운영 계정 SSH 세션 0, linger 활성 상태의 30초 동안 TC health와 Devora health·readyz·auth/me가 200 유지.
- 재부팅: boot ID 변경 뒤 수동 기동 없이 TC와 Devora health·readyz가 200으로 자동 복구했고, 이후 user unit·Podman
  socket active와 서비스 12개 running을 확인했습니다. 이는 시험에서 별도 준비한 Devora unit을 포함한 결과이며,
  이 저장소가 standalone unit 등록을 제공한다는 뜻은 아닙니다.
- 재부팅 후 새 정상 로그인으로 정식 `POST /v1/assist` SSE 200, 요청 nonce 일치, done 1개·error 0개와
  health·readyz·auth/me 200을 확인했습니다. 관리자 권한 증명과는 별개입니다.
- 일반 인터넷 TCP 443·TCP/UDP 53 차단과 별도 대조 지점 성공을 함께 확인했습니다. 이 시험의 폐쇄망 검증 범위이며
  모든 목적지의 차단 보장은 아닙니다.

미검증: Devora 포함 통합 TUI, Studio UI, 전체 설치 수용, production, 공개 Release, 다른 OS/버전/모든 RHEL 계열,
성능 일반화, 기존 데이터의 keep-id 소유권 이전, 이 통합 source 자체의 실제 엔진 재시험. legacy chat 502와
owner→USER 권한 매핑의 제품 수정은 BE 쪽에서 보류 상태입니다.
