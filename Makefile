SHELL := /bin/bash
K := kubectl
POLARIS_CHART_VERSION := 1.8.0
SPARK_OPERATOR_CHART_VERSION := 2.5.2
IMAGE := spark-iceberg:3.5

.PHONY: all cluster up secrets storage polaris bootstrap operator image jobs-cm \
        run-smoke run-reader run-migrate run-access demo status ui down destroy console-image console

all: up bootstrap operator image console-image console demo

cluster:            ## Arranca minikube (ajusta memoria a lo que tenga Docker Desktop)
	minikube status >/dev/null 2>&1 || minikube start --driver=docker --cpus=6 --memory=7000

up: cluster secrets storage polaris   ## Infra base: S3, Postgres y Polaris

secrets:
	$(K) apply -f k8s/namespaces.yaml
	./scripts/gen-secrets.sh

storage:
	$(K) apply -f k8s/s3.yaml -f k8s/postgres.yaml
	$(K) -n lakehouse rollout status statefulset/seaweedfs --timeout=180s
	$(K) -n lakehouse rollout status statefulset/postgres --timeout=180s
	$(K) -n lakehouse wait --for=condition=complete job/create-bucket --timeout=180s

polaris:
	$(K) apply -f k8s/polaris-bootstrap-job.yaml
	$(K) -n lakehouse wait --for=condition=complete job/polaris-bootstrap --timeout=300s
	helm repo add polaris https://downloads.apache.org/polaris/helm-chart >/dev/null 2>&1 || true
	helm repo update polaris >/dev/null
	helm upgrade --install polaris polaris/polaris --version $(POLARIS_CHART_VERSION) \
	  -n lakehouse -f helm/polaris-values.yaml --wait --timeout 5m

bootstrap:          ## Catálogo, principal spark, roles y grants en Polaris
	./polaris/bootstrap.sh

operator:           ## Kubeflow Spark Operator
	helm repo add spark-operator https://kubeflow.github.io/spark-operator >/dev/null 2>&1 || true
	helm repo update spark-operator >/dev/null
	helm upgrade --install spark-operator spark-operator/spark-operator \
	  --version $(SPARK_OPERATOR_CHART_VERSION) -n spark-operator --create-namespace \
	  -f helm/spark-operator-values.yaml --wait --timeout 5m

image:              ## Construye la imagen Spark+Iceberg dentro de minikube
	minikube image build -t $(IMAGE) spark/

jobs-cm:
	$(K) -n spark-jobs create configmap lakehouse-jobs --from-file=jobs/ \
	  --dry-run=client -o yaml | $(K) apply -f -

define run_app
	$(K) -n spark-jobs delete sparkapplication iceberg-$(1) --ignore-not-found
	$(K) apply -f k8s/sparkapps/$(1).yaml
	@echo "Esperando a iceberg-$(1)..."
	@for i in $$(seq 120); do \
	  s=$$($(K) -n spark-jobs get sparkapplication iceberg-$(1) -o jsonpath='{.status.applicationState.state}' 2>/dev/null); \
	  case "$$s" in COMPLETED) break;; FAILED|SUBMISSION_FAILED) echo "Estado: $$s"; break;; esac; sleep 5; done
	-$(K) -n spark-jobs logs iceberg-$(1)-driver | grep -vE "^\s*$$|WARN|INFO" | tail -80
	@test "$$($(K) -n spark-jobs get sparkapplication iceberg-$(1) -o jsonpath='{.status.applicationState.state}')" = COMPLETED
endef

run-smoke: jobs-cm
	$(call run_app,smoke)
run-reader: jobs-cm
	$(call run_app,reader)
run-migrate: jobs-cm
	$(call run_app,migrate)
run-access: jobs-cm
	$(call run_app,access)

demo: run-smoke run-reader run-migrate run-access   ## Ejecuta los cuatro jobs en orden

status:
	$(K) get pods -n lakehouse; $(K) get pods -n spark-operator; $(K) get sparkapplications -n spark-jobs

console-image:      ## Construye la Polaris Console (apache/polaris-tools, sin imagen oficial publicada)
	rm -rf .build/polaris-tools
	git clone -q --depth 1 https://github.com/apache/polaris-tools.git .build/polaris-tools
	cd .build/polaris-tools/console && minikube image build -t polaris-console:local -f docker/Dockerfile .

console:            ## Despliega la Polaris Console
	$(K) apply -f k8s/polaris-console.yaml
	$(K) -n lakehouse rollout status deploy/polaris-console --timeout=120s

ui:                 ## Port-forwards: Console :8080, Polaris API :8181, explorador S3 :8888, S3 :8333 (Ctrl+C para cerrar)
	@echo "Polaris Console   -> http://localhost:8080   (usuario root, password: .secrets/polaris_root_secret)"
	@echo "Explorador S3     -> http://localhost:8888/buckets/warehouse/"
	@echo "API Polaris / S3  -> http://localhost:8181 / http://localhost:8333"
	$(K) -n lakehouse port-forward svc/polaris 8181:8181 & \
	$(K) -n lakehouse port-forward svc/polaris-console 8080:8080 & \
	$(K) -n lakehouse port-forward pod/seaweedfs-0 8888:8888 & \
	$(K) -n lakehouse port-forward svc/seaweedfs 8333:8333; \
	kill %1 %2 %3 2>/dev/null

down:               ## Borra los recursos (mantiene minikube)
	-helm uninstall spark-operator -n spark-operator
	-helm uninstall polaris -n lakehouse
	-$(K) delete ns spark-jobs lakehouse spark-operator

destroy:            ## Borra el cluster minikube entero
	minikube delete
