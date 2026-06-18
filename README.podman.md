# Lucy TeamCloud On-Premise Podman 설치 가이드

## 사전 요구사항

- Podman
- `podman compose` 또는 `podman-compose`
- 최소 4GB RAM, 10GB 디스크 공간
- SELinux 사용 환경에서는 bind mount relabel 지원 필요

## 1. 환경 설정

`.env.example` 파일을 복사하여 `.env` 파일을 생성합니다.

```bash
cp .env.example .env
```

Podman 기본 compose는 rootless 환경을 고려해 gateway를 `18080:80`,
`18443:443`으로 publish합니다.

`.env`의 `EXTERNAL_URL` port를 바꿔도 Podman publish port는 자동으로 바뀌지
않습니다. 다른 host port를 쓰려면 [gateway port mapping](#gateway-port-mapping)에
맞춰 `compose.podman.yml`의 `gw.ports`와 `.env` URL을 함께 수정하세요.

HTTP 예시:

```env
EXTERNAL_URL=http://teamcloud.example.com:18080
BROKER_WS_URL=ws://teamcloud.example.com:18080/mqtt
PUBLIC_BROKER_WS_URL=ws://teamcloud.example.com:18080/mqtt
```

HTTPS 예시:

```env
EXTERNAL_URL=https://teamcloud.example.com:18443
BROKER_WS_URL=wss://teamcloud.example.com:18443/mqtt
PUBLIC_BROKER_WS_URL=wss://teamcloud.example.com:18443/mqtt
```

Linux 서버에서는 compose 실행 계정의 UID/GID를 확인해 `.env`에 설정합니다.

```bash
id
```

```env
HOST_UID=1000
HOST_GID=1000
```

아래 값들은 최초 실행 후 변경하지 마세요.

- `LUCY_ADMIN_EMAIL`
- `LUCY_ADMIN_PASSWORD`
- `LUCY_ADMIN_NAME`
- `DB_ROOT_PASSWORD`
- `DB_USERNAME`
- `DB_PASSWORD`

## 2. 라이센스 파일 배치

```bash
cp /path/to/your/license.json license/license.json
```

라이센스 파일이 없으면 `tc-be`가 시작 시 검증에 실패하여 종료됩니다.

## 3. 서비스 실행

폐쇄망 Podman 서버에서는 먼저 [Offline Image Flow](#4-offline-image-flow)로 이미지를
로드한 뒤 실행합니다.

Podman Compose는 일회성 `init-secrets` 완료 대기를 안정적으로 처리하지 못하는
버전이 있으므로, Podman 설치에서는 `init-secrets`를 직접 한 번 실행한 뒤 전체
서비스를 올립니다.

```bash
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets

podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

상태와 로그 확인:

```bash
podman compose --env-file .env -f compose.podman.yml ps
podman compose --env-file .env -f compose.podman.yml logs -f
podman compose --env-file .env -f compose.podman.yml logs -f tc-be
```

중지:

```bash
podman compose --env-file .env -f compose.podman.yml down
```

운영 환경에서 `down -v`는 사용하지 마세요.

## 4. Offline Image Flow

온라인 환경에서 Podman용 이미지 archive를 만듭니다. export는 Docker CLI를 사용하며,
`compose.podman.yml`과 `compose.podman.init-secrets.yml`을 함께 읽습니다.

```bash
./scripts/export-compose-images-podman.sh
```

생성된 Podman용 파일들을 폐쇄망 Podman 서버의 repo `images/` 디렉터리로 옮깁니다.

```text
images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz
images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz.sha256
images/lucy-teamcloud-onprem-podman-images-linux-amd64.images.txt
images/lucy-teamcloud-onprem-podman-images-linux-amd64.archive-images.txt
images/lucy-teamcloud-onprem-podman-images-linux-amd64.services.txt
```

폐쇄망 Podman 서버에서 로드하고 실행합니다.

```bash
./scripts/load-compose-images-podman.sh ./images/lucy-teamcloud-onprem-podman-images-linux-amd64.tar.gz

podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets

podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

Docker용 archive는 Podman 설치에 사용하지 마세요. Podman용 archive에는
`localhost/lucy-teamcloud-onprem-init-secrets:offline` 이미지가 포함됩니다.

Podman Compose에서는 Docker Compose의 `--pull never` 옵션을 쓰지 마세요. 일부
`podman-compose` 버전은 `never`를 서비스명으로 해석합니다. offline 실행에서는
`--build`도 쓰지 않습니다. 필요한 이미지는 archive load 단계에서 이미 준비되어야
합니다.

## 5. 인증서와 시크릿

서비스 실행 전에 수동으로 실행한 `init-secrets`가 다음 파일을 생성합니다.

- `secrets/secrets.env`
- `nginx/certs/server.crt`
- `nginx/certs/server.key`

운영 인증서를 사용하는 경우 파일을 직접 교체한 뒤 gateway를 재시작합니다.

```bash
cp /path/to/server.crt nginx/certs/server.crt
cp /path/to/server.key nginx/certs/server.key
podman compose --env-file .env -f compose.podman.yml restart gw
```

`EXTERNAL_URL` host를 바꾼 경우 기존 self-signed 인증서와 맞지 않을 수 있습니다.
필요하면 인증서 파일을 삭제하고 `init-secrets`를 다시 실행하세요.

```bash
rm -f nginx/certs/server.crt nginx/certs/server.key
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets
podman compose --env-file .env -f compose.podman.yml restart gw
```

## 6. Podman 운영 메모

`compose.podman.yml`은 bind mount에 SELinux relabel 옵션 `:z`를 포함합니다.
SELinux를 사용하는 rootless Podman 환경에서는 이 옵션을 유지하세요.

rootless Podman에서 80/443 같은 privileged port를 쓰려면 OS 설정을 직접 조정해야
합니다. 기본값인 18080/18443 사용을 권장합니다.

Podman에서 volume 디렉터리 소유자가 host UID와 다르게 보일 수 있습니다. 이는 user
namespace 매핑의 결과일 수 있으므로 임의로 `chown`하기 전에 컨테이너 로그와
SELinux label을 먼저 확인하세요.

## 7. 백업 대상

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

백업 예시:

```bash
podman compose --env-file .env -f compose.podman.yml down
tar -czvf backup-$(date +%Y%m%d).tar.gz \
  .env license/license.json secrets nginx/certs postgres/data git/data broker/data broker/logs
podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

## 8. 문제 해결

Compose config:

```bash
podman compose --env-file .env -f compose.podman.yml config
```

서비스별 로그:

```bash
podman compose --env-file .env -f compose.podman.yml logs -f tc-be
podman compose --env-file .env -f compose.podman.yml logs -f gw
```

컨테이너 상태:

```bash
podman compose --env-file .env -f compose.podman.yml ps -a
podman ps -a
```

Podman 시작 전에 host의 `/etc/resolv.conf`가 존재하는지도 확인하세요.

## 9. 알려진 문제

### `init-secrets` 산출물이 없을 때

다음 파일이 없으면 전체 stack을 내린 뒤 `init-secrets`를 먼저 실행하세요.

```bash
ls -l secrets/secrets.env nginx/certs/server.crt nginx/certs/server.key
```

폐쇄망 환경:

```bash
podman compose --env-file .env -f compose.podman.init-secrets.yml run --rm init-secrets

podman compose --env-file .env -f compose.podman.yml up -d --no-build
```

`compose.podman.init-secrets.yml`은 네트워크가 필요 없는 일회성 컨테이너이므로
`network_mode: none`으로 실행합니다. 그래도 사용 중인 `podman-compose`가 네트워크를
만들려고 하며 실패하면 아래 fallback으로 산출물만 먼저 생성할 수 있습니다.

```bash
podman run --network none --rm --env-file .env \
  -v "$PWD/secrets:/secrets:z" \
  -v "$PWD/nginx/certs:/certs:z" \
  localhost/lucy-teamcloud-onprem-init-secrets:offline
```

### `netavark`, `ip_tables`, `iptables nat` 오류

다음 오류는 이미지 로드 문제가 아니라 host Podman 네트워크 준비 문제입니다.

```text
netavark: code: 3, msg: modprobe: ERROR: could not insert 'ip_tables': Operation not permitted
iptables: can't initialize iptables table `nat'
```

`init-secrets`는 네트워크 없이 실행되도록 분리되어 있습니다. 전체 stack 실행에서 같은
오류가 나면 실제 서비스 네트워크를 만들 수 없는 상태이므로 운영자가 host kernel
module, iptables/nftables, rootless Podman 네트워크 정책을 확인해야 합니다.

```bash
podman info | grep -i network -A20
lsmod | grep -E 'ip_tables|iptable_nat|nf_nat|br_netfilter'
```

권한 있는 운영자가 host에서 필요한 module을 준비해야 할 수 있습니다.

```bash
sudo modprobe ip_tables
sudo modprobe iptable_nat
sudo modprobe nf_nat
sudo modprobe br_netfilter
```

`modprobe`가 보안 정책으로 막힌 VM이면 애플리케이션 설정으로 해결할 수 없습니다. VM
이미지, kernel module 정책, Podman/netavark 설치 상태를 먼저 맞추세요.

### `db`, `tc-fe` 같은 service name을 찾지 못할 때

`auth-be`가 `db:5432`에 접속하지 못하거나 `gw`가 `tc-fe:80`을 찾지 못하면 앱보다
Podman network DNS를 먼저 확인하세요.

```bash
podman info | grep -i network -A10
podman network ls
podman network inspect lucy-teamcloud-onprem_internal-network | grep -i dns
```

정상 기대값은 `networkBackend: netavark`와 `dns_enabled: true`입니다. `cni` backend,
`dns_enabled=false`, stale `aardvark-dns` 상태는 host Podman 설정 문제입니다.
운영자는 `netavark`, `aardvark-dns` 설치와 `/etc/containers/containers.conf`의
network backend 설정을 확인하고, 기존 네트워크를 삭제 후 재생성해야 합니다.

```bash
podman compose --env-file .env -f compose.podman.yml down
podman network rm lucy-teamcloud-onprem_internal-network
podman network create --disable-dns=false lucy-teamcloud-onprem_internal-network
```

### `aardvark-dns runs in a different netns`

이 메시지는 이전 rootless Podman 세션의 runtime state가 남았거나
`/run/user/<uid>/netns`가 정리된 상태에서 발생할 수 있습니다. 데이터 볼륨을 지우지
말고 runtime state를 정리한 뒤 네트워크를 재생성하세요.

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
podman compose --env-file .env -f compose.podman.yml down || true
podman rm -f $(podman ps -aq --filter name=lucy-teamcloud-onprem) 2>/dev/null || true
pkill -u $(id -u) aardvark-dns || true
podman system renumber
podman ps -a --sync
```

### SSH 세션 종료 후 컨테이너가 내려갈 때

rootless Podman을 SSH 세션에서 직접 실행하면 보안 정책이나 logind 설정에 따라
`/run/user/<uid>`가 정리되면서 컨테이너가 종료될 수 있습니다.

```bash
loginctl show-user $(whoami) -p Linger -p RuntimePath -p State
```

장기 운영 계정은 직접 SSH 로그인 계정이어야 하며, `su - <user>`로 들어간 shell에서
rootless Podman을 장기 운영하지 마세요. 운영 정책상 가능하다면 linger를 활성화하고
systemd user service로 관리하세요.

```bash
sudo loginctl enable-linger $(whoami)
```

보안 정책상 linger가 불가하면 Docker 또는 rootful Podman system service 운영을
검토하세요.

### `/etc/resolv.conf`가 없을 때

다음 오류는 애플리케이션 문제가 아니라 host OS 준비 문제입니다.

```text
failed to stat resolv.conf path: lstat /etc/resolv.conf: no such file or directory
```

운영자는 host에 `/etc/resolv.conf`를 준비해야 합니다.

```bash
sudo sh -c 'printf "nameserver <INTERNAL_DNS_IP>\n" > /etc/resolv.conf'
sudo chmod 644 /etc/resolv.conf
```

### privileged port 또는 unsafe port 문제

rootless Podman은 기본적으로 host의 80/443 같은 privileged port를 publish할 수
없습니다. `compose.podman.yml`은 기본값으로 `18080:80`, `18443:443`을 사용합니다.
포트를 바꾸면 `.env`의 URL도 같은 port로 맞추세요.

Chrome은 일부 port를 `ERR_UNSAFE_PORT`로 차단합니다. 예를 들어 `10080` 대신
`18080`처럼 브라우저가 허용하는 port를 사용하세요.

### 컨테이너 내부 80 bind 권한

`auth-be`, `tc-be`는 Podman 환경에서 내부 port 80 bind 권한 문제를 피하기 위해
`user: "0:0"`으로 실행합니다. `git`은 내부 `18080`을 사용합니다. 이 설정을 임의로
제거하면 `listen EACCES: permission denied 0.0.0.0:80` 오류가 날 수 있습니다.

### bind mount 권한과 SELinux

`compose.podman.yml`은 bind mount에 `:z`를 포함하지만, 이는 SELinux label 처리입니다.
파일 소유권 문제까지 모두 해결하는 것은 아닙니다. `postgres/data`, `git/data`,
`broker/data`, `broker/logs`에서 permission denied가 발생하면 컨테이너 로그를 먼저
확인하고, 필요 시 `podman unshare chown`으로 해당 이미지의 실행 UID/GID에 맞추세요.
임의의 host `chown -R`은 user namespace와 충돌할 수 있습니다.

### `podman-compose ps -q <service>` 미지원

일부 `podman-compose` 버전은 Docker Compose처럼 `ps -q db` 형식을 지원하지 않습니다.
디버깅할 때는 compose 로그와 `podman ps --filter name=...`를 사용하세요.

### port env interpolation

일부 `podman-compose` 버전은 `ports` 항목에서 `${HTTP_PORT}` 같은 env interpolation을
제대로 처리하지 못합니다. 이 repo는 port env를 사용하지 않고
`compose.podman.yml`에 고정 port를 둡니다. 포트를 변경하려면 compose 파일의
`ports`와 `.env` URL을 함께 수정하세요.

### 브라우저 캐시와 OIDC code 만료

서버는 새 버전인데 브라우저가 이전 화면을 계속 보여주거나 로그인 중
`invalid_grant`, `authorization code expired`가 발생하면 브라우저 캐시 또는
service worker를 삭제하세요.

```text
Chrome DevTools -> Application -> Service Workers -> Unregister
Chrome DevTools -> Application -> Storage -> Clear site data
```

### `postgres/initdb` permission denied

다음 오류는 host 파일 권한 또는 SELinux label 문제입니다.

```text
ls: cannot open directory '/docker-entrypoint-initdb.d/': Permission denied
```

운영자는 initdb 파일이 컨테이너에서 읽히도록 권한을 맞춰야 합니다.

```bash
chmod 755 postgres postgres/initdb
chmod 644 postgres/initdb/*
```

SELinux Enforcing 환경에서는 label도 확인하세요.

```bash
sudo chcon -Rt container_file_t postgres/initdb postgres/data
```

### gateway port mapping

gateway nginx는 컨테이너 내부에서 80/443을 listen합니다. host port를 바꿀 때도
오른쪽 컨테이너 port는 유지하세요.

```yaml
services:
  gw:
    ports:
      - "18080:80"
      - "18443:443"
```
