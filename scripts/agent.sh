#!/usr/bin/env bash
# agent.sh: a tiny MCP client that drives the Traefik MCP gateway deployed by the blueprint as one
# of the Keycloak personas, to show identity-aware tool governance. Ported from
# the repo's scripts/agent.sh.
#
#   agent.sh <admin|dev>
#
# It performs the MCP handshake over streamable HTTP through the gateway, lists the
# tools it is allowed to see, calls a read tool, then calls a PRIVILEGED tool:
#   - admin: the privileged call succeeds
#   - dev:   the privileged call is DENIED by the gateway's mcp-policy, not the server
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require curl jq

ROLE="${1:-}"
case "$ROLE" in admin|dev) ;; *) echo "Usage: agent.sh <admin|dev>" >&2; exit 2 ;; esac

URL="https://${AI_HOST}/mcp/ai-factory"
PROTO="2025-06-18"
TOKEN="$("$SCRIPTS_DIR/token.sh" "$ROLE")" || { echo "could not get a $ROLE token" >&2; exit 1; }

HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
SESSION=""

# mcp_call METHOD PARAMS_JSON [is_notification]
# POSTs one JSON-RPC message through the gateway and prints the JSON result body.
# Handles both application/json and text/event-stream (SSE) responses, and captures
# the Mcp-Session-Id from the initialize response.
mcp_call() {
  local method="$1" params="${2:-'{}'}" notif="${3:-}" id_field body
  if [[ -n "$notif" ]]; then
    id_field=""                       # notifications have no id
  else
    id_field='"id": 1,'
  fi
  local payload="{\"jsonrpc\":\"2.0\",${id_field}\"method\":\"${method}\",\"params\":${params}}"

  body="$(dcurl -sS -D "$HDR" -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "MCP-Protocol-Version: ${PROTO}" \
    ${SESSION:+-H "Mcp-Session-Id: ${SESSION}"} \
    --data "$payload")"

  # capture session id from the initialize response (header name is case-insensitive)
  if [[ -z "$SESSION" ]]; then
    SESSION="$(grep -i '^mcp-session-id:' "$HDR" | tr -d '\r' | awk '{print $2}' | head -1)"
  fi

  # SSE frames look like `data: {json}`; a plain JSON response has no such prefix.
  if grep -q '^data:' <<<"$body"; then
    grep '^data:' <<<"$body" | sed 's/^data: *//' | tail -1
  else
    echo "$body"
  fi
}

echo "=== MCP agent as $ROLE -> $URL ==="

echo "--- initialize ---"
init_params='{"protocolVersion":"'"$PROTO"'","capabilities":{},"clientInfo":{"name":"ai-factory-agent","version":"0.1"}}'
mcp_call "initialize" "$init_params" | jq -r '.result.serverInfo // .error // .' 2>/dev/null || true
# The initialize call above runs in a pipeline (subshell), so the SESSION set
# inside mcp_call is lost. Re-read it in this shell from the response headers
# ($HDR is a file, so it survives the subshell); later calls inherit it.
SESSION="$(grep -i '^mcp-session-id:' "$HDR" | tr -d '\r' | awk '{print $2}' | head -1)"
[[ -n "$SESSION" ]] && echo "(session: $SESSION)"

# tell the server we are initialized (notification, no response body expected)
mcp_call "notifications/initialized" '{}' notif >/dev/null 2>&1 || true

echo "--- tools/list (what this identity may see) ---"
mcp_call "tools/list" '{}' | jq -r '.result.tools[]?.name' 2>/dev/null || echo "(no tools / denied)"

echo "--- tools/call list_models (read tool, allowed for everyone) ---"
mcp_call "tools/call" '{"name":"list_models","arguments":{}}' \
  | jq -r '.result.content[0].text // .error.message // .' 2>/dev/null || true

echo "--- tools/call restart_model (PRIVILEGED, admins only) ---"
resp="$(mcp_call "tools/call" '{"name":"restart_model","arguments":{"model":"smollm2:135m"}}')"
if jq -e '.result' >/dev/null 2>&1 <<<"$resp"; then
  echo "ALLOWED:"; jq -r '.result.content[0].text' <<<"$resp" 2>/dev/null || echo "$resp"
else
  echo "DENIED by the gateway (expected for dev):"
  jq -r '.error.message // .' <<<"$resp" 2>/dev/null || echo "$resp"
fi

echo "=== done ==="
