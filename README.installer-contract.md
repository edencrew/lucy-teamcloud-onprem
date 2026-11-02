# 설치기 경로 확정과 설치본 식별 — 변경 범위와 검증 기준

이 문서는 다음 설치기 릴리스를 준비하는 개발자용 기록입니다. 경로 확정과 설치 기록 기능을 구현해 로컬 main에 통합한 미출시 개발 상태입니다. 설치기 버전과 공개 Release는 바꾸지 않았습니다. 고객 설치 절차나 현장 복구 지침을 대신하지 않습니다.

## 근거의 범위 (정정)

- 저장소/제품 차원의 재발 방지 작업입니다. 고객 핫픽스나 장애 복구가 아닙니다.
- v0.0.22 는 기본값으로 형제 디렉터리 `teamcloud-runtime` 을 TARGET 으로 제안하고, TUI 편집은 Enter 로 확정·Esc 로 취소합니다. 운영자는 Enter 로 의도한 `/lucy/teamcloud` 를 확정했는지 기억하지 못합니다. 확인된 것은 `<kit>/teamcloud-runtime/compose.installer.json` 하나뿐입니다. 최종 화면, 설치 기록, mount 라벨, 현장 kit 의 정확한 해시는 **수집되지 않았거나 확인되지 않았습니다**(존재하지 않는다는 뜻이 아닙니다). 원인은 **unknown** 이며, "Enter 가 무시되는 버그"로 입증된 것이 아닙니다. 원인이 unknown 이라는 것은 증거가 없다는 뜻이 아닙니다.
- SSH 종료 뒤 서비스가 중단됐다는 보고와 컨테이너 정지 상태는 있습니다. 다만 실제 종료 시각과 linger 변경 전후를 대조하지 못했으므로 세션 종료가 원인인지는 미확정입니다. 이번 변경으로 해결됐다고 판단하지 않습니다.

## 마일스톤 1 요구사항 (구현됨)

1. TARGET 은 명시적으로 확정해야 합니다(편집 상자에서 Enter). 손대지 않은 기본값은 "미확정"으로 표시되고 INSTALL 이 거부됩니다. 확정 시 `default` 또는 `explicit` 를 기록합니다. Enter 는 확정, Esc 는 취소이며, 편집 중 Tab/Shift-Tab/PgUp/PgDn/화살표는 확정도 폐기도 하지 않습니다. 확인 화면은 정확한 절대 경로와 확정 방식을 보여 줍니다.
2. 사전 점검 결과는 확정된 TARGET 과 확정 방식에 묶입니다. 어느 쪽이든 바뀌면 점검 결과와 INSTALL 입력이 무효화됩니다. 코어 `Apply` 는 미확정이거나 불일치하는 TARGET 을 어떤 명령·쓰기보다 먼저 거부합니다.
3. 버전이 있는 비밀값 없는 설치 기록(`teamcloud-installer-receipt.json`, 0600, 배타적 생성, 대상 디렉터리 생성 직후 1회 작성)이 확정 TARGET/확정 방식, 설치 프로그램 버전, 생성 시각, 소스 프로필, 런타임, 런타임 신원의 유일한 기준입니다. Config 전체, 비밀번호, .env/Compose 내용, 라이선스/인증서/키 내용은 넣지 않습니다.
4. 이미지 로드 전에 설치 기록과 확정 TARGET/런타임을 대조하고, 생성된 Compose 의 bind source, env_file, 파일 기반 secrets/configs 가 TARGET 안에 있는지 확인합니다. named volume/tmpfs 와 원본 라이선스·인증서 입력 경로는 TARGET 안에 있을 필요가 없습니다. 생성 파일에 대한 정적 검사이며 실제 런타임 mount 를 조사하지 않습니다.
5. `--status` 는 설치 기록이 있으면 조회 경로·런타임·소스 프로필·런타임 신원을 대조합니다. 구체적인 불일치가 있으면 실패합니다. 설치 기록이 없으면(legacy) 신원을 확인할 수 없다고 표시하고 기존 읽기 전용 상태 조회를 유지합니다. 기록을 자동 생성하거나 기존 설치를 새로 채택하지 않습니다.

## 설치 기록 검증 (스키마 1, fail-closed)

`--status` 는 설치 기록을 compose ps 나 런타임 진단보다 먼저 읽고 다음을 모두 확인합니다. 하나라도 어긋나면 "설치 기록이 불완전하거나 올바르지 않습니다" 로 실패하며, 이후 compose ps·docker/podman info 를 실행하지 않고 기록을 채택하거나 다시 쓰지 않습니다.

