#!/usr/bin/env bash
# chat.sh: send one chat completion through the AI gateway as a persona and
# print what the gateway decided: status, latency, the gateway headers
# (cache, rate limits) and the answer or the deny message.
#
#   chat.sh <admin|dev|none> <model> <prompt...>
#
#   chat.sh none qwen2.5:0.5b "hi"                        # no token -> 401
#   chat.sh dev  smollm2:135m "hi"                        # wrong group -> 403
#   chat.sh admin Qwen/Qwen2.5-1.5B-Instruct "Say hello"  # GPU model via vLLM
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require curl jq

ROLE="${1:-}"; MODEL="${2:-}"; shift 2 2>/dev/null || true; PROMPT="$*"
case "$ROLE" in admin|dev|none) ;; *) ROLE="" ;; esac
if [[ -z "$ROLE" || -z "$MODEL" || -z "$PROMPT" ]]; then
  echo "Usage: chat.sh <admin|dev|none> <model> <prompt...>" >&2; exit 2
fi

auth=()
if [[ "$ROLE" != none ]]; then
  token="$("$SCRIPTS_DIR/token.sh" "$ROLE")" || exit 1
  auth=(-H "Authorization: Bearer ${token}")
fi

hdr="$(mktemp)"; body="$(mktemp)"; trap 'rm -f "$hdr" "$body"' EXIT
meta="$(dcurl -sS -D "$hdr" -o "$body" -w '%{http_code} %{time_total}' -X POST \
  "https://${AI_HOST}/v1/chat/completions" \
  ${auth[@]+"${auth[@]}"} -H 'content-type: application/json' \
  -d "$(jq -nc --arg m "$MODEL" --arg p "$PROMPT" '{model:$m,messages:[{role:"user",content:$p}]}')")"

read -r code secs <<<"$meta"
served="$(jq -r '.model // empty' "$body" 2>/dev/null || true)"
printf 'HTTP %s  %.1fs  as %s  asked %s  answered by %s\n' "$code" "$secs" "$ROLE" "$MODEL" "${served:--}"
tr -d '\r' <"$hdr" | grep -iE '^x-(cache-status|cache-distance|ratelimit)' | sed 's/^/  /' || true
if [[ ! -s "$body" ]]; then
  echo "  (empty body)"
else
  jq -r '.choices[0].message.content // .error.message // .message // .' "$body" 2>/dev/null || cat "$body"
fi
echo
