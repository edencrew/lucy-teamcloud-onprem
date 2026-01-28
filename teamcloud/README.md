# teamcloud (app-stack)

`teamcloud`는 **Gateway(gw-stack)** 뒤에서 동작하는 “업스트림 서비스 묶음”입니다.  
외부 트래픽은 직접 받지 않고(원칙), `tc-transit` 네트워크를 통해 **gw-nginx가 서비스들을 찾아 라우팅**합니다.

구성 목표는 아래 3가지입니다.

1) `gw-stack`이 **컨테이너 DNS 이름**으로 업스트림을 안정적으로 찾을 수 있게 한다  
2) 서비스 내부 통신은 `teamcloud-internal`로 묶고, 외부에 노출할 서비스만 `tc-transit`에 붙인다  
3) Gitea + Postgres + MQTT 같은 필수 인프라를 한 스택으로 올려 “팀 개발 환경”을 빠르게 제공한다

---

## 1) 스택 구성 요약

이 스택은 크게 3 레이어로 이해하면 쉽습니다.

### 1.1 Application (dummy로 대체된 HTTP 서비스들)
- `teamcloud-fe` : TeamCloud Frontend (현재 nginx dummy)
- `teamcloud-be` : TeamCloud Backend (현재 nginx dummy)
- `auth-fe` : Auth Frontend (현재 nginx dummy)
- `auth-be` : Auth Backend (현재 nginx dummy)

> 지금은 dummy nginx로 “업스트림 라우팅/도메인/네트워크” 파이프라인을 먼저 고정하는 단계고,  
> 이후 실제 앱 컨테이너로 교체하면 됩니다.

### 1.2 Gitea (Git 서비스)
- `gitea-postgresql` : Gitea 전용 Postgres
- `gitea` : Gitea runtime
- `gitea-bootstrap` : Gitea 초기 설정/관리자 계정 자동 생성(1회성)

### 1.3 Infra
- `postgresql` : (teamcloud/auth 앱용이라고 가정한) App Postgres
- `mqtt` : Mosquitto MQTT Broker (WS 포함 가능)

---

## 2) 네트워크 설계

### 2.1 teamcloud-internal (내부 전용)
- 목적: DB, 내부 통신 등을 “스택 내부”로 격리
- 이 네트워크에만 붙은 컨테이너는 **gateway에서 직접 접근 불가**

현재 `teamcloud-internal`에 붙는 서비스:
- `gitea-postgresql`
- `postgresql(app-postgresql)`
- `gitea-bootstrap`
- (그리고 대부분의 서비스가 internal에도 함께 붙어 있음)

### 2.2 tc-transit (외부 공유 네트워크, gateway 연동)
- 목적: `gw-nginx`가 업스트림을 “서비스 이름으로” 찾기 위한 공용 버스
- `tc-transit`은 별도 스택(`transit-net`)에서 **미리 생성된 external network**여야 함

현재 `tc-transit`에 붙는 서비스(업스트림 제공자):
- `teamcloud-fe`  (alias: `teamcloud-network-teamcloud-fe`)
- `teamcloud-be`  (alias: `teamcloud-network-teamcloud-be`)
- `auth-fe`       (alias: `teamcloud-network-auth-fe`)
- `auth-be`       (alias: `teamcloud-network-auth-be`)
- `gitea`         (alias: `teamcloud-network-gitea`)
- `mqtt`          (alias: `teamcloud-network-mqtt`)

> gw-stack은 이 alias들을 upstream으로 사용합니다.  
> 예: `proxy_pass http://teamcloud-network-gitea:3000;`  
> 예: (stream) `proxy_pass $upstream;` where `$upstream = teamcloud-network-gitea:22`

---

## 3) 실행 순서(중요)

권장 순서:

1) `tc-transit` 네트워크 생성  
2) `teamcloud(app-stack)` up  
3) `gateway(gw-stack)` up

```bash
# 1) transit net 준비
docker network ls | grep tc-transit || docker network create tc-transit

# 2) teamcloud 기동
docker compose up -d

# 3) 상태 확인
docker compose ps
docker logs -f gitea
docker logs -f mqtt
````

> gateway를 먼저 띄워도 “살아있게” 만들 수는 있지만,
> stream(TCP) 라우팅이 DNS 문제로 nginx 전체를 죽이지 않도록 “변수 기반 proxy_pass 템플릿”을 지켜야 합니다.

---

## 4) 서비스별 상세

## 4.1 Gitea DB (gitea-postgresql)

* 이미지: `postgres:17`
* 네트워크: `teamcloud-internal` 전용
* 환경변수:

  * `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
