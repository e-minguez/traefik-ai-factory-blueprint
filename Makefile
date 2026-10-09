# Where this repository is published. The Helm repo is served from the repo/
# directory over HTTP (raw.githubusercontent.com by default; GitHub Pages or
# any static web server works too: override REPO_HTTP_URL).
REPO_OWNER    ?= e-minguez
REPO_NAME     ?= traefik-ai-factory-blueprint
BRANCH        ?= main
REPO_GIT_URL  ?= https://github.com/$(REPO_OWNER)/$(REPO_NAME).git
REPO_HTTP_URL ?= https://raw.githubusercontent.com/$(REPO_OWNER)/$(REPO_NAME)/$(BRANCH)/repo

CHART_DIR := charts/traefik-ai-gateway
TEST_SET  := --set domain=203.0.113.10.sslip.io

# SUSE AI charts the blueprint uses, as component=release, for validate-blueprint.
BLUEPRINT    := blueprints/traefik-ai-gateway-demo-0.1.0.yaml
APPCO_CHARTS := oci://dp.apps.rancher.io/charts

.PHONY: help lint template package clusterrepo validate-blueprint release

help:
	@echo "make lint                Lint the traefik-ai-gateway chart"
	@echo "make template            Render the chart with test values"
	@echo "make package             Package the chart into repo/ and regenerate repo/index.yaml"
	@echo "make clusterrepo         Regenerate cluster/clusterrepo.yaml and cluster/aif-operator-values.yaml"
	@echo "make validate-blueprint  Render every blueprint component against its SUSE AI chart (needs helm registry login dp.apps.rancher.io)"
	@echo "make release             lint + package + clusterrepo; then commit and push"

lint:
	helm lint $(CHART_DIR) $(TEST_SET)

template:
	helm template traefik-ai-gateway $(CHART_DIR) -n traefik-ai-gateway-demo-system $(TEST_SET)

# Absolute chart URLs in index.yaml, merged so older versions stay installable.
package: lint
	helm package $(CHART_DIR) -d repo
	helm repo index repo --url $(REPO_HTTP_URL) $(if $(wildcard repo/index.yaml),--merge repo/index.yaml)

clusterrepo:
	sed -i.bak -E 's#^  url: .*#  url: $(REPO_HTTP_URL)#' cluster/clusterrepo.yaml && rm -f cluster/clusterrepo.yaml.bak
	sed -i.bak -E 's#^    repoURL: .*#    repoURL: $(REPO_GIT_URL)#; s#^    branch: .*#    branch: $(BRANCH)#' cluster/aif-operator-values.yaml && rm -f cluster/aif-operator-values.yaml.bak

# Renders each application-collection component of the blueprint with its
# blueprint values (the operator adds pull secrets on top). The observability
# extension is expected to fail until serverUrl is set.
validate-blueprint:
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	for c in $$(yq -r '.spec.components[] | select(.chartRepo=="application-collection") | .chartName' $(BLUEPRINT)); do \
	  rel=$$(yq -r ".spec.components[] | select(.chartName==\"$$c\") | .releaseName" $(BLUEPRINT)); \
	  ver=$$(yq -r ".spec.components[] | select(.chartName==\"$$c\") | .chartVersion" $(BLUEPRINT)); \
	  yq ".spec.components[] | select(.chartName==\"$$c\") | .values" $(BLUEPRINT) > $$tmp/$$c.yaml; \
	  if helm template $$rel $(APPCO_CHARTS)/$$c --version $$ver -n traefik-ai-gateway-demo-system -f $$tmp/$$c.yaml >/dev/null 2>$$tmp/err; \
	  then echo "ok    $$c $$ver"; else echo "FAIL  $$c $$ver: $$(grep -m1 -i error $$tmp/err)"; fi; \
	done

release: package clusterrepo
	@echo "Now commit charts/, repo/, cluster/ and push to $(REPO_GIT_URL) ($(BRANCH))."
