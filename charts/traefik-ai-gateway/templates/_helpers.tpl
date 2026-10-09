{{/* Fail early on the one value every install must set. */}}
{{- define "tag.domain" -}}
{{- required "domain is required (e.g. 203.0.113.10.sslip.io)" .Values.domain -}}
{{- end -}}

{{- define "tag.aiHost" -}}ai.{{ include "tag.domain" . }}{{- end -}}
{{- define "tag.chatHost" -}}chat.{{ include "tag.domain" . }}{{- end -}}
{{- define "tag.kcHost" -}}keycloak.{{ include "tag.domain" . }}{{- end -}}
{{- define "tag.inspectorHost" -}}inspector.{{ include "tag.domain" . }}{{- end -}}

{{/* The token issuer: the public Keycloak URL, pinned by KC_HOSTNAME. */}}
{{- define "tag.kcIssuer" -}}https://{{ include "tag.kcHost" . }}/realms/ai-factory{{- end -}}

{{/* JWKS fetched in-cluster by Traefik over plain http. */}}
{{- define "tag.kcJwks" -}}http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080/realms/ai-factory/protocol/openid-connect/certs{{- end -}}

{{/*
In-cluster address of a SUSE AI backend. Traefik runs in its own namespace,
so middleware configs need the fully qualified name.
Usage: include "tag.svc" (list . "redis")
*/}}
{{- define "tag.svc" -}}
{{- $ctx := index . 0 -}}
{{- $b := index $ctx.Values.backends (index . 1) -}}
{{- printf "%s.%s.svc.cluster.local:%v" $b.service $ctx.Release.Namespace $b.port -}}
{{- end -}}

{{/*
A secret value: the explicit value if set, else the value already stored in
the cluster (so upgrades do not rotate it), else a new random one.
Usage: include "tag.secretValue" (list . "secret-name" "key" .Values.secrets.x)
*/}}
{{- define "tag.secretValue" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $key := index . 2 -}}
{{- $explicit := index . 3 -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace $name -}}
{{- if and $existing (hasKey $existing.data $key) -}}
{{- index $existing.data $key | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "tag.labels" -}}
app.kubernetes.io/part-of: traefik-ai-gateway
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* X-Groups regex tolerating JSON-array serialization of the groups claim. */}}
{{- define "tag.groupMatch" -}}
HeaderRegexp(`X-Groups`, `(^|[,\s"\[])
{{- . -}}
([,\s"\]]|$)`)
{{- end -}}

{{/*
Middleware chain of an allowed chat route, outermost first:
masking of personal data, secrets and injection phrases (all messages; data
and secrets also in the answer), LLM guards, model
pinning (chat-completion; empty when a failover TraefikService does it at the
service level), token budgets, semantic cache. The cache is innermost, so the
guards and the budgets apply to cached answers too.
Usage: include "tag.aiChain" (dict "ctx" $ "cc" "cc-vllm" "group" "admins" "model" "<model>" "ui" false)
With "ui" true the deny-capable middlewares are the -ui (HTTP 200) variants.
*/}}
{{- define "tag.aiChain" -}}
{{- $v := .ctx.Values -}}
{{- $s := ternary "-ui" "" (default false .ui) -}}
{{- if or $v.piiGuard.enabled $v.jailbreak.patterns }}
        - name: pii-guard
{{- end }}
{{- if include "tag.guardName" .ctx }}
        - name: {{ include "tag.guardName" .ctx }}{{ $s }}
{{- end }}
{{- if .cc }}
        - name: {{ .cc }}
{{- end }}
        - name: rl-{{ .group }}-group
        - name: rl-{{ .group }}-user
        - name: {{ include "tag.cacheName" .model }}
{{- end -}}

{{/* Name of the per-model semantic-cache middleware. */}}
{{- define "tag.cacheName" -}}
semantic-cache-{{ regexReplaceAll "[^a-z0-9]+" (lower .) "-" | trimAll "-" | trunc 40 | trimSuffix "-" }}
{{- end -}}

{{/*
The LLM guard middleware of the chat routes: "ai-guards" (parallel-llm-guard)
when the jailbreak judge runs next to llama-guard3, "llm-guard" for the safety
guard alone, empty when both are off.
*/}}
{{- define "tag.guardName" -}}
{{- if .Values.jailbreak.judge.enabled -}}ai-guards
{{- else if .Values.llmGuard.enabled -}}llm-guard
{{- end -}}
{{- end -}}

{{/*
GenAI observability of a chat-completion middleware. Detailed metrics need
Traefik Hub v3.21 or later (aiMetrics.detailed=false on older Hubs).
*/}}
{{- define "tag.ccObservability" -}}
{{- if .Values.aiMetrics.detailed }}
      observability:
        metrics:
          level: detailed
{{- end }}
{{- end -}}

{{/* Secrets masked by pii-guard (Go RE2). */}}
{{- define "tag.secretPatterns" -}}
- '\bsk-[A-Za-z0-9_-]{20,}'
- '\bgh[pousr]_[A-Za-z0-9]{36}\b'
- '\bAKIA[0-9A-Z]{16}\b'
- '-----BEGIN [A-Z ]*PRIVATE KEY-----'
{{- end -}}

{{/* Personal data masked by pii-guard (Go RE2): IBAN, e-mail, card number, international phone number. */}}
{{- define "tag.piiPatterns" -}}
- '\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b'
- '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
- '\b(?:\d[ -]?){12,18}\d\b'
- '\+\d{1,3}[ .-]?\(?\d{1,4}\)?(?:[ .-]?\d{2,4}){2,4}'
{{- end -}}

{{/* Matches requests sent by Open WebUI (ENABLE_FORWARD_USER_INFO_HEADERS). */}}
{{- define "tag.openWebUIMatch" -}}
HeaderRegexp(`X-OpenWebUI-User-Id`, `.+`)
{{- end -}}

{{/* Prompt-injection phrases masked by pii-guard (Go RE2). */}}
{{- define "tag.injectionPatterns" -}}
- '(?i)(ignore|disregard|forget)\s+(all\s+)?(the\s+)?(previous|prior|above|earlier|your)\s+(instructions|rules|prompts|guidelines)'
- '(?i)(reveal|print|show|repeat|output)\s+(me\s+)?(your|the)\s+(system\s+prompt|hidden\s+instructions|initial\s+instructions)'
- '(?i)you\s+are\s+now\s+(DAN|in\s+developer\s+mode|jailbroken|unrestricted)'
- '(?i)\bact\s+as\s+(DAN|an?\s+unrestricted\s+(AI|assistant|model))\b'
{{- end -}}