설치 기록을 처음 작성할 때도 같은 필수값 검증을 수행합니다. 불완전한 기록은 파일로 만들지 않습니다. 기록의 프로필과 생성된 Compose의 프로필이 다를 때도 런타임 명령 전에 중단합니다.

- 일반 파일, JSON, `kind` 일치, `schema` = 1(다른 값은 "지원하지 않는 설치 기록 스키마").
- 최상위 필드 `schema, kind, installer_version, created_at, target, target_source, profile, runtime, identity` 가 모두 있어야 하고(0 값과 "없음"을 구분), 알 수 없는 필드는 거부합니다.
- `installer_version` 비어 있지 않음, `created_at` RFC3339, `target` 정규화된 절대 경로, `target_source` ∈ {default, explicit}, `profile` ∈ {legacy-9, studio-10}, `runtime` ∈ {docker, podman}.
- 런타임 신원 — 진단이 실제로 보고하는 값만 요구합니다.
  - Docker: `uid`, `rootless`, `endpoint`(로컬 `unix://` 절대 경로), `daemon_id`(비어 있지 않음). Podman 전용 필드는 거부합니다. 상태 조회 시 rootless·endpoint·daemon id 를 대조합니다. **uid 는 추적용으로만 기록하고 대조하지 않습니다** — rootful Docker 데몬은 소켓에 접근 가능한 모든 사용자가 공유하므로 "같은 사용자"를 강제한다고 주장하지 않습니다.
  - Podman: `uid`, `rootless`(uid ≠ 0 과 일치해야 함), `socket`(절대 경로), `endpoint`(= `unix://` + socket), `graph_root`, `run_root`(절대 경로). 상태 조회 시 uid·rootless·endpoint·socket·graphRoot·runRoot 를 모두 대조합니다.
- 검증을 통과한 기록의 신원 필드는 빈 현재 값과도 비교합니다(빈 기록 값을 "알 수 없음"으로 건너뛰지 않음).

## 수용 기준 (오프라인)

- 2026-10-30 10:53 KST 작업 코드 기준으로 Go vet·전체 테스트, fixture와 onprem `b37b46a`의 양 런타임 Compose 해석, 임시 Mac·Linux 빌드를 통과했습니다. 런타임 동작은 fake로만 검사했습니다. 상세 범위는 별도 Go 프로젝트의 `VERIFICATION.md`에 남깁니다.
- 통합 테스트의 기대 이미지는 해당 소스의 `compose.docker.yml` 에 적힌 고정 태그/다이제스트 그대로이며(보간·태그 생략 거부), 저장소 fixture 일 때는 고정 표와도 일치해야 합니다. 해석/변환 후 서비스별 이미지가 바뀌지 않았는지 확인합니다.
- Mac PTY의 Podman demo에서는 편집 중 Tab 입력 보존, Enter 확정, Esc 취소와 정상 종료를 확인했습니다. 설치가 차단된 시연이며, 실제 엔진·마운트·Linux 로그아웃·재부팅 검증은 아닙니다.

## legacy 지원 경계

새 설치 전용입니다. 기존 대상/데이터와 legacy 설치는 자동으로 채택·이동·재작성·재생성·복구·업그레이드하지 않습니다. 설치 기록 마이그레이션이나 사후 작성(backfill)은 없습니다. 불완전한 기록을 보완하는 기능도 없습니다.

## 구현 이후 남은 검증

지속 실행(user socket·user service)과 새 설치와 분리된 제품 업데이트 경로는 미출시 소스에 구현했습니다. 이는 legacy 설치의 자동 채택·업그레이드 지원과는 다릅니다.

합성 Linux fixture의 부분 검증과 실제 TeamCloud·RHEL·로그아웃/재부팅 수용의 남은 범위는 [인프라 재설계 기록](README.infra-redesign.md)을 따릅니다. 구현이나 합성 시험의 성공을 실제 제품 설치의 수용 완료로 보지 않습니다.


## Optional Devora candidate

See [Devora installation](devora/README.md) and the exact [installer/kit interface](devora/INTERFACE.md). Devora is OFF by default; supply both `--devora-env /absolute/operator.env` and `--devora-media /absolute/media` only with prepared media and a real BE image. Operator env is never included in the kit. LLM and embedding servers are external endpoints; this option installs BE, dedicated PostgreSQL and Redis only. Local source integration is separate from real image, Podman, authentication and model acceptance.
