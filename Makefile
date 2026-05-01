.PHONY: setup teardown build push deploy health pay logs status clean

CLUSTER   := rbih-payments
REGISTRY  := localhost:5001
NS        := payments
GW_URL    := http://localhost:8080

## ── Bootstrap ────────────────────────────────────────────────────────────────
setup:          ## Full one-command cluster setup
	@chmod +x scripts/setup.sh && ./scripts/setup.sh

teardown:       ## Destroy the kind cluster and local registry
	@chmod +x scripts/teardown.sh && ./scripts/teardown.sh

## ── Build & Push ─────────────────────────────────────────────────────────────
build:          ## Build both Docker images
	docker build -t $(REGISTRY)/payment-gateway:1.0.0   services/payment-gateway
	docker build -t $(REGISTRY)/payment-processor:1.0.0 services/payment-processor

push: build     ## Push images to local registry
	docker push $(REGISTRY)/payment-gateway:1.0.0
	docker push $(REGISTRY)/payment-processor:1.0.0

## ── Deploy ───────────────────────────────────────────────────────────────────
deploy:         ## Apply all Kubernetes manifests
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/base/payment-gateway.yaml
	kubectl apply -f k8s/base/payment-processor.yaml
	kubectl apply -f k8s/base/reliability.yaml
	kubectl apply -f k8s/network-policy/network-policies.yaml
	kubectl apply -f k8s/monitoring/monitoring.yaml

rollout:        ## Trigger a rolling restart of both deployments
	kubectl rollout restart deployment/payment-gateway  -n $(NS)
	kubectl rollout restart deployment/payment-processor -n $(NS)
	kubectl rollout status  deployment/payment-gateway  -n $(NS) --timeout=120s
	kubectl rollout status  deployment/payment-processor -n $(NS) --timeout=120s

## ── Port-forward ─────────────────────────────────────────────────────────────
forward-gw:     ## Port-forward payment-gateway to localhost:8080
	kubectl port-forward svc/payment-gateway 8080:8080 -n $(NS)

forward-prom:   ## Port-forward Prometheus to localhost:9090
	kubectl port-forward svc/prometheus 9090:9090 -n monitoring

forward-grafana: ## Port-forward Grafana to localhost:3000
	kubectl port-forward svc/grafana 3000:3000 -n monitoring

## ── Smoke Tests ──────────────────────────────────────────────────────────────
health:         ## Check /healthz on payment-gateway
	@curl -sf $(GW_URL)/healthz | jq .

metrics:        ## Fetch Prometheus metrics
	@curl -sf $(GW_URL)/metrics | head -40

pay:            ## Send a sample payment
	@curl -sf -X POST $(GW_URL)/pay \
	  -H 'Content-Type: application/json' \
	  -d '{"amount":1500.00,"currency":"INR","reference":"test-$(shell date +%s)"}' | jq .

## ── Observability ────────────────────────────────────────────────────────────
logs-gw:        ## Tail payment-gateway logs
	kubectl logs -l app=payment-gateway  -n $(NS) -f --tail=50

logs-proc:      ## Tail payment-processor logs
	kubectl logs -l app=payment-processor -n $(NS) -f --tail=50

status:         ## Show pod and service status
	@echo "\n=== Pods ==="
	kubectl get pods    -n $(NS) -o wide
	@echo "\n=== Services ==="
	kubectl get svc     -n $(NS)
	@echo "\n=== HPA ==="
	kubectl get hpa     -n $(NS)
	@echo "\n=== NetworkPolicies ==="
	kubectl get netpol  -n $(NS)

## ── Cleanup ──────────────────────────────────────────────────────────────────
clean:          ## Delete payments namespace (keeps cluster)
	kubectl delete namespace $(NS) --ignore-not-found
	kubectl delete namespace monitoring --ignore-not-found

help:           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'
