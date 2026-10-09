# Traefik AI Gateway blueprint for SUSE AI Factory

A SUSE AI Factory blueprint that deploys the SUSE AI stack behind Traefik Hub's AI gateway and MCP gateway. The SUSE AI applications (Ollama, vLLM, Milvus, Redis, Open WebUI and the OpenTelemetry Collector) stay stock Application Collection charts. Every policy lives in one small chart from this repository: who may use which model, token budgets, semantic caching, prompt safety checks, and which tools an agent may call.

Traefik itself is a prerequisite. On RKE2 it is managed by the cluster's own HelmChart, not by the blueprint.

Status: built and validated offline, not yet deployed.

## What gets deployed

```
Browser ──> Open WebUI (chat.${DOMAIN}) ─┐  Keycloak SSO; each user's token is
curl / scripts / Claude Code ────────────┤  forwarded to the gateway
MCP Inspector ───────────────────────────┤
                                         v
       Traefik Hub (prerequisite, RKE2-managed)
       ai.${DOMAIN}
         /v1/models            -> model catalog (static, public)
         /v1/chat/completions  -> JWT (Keycloak) -> child route by group + Model():
             admins      qwen2.5:0.5b, smollm2:135m -> Ollama (CPU)
             admins      Qwen/Qwen2.5-1.5B-Instruct -> vLLM (GPU), fails over to Ollama (CPU)
             developers  qwen2.5:0.5b               -> Ollama (CPU)
             anything else                          -> 403
           allowed routes: mask personal data, secrets, injection phrases
                           -> llama-guard3 + jailbreak judge (parallel) -> chat-completion
                           -> ai-rate-limit group/user (Redis) -> semantic cache (Milvus)
         /mcp/ai-factory       -> JWT -> rate limit -> TBAC -> ops MCP server
         /mcp/deepwiki         -> JWT -> rate limit -> TBAC -> mcp.deepwiki.com
       chat. / keycloak. / inspector.${DOMAIN} -> WAF (Coraza + OWASP CRS)
       OTLP -> OpenTelemetry Collector -> SUSE Observability
```

| Blueprint component | Chart repo | Role |
|---|---|---|
| `traefik-ai-gateway` | this repo (`repo/`) | Keycloak and realm, model catalog, ops MCP server, MCP Inspector, cert-manager Certificate, shared secrets, every Traefik Middleware and IngressRoute |
| `ollama` | application-collection | CPU chat models, embeddings, `llama-guard3` |
| `vllm` | application-collection | GPU model; only accepts a key held by the gateway |
| `milvus` | application-collection | Semantic-cache vectors, plus Open WebUI RAG |
| `redis` | application-collection | Token-bucket store for the rate limits |
| `open-webui` | application-collection | Chat UI; its gateway, SSO and MCP settings come from a secret created by `traefik-ai-gateway` |
| `opentelemetry-collector` | application-collection | Forwards Traefik telemetry to SUSE Observability |
| `suse-ai-observability-extension` | application-collection | Installs the GenAI StackPack in SUSE Observability |

All components install into the AIWorkload's target namespace. `traefik-ai-gateway-demo-system` is assumed by `cluster/traefik-helmchart.yaml`.

## Repository layout

```
charts/traefik-ai-gateway/   chart source
repo/                        the Helm repo: index.yaml + packaged chart, served over HTTP
blueprints/                  Blueprint + BlueprintCatalog CRs, synced by the AI Factory operator
cluster/                     prerequisites and registration: Traefik HelmChart, ClusterRepo, operator values
docs/prerequisites.md        how to prepare the cluster
docs/demo.md                 goal of the demo and the demo script
docs/known-issues.md         known issues (Traefik v3.7 child routes) and fixes found during testing
examples/                    an AIWorkload for the local cluster
scripts/                     token.sh, chat.sh, agent.sh, verify.sh for the walkthrough
Makefile                     lint, package, regenerate the URLs, validate the blueprint
```

