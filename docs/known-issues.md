# Known issues

## Child IngressRoutes need Traefik Proxy v3.7.15 or later

The chat API uses multi-layer routing: the parent IngressRoute
(`chat-parent`) validates the Keycloak token and sets `X-Groups`, and the
child routes (`chat-children`, attached with `parentRefs`) match on
`X-Groups` and on the requested model. Traefik Proxy v3.7.14 rejected every
child IngressRoute
([traefik/traefik#14016](https://github.com/traefik/traefik/issues/14016)),
so chat requests got a 404. Proxy v3.7.15 fixes it.

Affected Hub releases are the ones built on Proxy v3.7.14: v3.20.14, v3.20.15,
v3.21.1 and v3.21.2. The blueprint pins Hub v3.21.3
([`cluster/traefik-helmchart.yaml`](../cluster/traefik-helmchart.yaml)). If you
pick another version, check that it ships Proxy v3.7.15 or later, then:

```shell
./scripts/chat.sh none qwen2.5:0.5b hi        # must be 401 (JWT on the parent route), not 404
kubectl -n traefik logs ds/traefik | grep 'no child routers could be added'   # must be empty
./scripts/verify.sh
```

## Other issues found during testing

| Issue | Where it is handled |
|---|---|
| vLLM stuck in `ContainerCreating`: `no runtime for "nvidia" is configured` (GPU Operator in NRI/CDI mode) | Blueprint sets `runtimeClassName: ""`; [prerequisites](prerequisites.md#5-gpu-node) |
| Keycloak OOMKilled at 1Gi and 2Gi (start-up build step peaks at ~2.4 GiB) | Chart default 1.5Gi request / 3Gi limit, heap capped at 50% |
| WAF denies every request: "CRS is deployed without configuration" (rule 901001) | Chart sets `tx.crs_setup_version` before `REQUEST-901-INITIALIZATION.conf` |
| Traefik log checks miss errors: the log is color-coded | Docs use `grep -E 'ERR\|FTL'`, not `' ERR '` |
| The workload stays `Degraded`: the vLLM bundle is `Modified`, because the AppCo vLLM chart hard-codes the label `app.kubernetes.io/managed-by: helm` while the live objects carry `Helm` | Cosmetic, vLLM works. The AIF Blueprint has no Fleet diff options to ignore it; needs a vLLM chart fix |
| Fleet reports components `NotReady` ("Available: 0/1") although their Deployments are available | Stale Fleet agent status after the install: `kubectl -n cattle-fleet-local-system rollout restart deploy/fleet-agent` |
| `redis-cli FLUSHALL` fails: `ERR unknown command` (disabled in the AppCo Redis) | Demo reset deletes the keys one by one ([demo guide](demo.md#reset-between-runs)) |
| Open WebUI spins on blocked requests: the AI middlewares wrap the deny message into an OpenAI answer (a stream for streaming requests) but keep the 403/429 status, which Open WebUI cannot parse | Open WebUI requests (`X-OpenWebUI-User-*` headers) use `-ui` copies of the deny-capable middlewares that answer 200. Exception: token budgets, whose Redis counters are keyed by middleware name, so a copy would split the budget; an exhausted budget shows nothing in Open WebUI |
| The same question to another model returned the first model's cached answer | One semantic-cache middleware and Milvus collection per model |
| Semantic cache answers a different question: "e-mail addresses for Globex" got the cached "Acme" answer (distance 0.063, threshold 0.1) | Trade-off of `semanticCache.maxDistance`: lower it (e.g. 0.05) for fewer wrong hits and fewer paraphrase hits |
| Masked text looks empty in Open WebUI (a run of `*` is a Markdown horizontal rule) | Mask character `X` |
| Open WebUI loads the MCP tool lists with the user's token (works), but `qwen2.5:0.5b` rarely calls tools | Demo tool calling with `agent.sh` / Inspector; show the tool lists in Open WebUI |
| Traefik access logs were not on stdout: with OTLP on, Traefik sends them only to the collector | `accessLog.dualOutput: true` in the Traefik HelmChart writes them to stdout too |
| A secret or injection phrase blocked once in an Open WebUI chat blocked every later message of that chat: content-guard scans the whole history (Open WebUI resends it), and in AI routes it switches to chat mode itself, ignoring `custom` mode and `jsonQueries` | Secrets and injection phrases are masked instead of blocked, in one masking rule with the personal data (with several masking rules only the last one applies) |
| Masked prompts look alike to the semantic cache ("Repeat: XXXX" and "XXXX and XXXX" got the same cached answer) | Harmless; the cache works on the masked text |
| Traefik restarted under load: liveness `/ping` (2 s timeout) timed out while Ollama's CPU inference saturated the 4-core control-plane node; Traefik had no CPU request; start-up took longer than the probe allowed | Traefik HelmChart: CPU/memory requests, 5 s probe timeouts, startup probe (up to 3 min); blueprint: Ollama CPU limit 2 |
| Failover answers are cached under the GPU model: after vLLM recovers, similar questions get the CPU model's cached answer for up to 5 minutes (cache `ttl`) | Expected with the cache after the failover; the demo uses fresh questions |
| Token budget act ended in HTTP 500 instead of 429: guard calls to Ollama timed out (30 s) while Ollama, limited to 2 CPUs and serving one request at a time, was busy | Ollama CPU limit 3, `OLLAMA_NUM_PARALLEL=2`, guard timeout 60 s |
| `demo-tls` stays not ready: Let's Encrypt `429 rateLimited: too many certificates (5) already issued for this exact set of identifiers in the last 168h` after several reinstalls with the same `domain` | Save and restore the `demo-tls` secret across reinstalls (README, "Uninstall"); or use another host name set, e.g. the dashed sslip.io form `194-14-81-230.sslip.io`; or `tls.issuer: selfsigned` |
| Fleet keeps using a cached chart when its version does not change | Reinstall the workload after rebuilding the same chart version |
| vLLM chat requests fail with HTTP 500 `No module named 'pydantic_extra_types'` (AppCo image `vllm-openai:0.19.0-5.20`: vLLM's chat path imports `mistral_common`, whose dependency is missing). `/v1/completions` works | Blueprint: an init container (same image) installs `pydantic-extra-types` and `pycountry` into an `emptyDir` on `PYTHONPATH`. Remove it once the image ships the package |
| vLLM update hangs: the new pod stays `Pending` while the old one holds the only GPU (chart default: rolling update, `maxSurge: 100%`) | Blueprint sets `servingEngineSpec.strategy.type: Recreate` |
| vLLM 0.19 crashes: `unrecognized arguments: --disable-log-requests` | Flag removed from the blueprint (request logging is off by default) |
| `llama-guard3:1b` flags some harmless prompts as unsafe, e.g. "Write a short reply to Anna confirming the refund." -> `unsafe S1` (6 of 7 sample prompts were classified correctly) | Demo prompts avoid it; a larger guard model (`llama-guard3:8b`) needs ~5 GB RAM on the Ollama node; or `llmGuard.enabled: false` |
