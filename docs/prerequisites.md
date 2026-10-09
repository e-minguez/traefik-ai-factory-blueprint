# Preparing the cluster

Everything the blueprint expects to exist before it is installed. The steps
assume an RKE2 cluster managed by Rancher, with the blueprint installed on the
`local` cluster in namespace `traefik-ai-gateway-demo-system`. Run `kubectl` against that cluster
unless a step says otherwise.

The commands below use the blueprint's domain. Set it once in your shell:

```shell
# <load-balancer-ip>.sslip.io (no DNS records needed) or your own wildcard DNS name
export DOMAIN=203.0.113.10.sslip.io
```

| # | Prerequisite | Check |
|---|---|---|
| 1 | Rancher + SUSE AI Factory | `kubectl get crd blueprints.ai-factory.suse.com` |
| 2 | Traefik Hub replaces the RKE2 ingress | `kubectl -n traefik get ds traefik` |
| 3 | cert-manager | `kubectl get crd certificates.cert-manager.io` |
| 4 | Default StorageClass | `kubectl get sc` shows `(default)` |
| 5 | GPU node with the NVIDIA GPU Operator | `kubectl get runtimeclass nvidia` |
| 6 | DNS, load balancer and outbound access | `curl http://ai.${DOMAIN}/` from outside reaches Traefik |

## Cluster sizing

What the blueprint asks for with its default values (blueprint 0.1.0, vLLM
model `Qwen/Qwen2.5-1.5B-Instruct`). This is on top of what Rancher, RKE2,
cert-manager and Traefik already use.

### Per component

"Requests" are what the scheduler reserves and "limits" are hard caps. "Typical
use" is an estimate of the steady-state memory. Several SUSE AI charts set no
requests, so their pods can land on any node, including the GPU node.

| Component | Pods | CPU request | Memory request / limit | Typical use | Storage (PVC) | Placement |
|---|---|---|---|---|---|---|
| `ollama` | 1 | 1 (limit 3) | 3Gi / 6Gi | 2.5-3 GB with the four models loaded | 20Gi | non-GPU node only (anti-affinity) |
| `vllm` engine | 1 | 4 + 1 GPU | 16Gi / - | GPU: 90% of its memory; host: a few GB | 50Gi (weights cache) | GPU node only |
| `vllm` router | 1 | 400m | 1000Mi / 1000Mi | < 500 MB | - | any |
| `milvus` (standalone, etcd, MinIO) | 3 | - | 512Mi for MinIO / - | 1.5-2 GB | 10Gi + 10Gi + 8Gi | any |
| `redis` | 1 | - | - | < 100 MB (rate-limit counters) | 8Gi | any |
| `open-webui` (+ its own Redis) | 2 | - | - | 1-1.5 GB (loads a RAG embedding model) | 2Gi | any |
| `traefik-ai-gateway`: Keycloak, ops MCP server, MCP Inspector, model catalog | 4 | 410m | 1.8Gi / 4Gi (Keycloak: 1.5Gi / 3Gi) | ~1.8 GB; Keycloak ~1.4 GiB steady, ~2.4 GiB peak at start | - (Keycloak re-imports its realm at start) | any |
| `opentelemetry-collector` | 1 | - | - / 512Mi | 100-200 MB | - | any |
| `suse-ai-observability-extension` | Job | - | - | runs once | - | any |

### Totals and recommended capacity

| | CPU | Memory | GPU | Storage |
|---|---|---|---|---|
| Requests, everything except the vLLM engine | ~1.8 | ~6.3 GiB | - | |
| Requests, vLLM engine | 4 | 16 GiB | 1 | |
| Typical memory use, everything except the vLLM engine | | ~9.5 GB | | |
| PersistentVolumeClaims | | | | ~108 GiB |
| **Recommended free capacity, non-GPU node(s)** | **4 vCPU** | **10 GiB** | | |
| **Recommended GPU node** | **6 vCPU** | **24 GiB** | **1 NVIDIA, 8 GB+** | |

