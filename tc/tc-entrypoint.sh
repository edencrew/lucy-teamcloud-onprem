#!/bin/sh

set -e

set -a
. /run/secrets/secrets.env
set +a

# tc-be 의 OIDC 클라이언트 자격증명 (Lucy TeamCloud web client)
export OIDC_CLIENT_SECRET=$TC_OIDC_CLIENT_SECRET

cd /app
exec ./entrypoint.sh