## Prerequisites

[`docs/prerequisites.md`](docs/prerequisites.md) has the step-by-step procedure, with commands and checks for each item:

1. **Rancher** with **SUSE AI Factory** installed (`aif-operator` and the `aif-ui` extension). Application Collection credentials must also be configured, so that the operator manages the `application-collection` ClusterRepo and the pull secrets.
2. **Traefik Hub as the cluster's ingress controller**, replacing the ingress embedded in RKE2:
   - disable the embedded ingress (`ingress-controller: none`) on every control-plane node;
   - create the `traefik-hub-license` secret by hand, or annotate it with `helm.sh/resource-policy=keep` if an earlier HelmChart created it;
   - apply [`cluster/traefik-helmchart.yaml`](cluster/traefik-helmchart.yaml), after adjusting the node placement, hostPorts and proxyProtocol settings to your environment.
3. **cert-manager.** Rancher usually has it already.
4. **A default StorageClass.** Check `kubectl get sc`; mark an existing class as default, or install a provisioner if there is none.
5. **A GPU node with the NVIDIA GPU Operator** (`nvidia` RuntimeClass, `nvidia.com/gpu.present=true` label), plus a non-GPU node for Ollama.
6. **DNS, load balancer and outbound access**:
   - `<load-balancer-ip>.sslip.io` or a wildcard DNS record;
   - port 80 reachable from the internet, for Let's Encrypt;
   - in-cluster hairpin to the load balancer;
   - outbound internet access for the models, the images and this repository.

## Publish

The Helm repo is plain files in `repo/`, so it needs no registry and no image build:

```shell
export REPO_OWNER=e-minguez REPO_NAME=traefik-ai-factory-blueprint BRANCH=main
make release
git add -A && git commit -m "release traefik-ai-gateway 0.1.0" && git push
```

`make release` lints and packages the chart, then regenerates `repo/index.yaml` with absolute chart URLs. It also rewrites the URLs in `cluster/clusterrepo.yaml` and `cluster/aif-operator-values.yaml`.

The default is `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/repo`. To serve the same files from GitHub Pages or any static web server, set `REPO_HTTP_URL`. Bump `version` in `Chart.yaml` and `chartVersion` in the blueprint for every chart change; `index.yaml` keeps the older versions.

## Register the blueprint

On the Rancher cluster:

```shell
# 1. The Helm repo the blueprint's traefik-ai-gateway component pulls from
kubectl apply -f cluster/clusterrepo.yaml

# 2. The blueprint catalog: a Fleet GitRepo syncing blueprints/ into the AI Factory UI.
#    Keeps the operator at its installed version and only adds the catalog.
export AIF_CHART=oci://ghcr.io/suse/chart/aif-operator
export AIF_NAMESPACE=aif-operator
export AIF_VERSION=$(helm -n "${AIF_NAMESPACE}" list -f '^aif-operator$' -o json | jq -r '.[0].chart | sub("^aif-operator-"; "")')
helm upgrade aif-operator "${AIF_CHART}" -n "${AIF_NAMESPACE}" --version "${AIF_VERSION}" \
  --reuse-values -f cluster/aif-operator-values.yaml
```

To try it without the catalog, `kubectl apply -f blueprints/` works too. Blueprints and catalogs are cluster-scoped.

## Install

Set the domain once; the commands below and the scripts use it:

```shell
export DOMAIN=203.0.113.10.sslip.io   # <load-balancer-ip>.sslip.io, or your own wildcard DNS name
export NAMESPACE=traefik-ai-gateway-demo-system
```

In Rancher, open **SUSE AI Factory**, pick **Traefik AI Gateway** from the **Traefik Blueprints** catalog, and choose the `local` cluster (or a downstream one). The wizard proposes workload `traefik-ai-gateway-demo` in namespace `traefik-ai-gateway-demo-system` (it derives `<blueprint>-system` from the blueprint name); keep that namespace, the Traefik OTLP endpoints assume it. Override these values in the wizard:

