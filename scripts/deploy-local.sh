#!/usr/bin/env bash
# deploy-local.sh - Local GPU (k3d) deployment
#
# Two-layer autoscaling on a local k3s cluster:
#   Layer 1 (pods): KEDA scales worker/vllm on Redis queue depth
#   Layer 2 (nodes): not applicable locally - run vLLM on the host GPU instead
#
# Prerequisites: k3d, kubectl, helm, docker
set -euo pipefail

CLUSTER_NAME="llm-gateway"
NAMESPACE="llm-gateway"

###############################################################################
# Dependency checks
###############################################################################
for cmd in k3d kubectl helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found in PATH."
    case "$cmd" in
      k3d) echo "  Install: https://k3d.io/#installation" ;;
      kubectl) echo "  Install: https://kubernetes.io/docs/tasks/tools/#kubectl" ;;
      helm) echo "  Install: https://helm.sh/docs/intro/install/" ;;
      docker) echo "  Install: https://www.docker.com/" ;;
    esac
    exit 1
  fi
done

echo "=== Phase 1: Local Deployment (k3d) ==="

# 1. Create k3d cluster with port mapping
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists, skipping creation."
else
  echo "Creating k3d cluster '$CLUSTER_NAME'..."
  k3d cluster create "$CLUSTER_NAME" --port "8080:80@loadbalancer"
fi

# 2. Build Docker images
echo "Building gateway image..."
docker build -t gateway:local ./gateway

echo "Building worker image..."
docker build -t worker:local ./worker

# 3. Import images into k3d (nodes use containerd, not the host docker daemon)
echo "Importing images into k3d cluster '$CLUSTER_NAME'..."
k3d image import gateway:local worker:local -c "$CLUSTER_NAME"

# 4. Install KEDA (if not already installed)
if ! kubectl get namespace keda &>/dev/null; then
  echo "Installing KEDA..."
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update
  helm install keda kedacore/keda --version 2.19.0 --namespace keda --create-namespace --wait
else
  echo "KEDA already installed, skipping."
fi

# 5. Install kube-state-metrics (for pod/node count Grafana panels)
if ! kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
  echo "Installing kube-state-metrics..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update
  helm install kube-state-metrics prometheus-community/kube-state-metrics --version 7.2.2 --namespace kube-system --wait
else
  echo "kube-state-metrics already installed, skipping."
fi

# 6. Create namespace and apply manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ -n "$NAMESPACE"

# 7. Patch worker for local: vLLM runs on the host, not in-cluster
echo "Patching worker VLLM_URL for local deployment..."
kubectl set env deployment/worker VLLM_URL=http://host.docker.internal:8000 -n "$NAMESPACE"

# 8. Apply monitoring stack
echo "Deploying monitoring stack (Prometheus + Grafana + DCGM)..."
kubectl apply -f monitoring/prometheus.yaml -n "$NAMESPACE"

# 9. Wait for rollouts
echo "Waiting for Redis..."
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=60s

echo "Waiting for Gateway..."
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=60s

echo ""
echo "=== Deployment Complete ==="
kubectl get all -n "$NAMESPACE"
echo ""
echo "Gateway:    http://localhost:8080"
echo "Grafana:    kubectl port-forward svc/grafana 3000:3000 -n $NAMESPACE"
echo "Prometheus: kubectl port-forward svc/prometheus 9090:9090 -n $NAMESPACE"
echo ""
echo "Next: start vLLM separately on the host GPU (required for inference):"
echo "  docker run --gpus all -p 8000:8000 --ipc=host \\"
echo "    vllm/vllm-openai:v0.19.0 --model Qwen/Qwen2.5-1.5B-Instruct \\"
echo "    --max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager"
echo ""
echo "Then run the load test:"
echo "  pip install locust"
echo "  locust -f loadtest/locustfile.py --host http://localhost:8080"
