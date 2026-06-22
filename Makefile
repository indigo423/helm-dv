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
kubeconform: ## Schema-validate rendered manifests
	helm template $(CHART_NAME) $(CHART) | \
	  kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default
	helm template $(CHART_NAME) $(CHART) -f $(CHART)/values-demo.yaml | \
	  kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default

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
	# Install the DEMO preset (first-party postgres/kafka via demoBackingServices,
	# delivered as pre-install hooks) overlaid with the lean CI subset. The
	# db-init hook waits on the demo postgres; daemon readiness (slow cold image
	# pulls + provisiond boot) is awaited explicitly below with diagnostics.
	helm upgrade --install $(CHART_NAME) $(CHART) \
	  -f $(CHART)/values-demo.yaml -f $(CHART)/ci/kind-values.yaml --timeout 600s
	@echo "=== waiting for daemons + backing + ingress (cold image pulls can be slow) ==="
	kubectl wait --for=condition=Available --timeout=600s \
	  deploy/postgres deploy/kafka \
	  deploy/$(CHART_NAME)-alarmd deploy/$(CHART_NAME)-provisiond \
	  deploy/$(CHART_NAME)-trapd deploy/$(CHART_NAME)-bsmd \
	  deploy/$(CHART_NAME)-envoy deploy/$(CHART_NAME)-minion-gateway \
	  || { echo "=== DIAGNOSTICS ==="; \
	       kubectl get pods -o wide; \
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
