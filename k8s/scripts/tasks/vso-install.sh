#!/usr/bin/env bash
# Install (or upgrade) the vault-secrets-operator Helm release.
#
# Idempotent. 이전 실행에서 failed / pending / uninstalling 상태로 남은 릴리즈
# 메타데이터가 있으면 먼저 uninstall 한 뒤 깨끗하게 재설치한다 (Helm 의
# "no deployed releases" 문제 회피).
#
# `--atomic` 은 설치 실패 시 자동 rollback 을 수행하는데, rollback 결과
# "no deployed releases" 상태가 돼서 다음 helm upgrade --install 이 실패하는
# 연쇄 문제를 낳는다. 이 스크립트는 대신 실패 상태를 명시적으로 감지해
# uninstall 로 cleanup 하므로 --atomic 없이 실행한다.
#
# VSO 는 전용 namespace 에 설치된다 (mnt 에 직접 두면 PSS Restricted 라벨과
# 차트 Pod spec 의 불일치로 Pod 생성이 막힘). Controller 는 cluster-scoped RBAC
# 를 갖고 있어 mnt 의 VaultAuth/VaultStaticSecret 도 정상 watch 한다.
#
# Optional env:
#   VSO_NAMESPACE   — target namespace (default: vault-secrets-operator-system)
#   VSO_RELEASE     — helm release name (default: vault-secrets-operator)
#   VSO_VERSION     — chart version pin (default: 0.9.0)
#   VSO_VALUES_FILE — values file path   (default: $REPO_ROOT/k8s/base/plugins/vso/helm/values.yaml)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

: "${VSO_NAMESPACE:=vault-secrets-operator-system}"
: "${VSO_RELEASE:=vault-secrets-operator}"
: "${VSO_VERSION:=0.9.0}"

resolve_values_file() {
  : "${VSO_VALUES_FILE:=$REPO_ROOT/k8s/base/plugins/vso/helm/values.yaml}"
  [[ -f "$VSO_VALUES_FILE" ]] || die "values.yaml 없음: $VSO_VALUES_FILE"
}

register_repo() {
  log "helm repo: hashicorp 등록 (idempotent)"
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update hashicorp >/dev/null
}

# 기존 릴리즈가 dirty 상태 (failed/pending-*/uninstalling/uninstalled) 면 선제
# uninstall 해야 다음 upgrade --install 이 성공한다.
cleanup_dirty_release() {
  local status=""
  if helm -n "$VSO_NAMESPACE" status "$VSO_RELEASE" -o json >/dev/null 2>&1; then
    status="$(helm -n "$VSO_NAMESPACE" status "$VSO_RELEASE" -o json \
      | jq -r '.info.status // "unknown"')"
  fi

  case "$status" in
    "")
      log "기존 Helm 릴리즈 없음 → 신규 install"
      ;;
    "deployed")
      log "기존 릴리즈 상태=deployed → upgrade 진행"
      ;;
    "failed"|"pending-install"|"pending-upgrade"|"pending-rollback"|"uninstalling"|"uninstalled")
      warn "기존 릴리즈 상태=$status (dirty) → helm uninstall 먼저"
      helm -n "$VSO_NAMESPACE" uninstall "$VSO_RELEASE" --wait --timeout 5m 2>/dev/null \
        || warn "  uninstall 중 오류 무시 (이미 부분 정리됐을 수 있음)"
      ;;
    *)
      warn "기존 릴리즈 상태=$status (예상 외) — 일단 upgrade 시도"
      ;;
  esac
}

install_or_upgrade() {
  log "helm upgrade --install $VSO_RELEASE (v=$VSO_VERSION ns=$VSO_NAMESPACE)"
  helm upgrade --install "$VSO_RELEASE" hashicorp/vault-secrets-operator \
    --namespace "$VSO_NAMESPACE" \
    --create-namespace \
    --version "$VSO_VERSION" \
    --values "$VSO_VALUES_FILE" \
    --wait \
    --timeout 5m
}

wait_ready() {
  log "VSO Pod Ready 확인"
  kubectl -n "$VSO_NAMESPACE" wait --for=condition=Ready \
    pod -l "app.kubernetes.io/name=vault-secrets-operator" \
    --timeout=120s
}

main() {
  require_cmd helm kubectl jq
  require_env REPO_ROOT

  resolve_values_file
  register_repo
  cleanup_dirty_release
  install_or_upgrade
  wait_ready
  log "vso-install 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
