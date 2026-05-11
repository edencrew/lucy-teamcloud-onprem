# syntax=docker/dockerfile:1.6

############################
# 1) Builder
############################
ARG BASE_IMAGE=rockylinux:9.0
FROM ${BASE_IMAGE} AS builder

# BuildKit meta (multi-arch introspection)
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ARG VMQ_REPO=https://github.com/vernemq/vernemq.git
# "2.0.1-19-g75c5a6a9" 커밋
ARG VMQ_COMMIT=75c5a6a9
# rebar3 폴백 버전
ARG REBAR3_VERSION=3.24.0

# 빌드 도구 및 라이브러리
RUN set -eux; \
  dnf -y update && dnf -y install dnf-plugins-core && \
    dnf config-manager --set-enabled crb || true && \
    dnf -y install epel-release && \
    dnf -y groupinstall "Development Tools" && \
    dnf -y install \
        openssl openssl-devel \
        ncurses ncurses-devel \
        zlib zlib-devel net-tools \
        snappy snappy-devel procps-ng iproute iputils \
        perl curl which wget git jq bash \
        autoconf automake libtool \
        unzip tar xz diffutils ca-certificates && \
  update-ca-trust && dnf clean all

# ===== Erlang/OTP + rebar3 =====
# 우선 distro 패키지를 시도하되, 실패 시 아키별 zero-dep RPM 폴백
# (x86_64/aarch64 모두 커버)  — OTP 25–27 범위 권장
RUN set -eux; \
  if ! dnf -y install erlang; then \
    echo "distro erlang not available -> zero-dep fallback"; \
    case "$(uname -m)" in \
      x86_64) arch="x86_64";; \
      aarch64) arch="aarch64";; \
      *) echo "Unsupported arch: $(uname -m)"; exit 1;; \
    esac; \
    erl_ver="27.3.4.2"; \
    base_url="https://github.com/rabbitmq/erlang-rpm/releases/download/${erl_ver}"; \
    rpm="erlang-${erl_ver}-1.el9.${arch}.rpm"; \
    curl -fSL --retry 5 "${base_url}/${rpm}" -o "/tmp/${rpm}"; \
    dnf -y install "/tmp/${rpm}" && rm -f "/tmp/${rpm}"; \
    fi; \
  if ! dnf -y install rebar3; then \
    curl -fSL --retry 5 \
        "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
        -o /usr/local/bin/rebar3; \
      chmod +x /usr/local/bin/rebar3; \
    fi; \
    erl -eval 'erlang:display(erlang:system_info(system_architecture)),halt().' -noshell; \
    rebar3 --version

# VerneMQ 소스 가져오기
WORKDIR /src
# 소스 취득 + 서브모듈
RUN --mount=type=cache,target=/root/.cache/git \
    set -eux; \
    git clone "${VMQ_REPO}" .; \
    git checkout "${VMQ_COMMIT}"; \
    git submodule update --init --recursive

# Release build (ERTS 포함)
# rebar 캐시 활용
RUN --mount=type=cache,target=/root/.cache/rebar3 \
    set -eux; \
    make rel; \
    mkdir -p /tmp/vernemq && \
    cp -a _build/default/rel/vernemq/* /tmp/vernemq/

############################
# 2) Runtime
############################
FROM ${BASE_IMAGE} AS runtime

# 런타임 최소 의존 (디버깅툴은 선택)
RUN set -eux; \
    dnf -y update && \
    dnf -y install \
        openssl \
        ncurses \
        zlib \
        snappy \
        perl \
        curl \
        which \
        wget \
        git \
        jq \
        bash \
        procps-ng \
        procps \
        iproute \
        net-tools \
        nano \
        ca-certificates \
        bash \
        jq \
        curl \
        which && \
    update-ca-trust && \
    dnf clean all

# vernemq 실행 계정/디렉토리
RUN groupadd -r vernemq && \
    useradd -r -g vernemq -d /vernemq -s /sbin/nologin vernemq
RUN mkdir -p /vernemq && chown vernemq:vernemq /vernemq
WORKDIR /vernemq

# 빌더 Release 복사(ERTS 포함)
COPY --from=builder /tmp/vernemq/ /vernemq/

#  런타임에서도 스키마가 들어왔는지 최종 확인(빌드 타임 체크)
RUN <<'SH'
set -euo pipefail
if ls /vernemq/releases/*/vmq.schema >/dev/null 2>&1 || \
   ls /vernemq/share/schema/*.schema >/dev/null 2>&1; then
  echo "[runtime] schema present:"
  ls -1 /vernemq/releases/*/vmq.schema 2>/dev/null || true
  ls -1 /vernemq/share/schema/*.schema 2>/dev/null || true
else
  echo "[runtime] vmq.schema not found under /vernemq (release incomplete)"
  find /vernemq -maxdepth 3 -type f | sed -n '1,200p'
  exit 32
fi
SH

# 엔트리포인트 등 나머지는 그대로
COPY ./docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PATH="/vernemq/bin:${PATH}"

# --- VerneMQ 런타임 설정 (엔트리포인트가 env -> vernemq.conf 로 변환) ---
# 이미지 단위로 고정되는 값들. 배포별로 바뀌어야 하는 NODENAME / 로그레벨은
# compose 의 environment 에서 지정.
ENV DOCKER_VERNEMQ_ALLOW_ANONYMOUS=on \
    DOCKER_VERNEMQ_DISTRIBUTED_COOKIE=nocluster \
    DOCKER_VERNEMQ_LISTENER__TCP__DEFAULT=0.0.0.0:1883 \
    DOCKER_VERNEMQ_LISTENER__WS__DEFAULT=0.0.0.0:8080 \
    DOCKER_VERNEMQ_LISTENER__HTTP__DEFAULT=0.0.0.0:8888 \
    DOCKER_VERNEMQ_LISTENER__VMQ__CLUSTERING=0.0.0.0:44053 \
    DOCKER_VERNEMQ_ERLANG__DISTRIBUTION__PORT_RANGE__MINIMUM=9100 \
    DOCKER_VERNEMQ_ERLANG__DISTRIBUTION__PORT_RANGE__MAXIMUM=9109

# Ports
EXPOSE 1883 8883 8080 8081 44053 4369 8888 \
       9100 9101 9102 9103 9104 9105 9106 9107 9108 9109

HEALTHCHECK --start-period=60s --interval=10s --timeout=5s --retries=6 \
  CMD vernemq ping | grep -q pong || exit 1

# 데이터/로그 디렉토리 보장
RUN mkdir -p /vernemq/data /vernemq/log && chown -R vernemq:vernemq /vernemq

# 공식 이미지와 호환되는 진입
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/vernemq/bin/vernemq start"]
