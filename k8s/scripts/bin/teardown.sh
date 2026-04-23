#!/usr/bin/env bash
# Entry point: tear down the full infra stack for a given environment.
#
# 체계적 정리 — 기본 경로는 "정상 API 삭제" 만 사용한다. finalizer 강제 제거와
# /finalize API 호출 같은 파괴적 복구 경로는 별도 플래그 아래로 격리했다.
#
# Phases:
#   1. Precheck                (namespace 존재 여부)
#   2. VSO CR 삭제              (controller 살아있을 때 정상 경로만)
#   3. VSO Helm uninstall
#   4. 인프라 overlay 삭제       (Vault / Registry / 앱)
#   5. namespace 삭제
#   6. (opt) FORCE_FINALIZERS=yes 일 때만 — finalizer 강제 제거 + /finalize
#   7. Cluster-scoped 리소스 정리 (ClusterRoleBinding, VSO ClusterRole/Webhook/CRD)
#
# 대화형:
#   bash k8s/scripts/bin/teardown.sh dev
#
# CI (비대화):
#   CONFIRM=yes bash k8s/scripts/bin/teardown.sh dev
#
# Required context (bootstrap 과 동일한 안전 가드):
#   KUBE_CONTEXT_<ENV_UPPER> 또는 KUBE_CONTEXT
#
# Destructive 플래그:
#   FORCE_FINALIZERS=yes
#     Phase 6 실행 — PVC / CRD / 모든 namespaced 리소스 finalizer 강제 제거 및
#     namespace /finalize 호출. PV 가 orphaned 되고 컨트롤러 정리 누락이 발생할
#     수 있으므로 Terminating 복구 외 목적으로는 쓰지 말 것.
#
#   ALLOW_PROD_DESTRUCTIVE=yes
#     env=prod teardown 을 허용. 추가로 namespace 이름 재입력 TTY 확인이 필요.
#
#   TEARDOWN_VSO_OPERATOR=yes
#     Phase 3 에서 VSO Helm 릴리즈와 vault-secrets-operator-system namespace 까지
#     제거. VSO operator 는 환경별이 아니라 **클러스터 공용** 이다. 다른 env 가
#     같은 클러스터에 있으면 그쪽 VSO reconciliation 이 같이 멈춘다.
#     Phase 7 의 vault-tokenreview-binding (cluster-scoped 이름 고정) 도 이
#     플래그로 함께 삭제한다. VSO 를 완전히 내릴 때만 켜라. 기본은 skip.
#
#   TEARDOWN_VSO_CRDS=yes
#     Phase 7 에서 cluster-scoped VSO 리소스 (ClusterRole/CRB/Webhook/CRD) 를
#     제거. CRD 는 클러스터 전체 공유라 같은 클러스터에 다른 env 가 있으면
#     그쪽 인스턴스까지 날아간다. 단일-env-per-cluster 환경 또는 VSO 를 완전히
#     버리려는 의도일 때만 켜라. 기본은 skip.
#
#   TEARDOWN_MINIO_OPERATOR=yes
#     MinIO Operator Helm 릴리즈도 제거 (기본 유지).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"

NAMESPACE="mnt"
VSO_NAMESPACE="${VSO_NAMESPACE:-vault-secrets-operator-system}"
VSO_RELEASE="${VSO_RELEASE:-vault-secrets-operator}"
VSO_CRD_KINDS=(vaultstaticsecret vaultauth vaultconnection)

usage() {
  cat >&2 <<EOF
Usage: bin/teardown.sh <dev|staging|prod>

Required env:
  KUBE_CONTEXT_DEV / KUBE_CONTEXT_STAGING / KUBE_CONTEXT_PROD
  (또는 KUBE_CONTEXT=<name>)

Options:
  CONFIRM=yes                   대화형 확인 자동 승인
  FORCE_FINALIZERS=yes          Phase 6 (finalizer 강제 + /finalize) 활성화
  ALLOW_PROD_DESTRUCTIVE=yes    env=prod teardown 허용 + namespace 재입력 필요
  TEARDOWN_VSO_OPERATOR=yes     VSO Helm 릴리즈 + 전용 namespace + vault-tokenreview-binding
                                모두 제거. VSO 는 클러스터 공용 플랫폼 리소스이므로
                                다른 env 의 reconciliation 이 함께 멈춤.
  TEARDOWN_VSO_CRDS=yes         VSO cluster-scoped 리소스 (ClusterRole/CRB/Webhook/CRD)
                                제거. 클러스터 전체에 영향.
  TEARDOWN_MINIO_OPERATOR=yes   MinIO Operator 도 함께 제거
EOF
  exit 1
}