* healthcheck:

  * `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB`

볼륨:

* `gitea_pgdata:/var/lib/postgresql/data`

### 4.2 Gitea Runtime (gitea)

* 이미지: `docker.gitea.com/gitea:1.25.3`
* 의존성:

  * `gitea-postgresql` healthy 이후 시작
* 네트워크:

  * `teamcloud-internal`
  * `tc-transit` (alias: `teamcloud-network-gitea`)

주요 설정 포인트:

* DB 연결

  * `GITEA__database__HOST=gitea-postgresql:5432`
* reverse proxy 환경

  * `GITEA__server__DOMAIN=${GITEA_DOMAIN}`
  * `GITEA__server__ROOT_URL=${GITEA_ROOT_URL}`
  * `GITEA__server__PROTOCOL=http`
  * `GITEA__server__HTTP_PORT=3000`
* SSH 도메인

  * `GITEA__server__SSH_DOMAIN=${GITEA_DOMAIN}`
* 설치 잠금

  * `GITEA__security__INSTALL_LOCK=true`
* Secret 고정(권장)

  * `GITEA__security__SECRET_KEY`
  * `GITEA__security__INTERNAL_TOKEN`
  * `GITEA__oauth2__JWT_SECRET`

볼륨:

* `gitea_data:/data`

> ⚠️ SSH 포트 자체는 Gitea 내부 설정(app.ini)에도 영향을 받습니다.
> gateway에서 `:2222 -> gitea:22`로 프록시한다면, 최종 사용자 입장 SSH Port는 2222입니다.
> 이 값은 gateway README의 stream ssh 템플릿과 함께 “한 세트”로 봐야 합니다.

### 4.3 Gitea Bootstrap (gitea-bootstrap)

* 이미지: `docker.gitea.com/gitea:1.25.3`
* 목적: “최초 1회” 관리자 계정을 자동 생성(이미 존재하면 스킵)
* 동작:

  1. `/data/gitea/conf/app.ini` 생성될 때까지 대기
  2. `gitea migrate` 재시도 루프로 테이블 생성 보장
  3. `gitea admin user list`로 존재 확인 후 없으면 생성

필수 환경변수(없으면 스킵):

* `GITEA_ADMIN_USERNAME`
* `GITEA_ADMIN_PASSWORD`
* `GITEA_ADMIN_EMAIL`

> 운영에서는 bootstrap을 제거하고 수동 운영해도 됩니다.
> 다만 “인프라 재현성”이 필요하면 bootstrap은 매우 유용합니다.

### 4.4 MQTT (mqtt)

* 이미지: `eclipse-mosquitto:2`
* 네트워크:

  * `teamcloud-internal`
  * `tc-transit` (alias: `teamcloud-network-mqtt`)
* 마운트:

  * `./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro`
  * `mosquitto_data`, `mosquitto_log`

> gateway에서 stream 1883/8883으로 받아서 이 mqtt로 전달하는 구조를 권장합니다.

### 4.5 App Postgres (app-postgresql)

* 이미지: `postgres:17`
* 네트워크: `teamcloud-internal`
* 현재는 “teamcloud/auth 앱용”으로 가정된 기본 DB 컨테이너

---

## 5) .env 템플릿

아래는 현재 제공된 `.env`를 “설명 포함 템플릿” 형태로 정리한 것입니다.

