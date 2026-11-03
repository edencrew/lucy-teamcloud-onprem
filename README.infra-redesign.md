# 온프렘 인프라 재설계 — 구현·검증 기록

상태: 오프라인 결합 검증 통과, 미출시, 실제 Linux 수용 대기. 전체 Goal acceptance는 끝나지 않았습니다.
승인된 task/Go 개발 원본 반영 여부와 검증 시각은 실행 작업자의 port-followup-integration.json에 기록합니다.
실행 작업자 소유 범위는 candidate 구현, 오프라인 검증, 전제조건을 확인한 task/Go 반영입니다.
부모가 최종 acceptance·통합·Wiki 연속성 기록을 소유합니다. 고객 서버·VM·실제 엔진 작업은 실행하지 않았습니다.

## 1. 작업 공간과 보존 기준

- Git task: `installer-target-contract`, base/HEAD `b37b46a77c5ef2f0054ee75f443a185837e9a6e2`.
- onprem main의 기존 Modified 8 + Untracked 2는 candidate 출발점으로 수입했습니다.
  `.gitignore`, `README.docker.md`, `README.md`, `README.podman.md`,
  `dev/studio-dist-local/README.md`, `dmz/README.docker.md`, `dmz/README.md`, `dmz/README.podman.md`,
  `README.installer.md`, `scripts/package-offline-installer.sh`입니다.
- candidate 작업 중에는 main 원본을 수정하지 않았고, 이후 미출시 소스의 로컬 main 통합이 승인됐습니다. DMZ/dev 문서는 수입한 baseline과 동일하게 유지했습니다.
- Go 기존 TARGET 확정·strict receipt·runtime identity와 A2 후보를 보존했습니다.
- 공개 Version·dist·Release는 바꾸지 않았습니다. 새 capability 선언과 실행 파일 SHA로 빌드를 구분합니다.
- `before/`, `pre-stage2/`, 각 분리 후보와 결과·로그는 Go `.work/infra-redesign-20261030.Qc9jrT/`에 보존합니다.

## 2. 채택 설계와 구현

| 요구 | 구현/선택 이유 |
|---|---|
| A4/B1 | ROOT·project·데이터 경로를 고정하고 `releases/<version>/payload`와 일반 파일 `state/active-release`를 사용합니다. |
| base/local | ROOT `.env` + 자원 설정 전용 `local/compose.local.yml`; 이미지·토폴로지·템플릿은 제품 base 소유입니다. |
| 호출 계약 | 명시적 runtime/provider, `-p`, `--project-directory`, `--env-file`, base 다음 local 순서입니다. |
| staging | manifest/hash/arch/image config digest 검증 → stage → load → plan → 명시적 apply. up 실패는 이전 포인터와 failed 상태를 보존합니다. |
| 백업 경계 | apply는 project/from/to/receipt hash와 실제 백업 파일 SHA에 묶인 acknowledgement를 요구합니다. DB 복원 검증은 별도입니다. |
| 신원 | strict `teamcloud-installer-receipt.json`만 정본입니다. 경쟁하는 `state/identity`는 사용하지 않습니다. |
| 환경 | 기록된 신원에서 process-local runtime 환경을 구성하고 Compose/runtime 관련 상속 변수를 제거합니다. 매 로그인 export·profile 수정은 없습니다. |
| A3 | format 2 최초 TUI가 ProductInstall로 연결됩니다. root 실행·기존 ROOT·지원하지 않는 키트를 거부합니다. |
| lifecycle | 관리자 linger/선택 포트 준비는 출력만 합니다. 설치 승인 후 user socket을 먼저 활성화하고 ROOT controller/provider와 user unit을 설치·기동합니다. |
| systemd | Compose 의존 그래프를 유지하려고 user oneshot/RemainAfterExit unit을 선택했습니다. linger 자체를 로그아웃/재부팅 증거로 간주하지 않습니다. |
| Docker | `compose.docker.init-secrets.yml` bootstrap을 base에서 분리했습니다. 업데이트/up/stop에는 init이 없습니다. |
| kit/pack | allowlist와 exact ref/version/commit/image-set을 검증합니다. format 2는 내부 제품 패키지 경로·SHA와 바이너리 capability 선언을 검사합니다. |
| B2 | `TC_PROTOCOL=http|https`, host ports, URL/ws/wss를 함께 검증하고 제품 소유 nginx 템플릿을 고릅니다. 기존 기본 TLS 동작을 유지합니다. |
| A2 | rune cursor, Home/End/Delete/Backspace, 가로 창, 비밀번호 마스킹, Enter 검증/다음 필드와 Esc 취소를 보존했습니다. |
| A1 | 서비스별 경로·UID 정책, local rootless Podman unshare backup/restore/log quarantine을 제공합니다. blind chown/전 서비스 keep-id는 없습니다. |
| B3 | 제한된 label/state/mount 인벤토리와 텍스트 migration plan만 제공합니다. 자동 채택·receipt 생성·데이터 이동은 없습니다. |

