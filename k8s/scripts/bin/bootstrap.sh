#!/usr/bin/env bash
# Entry point: bootstrap the full infra stack for a given environment.
#
# Phases:
#   1. Apply base + plugins (namespace + Vault + Registry)
#   2. Wait for Vault pod
#   3. Vault init + unseal + k8s auth + KV + VSO policy/role   (tasks/vault-init.sh)
#   4. Seed registry credentials into Vault                     (tasks/vault-seed-registry.sh)
#   5. Helm install VSO                                         (tasks/vso-install.sh)
#   6. Apply VSO CRDs (VaultConnection / VaultAuth / VaultStaticSecret)
#
# Usage:
#   bin/bootstrap.sh dev
#   CONFIRM=yes VAULT_PUSH_PASSWORD=... VAULT_PULL_PASSWORD=... bin/bootstrap.sh dev
#
# Non-interactive mode requires:
#   VAULT_PUSH_PASSWORD, VAULT_PULL_PASSWORD
#   CONFIRM=yes  (to skip interactive prompts if any are added later)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"
TASKS_DIR="$SCRIPT_DIR/../tasks"
export REPO_ROOT

NAMESPACE="mnt"

usage() {
  cat >&2 <<EOF
Usage: bin/bootstrap.sh <dev|staging|prod>

Environment variables:
  VAULT_PUSH_PASSWORD   push-user 비밀번호 (비대화 모드에서 필수)
  VAULT_PULL_PASSWORD   pull-user 비밀번호 (비대화 모드에서 필수)
  CONFIRM=yes           대화형 확인을 자동 yes 처리
EOF
  exit 1
}

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  dev|staging|prod) ;;
  *) usage ;;
esac

OVERLAY_DIR="$K8S_ROOT/overlays/$ENV_NAME"
[[ -d "$OVERLAY_DIR" ]] || die "overlay 디렉토리 없음: $OVERLAY_DIR"

require_cmd kubectl helm jq

log "============================================"
log "  Project-Infra 부트스트랩 ($ENV_NAME)"
log "============================================"

# -----------------------------------------------------------------------------
# Phase 1
# -----------------------------------------------------------------------------
log "[1/6] 인프라 리소스 배포 ($OVERLAY_DIR)"
kubectl apply -k "$OVERLAY_DIR"
log "  namespace/vault/registry 선언 완료"

# -----------------------------------------------------------------------------
# Phase 2
# -----------------------------------------------------------------------------
log "[2/6] vault-0 Ready 대기 (120s)"
retry 3 10 kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready pod/vault-0 --timeout=120s

# -----------------------------------------------------------------------------
# Phase 3
# -----------------------------------------------------------------------------
log "[3/6] Vault 초기화 / unseal / auth / policy / role"
bash "$TASKS_DIR/vault-init.sh"

# -----------------------------------------------------------------------------
# Phase 4 — skip if already seeded
# -----------------------------------------------------------------------------
log "[4/6] Docker Registry 자격 증명 seed 확인"

# Login quietly to check existence (stdin token — not on argv).
ROOT_TOKEN="$(jq -r '.root_token' "$REPO_ROOT/vault-init-keys.json")"
printf '%s' "$ROOT_TOKEN" \
  | kubectl exec -i -n "$NAMESPACE" vault-0 -- vault login -no-print - >/dev/null
unset ROOT_TOKEN

if kubectl exec -n "$NAMESPACE" vault-0 -- \
     vault kv get -format=json secret/docker-registry/auth >/dev/null 2>&1; then
  log "  secret/docker-registry/auth 이미 존재 → seed 건너뜀"
else
  bash "$TASKS_DIR/vault-seed-registry.sh"
fi

# -----------------------------------------------------------------------------
# Phase 5
# -----------------------------------------------------------------------------
log "[5/6] VSO Helm upgrade --install"
bash "$TASKS_DIR/vso-install.sh"

# -----------------------------------------------------------------------------
# Phase 6
# -----------------------------------------------------------------------------
log "[6/6] VSO CRD 적용 ($OVERLAY_DIR/vso/)"
kubectl apply -k "$OVERLAY_DIR/vso/"

# -----------------------------------------------------------------------------
# Summary — secrets are NEVER printed; tell the user where to find them.
# -----------------------------------------------------------------------------
log "============================================"
log "  $ENV_NAME 부트스트랩 완료"
log "============================================"
log "unseal keys + root token: $REPO_ROOT/vault-init-keys.json (0600)"
log "  → 오프라인 / 외부 KMS 로 즉시 이동하세요 (Git 반입 금지)"
log ""
log "다음 확인:"
log "  kubectl -n $NAMESPACE get pods"
log "  kubectl -n $NAMESPACE get secrets | grep -E 'htpasswd|pull-credential'"
log "  kubectl -n $NAMESPACE get vaultstaticsecret"
