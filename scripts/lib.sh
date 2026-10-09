#!/usr/bin/env bash
# scripts/lib.sh: shared settings for token.sh, agent.sh and verify.sh.
# Configure through the environment:
#   DOMAIN                  the blueprint's domain value (default: read from the cluster)
#   NAMESPACE               default traefik-ai-gateway-demo-system, used to read DOMAIN
#   DEMO_ADMIN_PASSWORD     default admin1234 (chart value secrets.demoAdminPassword)
#   DEMO_DEV_PASSWORD       default dev1234   (chart value secrets.demoDevPassword)
#   VLLM_MODEL              default Qwen/Qwen2.5-1.5B-Instruct
#   CA_CERT                 path to the demo CA, only for tls.issuer=selfsigned
#                           (kubectl -n traefik-ai-gateway-demo-system get secret demo-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Without DOMAIN, read it from the deployed certificate (first name is ai.<domain>).
if [[ -z "${DOMAIN:-}" ]] && command -v kubectl >/dev/null 2>&1; then
  DOMAIN="$(kubectl -n "${NAMESPACE:-traefik-ai-gateway-demo-system}" get certificate demo-tls \
    -o jsonpath='{.spec.dnsNames[0]}' 2>/dev/null || true)"
  DOMAIN="${DOMAIN#ai.}"
fi
: "${DOMAIN:?set DOMAIN to the blueprint domain (e.g. 203.0.113.10.sslip.io) or point kubectl at the cluster}"
DEMO_ADMIN_PASSWORD="${DEMO_ADMIN_PASSWORD:-admin1234}"
DEMO_DEV_PASSWORD="${DEMO_DEV_PASSWORD:-dev1234}"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
CA_CERT="${CA_CERT:-}"

AI_HOST="ai.${DOMAIN}"
KC_ISSUER="https://keycloak.${DOMAIN}/realms/ai-factory"

require() {
  local missing=()
  for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  if ((${#missing[@]})); then
    echo "Missing required tools: ${missing[*]}" >&2
    exit 1
  fi
}

# dcurl: curl for the demo hosts, trusting CA_CERT when set.
dcurl() {
  if [[ -n "$CA_CERT" ]]; then
    curl --cacert "$CA_CERT" "$@"
  else
    curl "$@"
  fi
}