- **Node disk.** Images are pulled to each node's
  `/var/lib/rancher/rke2/agent/containerd`. The vLLM image alone is several
  GB, so keep about 50 GB free on the GPU node. Volumes come on top of that
  when the StorageClass uses node-local disks (local-path).
- **The GPU node needs more RAM than vLLM's 16Gi request.** Pods without
  requests (Milvus, Redis, Open WebUI) may be scheduled there too.
- **Traefik needs more memory with the WAF.** Coraza compiles the Core Rule Set
  for each route that uses it (three by default), on the Traefik pods
  (control-plane nodes with the file's defaults). Not measured yet; watch
  `kubectl top pod -n traefik` after the install, or set
  `traefik-ai-gateway.waf.enabled: false`.
- **The guards add CPU work on Ollama, not memory.** The jailbreak judge uses
  `qwen2.5:0.5b`, which is already loaded. Each prompt now runs two small
  models in parallel before the chat model.
- **The first start downloads about 10 GB:** the Ollama models (~2.5 GB), the
  vLLM weights (3.1 GB) and the images.

### Smaller clusters

The values below are set in the install wizard. Maps such as `resources` merge
with the blueprint defaults; lists such as `modelSpec` replace them entirely
(see 5.1).

- **Ollama.** The request can go down to 2-3Gi with these small models. The
  limit should stay below the node's free memory, or the kubelet starts
  evicting pods when memory runs out.
- **vLLM host memory.** `servingEngineSpec.modelSpec[0].requestMemory` (16Gi)
  can go down to about 8Gi for the 1.5B model. This is a list value: repeat the
  whole `modelSpec` entry.
- **Optional parts.** In `traefik-ai-gateway`, `inspector.enabled: false`
  removes the MCP Inspector. Disabling `opentelemetry-collector` and
  `suse-ai-observability-extension` removes the observability stack.

Check what is free on each node before installing:

```shell
kubectl describe nodes | grep -E '^Name:|^  (cpu|memory) ' | paste - - -
kubectl get nodes -o custom-columns='NODE:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,GPU:.status.allocatable.nvidia\.com/gpu'
```

## 1. Rancher and SUSE AI Factory

Install the `aif-operator` chart, the `aif-ui` Rancher extension, and
configure your Application Collection credentials. The operator then manages
the `application-collection` ClusterRepo and the image pull secrets.

On a fresh cluster, install the operator with this blueprint's catalog already
registered (an existing operator gets the catalog in the README's "Register
the blueprint" step instead):

```shell
export AIF_CHART=oci://ghcr.io/suse/chart/aif-operator
export AIF_NAMESPACE=aif-operator
export AIF_VERSION=2.3.0
helm install aif-operator "${AIF_CHART}" --version "${AIF_VERSION}" \
  -n "${AIF_NAMESPACE}" --create-namespace \
  -f cluster/aif-operator-values.yaml
```

Check:

```shell
helm -n "${AIF_NAMESPACE}" list                       # aif-operator deployed
kubectl get crd blueprints.ai-factory.suse.com aiworkloads.ai-factory.suse.com
kubectl get clusterrepo application-collection
```

## 2. Traefik Hub instead of the embedded RKE2 ingress

The blueprint's routes, AI middlewares and MCP gateway need **Traefik Hub**,
which the ingress bundled with RKE2 is not. The embedded controller is
switched off and Traefik Hub is installed with RKE2's own Helm controller
(a `HelmChart` resource), so RKE2 keeps managing it.

The Rancher UI goes through the ingress controller, so it is unreachable
between steps 2.1 and 2.3. Keep a kubeconfig that does not depend on Rancher:
on a server node, `/etc/rancher/rke2/rke2.yaml` with
`/var/lib/rancher/rke2/bin/kubectl`.

### 2.1 Disable the embedded ingress controller

On **every** server (control-plane) node, one node at a time so etcd keeps
quorum:

```shell
echo "ingress-controller: none" | sudo tee /etc/rancher/rke2/config.yaml.d/99-disable-ingress.yaml
sudo systemctl restart rke2-server
```

Wait until the node is `Ready` again before moving to the next one. RKE2
versions without the `ingress-controller` option use
`disable: [rke2-ingress-nginx]` in the same file instead.

Check that the bundled chart and its pods are gone:

```shell
kubectl -n kube-system get helmchart | grep -E 'rke2-(traefik|ingress-nginx)'   # no output
kubectl get pods -A | grep -E 'rke2-(traefik|ingress-nginx)'                    # no output
```

The removal happens in the background, after the restarts. RKE2 deletes the
`HelmChart`, then a `helm-delete-*` job in `kube-system` uninstalls the
release, and only then do the pods terminate. This can take several minutes
after the last node is back. Wait until both commands return nothing before
installing Traefik Hub in 2.3: both controllers bind hostPorts 80/443, so the
new pods stay `Pending` on a node where an old pod is still running. To follow
the removal:

```shell
kubectl -n kube-system get jobs | grep -E 'helm-delete-rke2-(traefik|ingress-nginx)'
kubectl get pods -A -w | grep -E 'rke2-(traefik|ingress-nginx)'
```

### 2.2 Create the Traefik Hub license secret

Create a gateway on [hub.traefik.io](https://hub.traefik.io) and copy its
token. Store it in a secret named `traefik-hub-license` (key `token`) in
namespace `traefik`. It is created by hand, not in the HelmChart, so the token
is never stored in git or in the `kube-system` HelmChart object.

With the token in the clipboard, pipe it in. It never appears on screen or in
the shell history, and `tr` strips the trailing newline a copy often carries:

```shell
kubectl create namespace traefik
pbpaste | tr -d '[:space:]' | \
  kubectl -n traefik create secret generic traefik-hub-license --from-file=token=/dev/stdin
```

`pbpaste` is macOS. On Linux use `wl-paste` (Wayland) or `xclip -o -selection clipboard` (X11).
Without a clipboard tool, use `cat` instead. Paste the token, press Enter, then
Ctrl-D. The token is then shown in the terminal:

```shell
cat | tr -d '[:space:]' | \
  kubectl -n traefik create secret generic traefik-hub-license --from-file=token=/dev/stdin
```

Check the stored length matches the token (no stray characters):

```shell
kubectl -n traefik get secret traefik-hub-license -o jsonpath='{.data.token}' | base64 -d | wc -c
```

**If the secret already exists** because an earlier Traefik HelmChart created
it through `extraObjects`, do not recreate it. Annotate it instead. Helm deletes
objects that disappear from a release on upgrade, and the annotation stops it
from deleting this one:

```shell
kubectl -n traefik annotate secret traefik-hub-license helm.sh/resource-policy=keep
```

To rotate the token later:

```shell
pbpaste | tr -d '[:space:]' | \
  kubectl -n traefik create secret generic traefik-hub-license --from-file=token=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n traefik rollout restart ds/traefik
```

### 2.3 Install Traefik Hub

[`cluster/traefik-helmchart.yaml`](../cluster/traefik-helmchart.yaml) is a
complete `HelmChart`. Review the environment-specific settings first:

| Setting | Default in the file | Change it when |
|---|---|---|
| `deployment.kind`, `nodeSelector`, `tolerations` | DaemonSet on control-plane nodes only | your load balancer targets other nodes |
| `ports.{web,websecure,traefik}.hostPort` | 80, 443, 8080 | the load balancer forwards to other ports |
| `ports.{web,websecure}.proxyProtocol.trustedIPs` | `10.20.0.0/16` | set it to your load balancer's source subnet; remove both blocks if it does not send PROXY protocol |
| `service.type` | `ClusterIP` (traffic arrives via hostPorts) | you use a `LoadBalancer` service instead |
| OTLP endpoints | `otel-collector.traefik-ai-gateway-demo-system...` | the blueprint goes to another namespace; remove the `log.otlp`, `accessLog.otlp`, `metrics` and `tracing` blocks without SUSE Observability |
| `version`, `image.tag` | chart `41.7.0`, Hub image `v3.20.13` | only after checking [known issues](known-issues.md): Hub v3.20.14 and v3.21.1 break the chat routing |

The file also sets what the blueprint needs, whatever your environment:
`hub.aigateway` and `hub.mcpgateway` with their request-body size limits,
`providers.kubernetesCRD.allowExternalNameServices` (DeepWiki is reached
through an ExternalName service), and access logs that keep `X-User` /
`X-Groups` but drop `Authorization` and `Cookie`. The chart switches to the
`ghcr.io/traefik/traefik-hub` image by itself because `hub.token` is set.

Helm installs a chart's CRDs only on the first install and never upgrades
them. A newer Traefik Hub needs the CRDs of its chart, so apply them first,
on a fresh cluster and on every Traefik upgrade:

```shell
export TRAEFIK_CHART_VERSION=$(yq '.spec.version' cluster/traefik-helmchart.yaml)
tmp=$(mktemp -d)
helm pull oci://ghcr.io/traefik/helm/traefik --version "${TRAEFIK_CHART_VERSION}" --untar -d "$tmp"
kubectl apply --server-side --force-conflicts -f "$tmp/traefik/crds/"
```

Then install or upgrade Traefik:

```shell
kubectl apply -f cluster/traefik-helmchart.yaml
kubectl -n kube-system get job | grep helm-install-traefik     # Completed
kubectl -n traefik rollout status ds/traefik
```

### 2.4 Check Traefik

```shell
# Hub image and the flags the blueprint relies on
kubectl -n traefik get ds traefik -o jsonpath='{..image}{"\n"}'      # ghcr.io/traefik/traefik-hub:v3.20.13
kubectl -n traefik get ds traefik -o jsonpath='{..args}' | tr ',' '\n' \
  | grep -E 'aigateway|mcpgateway|allowExternalNameServices'

# Hub started with the license: pods Ready, Hub lease acquired, no errors
kubectl -n traefik get pods
kubectl -n traefik logs ds/traefik | grep -i 'license'        # "Gateway linked to the Traefik Hub platform, license validated"
kubectl -n traefik logs ds/traefik | grep -E 'ERR|FTL'    # no output

# Secret kept (only if you annotated it in 2.2)
kubectl -n traefik get secret traefik-hub-license

# Default IngressClass "traefik": cert-manager HTTP-01 solvers and Rancher use it
kubectl get ingressclass

# Access logs on stdout (JSON; Authorization and Cookie headers dropped)
kubectl -n traefik logs ds/traefik --tail=200 | grep RequestPath | tail -3

# Rancher still reachable through Traefik
kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.ingressClassName}{"\n"}'   # empty or traefik
RANCHER_HOST=$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[0].host}')
curl -ksS "https://${RANCHER_HOST}/healthz"; echo                                          # ok
```

The gateway also shows as online in the [hub.traefik.io](https://hub.traefik.io)
dashboard. A `WRN Traefik Hub can reject some encoded characters in the request
path` line at startup is informational, not a license problem. `-k` is there
because Rancher's default certificate comes from its own CA; drop it if Rancher
uses Let's Encrypt or your own certificate.

If the Rancher ingress still names the old class (`nginx`), point it at Traefik:

```shell
# The Helm repo Rancher was installed from (see `helm repo list`), and the
# installed chart version, so the upgrade changes nothing else
export RANCHER_CHART=rancher-stable/rancher
export RANCHER_VERSION=$(helm -n cattle-system list -f '^rancher$' -o json | jq -r '.[0].chart | sub("^rancher-"; "")')
helm upgrade rancher "${RANCHER_CHART}" -n cattle-system --version "${RANCHER_VERSION}" \
  --reuse-values --set ingress.ingressClassName=traefik
```

## 3. cert-manager

The blueprint creates a `ClusterIssuer` (Let's Encrypt) or a self-signed CA,
and a `Certificate`. Rancher installs that use Rancher-generated or Let's
Encrypt certificates already have cert-manager:

```shell
kubectl get crd certificates.cert-manager.io
kubectl -n cert-manager get pods
```

If it is missing, install it the same RKE2-native way (pin the version you
want):

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  chart: cert-manager
  repo: https://charts.jetstack.io
  targetNamespace: cert-manager
  createNamespace: true
  valuesContent: |-
    crds:
      enabled: true
```

## 4. Default StorageClass

Ollama, Milvus, Redis and Open WebUI request PersistentVolumeClaims without
naming a class, so the cluster needs exactly one **default** StorageClass.
Check what exists:

```shell
kubectl get storageclass
```

- **One class marked `(default)`**: nothing to do.
- **Classes exist, none marked `(default)`**: make one of them the default:

  ```shell
  export STORAGECLASS=longhorn    # a name from the list above
  kubectl patch storageclass "${STORAGECLASS}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  ```

- **More than one marked `(default)`**: Kubernetes uses the most recently
  created one. Set the annotation to `"false"` on the others (same command,
  with `STORAGECLASS` set to each of them) so the choice is explicit.
- **No StorageClass at all** (RKE2 ships none): install a provisioner, for
  example Longhorn from the Rancher Apps catalog, then mark its class as
  default as above.

With `volumeBindingMode: WaitForFirstConsumer` (local-path, some CSI drivers)
the blueprint's PVCs stay `Pending` until their pod is scheduled; that is
expected.

## 5. GPU node

vLLM needs one NVIDIA GPU, requested as `nvidia.com/gpu: 1`. Ollama runs on
CPU and is kept off nodes labelled `nvidia.com/gpu.present=true`, so the
cluster also needs a non-GPU node with about 1 CPU / 3 GiB free.

Install the NVIDIA GPU Operator. The RKE2 documentation
(<https://docs.rke2.io/advanced#deploy-nvidia-operator>) has the values for
RKE2's containerd. On SLE Micro / SLES the driver is often preinstalled on the
host (`driver.enabled: false`). Check:

```shell
kubectl get nodes -l nvidia.com/gpu.present=true
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
kubectl -n gpu-operator get pods      # all Running, validators Completed
```

**How GPUs reach the pods: two GPU Operator modes.** The blueprint must match
the one your operator uses:

| GPU Operator mode | How to tell | vLLM `servingEngineSpec.runtimeClassName` |
|---|---|---|
| **NRI / CDI injection** (gpu-operator v26+ with `cdi.nriPluginEnabled: true`) | `helm -n gpu-operator get values gpu-operator` shows `nriPluginEnabled: true`; the toolkit log shows `Started plugin 10-nvidia-toolkit` and `injecting CDI devices` | `""` (the blueprint default): the GPU is injected into any pod that requests `nvidia.com/gpu`, on the default runtime |
| **Runtime class** (classic toolkit mode) | containerd on the GPU node has an `nvidia` runtime; `kubectl get runtimeclass nvidia` exists and pods using it start | `nvidia`: set it in the install wizard under `vllm` |

In NRI mode a `RuntimeClass` named `nvidia` may still exist, while containerd
has no matching runtime. A pod that uses it stays in `ContainerCreating` with
`no runtime for "nvidia" is configured`. The vLLM chart defaults to `nvidia`,
which is why the blueprint sets it to `""`.

### 5.1 Choosing the vLLM model for your GPU

The default vLLM model is `Qwen/Qwen2.5-1.5B-Instruct`: 1.5B parameters,
3.1 GB of BF16 weights, Apache-2.0. It is chosen to download fast and run on
almost any NVIDIA GPU. The demo is about gateway policies, not answer quality.

**vLLM takes 90% of the GPU memory whatever the model.** The blueprint sets
`gpuMemoryUtilization: 0.90`. After loading the weights, vLLM fills the rest
with KV cache for concurrent requests. On a 16 GB GPU, `nvidia-smi` shows about
14.3 GB used by `VLLM::EngineCore` even with the 1.5B model. That is expected,
not a leak. Lower `gpuMemoryUtilization` only if something else shares the GPU.

Find the GPU memory per node (labels set by the GPU Operator's feature discovery):

```shell
kubectl get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns='NODE:.metadata.name,GPU:.metadata.labels.nvidia\.com/gpu\.product,MiB:.metadata.labels.nvidia\.com/gpu\.memory'
```

A model fits when its weights plus about 2.5 GB of overhead stay under 90% of
the GPU memory (CUDA graphs, activations, KV cache for `maxModelLen: 8192`).
Weight sizes are the Hugging Face download sizes. All models below are
ungated (no Hugging Face token) and Apache-2.0 unless noted.

| GPU memory | Example GPUs | Recommended | Weights | Also fits |
|---|---|---|---|---|
| 4-6 GB | T1000, A2-4Q vGPU | `Qwen/Qwen2.5-0.5B-Instruct` | 1.0 GB | |
| 8 GB | RTX 3070/4060, A2-8Q vGPU | `Qwen/Qwen2.5-1.5B-Instruct` (default) | 3.1 GB | |
| 12 GB | RTX 3060/4070 | `Qwen/Qwen2.5-7B-Instruct-AWQ` | 5.6 GB | `Qwen/Qwen2.5-3B-Instruct` (6.2 GB, Qwen Research license) |
| 16 GB | A2, A2-16Q vGPU, T4, A4000, V100-16 | `Qwen/Qwen2.5-7B-Instruct-AWQ` | 5.6 GB | `Qwen/Qwen2.5-14B-Instruct-AWQ` (10.0 GB, tight) |
| 24 GB | L4, A10, A30, RTX 3090/4090 | `Qwen/Qwen2.5-7B-Instruct` | 15.2 GB | `Qwen/Qwen2.5-14B-Instruct-AWQ` (10.0 GB) |
| 40-48 GB | A100-40, A40, L40S, RTX A6000 | `Qwen/Qwen2.5-14B-Instruct` | 29.5 GB | `Qwen/Qwen2.5-32B-Instruct-AWQ` (19.3 GB) |
| 80 GB | A100-80, H100 | `Qwen/Qwen2.5-32B-Instruct-AWQ` | 19.3 GB | `Qwen/Qwen2.5-32B-Instruct` (65.5 GB, tight); `Qwen/Qwen2.5-72B-Instruct-AWQ` (41.6 GB, Qwen license) |

Notes:

- **AWQ** models are 4-bit quantized, with about a third of the memory of
  BF16 and a small quality loss. vLLM detects the quantization from the model
  config, so no extra flag is needed. On 12-16 GB, a 7B AWQ model answers much
  better than a 3B BF16 one.
- **Older GPUs** (T4, V100: no BF16) run the BF16 checkpoints in FP16. vLLM
  falls back automatically.
- **Qwen3** works too, at similar sizes: `Qwen/Qwen3-8B-AWQ` (6.1 GB),
  `Qwen/Qwen3-14B-AWQ` (10.0 GB), `Qwen/Qwen3-32B-AWQ` (19.3 GB). It "thinks"
  by default, so answers start with a `<think>` block. For a gateway demo,
  Qwen2.5 gives shorter, cleaner answers.
- **vGPU profiles** (e.g. `A2-16Q`) expose only the profile's memory: size by
  the profile, not the physical card.

**Changing the model.** The name is set in two components, and both must be
equal. Traefik matches the request's `model` field against it and pins it in
the upstream request.

| Component | Value | Change when |
|---|---|---|
| `traefik-ai-gateway` | `vllmModel` | always |
| `vllm` | `servingEngineSpec.modelSpec[0].modelURL` | always |
| `vllm` | `servingEngineSpec.modelSpec[0].pvcStorage` (50Gi) | weights above ~30 GB |
| `vllm` | `servingEngineSpec.modelSpec[0].requestMemory` (16Gi) | weights above ~12 GB (host RAM while loading) |

AIWorkload values merge maps but **replace lists**. Overriding `modelSpec` in
the wizard or in `examples/aiworkload-local.yaml` therefore means repeating the
whole entry, not only `modelURL`. Copy it from the blueprint:

```shell
yq '.spec.components[] | select(.chartName=="vllm") | .values' blueprints/traefik-ai-gateway-demo-0.1.0.yaml
```

The scripts also need the name: `export VLLM_MODEL=<the same model>` before
running `scripts/verify.sh`.

## 6. DNS, load balancer and outbound access

- **Hostnames.** The blueprint serves `ai.${DOMAIN}`, `chat.${DOMAIN}`,
  `keycloak.${DOMAIN}` and `inspector.${DOMAIN}`. With
  [sslip.io](https://sslip.io), `DOMAIN` is `<load-balancer-ip>.sslip.io` and
  needs no DNS records. With your own domain, point a wildcard record at the
  load balancer. Check that every host resolves to the load balancer:

  ```shell
  for h in ai chat keycloak inspector; do echo "$h.${DOMAIN} -> $(dig +short "$h.${DOMAIN}")"; done
  ```

- **Load balancer.** Ports 80 and 443 forwarded to the Traefik nodes
  (control-plane nodes with the file's defaults). From outside the cluster:

  ```shell
  curl -sS -o /dev/null -w '%{http_code}\n' "http://ai.${DOMAIN}/"   # 404 from Traefik before the blueprint is installed
  ```

- **Let's Encrypt** (`tls.issuer=letsencrypt`, the default) validates over
  HTTP-01: port 80 of those four hosts must be reachable from the internet.
  Otherwise use `tls.issuer=selfsigned` and trust the generated CA.
  cert-manager registers an ACME account with Let's Encrypt for this. The
  optional `tls.acmeEmail` value is the contact address of that account, used
  only for account recovery and notices about the account. Certificates are
  issued without it, so leave it empty unless you want those notices.
- **In-cluster hairpin.** Open WebUI calls `https://ai.${DOMAIN}` and
  `https://keycloak.${DOMAIN}` from inside the cluster. Check from a pod
  (`${DOMAIN}` is expanded by your shell before the pod starts):

  ```shell
  kubectl run hairpin --rm -it --restart=Never --image=curlimages/curl -- \
    curl -sS -o /dev/null -w '%{http_code}\n' "http://ai.${DOMAIN}/"
  ```

  Any HTTP status (404 is fine before the blueprint is installed) means it
  works. A timeout means the load balancer does not hairpin: set
  `open-webui.hostAliases` to the Traefik ClusterIP in the install wizard
  (see the blueprint's open-webui values).
- **Outbound internet access** from the nodes:
  - `registry.ollama.ai` for the Ollama models;
  - `huggingface.co` for the vLLM weights and Open WebUI's embedding model;
  - `pypi.org` and `files.pythonhosted.org` for the ops MCP server and the vLLM init container, plus `bootstrap.pypa.io` (pip bootstrap in the vLLM init container);
  - `mcp.deepwiki.com` for DeepWiki;
  - `dp.apps.rancher.io` for the Application Collection;
  - `registry.suse.com` (BCI Python), `quay.io` (Keycloak) and `ghcr.io`
    (Traefik Hub, MCP Inspector);
  - `raw.githubusercontent.com` and `github.com` for this repository.