phase1_precheck() {
  log "[1/7] Precheck"
  if ns_exists "$NAMESPACE"; then
    log "  namespace $NAMESPACE phase=$(ns_phase "$NAMESPACE")"
  else
    log "  namespace $NAMESPACE 없음 → 일부 phase 는 skip"
  fi
}

phase2_vso_cr_delete() {
  log "[2/7] VSO CR 삭제"
  if kubectl get -k "$OVERLAY_DIR/vso/" >/dev/null 2>&1; then
    # 정상 API 삭제만 시도. 타임아웃 나도 Phase 6 (FORCE_FINALIZERS) 에 위임.
    kubectl delete -k "$OVERLAY_DIR/vso/" --ignore-not-found \
      --wait=true --timeout=60s 2>&1 \
      || warn "  VSO CR 삭제 타임아웃 — FORCE_FINALIZERS=yes 로 재실행하면 강제 해제"
  else
    log "  VSO overlay 리소스 없음 → skip"
  fi
}

uninstall_vso_in_ns() {
  local ns="$1"
  kubectl get namespace "$ns" >/dev/null 2>&1 || return 0

  # pre-delete hook Job 이 stuck 이면 uninstall 이 hang → 먼저 정리
  kubectl -n "$ns" get job -l app.kubernetes.io/instance="$VSO_RELEASE" -o name 2>/dev/null \
    | xargs -r kubectl -n "$ns" delete --force --grace-period=0 --ignore-not-found 2>/dev/null || true
  kubectl -n "$ns" delete job pdcc-vault-secrets-operator \
    --force --grace-period=0 --ignore-not-found 2>/dev/null || true

  if helm -n "$ns" status "$VSO_RELEASE" >/dev/null 2>&1; then
    log "  [$ns] helm uninstall $VSO_RELEASE"
    helm -n "$ns" uninstall "$VSO_RELEASE" --wait --timeout 5m 2>&1 \
      || warn "  [$ns] helm uninstall 실패 — 릴리즈 Secret 잔존물 직접 제거"
  else
    log "  [$ns] VSO 릴리즈 없음"
  fi

  # uninstall 실패 / rollback 잔존 상태에서 남는 sh.helm.release.v1.* Secret 정리
  kubectl -n "$ns" get secret -o name 2>/dev/null \
    | grep "sh.helm.release.*${VSO_RELEASE}" \
    | xargs -r kubectl -n "$ns" delete --ignore-not-found 2>/dev/null || true
}

# $NAMESPACE (mnt) 내 잔존 uninstall 은 **env-specific 레거시 cleanup** 이라
# 항상 실행한다 — 과거 VSO 가 mnt 에 설치됐던 적이 있으면 릴리즈 메타데이터가
# 남아 다음 install 을 막으므로. $VSO_NAMESPACE (공용 operator 공간) 에 대한
# uninstall 은 클러스터 공유이므로 명시적 opt-in 요구.
phase3_vso_helm_uninstall() {
  log "[3/7] VSO Helm uninstall"
  uninstall_vso_in_ns "$NAMESPACE"

  if [[ "${TEARDOWN_VSO_OPERATOR:-}" == "yes" ]]; then
    warn "  TEARDOWN_VSO_OPERATOR=yes — 공용 VSO operator ($VSO_NAMESPACE) 제거"
    warn "  경고: 같은 클러스터에 다른 env 의 VaultStaticSecret 이 있으면 reconciliation 이 멈춥니다."
    uninstall_vso_in_ns "$VSO_NAMESPACE"
  else
    log "  VSO operator ($VSO_NAMESPACE) 보존 (TEARDOWN_VSO_OPERATOR=yes 로 제거 가능)"
  fi
}

