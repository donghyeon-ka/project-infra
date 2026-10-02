#!/usr/bin/env bash
# Install (or upgrade) the MinIO Operator Helm release.
#
# MinIO Tenant CR (minio.min.io/v2) 는 이 Operator 가 CRD 를 먼저 등록해야
# apply 가능하다. bootstrap.sh 의 Phase 1 이전에 실행된다.
#
# Operator 는 자체 namespace (기본 minio-operator) 에 배포된다. 애플리케이션
# namespace (mnt) 와 분리되므로 Tenant CR 만 mnt 에 있어도 동작한다.
#
# Optional env:
#   MINIO_OPERATOR_NAMESPACE  — 기본 minio-operator
#   MINIO_OPERATOR_RELEASE    — 기본 minio-operator
#   MINIO_OPERATOR_VERSION    — 기본 7.0.0

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

: "${MINIO_OPERATOR_NAMESPACE:=minio-operator}"
: "${MINIO_OPERATOR_RELEASE:=minio-operator}"
: "${MINIO_OPERATOR_VERSION:=7.0.0}"

helm_install() {
  log "helm repo: minio-operator 등록 (idempotent)"
  helm repo add minio-operator https://operator.min.io >/dev/null 2>&1 || true
  helm repo update minio-operator >/dev/null

  log "helm upgrade --install ${MINIO_OPERATOR_RELEASE} (v=${MINIO_OPERATOR_VERSION} ns=${MINIO_OPERATOR_NAMESPACE})"
  helm upgrade --install "$MINIO_OPERATOR_RELEASE" minio-operator/operator \
    --namespace "$MINIO_OPERATOR_NAMESPACE" \
    --create-namespace \
    --version "$MINIO_OPERATOR_VERSION" \
    --wait \
    --atomic \
    --timeout 5m
}

wait_ready() {
  log "MinIO Operator Pod Ready 확인"
  kubectl -n "$MINIO_OPERATOR_NAMESPACE" wait --for=condition=Ready \
    pod -l "app.kubernetes.io/name=operator" \
    --timeout=120s

  log "Tenant CRD 등록 확인"
  kubectl get crd tenants.minio.min.io >/dev/null \
    || die "Tenant CRD 가 여전히 없음. Operator 설치 로그 확인."
}

main() {
  require_cmd helm kubectl
  helm_install
  wait_ready
  log "minio-operator-install 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
