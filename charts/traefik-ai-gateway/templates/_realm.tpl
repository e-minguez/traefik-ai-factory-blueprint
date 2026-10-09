{{/*
Keycloak realm "ai-factory": two groups, two personas, and two clients.
  ai-factory-cli  public, password grant (scripts, curl, Claude Code, Inspector)
  open-webui      confidential, authorization code (Open WebUI SSO)
Both clients map `groups` (routing and TBAC) and `repos` (DeepWiki scoping)
into the access token.
Usage: include "tag.realm" (dict "ctx" . "clientSecret" $secret)
*/}}
{{- define "tag.realm" -}}
{{- $ctx := .ctx -}}
{{- $chat := include "tag.chatHost" $ctx -}}
{{- $mappers := list
  (dict "name" "groups" "protocol" "openid-connect" "protocolMapper" "oidc-group-membership-mapper"
    "config" (dict "claim.name" "groups" "full.path" "false" "access.token.claim" "true" "id.token.claim" "true" "userinfo.token.claim" "true"))
  (dict "name" "repos" "protocol" "openid-connect" "protocolMapper" "oidc-usermodel-attribute-mapper"
    "config" (dict "user.attribute" "repos" "claim.name" "repos" "jsonType.label" "String" "multivalued" "true" "access.token.claim" "true" "id.token.claim" "true" "userinfo.token.claim" "true"))
-}}
{{- $realm := dict
  "realm" "ai-factory"
  "enabled" true
  "accessTokenLifespan" (int $ctx.Values.keycloak.accessTokenLifespan)
  "groups" (list (dict "name" "admins") (dict "name" "developers"))
  "users" (list
    (dict "username" "admin@ai-factory.demo" "email" "admin@ai-factory.demo" "firstName" "Ada" "lastName" "Admin"
      "enabled" true "emailVerified" true "requiredActions" list
      "credentials" (list (dict "type" "password" "value" $ctx.Values.secrets.demoAdminPassword "temporary" false))
      "groups" (list "/admins")
      "attributes" (dict "repos" (list "traefik/traefik" "traefik/traefik-helm-chart")))
    (dict "username" "dev@ai-factory.demo" "email" "dev@ai-factory.demo" "firstName" "Dev" "lastName" "Eloper"
      "enabled" true "emailVerified" true "requiredActions" list
      "credentials" (list (dict "type" "password" "value" $ctx.Values.secrets.demoDevPassword "temporary" false))
      "groups" (list "/developers")
      "attributes" (dict "repos" (list "traefik/traefik-helm-chart"))))
  "clients" (list
    (dict "clientId" "ai-factory-cli" "enabled" true "publicClient" true
      "directAccessGrantsEnabled" true "standardFlowEnabled" false
      "protocol" "openid-connect" "protocolMappers" $mappers)
    (dict "clientId" "open-webui" "name" "Open WebUI" "enabled" true "publicClient" false
      "secret" .clientSecret
      "standardFlowEnabled" true "directAccessGrantsEnabled" false
      "redirectUris" (list (printf "https://%s/oauth/oidc/callback" $chat))
      "webOrigins" (list (printf "https://%s" $chat))
      "attributes" (dict "post.logout.redirect.uris" (printf "https://%s/*" $chat))
      "protocol" "openid-connect" "protocolMappers" $mappers))
-}}
{{- toPrettyJson $realm -}}
{{- end -}}