```dotenv
# =========================
# Timezone
# =========================
TZ=Asia/Seoul

# =========================
# Gitea Postgres
# =========================
GITEA_POSTGRES_DB=gitea
GITEA_POSTGRES_USER=gitea
GITEA_POSTGRES_PASSWORD=CHANGE_ME

# (참고) 아래 3개는 이 compose에서는 직접 사용하지 않지만
# 관성적으로 Postgres 이미지 기본 env로 쓰는 경우가 많아 참고로 둡니다.
POSTGRES_DB=gitea
POSTGRES_USER=gitea
POSTGRES_PASSWORD=CHANGE_ME

# =========================
# Gitea URL/SSH (Gateway와 "한 세트"로 맞춰야 함)
# =========================
GITEA_DOMAIN=git.dev.edencrew.io
GITEA_ROOT_URL=https://git.dev.edencrew.io/

# 사용자가 SSH 접속할 포트(외부에서 보이는 포트)
# 예) ssh -p 2222 git@git.dev.edencrew.io
GITEA_SSH_PORT=2222
GITEA_SSH_PUBLISH_PORT=2222

# =========================
# Gitea secrets (고정 권장)
# - 새 설치 때 자동 생성도 가능하지만,
#   분실/변경 시 암호화된 데이터 복호화 불가 리스크가 있음
# =========================
GITEA_SECRET_KEY=CHANGE_ME_LONG_RANDOM
GITEA_INTERNAL_TOKEN=CHANGE_ME_LONG_RANDOM
GITEA_JWT_SECRET=CHANGE_ME_LONG_RANDOM

# =========================
# Gitea Admin (bootstrap 초기 1회 생성용)
# =========================
GITEA_ADMIN_USERNAME=sysadmin
GITEA_ADMIN_PASSWORD=sysadmin
GITEA_ADMIN_EMAIL=sysadmin@edencrew.com
```

> ✅ 운영 팁
>
> * `GITEA_SECRET_KEY`, `GITEA_INTERNAL_TOKEN`, `GITEA_JWT_SECRET`는 “절대 바꾸지 않는 값”으로 관리(Secrets Manager/SSM Parameter Store 권장)
> * admin password는 bootstrap 이후 즉시 변경 권장

---

## 6) Gateway(gw-stack)에서 바라보는 “업스트림 계약(Contract)”

gateway는 `tc-transit` 기준으로 아래 이름을 믿고 라우팅합니다.

| 목적           | upstream 이름(alias)               | 포트 예시                                |
| ------------ | -------------------------------- | ------------------------------------ |
| TeamCloud FE | `teamcloud-network-teamcloud-fe` | 80(또는 앱 포트)                          |
| TeamCloud BE | `teamcloud-network-teamcloud-be` | 80/8080 등                            |
| Auth FE      | `teamcloud-network-auth-fe`      | 80                                   |
| Auth BE      | `teamcloud-network-auth-be`      | 80/8080 등                            |
| Gitea HTTP   | `teamcloud-network-gitea`        | 3000                                 |
| Gitea SSH    | `teamcloud-network-gitea`        | 22 (gateway가 2222로 publish)          |
| MQTT         | `teamcloud-network-mqtt`         | 1883 (gateway가 1883/8883 publish 가능) |

> 이 alias가 바뀌면 gateway의 nginx conf도 같이 바뀌어야 합니다.
> 즉, alias는 “인터페이스”이므로 가급적 고정하세요.

---

## 7) 운영 점검 / 트러블슈팅

### 7.1 네트워크/DNS 확인

```bash
# gitea가 tc-transit에 붙어있는지
docker inspect gitea --format '{{json .NetworkSettings.Networks}}' | jq

# gw-nginx에서 gitea 이름이 해석되는지(게이트웨이 컨테이너가 떠있다는 가정)
docker exec -it gw-nginx sh -lc 'getent hosts teamcloud-network-gitea || true'
```

### 7.2 Gitea 상태 확인

```bash
docker logs -f gitea
docker logs -f gitea-postgresql
docker logs -f gitea-bootstrap
```

### 7.3 자주 나는 문제

#### (A) gateway에서 `host not found in upstream "teamcloud-network-gitea:22"`

* 원인: `tc-transit`에 gitea가 아직 안 붙었거나, alias/이름이 다름
* 해결:

  * `docker compose ps`로 gitea 상태 확인
  * `docker network inspect tc-transit`로 연결 확인
  * gateway stream conf는 변수 기반 `proxy_pass` 사용(게이트웨이 README 참조)

#### (B) gitea-bootstrap이 admin 생성 실패

* 원인: `GITEA_ADMIN_*` env 누락 또는 app.ini 생성/마이그레이션 실패
* 해결:

  * `docker logs gitea-bootstrap` 확인
  * `/data/gitea/conf/app.ini` 생성 여부 확인

---