| Component | Values |
|---|---|
| `traefik-ai-gateway` | `domain` (the value of `${DOMAIN}`). Optionally `tls.acmeEmail` (contact address for the Let's Encrypt account, not needed to get certificates) and `vllmModel` |
| `vllm` | `servingEngineSpec.modelSpec[0].modelURL`, only if you change the model (it must equal `vllmModel`). The default `Qwen/Qwen2.5-1.5B-Instruct` fits almost any GPU; see [choosing the vLLM model for your GPU](docs/prerequisites.md#51-choosing-the-vllm-model-for-your-gpu) |
| `opentelemetry-collector` | `suseObservability.endpoint`, `.clusterName` and `.apiKey`, or disable the component |
| `suse-ai-observability-extension` | `serverUrl`, `apiToken` and `kubernetesClusters`, or disable the component |

[`examples/aiworkload-local.yaml`](examples/aiworkload-local.yaml) is the same thing written as a manifest, with `${VAR}` placeholders. Export the variables listed in its header, then:

```shell
envsubst < examples/aiworkload-local.yaml | kubectl apply -f -
```

The first install takes a while, because Ollama pulls four models and vLLM downloads the weights. Components start in parallel; a blueprint has no install order. Redis and vLLM wait a minute or two for the secrets that `traefik-ai-gateway` creates, and the workload settles once they exist.

Then, in Open WebUI at `https://chat.${DOMAIN}`:

1. Sign in with Keycloak as `admin@ai-factory.demo` (password `admin1234`) **first**. The first user becomes the Open WebUI admin.
2. Use a private window for `dev@ai-factory.demo` (password `dev1234`).

The gateway connection (`https://ai.${DOMAIN}/v1`) already uses **Auth: OAuth**, so chats carry each user's own token. Open WebUI 0.6.41 has no environment variable for this setting. The blueprint writes it into Open WebUI's `config.json` before the first start, and Open WebUI imports that file into its database. Check it under **Admin Panel > Settings > Connections**.

## Walkthrough

[`docs/demo.md`](docs/demo.md) explains the goal of the demo and gives a step-by-step demo script with talking points. The checks below are the short version.

```shell
# The scripts use DOMAIN and NAMESPACE from the environment (see Install).
# Without DOMAIN they read it from the deployed certificate in NAMESPACE.
./scripts/verify.sh            # every check below, PASS/FAIL
TOKEN=$(./scripts/token.sh dev -v)
./scripts/agent.sh admin       # 5 MCP tools; the privileged restart_model succeeds
./scripts/agent.sh dev         # 3 MCP tools; restart_model is hidden and denied
```

1. **No token, no service.** `/v1/chat/completions` without a token returns 401.
2. **Model access by group, across CPU and GPU.** The developer can use `qwen2.5:0.5b`. On `smollm2:135m` or the vLLM model, Open WebUI shows the gateway's 403 message. The admin can use all three.
3. **Token budgets.** Developers get 1500 tokens per user and 5000 per group every 10 minutes (`traefik-ai-gateway.rateLimits`). A burst of long prompts as the developer counts down `X-Ratelimit-Remaining-Tokens-Total`, then returns 429. The admin is unaffected. Open WebUI also spends budget on background requests (titles, tags), so a dev chat session drains it faster than the API.
4. **Semantic cache.** The same prompt twice gives `X-Cache-Status: Miss` then `Hit`, with the vectors stored in Milvus.
5. **Prompt safety.** A harmful prompt is blocked by `llm-guard` (`llama-guard3`) before any tokens are spent.
6. **Tool governance.** In Open WebUI, the Inspector (`https://inspector.${DOMAIN}`) or Claude Code:
   - the developer never sees the privileged ops tools;
   - DeepWiki answers about `traefik/traefik` only for the admin, because the developer's token is scoped to `traefik/traefik-helm-chart`.
7. **Observability.** Traefik's traces, metrics and access logs appear in SUSE Observability as `traefik-ai-gateway`, with `X-User` and `X-Groups` on every request. Tokens are dropped from the logs.

## Uninstall

Deleting the workload in the AI Factory UI (or `kubectl delete aiwl`) removes
the component releases. It does not remove everything:

- **The namespace.** Neither Fleet nor the operator deletes it.
- **Some PersistentVolumeClaims**, by design: `milvus` (the chart marks it
  `helm.sh/resource-policy: keep`), and `data-milvus-etcd-0` / `data-redis-0`
  (StatefulSet volumes, which Kubernetes keeps).
- **PersistentVolumes** whose StorageClass has `reclaimPolicy: Retain` stay as
  `Released` after their PVC is gone.

Deleting the namespace also deletes the `demo-tls` certificate. Let's Encrypt
issues at most 5 certificates per week for the same set of host names, so
repeated reinstalls with the same `domain` run into its rate limit. To reuse the
certificate, save it before deleting the namespace and restore it right after
creating the namespace again: cert-manager keeps a valid certificate instead of
ordering a new one.

```shell
kubectl -n "${NAMESPACE}" get secret demo-tls -o yaml | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.ownerReferences)' > demo-tls.yaml
# ... uninstall, then after creating the namespace for the reinstall:
kubectl apply -f demo-tls.yaml
```

For a clean slate, wait until Fleet has uninstalled everything, then delete the
namespace:

```shell
export NAMESPACE=traefik-ai-gateway-demo-system
kubectl -n fleet-local get helmops | grep "${NAMESPACE}"     # wait until empty
kubectl delete namespace "${NAMESPACE}"                      # PVCs, secrets, generated passwords
kubectl get pv | grep "${NAMESPACE}/"                        # Released volumes left by Retain classes
kubectl get clusterissuer "${NAMESPACE}-letsencrypt"         # cluster-scoped; should be gone with the release
```

## Known limits

- **Traefik Hub is pinned to v3.20.13.** Hub v3.20.14 and v3.21.1 (Traefik Proxy v3.7.14) reject every child IngressRoute, and the chat routing depends on them ([traefik/traefik#14016](https://github.com/traefik/traefik/issues/14016)). See [`docs/known-issues.md`](docs/known-issues.md), which also lists the other issues found during testing.

- **The vLLM model name is set in two places** (`vllm` and `traefik-ai-gateway`). Blueprint components cannot reference each other's values. vLLM also takes 90% of the GPU memory whatever the model size (`gpuMemoryUtilization: 0.90`); see [choosing the vLLM model](docs/prerequisites.md#51-choosing-the-vllm-model-for-your-gpu).
- **Open WebUI must reach `ai.${DOMAIN}` and `keycloak.${DOMAIN}` from inside the cluster.** If your load balancer cannot route traffic from the cluster back to itself, set `open-webui.hostAliases` to the Traefik ClusterIP in the wizard.
- **Generated secrets** (Redis password, vLLM key, OIDC client secret) use `helm lookup` to survive upgrades. If your Fleet version renders without cluster access, set them explicitly under `traefik-ai-gateway.secrets`.
- **Not yet verified on a live cluster:**
  - Milvus support in the semantic-cache plugin (verified on Hub v3.20.6 and v3.20.13). The plugin key can be switched with `semanticCachePluginKey: semantic-cache`.
  - Tuning of the `llama-guard3` prompt.
  - The `chat-completion` token header sent to vLLM.
  - Whether Open WebUI sends the user token during MCP tool discovery.
  - The data protection, jailbreak, failover, MCP rate limit and WAF features. They follow the Traefik Hub documentation and release notes, and each can be turned off on its own (`piiGuard`, `jailbreak`, `failover`, `mcpRateLimit`, `waf`).
  - Open WebUI with answer masking on (`piiGuard.maskResponses`): the answer is buffered, so it arrives in one piece instead of streamed.