phase4_overlay_delete() {
  log "[4/7] 인프라 리소스 삭제 (kustomize overlay)"
  if ns_exists "$NAMESPACE"; then
    kubectl delete -k "$OVERLAY_DIR" --ignore-not-found \
      --wait=true --timeout=120s 2>&1 \
      || warn "  overlay 삭제 타임아웃 — 필요 시 FORCE_FINALIZERS=yes 로 Phase 6 사용"
  else
    log "  namespace 없음 → overlay 삭제 skip"
  fi
}

phase5_namespace_delete() {
  log "[5/7] namespace 정상 삭제"
  if ns_exists "$NAMESPACE"; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
    log "  namespace 제거 대기 (최대 60s)"
    if wait_namespace_gone "$NAMESPACE" 60; then
      log "  namespace $NAMESPACE 제거 완료"
    else
      warn "  namespace $NAMESPACE 가 Terminating 60s 초과."
      warn "  정상 삭제로 끝나지 않은 경우:"
      warn "    1) 'kubectl get all -n $NAMESPACE' 로 남은 리소스 원인 확인"
      warn "    2) controller/operator 재기동 으로 finalizer 처리 시도"
      warn "    3) 그래도 막히면 FORCE_FINALIZERS=yes 로 재실행 — 단 파괴적"
    fi
  else
    log "  namespace 이미 없음"
  fi
}

# FORCE_FINALIZERS=yes 일 때만 — PV orphaned / 데이터 정합성 리스크 있음.
phase6_force_finalizers() {
  if [[ "${FORCE_FINALIZERS:-}" != "yes" ]]; then
    log "[6/7] FORCE_FINALIZERS!=yes → skip (파괴적 경로 비활성)"
    return 0
  fi

  log "[6/7] FORCE_FINALIZERS=yes — finalizer 강제 제거 + /finalize"
  warn "  경고: PV orphan / controller 정리 누락이 발생할 수 있습니다."
  warn "  Terminating stuck 복구 외 목적으로 사용하지 마세요."

  if ! ns_exists "$NAMESPACE"; then
    log "  namespace 이미 없음 → skip"
    return 0
  fi

  strip_finalizers_in_ns "$NAMESPACE" persistentvolumeclaim
  strip_finalizers_in_ns "$NAMESPACE" "${VSO_CRD_KINDS[@]}" 2>/dev/null || true
  log "  namespace $NAMESPACE 전체 리소스 finalizer 일괄 제거 (최후 수단)"
  strip_finalizers_all_ns_resources "$NAMESPACE"

  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  if wait_namespace_gone "$NAMESPACE" 30; then
    log "  namespace $NAMESPACE 제거 완료 (FORCE_FINALIZERS)"
    return 0
  fi

  warn "  namespace 여전히 Terminating → /finalize API 호출"
  force_finalize_namespace "$NAMESPACE" \
    || warn "  /finalize 호출 실패 — 수동 확인 필요"
  if wait_namespace_gone "$NAMESPACE" 30; then
    log "  namespace $NAMESPACE 제거 완료 (/finalize)"
  else
    err "  namespace $NAMESPACE 여전히 존재. 'kubectl get namespace $NAMESPACE -o yaml' 로 확인 필요."
  fi
}

