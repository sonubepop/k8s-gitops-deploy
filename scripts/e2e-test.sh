#!/usr/bin/env bash
# End-to-end test on a kind cluster (run by CI):
#   1. deploy v1 of the service with the dev overlay and check every endpoint from inside the cluster
#   2. roll out v2 while sending continuous traffic and fail if a single request is dropped
# Expects images release-info:e2e-v1 and release-info:e2e-v2 to be loaded into the cluster.
set -euo pipefail

NS=release-info-dev
OVERLAY=k8s/overlays/e2e
SVC=http://release-info.${NS}.svc.cluster.local

set_tag() { sed -i -E "s/^( *newTag: ).*/\1$1/" "$OVERLAY/kustomization.yaml"; }
in_cluster() { kubectl -n "$NS" exec probe -- "$@"; }

echo "::group::Deploy v1"
set_tag e2e-v1
kustomize build "$OVERLAY" | kubectl apply -f -
kubectl -n "$NS" rollout status deploy/release-info --timeout=180s
kubectl -n "$NS" run probe --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 3600
kubectl -n "$NS" wait --for=condition=Ready pod/probe --timeout=120s
echo "::endgroup::"

echo "::group::Endpoint checks"
body=$(in_cluster curl -fsS "$SVC/")
echo "$body"
echo "$body" | grep -q '"version":"e2e-v1"'
echo "$body" | grep -q '"environment":"dev"'
in_cluster curl -fsS "$SVC/healthz" | grep -q ok
in_cluster curl -fsS "$SVC/readyz" | grep -q ready
in_cluster curl -fsS "$SVC/metrics" | grep -q 'app_build_info{commit='
echo "all endpoints OK"
echo "::endgroup::"

echo "::group::Rolling update v1 -> v2 under load"
# shellcheck disable=SC2016  # the loop runs inside the probe pod, variables expand there
in_cluster sh -c '
  ok=0; fail=0; end=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if curl -fsS -m 2 -o /dev/null '"$SVC"'/; then ok=$((ok+1)); else fail=$((fail+1)); fi
    sleep 0.1
  done
  echo "ok=$ok fail=$fail"' > /tmp/load-result.txt &
LOAD_PID=$!
sleep 5
set_tag e2e-v2
kustomize build "$OVERLAY" | kubectl apply -f -
kubectl -n "$NS" rollout status deploy/release-info --timeout=180s
wait "$LOAD_PID"
cat /tmp/load-result.txt
echo "::endgroup::"

in_cluster curl -fsS "$SVC/" | grep -q '"version":"e2e-v2"' || { echo "v2 is not serving"; exit 1; }
grep -q ' fail=0$' /tmp/load-result.txt || { echo "requests were dropped during the rolling update"; exit 1; }
echo "PASS: v2 is live and no request failed during the rollout ($(cat /tmp/load-result.txt))"
set_tag e2e-v1
