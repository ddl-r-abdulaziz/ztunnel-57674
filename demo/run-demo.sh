#!/usr/bin/env bash
# Stands up a local minikube cluster running ambient-mode Istio with this
# repo's patched ztunnel image, then demonstrates the deterministic
# identity-wait race end to end: a plain pod repeatedly tries to reach the
# kube API until ztunnel's forced-failure window elapses and the connection
# finally goes through, with no changes to the pod itself.
#
# flags:
#   -K - keep the minikube cluster around on exit (also skips deleting it
#        first if it already exists)
#
# env:
#   HOLD_SECS - overrides ZTUNNEL_FAKE_RACE_HOLD_SECS (default: 15). Kept
#               above the ~5s a single failed attempt takes so the probe
#               pod sees a few failures before the window elapses, rather
#               than just one.

set -euo pipefail

print_error()   { echo -e "\n\033[30;41m ERROR \033[0m: $1" >&2; }
print_info()    { echo -e "\n\033[30;103m INFO \033[0m: $1\n"; }
print_success() { echo -e "\n\033[30;42m SUCCESS \033[0m: $1\n"; }

readonly profile_name="fake-ztunnel-demo"
readonly test_namespace="fake-ztunnel-demo"
readonly image_ref="ztunnel-57674/demo:local"
readonly hold_secs="${HOLD_SECS:-15}"

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(dirname "$script_dir")"

keep_cluster=false
while getopts "K" opt; do
  case $opt in
    K) keep_cluster=true ;;
    \?) print_error "-$OPTARG"; exit 1 ;;
  esac
done

for bin in docker minikube istioctl kubectl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    print_error "'$bin' not found on PATH"
    exit 1
  fi
done

print_info "Building $image_ref from $repo_root"
docker build -t "$image_ref" "$repo_root"

if [[ "$keep_cluster" == "false" ]]; then
  print_info "Deleting any existing '$profile_name' minikube profile"
  minikube delete --profile "$profile_name" || true
fi

if ! minikube status --profile "$profile_name" >/dev/null 2>&1; then
  print_info "Starting minikube profile '$profile_name'"
  minikube start --profile "$profile_name" --cpus=2 --memory=4g
else
  print_info "Reusing existing minikube profile '$profile_name'"
fi

readonly kubectl="minikube --profile $profile_name kubectl -- "

print_info "Loading $image_ref into minikube"
minikube image load "$image_ref" --profile "$profile_name"

print_info "Installing istio ambient profile via istioctl, with ztunnel pointed at $image_ref (forced-failure window: ${hold_secs}s, namespace: $test_namespace)"
istioctl install --set profile=ambient --skip-confirmation \
  --context "$profile_name" \
  --set "values.ztunnel.image=$image_ref" \
  --set "values.ztunnel.imagePullPolicy=Never" \
  --set "values.ztunnel.env.ZTUNNEL_FAKE_RACE_NAMESPACES=$test_namespace" \
  --set "values.ztunnel.env.ZTUNNEL_FAKE_RACE_HOLD_SECS=$hold_secs"

print_info "Waiting for istiod, ztunnel and istio-cni-node to be ready"
$kubectl -n istio-system rollout status deployment/istiod --timeout=180s
$kubectl -n istio-system rollout status daemonset/ztunnel --timeout=180s
$kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout=180s

print_info "Creating and labeling namespace '$test_namespace' for ambient dataplane mode"
$kubectl create namespace "$test_namespace" || true
$kubectl label namespace "$test_namespace" istio.io/dataplane-mode=ambient --overwrite

print_info "Running the probe pod (namespace '$test_namespace' is targeted, so ztunnel forces roughly its first ${hold_secs}s of identity waits to fail)"
$kubectl -n "$test_namespace" delete pod kube-api-probe --ignore-not-found
$kubectl -n "$test_namespace" apply -f "$script_dir/manifests/probe-pod.yaml"
$kubectl -n "$test_namespace" wait pod/kube-api-probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=$((hold_secs + 120))s

readonly ztunnel_pod=$($kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')

print_success "Probe pod finished. Logs below."

echo "----- pod/kube-api-probe (namespace $test_namespace) -----"
$kubectl -n "$test_namespace" logs kube-api-probe

echo
echo "----- ztunnel ($ztunnel_pod, namespace istio-system) - fake_race entries -----"
$kubectl -n istio-system logs "$ztunnel_pod" | grep -i fake_race || print_info "(no fake_race log lines found - see the full logs with: $kubectl -n istio-system logs $ztunnel_pod)"

if [[ "$keep_cluster" == "false" ]]; then
  print_info "Deleting minikube profile '$profile_name' (pass -K to keep it around)"
  minikube delete --profile "$profile_name"
else
  print_info "Leaving minikube profile '$profile_name' running (-K was passed). Delete it later with: minikube delete --profile $profile_name"
fi
