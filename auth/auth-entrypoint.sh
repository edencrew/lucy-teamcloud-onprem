#!/bin/sh

set -e

set -a
. /run/secrets/secrets.env
set +a

export OIDC_CLIENT_ID=lucy-auth-oidc-client-id
export OIDC_CLIENT_SECRET=$AUTH_OIDC_CLIENT_SECRET
export OIDC_CLIENTS_PRESET=$(cat <<EOF
[{
  "clientId":"lucy-auth-oidc-client-id",
  "clientSecret":"${AUTH_OIDC_CLIENT_SECRET}",
  "clientName":"Lucy Auth",
  "applicationType":"web",
  "redirectUris":["${EXTERNAL_URL}/auth/callback"],
  "grantTypes":["authorization_code","refresh_token"],
  "scopes":["openid","email","profile","offline_access"],
  "postLogoutRedirectUris":["${EXTERNAL_URL}/auth/"]
},{
  "clientId":"lucy-teamcloud-oidc-client-id",
  "clientSecret":"${TC_OIDC_CLIENT_SECRET}",
  "clientName":"Lucy TeamCloud",
  "applicationType":"web",
  "redirectUris":["${EXTERNAL_URL}/callback"],
  "grantTypes":["authorization_code","refresh_token"],
  "scopes":["openid","email","profile","offline_access"]
},{
  "clientId":"lucy-studio-oidc-client-id",
  "clientName":"Lucy Studio",
  "applicationType":"native",
  "redirectUris":["com.edencrew.lucystudio://auth"],
  "grantTypes":["authorization_code","refresh_token"],
  "scopes":["openid","email","profile","offline_access"],
  "token_endpoint_auth_method":"none"
},{
  "clientId":"lucy-player-oidc-client-id",
  "clientName":"Lucy Player",
  "applicationType":"native",
  "redirectUris":["com.edencrew.lucyplayer://"],
  "grantTypes":["authorization_code","refresh_token"],
  "scopes":["openid","email","profile","offline_access"],
  "token_endpoint_auth_method":"none"
}]
EOF
)

cd /app
exec ./entrypoint.sh
