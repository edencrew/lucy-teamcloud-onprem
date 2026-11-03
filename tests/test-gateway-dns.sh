#!/bin/sh
# gw 요청 시 DNS 재조회: nginx 이미지 stock entrypoint(15-local-resolvers + 20-envsubst-on-templates,
# FILTER=^NGINX_LOCAL_RESOLVERS$)를 로컬 도구로 흉내 내 두 템플릿 렌더링을 확인하고, 경로 제거·query·
# WebSocket·변수 proxy_pass 불변식과 compose 마운트/환경을 정적으로 확인한다.
# 실제 Docker/Podman/nginx 런타임은 검증하지 않는다.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

fail=0
ok() { echo "ok - $*"; }
ng() { echo "not ok - $*"; fail=1; }

# 15-local-resolvers.envsh 와 같은 규칙: nameserver 값 전부, IPv6 는 대괄호, 공백 구분
local_resolvers() { # <resolv.conf>
    awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' "$1" | sed 's/ *$//'
}

# 20-envsubst-on-templates.sh 의 FILTER 동작: 정규식에 맞는 변수(NGINX_LOCAL_RESOLVERS)만 치환,
# 나머지 $변수는 그대로 둔다. envsubst 가 있으면 그것을, 없으면 같은 규칙의 awk 로 대체한다.
render() { # <template> <resolv content> <out>
    printf '%s\n' "$2" > "$WORK/resolv.conf"
    NGINX_LOCAL_RESOLVERS=$(local_resolvers "$WORK/resolv.conf")
    export NGINX_LOCAL_RESOLVERS
    if command -v envsubst >/dev/null 2>&1; then
        envsubst '${NGINX_LOCAL_RESOLVERS}' < "$1" > "$3"
    else
        sed -e "s|\${NGINX_LOCAL_RESOLVERS}|$NGINX_LOCAL_RESOLVERS|g" \
            -e "s|\$NGINX_LOCAL_RESOLVERS\([^A-Za-z0-9_]\)|$NGINX_LOCAL_RESOLVERS\1|g" \
            -e "s|\$NGINX_LOCAL_RESOLVERS\$|$NGINX_LOCAL_RESOLVERS|" "$1" > "$3"
    fi
}

for conf in nginx.conf nginx.http.conf; do
    tpl="$ROOT/nginx/$conf"

    # 템플릿 자리표시자: 정확히 한 번, resolver 줄에만, 이전 자리표시자 없음
    [ "$(grep -cF '$NGINX_LOCAL_RESOLVERS' "$tpl")" = 0 ] && [ "$(grep -cF '${NGINX_LOCAL_RESOLVERS}' "$tpl")" = 1 ] && ok "$conf single placeholder" || ng "$conf single placeholder"
    grep -q '^    resolver \${NGINX_LOCAL_RESOLVERS} valid=10s ipv6=off;$' "$tpl" && ok "$conf resolver placeholder" || ng "$conf resolver placeholder"
    grep -q '__TC_GW_RESOLVER__' "$tpl" && ng "$conf legacy placeholder remains" || ok "$conf no legacy placeholder"

    # Docker 내장 DNS 모드
    out="$WORK/docker-$conf"
    render "$tpl" "nameserver 127.0.0.11
options ndots:0" "$out"
    grep -q '^    resolver 127\.0\.0\.11 valid=10s ipv6=off;$' "$out" && ok "$conf docker resolver" || ng "$conf docker resolver"

    # Podman aardvark 모드: 주석/search 무시, nameserver 두 값 모두 사용
    out="$WORK/podman-$conf"
    render "$tpl" "# generated
