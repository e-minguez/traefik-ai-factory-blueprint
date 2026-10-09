#!/usr/bin/env bash
# token.sh: fetch a Keycloak access token for one of the two demo personas via
# the password grant, and print the raw access_token to stdout.
#
#   token.sh <admin|dev> [-v]
#
# With -v it also decodes and pretty-prints the JWT payload to stderr, so stdout
# stays a clean token you can pipe into a curl Authorization header.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require curl jq

ROLE="${1:-}"
VERBOSE=false
[[ "${2:-}" == "-v" ]] && VERBOSE=true

case "$ROLE" in
  admin) username="admin@ai-factory.demo"; password="$DEMO_ADMIN_PASSWORD" ;;
  dev)   username="dev@ai-factory.demo";   password="$DEMO_DEV_PASSWORD" ;;
  *) echo "Usage: token.sh <admin|dev> [-v]" >&2; exit 2 ;;
esac

decode_payload() {
  # JWT payload is the middle dot-separated segment, base64url. Pad and swap the
  # url-safe alphabet so plain base64 -d can handle it.
  local jwt="$1" payload
  payload="$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  { base64 -d <<<"$payload" 2>/dev/null || base64 -D <<<"$payload" 2>/dev/null; } | jq . 2>/dev/null || echo "(could not decode JWT payload)" >&2
}

resp="$(dcurl -sS "${KC_ISSUER}/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=ai-factory-cli -d scope=openid \
  --data-urlencode "username=${username}" --data-urlencode "password=${password}")"

token="$(jq -r '.access_token // empty' <<<"$resp")"
if [[ -z "$token" ]]; then
  echo "Failed to obtain an access token. Keycloak response:" >&2
  echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
  exit 1
fi

if [[ "$VERBOSE" == true ]]; then
  echo "--- JWT payload (${ROLE}) ---" >&2
  decode_payload "$token" >&2
fi

echo "$token"