phase7_cluster_scoped() {
  log "[7/7] Cluster-scoped 리소스 정리"

  # vault-tokenreview-binding 은 cluster-scoped 이름 고정이라 env 별 분리가
  # 불가능하다 (kustomize base 를 env-scoped 이름으로 재설계하기 전까지).
  # 기본 경로에서 삭제하면 다른 env 의 Vault k8s auth TokenReview 가 부서지므로
  # TEARDOWN_VSO_OPERATOR=yes 와 함께 게이트 (플랫폼 auth 평면 전체 정리).
  if [[ "${TEARDOWN_VSO_OPERATOR:-}" == "yes" ]]; then
    log "  vault-tokenreview-binding 제거 (TEARDOWN_VSO_OPERATOR=yes)"
    kubectl delete clusterrolebinding vault-tokenreview-binding --ignore-not-found 2>&1 \
      | sed 's/^/    /' || true
    if ns_exists "$VSO_NAMESPACE"; then
      log "  VSO namespace $VSO_NAMESPACE 삭제"
      kubectl delete namespace "$VSO_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null \
        || warn "  $VSO_NAMESPACE 삭제 타임아웃 — 수동 확인 필요"
    fi
  else
    log "  vault-tokenreview-binding 보존 (TEARDOWN_VSO_OPERATOR=yes 로 제거 가능)"
  fi

  # VSO 의 ClusterRole / CRB / Webhook / CRD 는 클러스터 전체 공유다.
  # 운영자가 의도적으로 VSO 전체를 버릴 때만 TEARDOWN_VSO_CRDS=yes 로 활성화.
  if [[ "${TEARDOWN_VSO_CRDS:-}" == "yes" ]]; then
    warn "  TEARDOWN_VSO_CRDS=yes — cluster-scoped VSO 리소스 제거 (ClusterRole/CRB/Webhook/CRD)"
    warn "  경고: 같은 클러스터의 다른 env 에서 VSO 를 쓰고 있으면 모두 영향받습니다."
    local kind
    for kind in clusterrole clusterrolebinding validatingwebhookconfiguration mutatingwebhookconfiguration; do
      kubectl get "$kind" -o name 2>/dev/null \
        | grep -E 'vault-secrets-operator' \
        | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true
    done
    kubectl get crd -o name 2>/dev/null \
      | grep 'secrets.hashicorp.com' \
      | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true
  else
    log "  cluster-scoped VSO 리소스 보존 (TEARDOWN_VSO_CRDS=yes 로 제거 가능)"
  fi

  if [[ "${TEARDOWN_MINIO_OPERATOR:-}" == "yes" ]]; then
    log "  TEARDOWN_MINIO_OPERATOR=yes → MinIO Operator 제거"
    helm -n minio-operator uninstall minio-operator --wait --timeout 5m 2>/dev/null \
      || warn "  MinIO Operator Helm uninstall 실패"
    kubectl delete namespace minio-operator --ignore-not-found --wait=true --timeout=60s \
      || warn "  minio-operator namespace 삭제 실패"
  else
    log "  MinIO Operator 유지 (TEARDOWN_MINIO_OPERATOR=yes 로 제거 가능)"
  fi
}

summary() {
  log "============================================"
  log "  $ENV_NAME 삭제 완료"
  log "============================================"
  log "Vault unseal key 파일은 그대로 남아있습니다 (${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json})."
  log "완전 초기화하려면 수동 삭제하세요."
}

main() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in
    dev|staging|prod) ;;
    *) usage ;;
  esac

  OVERLAY_DIR="$K8S_ROOT/overlays/$ENV_NAME"
  [[ -d "$OVERLAY_DIR" ]] || die "overlay 디렉토리 없음: $OVERLAY_DIR"

  require_cmd kubectl helm jq

  # 안전 가드 1 — kubectl context 가 env 와 맞는지
  require_kube_context "$ENV_NAME"

  # 안전 가드 2 — prod 는 추가 게이트 (namespace 재입력 포함)
  require_production_gate "$ENV_NAME" "$NAMESPACE"

  log "============================================"
  log "  Project-Infra 삭제 ($ENV_NAME)"
  log "  context : $(kubectl config current-context)"
  log "============================================"

  confirm "namespace='$NAMESPACE' 의 모든 Vault / Registry / VSO / 앱 리소스를 삭제합니다. 계속?" \
    || die "사용자 취소"

  phase1_precheck
  phase2_vso_cr_delete
  phase3_vso_helm_uninstall
  phase4_overlay_delete
  phase5_namespace_delete
  phase6_force_finalizers
  phase7_cluster_scoped
  summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
