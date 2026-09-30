#!/usr/bin/env bash
# Run the whole GitOps setup on your laptop:
#   kind cluster -> Argo CD -> release-info (dev) synced from this GitHub repo
#   optional: kube-prometheus-stack + the Grafana dashboard (pass --monitoring)
# Needs: docker, kind, kubectl (and helm for --monitoring).
set -euo pipefail
CLUSTER=gitops-demo
ARGOCD_VERSION=v2.12.4

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
kubectl config use-context "kind-$CLUSTER"

echo "Installing Argo CD $ARGOCD_VERSION..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s

kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application-dev.yaml
echo "Waiting for Argo CD to sync release-info-dev..."
for _ in $(seq 1 60); do
  status=$(kubectl -n argocd get application release-info-dev -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  echo "  $status"
  [ "$status" = "Synced/Healthy" ] && break
  sleep 5
done

if [ "${1:-}" = "--monitoring" ]; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
    --set grafana.adminPassword=admin --wait --timeout 10m
  kubectl apply -f monitoring/servicemonitor.yaml
  kubectl -n monitoring create configmap release-info-dashboard \
    --from-file=release-info.json=monitoring/grafana-dashboard.json --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
  echo "Grafana:  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80   (admin / admin)"
fi

echo
echo "App:      kubectl -n release-info-dev port-forward svc/release-info 8080:80 ; curl localhost:8080"
echo "Argo CD:  kubectl -n argocd port-forward svc/argocd-server 8443:443"
echo "          password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