search dns.podman
nameserver 10.89.0.1
nameserver 192.0.2.53" "$out"
    grep -q '^    resolver 10\.89\.0\.1 192\.0\.2\.53 valid=10s ipv6=off;$' "$out" && ok "$conf podman resolver both values" || ng "$conf podman resolver both values"
    grep -qE '\$\{?NGINX_LOCAL_RESOLVERS' "$out" && ng "$conf placeholder left" || ok "$conf placeholder replaced"

    # 치환 대상 외 nginx 변수는 그대로 남아야 한다(템플릿과 resolver 줄만 다름)
    if diff "$tpl" "$out" | grep -E '^[<>]' | grep -vqE '^[<>][[:space:]]+resolver '; then
        ng "$conf render changed lines other than resolver"
    else ok "$conf only resolver line changed"; fi
    for v in '$http_upgrade' '$connection_upgrade' '$tc_fe' '$tc_be' '$auth_fe' '$auth_be' \
             '$broker_ws' '$studio_dl' '$1' '$scheme' '$http_host' '$request_uri' '$host' '$remote_addr'; do
        n_tpl=$(grep -cF "$v" "$tpl" || true)
        n_out=$(grep -cF "$v" "$out" || true)
        [ "$n_tpl" = "$n_out" ] && ok "$conf keeps $v ($n_out)" || ng "$conf $v changed ($n_tpl -> $n_out)"
    done

    # IPv6 nameserver 는 대괄호 표기
    out="$WORK/v6-$conf"
    render "$tpl" "nameserver fd00::1" "$out"
    grep -q '^    resolver \[fd00::1\] valid=10s ipv6=off;$' "$out" && ok "$conf ipv6 resolver" || ng "$conf ipv6 resolver"

    # 템플릿 불변식
    t=$(cat "$tpl")
    grep -q '^[[:space:]]*upstream ' "$tpl" && ng "$conf static upstream blocks remain" || ok "$conf no static upstream"
    # 모든 proxy_pass 는 변수 호스트 + URI 없음(정적 이름 캐시 금지)
    if grep -E '^[[:space:]]*proxy_pass ' "$tpl" | grep -vqE 'proxy_pass http://\$[a-z_]+;$'; then
        ng "$conf proxy_pass must be variable without URI"
    else ok "$conf variable proxy_pass"; fi
    for s in 'set $tc_fe     tc-fe:80;' 'set $tc_be     tc-be:80;' 'set $auth_fe   auth-fe:80;' \
             'set $auth_be   auth-be:80;' 'set $broker_ws broker:8080;' 'set $studio_dl studio-dl:80;' \
             'rewrite ^/auth(/api/.*)$ $1 break;' 'rewrite ^/auth(/.*)$ $1 break;' \
             'rewrite ^/studio(/.*)$ $1 break;' 'proxy_cookie_path /api/ /auth/api/;' \
             'proxy_set_header Upgrade $http_upgrade;' 'proxy_set_header Connection $connection_upgrade;' \
             'proxy_http_version 1.1;' 'location ^~ /mqtt {' 'return 307 $scheme://$http_host/auth$request_uri;' \
             'client_max_body_size 4g;' 'client_max_body_size 250m;'; do
        case "$t" in *"$s"*) ok "$conf has: $s" ;; *) ng "$conf missing: $s" ;; esac
    done
    # rewrite 대상에 '?' 를 붙이면 query 가 사라진다
    grep -E '^[[:space:]]*rewrite ' "$tpl" | grep -q '?' && ng "$conf rewrite drops query" || ok "$conf rewrite keeps query"
done

grep -q 'listen 443 ssl;' "$ROOT/nginx/nginx.conf" && ok "https template listens 443" || ng "https 443"
grep -q 'listen 443' "$ROOT/nginx/nginx.http.conf" && ng "http template must not listen 443" || ok "http template 80 only"

# rewrite 정규식이 기대대로 경로를 떼는지(sed -E 로 동등 확인, query 는 nginx 가 별도 보존)
chk() { r=$(printf '%s' "$2" | sed -E "s#$1#\\1#"); [ "$r" = "$3" ] && ok "strip $2 -> $3" || ng "strip $2 -> $r (want $3)"; }
chk '^/auth(/api/.*)$' /auth/api/v1/me /api/v1/me
chk '^/auth(/.*)$' /auth/login /login
chk '^/studio(/.*)$' /studio/latest.json /latest.json

# compose: 템플릿은 stock 템플릿 디렉터리에 읽기 전용, stock entrypoint/command, 필터 환경
for c in compose.docker.yml compose.podman.yml; do
    f="$ROOT/$c"
    gw=$(awk '/^  gw:$/{on=1; print; next} on && /^  [a-z]/{exit} on{print}' "$f")
    case "$gw" in *'${TC_GW_CONFIG:-nginx/nginx.conf}:/etc/nginx/templates/nginx.conf.template:ro'*) ok "$c template ro" ;; *) ng "$c template ro" ;; esac
    case "$gw" in *'NGINX_ENTRYPOINT_LOCAL_RESOLVERS: "1"'*) ok "$c local resolvers env" ;; *) ng "$c local resolvers env" ;; esac
    case "$gw" in *'NGINX_ENVSUBST_OUTPUT_DIR: /etc/nginx'*) ok "$c envsubst output dir" ;; *) ng "$c envsubst output dir" ;; esac
    # compose 에서 $$ 는 리터럴 $ 이므로 컨테이너에는 ^NGINX_LOCAL_RESOLVERS$ 로 전달된다
    case "$gw" in *'NGINX_ENVSUBST_FILTER: ^NGINX_LOCAL_RESOLVERS$$'*) ok "$c envsubst filter" ;; *) ng "$c envsubst filter" ;; esac
    case "$gw" in *'entrypoint:'*|*'command:'*) ng "$c gw overrides stock entrypoint/command" ;; *) ok "$c stock entrypoint" ;; esac
    case "$gw" in *'docker-entrypoint.sh'*|*'tc-gw-entrypoint'*) ng "$c still mounts gw helper" ;; *) ok "$c no gw helper" ;; esac
    case "$gw" in *':/etc/nginx/nginx.conf'*) ng "$c still mounts over nginx.conf" ;; *) ok "$c no nginx.conf overwrite" ;; esac
done
grep -q 'nginx/docker-entrypoint.sh' "$ROOT/scripts/package-update.sh" && ng "package allowlist includes gw helper" || ok "package allowlist unchanged"

echo "# skip: Docker/Podman/nginx runtime not exercised; stock entrypoint behaviour simulated only"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
