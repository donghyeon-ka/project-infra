#!/usr/bin/env bash
# Install (or upgrade) the vault-secrets-operator Helm release.
#
# Uses `helm upgrade --install` so the task is fully idempotent. Waits for
# the deployment to become ready before returning, so callers can proceed
# to apply VSO CRDs immediately.
#
# Optional env:
#   VSO_NAMESPACE   — target namespace (default: mnt)
#   VSO_RELEASE     — helm release name (default: vault-secrets-operator)
#   VSO_VERSION     — chart version pin (default: 0.9.0)
#   VSO_VALUES_FILE — values file path   (default: $REPO_ROOT/k8s/base/plugins/vso/helm/values.yaml)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

require_cmd helm kubectl
require_env REPO_ROOT

: "${VSO_NAMESPACE:=mnt}"
: "${VSO_RELEASE:=vault-secrets-operator}"
: "${VSO_VERSION:=0.9.0}"
: "${VSO_VALUES_FILE:=$REPO_ROOT/k8s/base/plugins/vso/helm/values.yaml}"

[[ -f "$VSO_VALUES_FILE" ]] || die "values.yaml 없음: $VSO_VALUES_FILE"

log "helm repo: hashicorp 등록 (idempotent)"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

log "helm upgrade --install $VSO_RELEASE (v=$VSO_VERSION ns=$VSO_NAMESPACE)"
helm upgrade --install "$VSO_RELEASE" hashicorp/vault-secrets-operator \
  --namespace "$VSO_NAMESPACE" \
  --version "$VSO_VERSION" \
  --values "$VSO_VALUES_FILE" \
  --wait \
  --atomic \
  --timeout 5m

log "VSO Pod Ready 확인"
kubectl -n "$VSO_NAMESPACE" wait --for=condition=Ready \
  pod -l "app.kubernetes.io/name=vault-secrets-operator" \
  --timeout=120s

log "vso-install 태스크 완료"
