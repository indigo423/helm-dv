# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# ==============================================================================
# helm-dv — Delta-V Helm chart front door.
#
# CI invokes these targets (never the underlying tooling directly), so local and
# CI behaviour stay in lock-step. See .github/workflows/.
#
#   make deps         Vendor subchart dependencies (helm dependency update)
#   make lint         chart-testing lint (ct lint)
#   make unittest     helm-unittest suites
#   make template     Render both presets to stdout
#   make kubeconform  Schema-validate rendered manifests
#   make docs         Regenerate chart READMEs from README.md.gotmpl (helm-docs)
#   make docs-check   Fail if the committed README is stale
#   make package      Package the chart into ./.cr-release-packages
#   make kind-test    Install onto the current kind context + smoke test
#   make verify       deps + lint + unittest + kubeconform + docs-check
# ==============================================================================

CHART        ?= charts/deltav
CHART_NAME   ?= deltav

# CloudNativePG operator (assume-installed prerequisite for managed/demo modes).
CNPG_CHART_VERSION ?= 0.28.3
# Extra kubeconform schema source for CRDs (CNPG Cluster, etc.) not in the core set.
CRD_SCHEMA_LOCATION ?= https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## Vendor subchart dependencies
	helm dependency update $(CHART)

.PHONY: lint
lint: ## chart-testing lint (requires ct on PATH)
	ct lint --config ct.yaml --charts $(CHART)

.PHONY: helm-lint
helm-lint: ## Plain helm lint (no ct)
	helm lint $(CHART)

.PHONY: unittest
unittest: ## Run helm-unittest suites
	helm unittest $(CHART)

.PHONY: template
template: ## Render both presets to stdout
	helm template $(CHART_NAME) $(CHART)
	helm template $(CHART_NAME) $(CHART) -f $(CHART)/values-demo.yaml

.PHONY: kubeconform
kubeconform: ## Schema-validate rendered manifests (incl. CNPG Cluster CRD)
	helm template $(CHART_NAME) $(CHART) | \
	  kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default \
	    -schema-location '$(CRD_SCHEMA_LOCATION)'
	helm template $(CHART_NAME) $(CHART) -f $(CHART)/values-demo.yaml | \
	  kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default \
	    -schema-location '$(CRD_SCHEMA_LOCATION)'

.PHONY: docs
docs: ## Regenerate chart READMEs from README.md.gotmpl
	helm-docs --chart-search-root=charts --template-files=README.md.gotmpl

.PHONY: docs-check
docs-check: docs ## Fail if the committed README is stale
	@git diff --exit-code -- '$(CHART)/README.md' || \
	  { echo 'README.md is stale — run `make docs` and commit.'; exit 1; }

.PHONY: package
package: deps ## Package the chart
	helm package $(CHART) --destination .cr-release-packages

.PHONY: kind-test
kind-test: deps ## Install the self-contained demo onto the current kind context + smoke test
	@echo "Context: $$(kubectl config current-context)"
	# The demo preset uses mode: demo → a CloudNativePG-managed PostgreSQL Cluster
	# (operator is an assume-installed prerequisite). Install the pinned operator
	# first, then the chart. Kafka is still the first-party demo Deployment.
	@echo "=== installing CloudNativePG operator $(CNPG_CHART_VERSION) ==="
	helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
	helm repo update cnpg >/dev/null
	helm upgrade --install cnpg cnpg/cloudnative-pg \
	  --namespace cnpg-system --create-namespace \
	  --version $(CNPG_CHART_VERSION) --wait --timeout 300s
	kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=300s
	# Install the DEMO preset overlaid with the lean CI subset. db-init is a
	# post-install hook (the Cluster is a normal resource); daemon readiness (slow
	# cold image pulls + provisiond boot) is awaited explicitly below.
	helm upgrade --install $(CHART_NAME) $(CHART) \
	  -f $(CHART)/values-demo.yaml -f $(CHART)/ci/kind-values.yaml --timeout 600s
	@echo "=== waiting for the CNPG postgres Cluster to be Ready ==="
	kubectl wait --for=condition=Ready --timeout=300s cluster/$(CHART_NAME)-pg \
	  || { echo "=== CNPG CLUSTER DIAGNOSTICS ==="; \
	       kubectl get cluster,pods -o wide; \
	       kubectl describe cluster/$(CHART_NAME)-pg | tail -30; \
	       exit 1; }
	@echo "=== waiting for daemons + backing + ingress (cold image pulls can be slow) ==="
	kubectl wait --for=condition=Available --timeout=600s \
	  deploy/kafka \
	  deploy/$(CHART_NAME)-alarmd deploy/$(CHART_NAME)-provisiond \
	  deploy/$(CHART_NAME)-trapd deploy/$(CHART_NAME)-bsmd \
	  deploy/$(CHART_NAME)-envoy deploy/$(CHART_NAME)-minion-gateway \
	  || { echo "=== DIAGNOSTICS ==="; \
	       kubectl get cluster,pods -o wide; \
	       kubectl get events --sort-by=.lastTimestamp | tail -40; \
	       kubectl describe deploy/$(CHART_NAME)-provisiond | tail -25; \
	       kubectl logs deploy/$(CHART_NAME)-alarmd --tail=50 || true; \
	       exit 1; }
	@echo "=== smoke: alarmd /actuator/health ==="
	kubectl exec deploy/$(CHART_NAME)-alarmd -- \
	  curl -sf http://localhost:8080/actuator/health | grep -q '"status":"UP"'
	@echo "kind-test OK"

.PHONY: verify
verify: deps lint unittest kubeconform docs-check ## Full local quality gate
	@echo "verify OK"
