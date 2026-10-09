# Known issues

## Traefik Proxy v3.7.14 rejects every child IngressRoute (Hub v3.20.14, v3.21.1)

**Status:** confirmed upstream bug, fix announced:
[traefik/traefik#14016](https://github.com/traefik/traefik/issues/14016)
(our report [#14032](https://github.com/traefik/traefik/issues/14032) is a
duplicate of it). The code was checked on 2026-10-09 against the Traefik
`v3.7` and `master` branches. **Workaround in this repository:** Traefik Hub is pinned to
**v3.20.13** ([`cluster/traefik-helmchart.yaml`](../cluster/traefik-helmchart.yaml)).

| Traefik Hub | Traefik Proxy | Child IngressRoutes |
|---|---|---|
| v3.20.6 to v3.20.13 | v3.7.13 or older | work (v3.20.6 and v3.20.13 tested) |
| v3.21.0 | v3.7.13 | should work (not tested) |
| **v3.20.14, v3.21.1** | **v3.7.14** | **rejected** (both tested) |

The Proxy versions come from the Hub release notes. Traefik chart 41.6.1 and
later default to an affected Hub version, so the chart's image tag is pinned.

### Symptoms

With an affected version:

- `POST https://ai.${DOMAIN}/v1/chat/completions` returns **404** for every
  caller, including requests without a token. The parent route never gets as
  far as the JWT check.
- The Traefik log repeats, with no further detail:

  ```text
  ERR error="building child routers muxer: no child routers could be added to muxer (5 skipped)"
      routerName=traefik-ai-gateway-demo-system-chat-parent-...@kubernetescrd
  ```

- The middlewares of the child routes are fine: the same middlewares on a
  top-level IngressRoute build without errors.

### Why this breaks the blueprint

The chat API uses multi-layer routing. The parent IngressRoute (`chat-parent`)
validates the Keycloak token, and the `gateway-jwt` middleware sets the
`X-Groups` header from it. The child routes (`chat-children`, attached with
`parentRefs`) then match on `X-Groups` and on the requested model (`Model()`).
Matching on a header that a middleware sets is only possible with child
routes. Without them, nothing routes chat requests.

### Root cause

A regression in Traefik Proxy **v3.7.14**, from the upstream commit
[`a39758f925`](https://github.com/traefik/traefik/commit/a39758f925) "Expose
IngressRoute metadata in access logs" (2026-09-08), in how the Kubernetes CRD
provider builds routers:

1. **The CRD provider gives every IngressRoute router an observability block**,
   child routes included, to carry ingress metadata
   (`pkg/provider/kubernetes/crd/kubernetes_http.go`, v3.7 and `master`):

   ```go
   r := &dynamic.Router{
       ...
       ParentRefs:  parentRouterNames,
       Observability: &dynamic.RouterObservabilityConfig{
           Metadata: &dynamic.ObservabilityMetadata{
               Ingress: buildIngressRouteMetadata(ingressRoute),
           },
       },
   }
   ```

2. **The router manager rejects any child router with an observability block**
   (`pkg/server/router/router.go`):

   ```go
   // Check for non-root router with Observability config.
   if router.Observability != nil {
       router.AddError(errors.New("non-root router cannot have Observability configuration"), true)
       continue
   }
   ```

3. **The rejected children are then skipped silently** when the parent's
   child muxer is built (`buildChildRoutersMuxer`: `if len(childRouter.Err) > 0
   { continue }`). That only logs the generic "no child routers could be added
   to muxer" error.

Before that commit (Traefik v3.6, and v3.7 up to v3.7.13), the provider only
copied the route's own `observability` field (`Observability:
route.Observability`), which is nil unless the IngressRoute sets it. The same
check in `router.go` therefore passed. The default-observability code in `pkg/server/aggregator.go` already
skips child routers on purpose ("Only root routers can have models applied"),
so the behavior in v3.7 looks unintended.

It does not depend on this chart. Any IngressRoute with `parentRefs` hits it
on Traefik v3.7.14. The minimal reproduction below also failed on the cluster
with Hub v3.20.14, without any middleware.

### Minimal reproduction

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: parent
spec:
  entryPoints: [web]
  routes:
    - kind: Rule
      match: Host(`repro.example.com`)
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: child
spec:
  parentRefs:
    - name: parent
  routes:
    - kind: Rule
      match: PathPrefix(`/`)
      services:
        - name: whoami
          port: 80
```

- **Traefik Proxy v3.7.13 / Hub v3.20.13:** `curl -H 'Host: repro.example.com' http://<traefik>/` reaches `whoami`.
- **Traefik Proxy v3.7.14 / Hub v3.20.14 or v3.21.1:** 404, and the log shows `no child routers could be added to muxer (1 skipped)`.

### Checking whether a newer version fixes it

Before moving the pin to a newer Hub version:

1. Look at `pkg/provider/kubernetes/crd/kubernetes_http.go` in the matching
   Traefik release. Child routers must not get a non-nil `Observability`, or
   `router.go` must accept metadata-only observability on child routers.
2. Or test on the cluster. Change `image.tag` in
   `cluster/traefik-helmchart.yaml`, apply it, then:

   ```shell
   ./scripts/chat.sh none qwen2.5:0.5b hi        # must be 401 (JWT on the parent route), not 404
   kubectl -n traefik logs ds/traefik | grep 'no child routers could be added'   # must be empty
   ./scripts/verify.sh
   ```

### Consequences of the pin

- `traefik-ai-gateway.aiMetrics.detailed` stays `false`. Detailed GenAI
  metrics (`observability.metrics.level: detailed`) arrived in v3.21.
  OpenTelemetry traces, metrics and access logs still work.
- Everything else in the blueprint (AI gateway, MCP gateway, WAF, failover,
  PII masking) is supported and was verified on v3.20.13.
- Hub v3.21.0 (Proxy v3.7.13) should also be unaffected, and would bring
  detailed metrics, but it was not tested.

### Upstream issue

Tracked in [traefik/traefik#14016](https://github.com/traefik/traefik/issues/14016)
("Observability Metadata break non-root router", labelled
`kind/bug/confirmed`; a maintainer announced a fix on 2026-10-08). The
change that introduced it is PR
[#12985](https://github.com/traefik/traefik/pull/12985) (commit `a39758f925`).
Our report, [#14032](https://github.com/traefik/traefik/issues/14032), is a
duplicate with the Traefik Hub versions and a minimal reproduction. Once a
fixed Traefik Proxy release is out, check it as described above and move the
image pin in `cluster/traefik-helmchart.yaml`.

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
