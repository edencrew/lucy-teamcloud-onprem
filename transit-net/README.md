````md
# transit-net (tc-transit Docker Network)

`transit-net`은 컨테이너/서비스가 아니라, 여러 docker-compose 스택이 **서로를 “컨테이너 이름(DNS)”으로 찾기 위해 공유하는 외부 Docker 네트워크**입니다.

- `teamcloud` 같은 서비스 스택이 `tc-transit`에 붙어 **업스트림(서비스)을 제공**
- `gateway(gw-stack)`가 같은 `tc-transit`에 붙어 **reverse proxy / stream proxy**로 트래픽을 라우팅

> 핵심: `tc-transit`은 “공용 버스(backbone)”이며, 없으면 스택 간 통신이 끊깁니다.

---

## 1) 왜 필요한가?

Docker Compose 스택은 기본적으로 **각 스택 내부(default network)** 에서만 이름 해석이 됩니다.  
즉, `teamcloud` 스택의 컨테이너 이름(예: `teamcloud-network-gitea`)을 `gateway` 스택에서 바로 쓰려면,
두 스택이 **같은 네트워크에 함께 연결**되어 있어야 합니다.

`tc-transit`은 이 목적을 위한 **External Network**입니다.

- 장점
  - 스택 간 연결이 명확해짐(“여기 붙으면 서로 보임”)
  - 포트 외부 노출을 최소화하고, `gateway`를 단일 진입점으로 만들기 쉬움
- 주의
  - 네트워크 이름(`tc-transit`)이 compose 파일의 external name과 **정확히 일치**해야 함

---

## 2) 네트워크 생성/확인/삭제

### 2.1 생성 (최초 1회)
```bash
docker network create tc-transit
````

### 2.2 확인

```bash
docker network ls | grep tc-transit

# 상세(연결된 컨테이너/서브넷 등 확인)
docker network inspect tc-transit | sed -n '1,200p'
```

### 2.3 삭제 (주의)

⚠️ `tc-transit`을 삭제하면, 이 네트워크에 의존하는 스택이 통신 불가가 되거나 재기동 실패가 날 수 있습니다.

```bash
docker network rm tc-transit
```

---

## 3) docker-compose에서 연결하는 방법

### 3.1 gateway(gw-stack)에서 예시

`gw-stack`은 아래처럼 외부 네트워크를 “참조만” 합니다.

```yaml
networks:
  tc-transit:
    external: true
    name: tc-transit
```

그리고 서비스(예: `gw-nginx`)에서 networks에 추가합니다.

```yaml
services:
  nginx:
    networks:
      - gw_default
      - tc-transit
```

### 3.2 teamcloud에서 예시

`teamcloud`의 주요 서비스 컨테이너(nginx가 라우팅할 대상)도 `tc-transit`에 붙여야 합니다.

```yaml
networks:
  tc-transit:
    external: true
    name: tc-transit

services:
  teamcloud-network-gitea:
    networks:
      - default
      - tc-transit
```

---

## 4) 띄우는 순서(권장)

1. `tc-transit` 생성
2. `teamcloud` up (업스트림 서비스 제공)
3. `gateway(gw-stack)` up (외부 노출/라우팅)

```bash
docker network ls | grep tc-transit || docker network create tc-transit
cd teamcloud && docker compose up -d
cd gateway  && docker compose up -d
```

> 참고: gateway를 먼저 띄워도 “살아있게” 만들 수는 있지만,
> stream(TCP) 라우팅은 upstream DNS 문제로 nginx 전체가 죽지 않도록 **변수 기반 proxy_pass 템플릿**을 반드시 지켜야 합니다.

---

## 5) 운영 체크/디버깅

### 5.1 어떤 컨테이너가 붙어있는지 확인

```bash
docker network inspect tc-transit \
  --format '{{json .Containers}}' | jq
```

### 5.2 gateway 컨테이너에서 업스트림 DNS 확인

(예: `gw-nginx`에서 `teamcloud-network-gitea`가 해석되는지)

```bash
docker exec -it gw-nginx sh -lc 'getent hosts teamcloud-network-gitea || true'
```

### 5.3 컨테이너가 tc-transit에 붙어있는지 확인

```bash
docker inspect gw-nginx --format '{{json .NetworkSettings.Networks}}' | jq
```

---

## 6) 베스트 프랙티스

* **네트워크 이름은 고정**: `tc-transit` (compose external name과 동일해야 함)
* **외부 노출 포트 최소화**: 내부 서비스는 가능하면 외부 publish 하지 않고 gateway가 받아서 라우팅
* **서비스명/컨테이너명 변경 시 주의**: gateway의 nginx upstream(`proxy_pass`)는 컨테이너 이름을 사용하므로, 이름 바꾸면 라우팅도 같이 바뀜
* **SSH 같은 Stream 트래픽은 도메인으로 분기 불가**: 같은 포트(예: 2222)에서 `git.dev`/`tunnel.dev`처럼 SNI/Host 기반 분기가 안 되므로, 포트 분리 또는 IP 분리 정책을 권장