A1은 canonical project/신원·중지·경로를 검사하고 기본 dry-run + 정확한 확인 문구를 요구합니다.
백업 출력은 독점 생성된 fd에 스트리밍합니다. 복원은 원본을 두 번 검사하고 검증한 항목만 새 tar로 정규화합니다.
UID/GID·일반 권한·수정 시각만 복원하며 ACL/xattr/SELinux 라벨은 복원하지 않습니다.
링크·장치·FIFO·sparse·중복·경로 이탈은 거부합니다. named `studio-release`는 별도 백업 대상으로 구분하고 현재 helper에서는 거부합니다.
대상 계정 자체가 경로 구성요소를 동시에 바꾸는 openat 경쟁까지 해결한 구현은 아닙니다.

공식 근거: [Compose merge](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/),
[Podman 5.6 unshare](https://docs.podman.io/en/v5.6.0/markdown/podman-unshare.1.html),
[systemd command lines](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Command%20lines).
이 문서의 코드/fixture 증거는 실제 Podman·systemd의 동작 증거와 구분합니다.

## 3. 변경과 관찰된 검증

- Go: ops/manifest/lifecycle/product_install/namespace/inventory와 테스트, main/installer/receipt 연결, TUI 및 TARGET 회귀.
- onprem: Docker/Podman Compose, Docker bootstrap, HTTP 템플릿, env 예시, 두 packager와 fixture, runtime 문서·ignore.
- 기존 stage1은 7/8 테스트 이후 missing packaging test로 실패한 이력이 있습니다. 이를 완료로 취급하지 않습니다.
- 개별 packaging format 2 fixture 및 구 바이너리 거부 fixture는 관찰된 테스트가 통과했습니다.
- ProductInstall fake happy path: receipt/env/local/ctl/provider/unit, socket→load→init 순서, init 1회,
  원본 KIT 삭제 후 Up/Stop, 중복 설치 거부, linger 누락 시 쓰기 전 거부가 통과했습니다.
- tar 보강 wrapper 1회 실패는 작업자가 잘못 지정한 TC_TEST_SOURCE 때문이었습니다.
  보존된 실제 fixture 경로로 환경만 교정한 전체 Go 재실행은 exit 0이었습니다. 원 실패 기록도 남겼습니다.
- 최종 통합 검증의 실제 명령·시각·exit/log는 외부 `verification-results.json`과 `verification-logs/`를 정본으로 봅니다.
  첫 통합에서 split init count 가정이 실패했고, 교정 2회 후에도 Docker gw published ports가
  기대 18080/18443 대신 80/443인 검사 1개가 남아 당시 추가 교정을 중단했고 full suite는 FAIL이었습니다.
- 포트 후속에서 legacy RenderDotenv를 사용한 test helper가 TC 포트 키를 누락한 것으로 분리했습니다.
  실제 현대 env 생성 경로로 테스트를 연결한 뒤 current-source 전체 suite, 양 runtime/protocol 포트8-case,
  legacy 회귀와 packaging fixture를 포함한 14개 검사가 통과했습니다. 현장 포트 결함 해결로 확대하지 않습니다.
- 임시 native/Linux 빌드·demo/PTy는 공개 dist 교체나 Linux 실행·설치 증거가 아닙니다.

독립 최종 검증 11개(포맷/vet, Bash 문법5, native/Linux 빌드2, ops version, packaging fixture)는 통과했습니다.
Mac PTY demo의 한글 cursor 편집·Enter 이동·Esc 취소·정상 종료도 확인했습니다.
이 성공들은 위 full-suite 실패를 해소하거나 실제 Linux 설치를 증명하지 않습니다.

candidate의 before 대비 증분(stage1/A2 승계 포함):

- `onprem/.env.example`
- `onprem/.gitignore`
- `onprem/README.docker.md`
- `onprem/README.infra-redesign.md`
- `onprem/README.installer.md`
- `onprem/README.md`
- `onprem/README.podman.md`
- `onprem/compose.docker.init-secrets.yml`
- `onprem/compose.docker.yml`
- `onprem/compose.podman.yml`
- `onprem/nginx/nginx.http.conf`
- `onprem/scripts/package-offline-installer.sh`
- `onprem/scripts/package-update.sh`
- `onprem/tests/test-infra-package.sh`
- `installer/docker.go`
- `installer/installer.go`
- `installer/integration_test.go`
- `installer/inventory.go`
- `installer/inventory_test.go`
- `installer/lifecycle.go`
- `installer/lifecycle_test.go`
- `installer/main.go`
- `installer/manifest.go`
- `installer/manifest_test.go`
- `installer/namespace.go`
- `installer/namespace_test.go`
- `installer/ops.go`
- `installer/ops_test.go`
- `installer/product_install.go`
- `installer/product_install_test.go`
- `installer/receipt.go`
- `installer/target_contract_test.go`
- `installer/tui.go`
- `installer/tui_test.go`

### 3.x Rootless 영속 데이터 소유권 (일부 Linux 검증, 미통합)

- 정책(Podman compose 만, Docker compose 불변): 데이터를 쓰는 비 root 이미지 사용자에 호스트 설치 계정을 `userns_mode: keep-id:uid=N,gid=N` 으로 매핑하고 `user` 를 같은 숫자로 고정한다. TC `db`·Devora `postgres` 999(initdb 부터 root 미경유), `broker` 1883, `git` 은 `keep-id:uid=${HOST_UID},gid=${HOST_GID}` + `user: "0:0"`(stock entrypoint 가 root 로 git 사용자를 USER_UID 로 맞춘 뒤 내려감).
- `git/gitea-entrypoint.sh` 는 `/data/gitea`, `conf`, `app.ini`, `.admin-created` 를 숫자 `USER_UID:USER_GID` 로 생성한다(새로 만든 디렉터리만 chown, 파일은 `su-exec`; 재귀 chown 없음). 숫자가 아니면 데이터 생성 전에 실패한다. Docker 는 같은 기본값(1000)으로 동일하게 동작한다.
- Devora media 의 SQL/docs 읽기 전용 mount 에 SELinux `:ro,Z` 를 붙였다. 0777, label 비활성화, privileged, 전역 설정은 쓰지 않는다.
- tc-be/Studio: `keep-id:uid=1001,gid=1001` + `user: "1001:1001"`. 근거는 고정 이미지 아카이브의 source 증거(실행 아님): config `User=appuser`, rootfs `/etc/passwd` appuser 1001:1001, `/data/studio-releases` 1001:1001 0755, `app/entrypoint.sh`(0 소유 0755)는 `prisma migrate deploy` 후 `exec node` 만 하고 chown/chmod/su-exec·root 요구가 없다. `tc/tc-entrypoint.sh` 도 secrets export → `exec ./entrypoint.sh` 뿐이다. 그래서 logs·Studio 쓰기는 호스트 설치 계정 소유, 호스트 계정 소유 secret/cert/license 는 컨테이너에서 1001 로 읽힌다. 이미지·BE 코드·기존 볼륨 소유권은 바꾸지 않았다. 이전 `user: "0:0"` 으로 만든 기존 `studio-release` 볼륨 루트(이전 매핑의 subordinate 1001)는 새 매핑에서 1001 이 아니므로 아래 이전 절차 대상이다(자동 chown 없음).
- 일반 규칙: 비 root 이미지 사용자의 숫자 UID/GID 는 이미지 config `User` 와 rootfs `/etc/passwd`·데이터 디렉터리 소유·entrypoint 의 root 요구 여부로 증명한 뒤에만 keep-id 로 매핑한다.
- 기본 rootless userns 유지: `studio-dl`(읽기 전용 서빙), Devora `redis`(고정 config 기본 root, entrypoint setuid 없음), Devora `api`(고정 config `User`/`Entrypoint` null, `Cmd` granian). 비 root 를 강제하거나 보안을 약화하지 않는다. 실제 API 가 생성하는 AI 데이터 소유권은 미검증이다.
- 공식 문서 근거: Podman v5.6.0 `podman run --userns=keep-id` 의 `uid=`/`gid=` 는 현재 사용자를 컨테이너 안 지정 UID/GID 로 매핑한다(https://docs.podman.io/en/v5.6.0/markdown/podman-run.1.html). Compose spec services 페이지(https://compose-spec.github.io/compose-spec/05-services.html)는 `userns_mode`·서비스 `user` 정의를 별도 Container/Workload spec 으로 넘겨 그 페이지에서는 확인되지 않았다. Compose→Podman 호환 API 전달은 아래 Podman 5.8.2 시험 범위에서 확인했으며, 5.6.0의 실제 엔진 검증은 남아 있다.
- 설치기(Go, 읽기 전용 확인·변경 없음): `config.go:80` allowlist 가 `compose.podman.yml` 을 그대로 payload 로 복사하므로 `userns_mode`/`user` 는 재생성 없이 보존된다. `namespace.go:136-147` 의 서비스 UID 는 고정 숫자가 아니라 `image-specific/unknown` 이고, 백업은 namespace 안 `tar --numeric-owner`, 복원은 `podman unshare chown +UID:+GID`(`namespace.go:800`) 다. `podman unshare` 는 keep-id 가 아닌 기본 매핑(호스트 계정 = 0)으로 보므로 keep-id 데이터는 아카이브에 0 으로 기록·복원된다. 같은 ROOT·같은 매핑 안의 왕복은 일관되지만, 매핑을 바꾸는 이전에는 그대로 쓸 수 없다. 이전은 이 live-install 작업 범위 밖이며 backup/restore 정책 변경은 담당자 결정으로 보류한다.
- 설치기 전달·ROOT source 추적(실행 증거 아님): ops 경로는 `ops.go`의 `composeArgv`로 `--project-directory ROOT`와 릴리스 payload Compose를 직접 사용하고, `config --format json` 결과는 검증만 한다. legacy 경로는 `runtime.go` → `docker.go:TransformComposeSpec`의 `map[string]any`를 저장하며 build/pull policy·포트·init restart 등의 한정 변환에 `userns_mode`/`user` 삭제는 없다. local override allowlist에도 두 키가 없어 변경 시 거부한다. TC bind는 ROOT 기준, 제품 설정은 `TC_PAYLOAD_DIR` 기준이며 Devora는 `ROOT/devora/{devora.env,media}`로 전달된다(`devora.go`). named volume과 image storage 위치는 ROOT와 별도로 Podman GraphRoot를 따른다. 외부 CA 등 운영자가 명시한 별도 경로는 별도 입력 계약이며 현재 소스에 고정된 Devora CA mount는 없다. 실제 생성 JSON·엔진 inspect와 비기본 ROOT의 실행 수용은 별도다.
- 기존 데이터 이전 절차(자동화 없음, 명시 승인 시에만): ① 해당 서비스를 정지한다(`--root <ROOT> --runtime podman` 명시). ② 기존 UID/GID 매핑 fingerprint 를 기록한다(`podman unshare cat /proc/self/uid_map`, `/etc/subuid`·`/etc/subgid` 해당 계정 줄, 서비스별 `podman unshare stat -c '%u:%g'` 결과, 사용 중인 compose 사본의 hash). ③ 정지 상태에서 bind 데이터와 named volume 을 숫자 소유자·권한·mtime 메타데이터와 함께 일관 백업하고 기존 compose/매핑 사본을 보존한다. ④ 운영자가 서비스별 대상 디렉터리만 범위로 승인한 이전을 수행한다(blind/전체 재귀 chown 금지). ⑤ rootless+SELinux Enforcing 에서 기동·쓰기·재시작 후 소유권을 네이티브로 검증한다. ⑥ 실패 시 보존한 이전 compose/매핑과 백업 데이터로 되돌린다. 서비스가 쓰기나 스키마 migration 을 한 뒤에는 자동 rollback 하지 않는다. named volume 객체 제거는 Podman CLI(`podman volume rm`)로만 하고 GraphRoot 메타데이터를 직접 지우지 않는다. 고객 식별자·IP·secret 은 이 문서와 Git 에 기록하지 않는다.
- 검증 도구: `tests/test-rootless-data-ownership.sh`는 Compose의 userns/user/mount·HOST_UID 전파와 래퍼를 렌더/모의 검사한다. `tests/test-devora.sh`는 별도 Devora 회귀 검사다. 실제 서비스 검증 범위는 아래와 같으며, tc-be 기동·migration·Studio 업로드와 기존 볼륨 이전은 포함하지 않는다. 기존 producer allowlist가 변경 런타임 파일을 포함하지만 새 제품 kit는 아직 없다.

- 2026-11-03 실제 격리 Linux 결과: Rocky 9.8 / Podman 5.8.2, rootless·SELinux Enforcing, UID와 GID가 다른 일반 계정 및 비기본 ROOT에서 TC PG17·Broker·Devora PG16/Redis의 실제 생성 파일을 검사했다. 정상 중지 뒤 일반 셸의 하위 조회·복사본 생성/수정/삭제(원본 불변, sudo/unshare 없음), recreate 뒤 DB 트랜잭션·MQTT retained 값·Redis 값 보존이 통과했다. 시험은 TC PG → Broker → Devora PG/Redis phase와 별도 PG/Gitea pair 범위이며 전체 stack 동시 기동은 하지 않았다.
- Studio는 source-configured tc-be 이미지의 Node 쓰기 probe로 named volume의 실제 host 소유권과 native CRUD만 확인했다. 실제 tc-be 기동·migration·Studio 업로드/API, Devora API가 생성한 AI 데이터, 실제 Docker 엔진 회귀 및 RHEL 9 / Podman 5.6은 미검증이다. Docker Compose 원문 불변·렌더/공유 wrapper 모의 회귀는 실제 Docker 수용과 구분한다.
- Gitea 실패 이력은 보존했다. 첫 구간에서는 디렉터리와 SSH host key 6개가 subordinate 소유로 남았다. 추가 구간에서는 고정 이미지의 stock SSH setup이 key를 무조건 `root:root`로 바꾸는 것을 확인했다. 이를 보정한 첫 실제 시도는 계정 등록 전 `ssh-keygen`의 `getpwuid` 요구로 실패했다(`No user exists for uid …`). 모의 검사의 glob 인자 순서 단언 오류도 따로 기록했으며, 실패 트리는 chown/삭제하지 않았다.
- 현재 Gitea 소스: Podman만 `TC_GITEA_SSH_KEY_OWNER=data`를 설정한다. 래퍼는 stock SSH setup의 알려진 계약을 확인하고 컨테이너의 비영속 레이어에서 데이터 소유 key의 root 재chown만 건너뛴다. 없는 key는 보호된 `/tmp` 디렉터리에서 생성한 뒤 `USER_UID:USER_GID`가 noclobber로 새 영속 파일을 쓴다. 임시 정리는 생성한 여섯 파일로 제한한다. SSH 디렉터리 0700·key 0600과 root sshd는 유지하며, 미지 계약·생성 실패·개인키 없는 기존 공개키는 시작을 거부한다. 기존 key의 자동 소유권 이전은 하지 않는다. Docker는 이 정책을 켜지 않아 stock SSH setup을 그대로 쓴다.
- Gitea 실제 검증(2026-11-03 08:08:58–08:09:37 UTC): 고정 Gitea 1.25.3/linux-amd64 이미지로 Rocky 9.8·Podman 5.8.2 rootless·SELinux Enforcing에서 health, 관리자 생성, REST 저장소 생성이 통과했다. UID/GID가 다른 호스트 실행 계정 소유로 key 6개와 전체 데이터가 생성됐고, 재귀 검사 146항목에서 다른 소유자가 없었다. 실제 Git SSH `ls-remote`는 고정 known_hosts와 등록한 테스트 키로 통과했다.
- 같은 시험에서 정상 중지 뒤 일반 계정의 복사본 조회·수정·삭제가 통과했다. 컨테이너 recreate 뒤 저장소 HEAD, key 6개의 내용·권한·소유자와 SSH fingerprint가 유지됐고 실제 Git SSH 조회도 다시 통과했다. 마지막 정상 중지 후 링크·중첩 mount 없음과 정확한 대상을 확인하고 새 시험용 `<ROOT>/git/data` 한 곳 전체를 일반 `rm -r`로 삭제했다. sudo/unshare·volume 객체 삭제·엔진 metadata 삭제는 사용하지 않았다. 이는 승인된 새 폐기용 데이터 검사이며 기존 데이터 이행이 아니다.
- 회귀 검사: `tests/test-rootless-data-ownership.sh`는 stock setup의 정책 off/on, 멱등성, 미지 계약, 기존 key 보존, getpwuid 전제와 keygen 실패를 검사했다. Docker Compose 원문 불변과 정책 off의 stock SSH 동작은 모의 검사 범위이며 실제 Docker 엔진 수용은 아니다.
- 최종 범위는 미통합 source 후보와 위 Linux 서비스 증거다. 새 제품 kit는 없고 진단용 이미지 subset·source 시험 tar만 남겼다. 기존 producer/manifest fixture 통과는 최종 후보의 공식 kit 제작·설치 수용을 뜻하지 않는다. 시험 컨테이너는 정상 중지했고, 기존 실패 데이터·named volume·VM은 보존했다. 삭제 범위는 위 새 폐기용 Gitea bind 데이터 한 곳뿐이다. 위 backup/restore 매핑 설명은 source 추적이며 실제 복원 수용이 아니다.

## 4. Linux/RHEL acceptance 갭

다음 항목은 전부 실제 엔진/VM/RHEL에서 미검증입니다.

| 항목 | 남은 검증 |
|---|---|
| manifest/no-pull/no-build | Podman 5.6/Docker 실제 image ID·digest·플랫폼, load 실패 후 기존 실행 유지 |
| 설정/secret/볼륨 | 실제 반복 업데이트 보존, named studio-release 백업·복원, 서비스 추가/삭제 |
| DB rollback | migration 전 백업과 실제 복원 리허설, migration 후 자동 rollback 금지 확인 |
| UID/unshare | 이미지별 실제 UID/GID, subuid 매핑, SELinux/NFS/ACL/xattr 정책과 복원 범위 |
| 세션 | SSH 로그아웃 후 유지와 재부팅 자동 기동; linger와 unit 파일만으로 PASS하지 않음 |
| 네트워크 | firewalld active 상태 선택 포트, TLS 로그인·MQTT wss, HTTP/HTTPS 실제 전환 |
| v0.0.22 | 기존 이중 중첩 경로·구 project·데이터·비밀값·named volume 보존 adoption 리허설 |
| TUI | Mac demo/PTy와 단위 입력 검증 외 실제 RHEL 터미널·현장 INSTALL acceptance |

## 5. 교보 운영자 체크리스트 초안 — 전부 미실행

기존 경로 이동과 HTTP 전환은 보류합니다. 아래는 별도 현장 작업에 앞선 검토용이며 이번 작업에서 실행하지 않았습니다.

1. 기존 BASE/project/운영 계정/GraphRoot/소켓과 기존 JSON을 보존합니다.
   `teamcloud-installer ops inventory show --root <현재_BASE> --runtime podman --project lucy-teamcloud-onprem`
   와 `ops inventory plan` 결과에서 실제 서비스·mount·named volume을 확인합니다. 9개 수를 새 acceptance로 고정하지 않습니다.
2. 관리자에게 `ops admin-prep --account platform --ports 18080,18443 --firewalld` 출력의 필요 항목만 검토받습니다.
   `loginctl show-user platform -p Linger -p State -p RuntimePath`와 실제 firewalld zone/선택 포트를 확인합니다.
   firewalld를 끄거나 전역 KillUserProcesses를 바꾸지 않습니다.
3. 프로젝트 중지와 DB/git/broker/license/certs/secrets/config 백업, named studio-release 별도 백업·복원 리허설을 준비합니다.
   A1 명령은 먼저 확인 문구 없는 dry-run으로 검토하고, restore의 메타데이터 보존 범위를 확인합니다.
4. v0.0.22는 현재 자동 채택 대상이 아닙니다. 인벤토리·DB/서비스 차이·백업 검증 후 별도 migration 계획을 승인받습니다.
5. 새 format 2 ROOT에서만 `bin/teamcloudctl verify → stage → load → plan → apply`를 사용합니다.
   각 명령에 `--root <ROOT> --runtime podman`, package/release/backup-ack 등 해당 인자를 명시합니다.
   apply 전 migration 경계와 acknowledgement를 확인합니다. 실패 시 자동 재초기화·데이터 이동·rollback하지 않습니다.
6. `systemctl --user is-active teamcloud.service`, 실제 project 컨테이너 상태, HTTP health/login/MQTT,
   SSH logout/reboot를 각각 검증합니다. `ops status`는 아래 읽기 전용 관찰만 하므로 전체 수용 증거로 쓰지 않습니다.
7. `bin/teamcloudctl status --root <ROOT> --runtime podman [--compose-binary PATH]`(Compose 기본값은 ROOT provider)는
   쓰기·시작·중지·repair·rollback 없이 다음을 각각 표시합니다: 기존 `active-release`/`pending-apply` 줄, 관찰 시각,
   strict receipt/runtime identity(새 로그인에서도 process-local 환경만 사용, 불일치·receipt 없는 레거시는 FAILED 후 런타임 조회 안 함),
   active release 재검증, 검증된 base+local 구성의 기대 서비스(init-secrets 제외)별 `running=`/`health=`
   (project label과 ROOT working_dir가 같은 컨테이너만 계산; 누락·exited/stopped/restarting은 FAILED,
   starting·healthcheck 미정의·조회 실패/timeout/잘못된 JSON은 UNKNOWN), 그리고 `.env`에서 도출한
   `127.0.0.1:<게시 포트>`로의 `GET /health` 1회(SNI/Host=EXTERNAL_URL 호스트, TLS 검증 유지, redirect 미추종,
   2xx만 OK, 그 외 응답 FAILED, 접속 불가·timeout·인증서 검증 실패는 UNKNOWN). 마지막 `unverified:` 줄의
   로그인/MQTT/SSH logout/reboot/host 수용은 확인하지 않습니다. 결과 줄과 exit: `result: OBSERVED-OK` 0,
   `result: FAILED` 1(포인터 없음·pending/failed apply 포함, 자동 rollback 없음), `result: UNKNOWN` 3, 사용법 오류 2.
   허용 명령은 runtime `info`/`ps -a -q --filter label=…`/`inspect --format <id·label·state·health 요약>`과
   Compose `config --format json`뿐이며 명령별 시간·출력 상한이 있고 명령 출력/오류 본문·env·mount·log는 출력하지 않습니다.
   기본 조회 제한은 명령별 15초, stdout 1MiB, 버리는 stderr 64KiB입니다. 취소는 status가 직접 시작한
   조회 명령만 대상으로 하며 daemon/운영 컨테이너에는 신호를 보내지 않습니다. 별도 자식 프로세스 전체를 관리한다고 보장하지 않고,
   상속된 출력 pipe 대기는 500ms로 제한합니다.

## 6. 남은 작업·결정·보존

포트 후속 검증은 완료했습니다. 원인은 이 재현의 test helper가 legacy env serializer를 사용한 것이며,
검사한 현대 최초설치 경로는 포트 설정을 보존했습니다. 최신 근거는 port-followup-report.md에 보존합니다.
아래 실제 Linux 수용과 전체 Goal의 남은 범위는 그대로입니다.

- `ops status`는 pointer-only에서 위 5절 7항의 한정 읽기 전용 관찰(서비스·health·로컬 gateway)로 보완했습니다(fake/loopback 및 Mac Docker Desktop의 작은 실제 HTTP lab 네 상태 확인; RHEL/rootless Podman/전체 TeamCloud 수용 미검증).
  실제 Linux/RHEL 런타임에서의 출력 확인과 로그인/MQTT/SSH logout/reboot 수용은 여전히 남아 있습니다.
- 실제 Linux/RHEL, DB 복원·named volume helper·SELinux/NFS/메타데이터 정책 acceptance가 남아 있습니다.
- Docker apply의 추가 positive 통합 fixture와 public TUI 전체 modern Preflight/Apply 자동화 범위는 남은 검증입니다.
- 새 실제 kit는 변경된 정확한 source commit와 미릴리스 installer 빌드가 필요합니다. 현재 작업은 commit/Release 권한을 포함하지 않습니다.
- 구 바이너리 marker 검사는 capability 선언과 해시 검사이며 실행 동작이나 attestation 증거가 아닙니다.
- orphan 제거 정책과 기존 v0.0.22 채택/경로 이동/HTTP 전환은 별도 범위입니다. 자동 수행하지 않았습니다.
- 전체 Goal을 완료로 인계하지 않습니다. 부모가 현재 검증 로그·diff를 확인하고 다음 Linux 검증 범위를 정합니다.
- active task checkout과 모든 분리 후보/산출물을 보존합니다. 정리 inventory는 외부 `execution-cleanup-inventory.md`이며,
  통합 담당자가 accepted integration·writer release·tracked/untracked/ignored 보존을 확인하기 전 삭제하지 않습니다.
