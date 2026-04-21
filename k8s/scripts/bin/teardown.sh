#!/usr/bin/env bash
# Entry point: tear down the full infra stack for a given environment.
#
# Destructive. Requires interactive y/N OR CONFIRM=yes.
#
# Phases:
#   1. Delete VSO CRDs
#   2. Uninstall VSO Helm release
#   3. Delete Vault + Registry + Namespace overlay
#   4. Delete leftover PVCs
#   5. Delete cluster-scoped ClusterRoleBinding

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"

NAMESPACE="mnt"

usage() {
  echo "Usage: bin/teardown.sh <dev|staging|prod>" >&2
  echo "       CONFIRM=yes bin/teardown.sh <dev|staging|prod>" >&2
  exit 1
}

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  dev|staging|prod) ;;
  *) usage ;;
esac

OVERLAY_DIR="$K8S_ROOT/overlays/$ENV_NAME"
[[ -d "$OVERLAY_DIR" ]] || die "overlay 디렉토리 없음: $OVERLAY_DIR"

require_cmd kubectl helm

log "============================================"
log "  Project-Infra 삭제 ($ENV_NAME)"
log "============================================"

confirm "namespace='$NAMESPACE' 의 모든 Vault / Registry / VSO 리소스를 삭제합니다. 계속?" \
  || die "사용자 취소"

# -----------------------------------------------------------------------------
# Phase 1
# -----------------------------------------------------------------------------
log "[1/5] VSO CRD 삭제"
kubectl delete -k "$OVERLAY_DIR/vso/" --ignore-not-found --wait=true

# -----------------------------------------------------------------------------
# Phase 2
# -----------------------------------------------------------------------------
log "[2/5] VSO Helm 삭제"
if helm -n "$NAMESPACE" status vault-secrets-operator >/dev/null 2>&1; then
  helm -n "$NAMESPACE" uninstall vault-secrets-operator --wait --timeout 5m
else
  log "  VSO 릴리즈 없음 → 건너뜀"
fi

# -----------------------------------------------------------------------------
# Phase 3
# -----------------------------------------------------------------------------
log "[3/5] 인프라 리소스 삭제 (kustomize)"
kubectl delete -k "$OVERLAY_DIR" --ignore-not-found --wait=true

# -----------------------------------------------------------------------------
# Phase 4
# -----------------------------------------------------------------------------
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  log "[4/5] 남은 PVC 삭제 (namespace=$NAMESPACE)"
  kubectl -n "$NAMESPACE" delete pvc --all --ignore-not-found --wait=true
else
  log "[4/5] namespace 이미 삭제됨 → PVC 스킵"
fi

# -----------------------------------------------------------------------------
# Phase 5
# -----------------------------------------------------------------------------
log "[5/5] ClusterRoleBinding 삭제 (vault-tokenreview-binding)"
kubectl delete clusterrolebinding vault-tokenreview-binding \
  --ignore-not-found

log "============================================"
log "  $ENV_NAME 삭제 완료"
log "============================================"
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" get all 2>/dev/null || true
else
  log "namespace '$NAMESPACE' 제거됨"
fi
