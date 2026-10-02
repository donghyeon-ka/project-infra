#!/usr/bin/env bash
# Entry point: bootstrap the full infra stack for a given environment.
#
# Phases:
#   0. MinIO Operator Helm install            (tasks/minio-operator-install.sh)
#   1. Apply namespace + PSS labels           (kubectl apply -k base/managing/namespace)
#   2. (optional) Reset stale K8s Secrets     (RESET_STALE_SECRETS=yes 일 때만)
#   2.5 VSO CRD 선행 설치                     (VaultStaticSecret CR 가 overlay 에 포함돼 있어)
#   2.6 cert-manager 선행 설치                (ClusterIssuer / Certificate CR 가 overlay 에 포함돼 있어)
#   2.7 Keycloak Operator 선행 설치           (Keycloak / KeycloakRealmImport CR 가 overlay 에 포함돼 있어)
#   2.8 Traefik HelmChartConfig + Middleware/TLSOption (kube-system 에 배치 — root overlay 의 `namespace: mnt` 와 충돌하므로 별도 apply)
#   3. Render + diff + confirm + apply overlay  (--server-side --field-manager=project-infra-bootstrap)
#   4. Wait for vault-0 Running
#   5. Vault init + unseal + KV + k8s auth + policy / role  (tasks/vault-init.sh)
#   6. Seed application secrets               (tasks/vault-seed-apps.sh)
#   7. Helm install VSO                       (tasks/vso-install.sh)
#   8. Apply VSO CRs                          (kubectl apply -k overlays/<env>/vso/)
#   9. MinIO docker-registry bucket/user/policy 프로비저닝 (tasks/minio-provision-registry.sh)
#
# 대화형 실행 (bash history 에 비밀번호 남지 않음):
#   bash k8s/scripts/bin/bootstrap.sh dev
#
# Required context (안전 가드):
#   KUBE_CONTEXT_DEV / KUBE_CONTEXT_STAGING / KUBE_CONTEXT_PROD
#   또는 KUBE_CONTEXT= 로 명시. 쉘 rc 에 선언해 두면 현재 kubectl context
#   와 일치 여부를 자동 검증한다. 매핑이 없으면 대화형으로 context 이름
#   재입력을 요구.
#
# Optional env:
#   RESET_STALE_SECRETS=yes       이미 있는 VSO-managed K8s Secret 을 삭제 후 재생성
#   VAULT_KEYS_FILE=<path>        env=prod 필수 — repo 바깥 경로
#   SKIP_DIFF=yes                 Phase 3 의 kubectl diff preview 생략
#   CONFIRM=yes                   대화형 프롬프트 자동 승인 (CI)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"
TASKS_DIR="$SCRIPT_DIR/../tasks"
export REPO_ROOT

NAMESPACE="mnt"
FIELD_MANAGER="project-infra-bootstrap"

# VSO 가 관리하는 K8s Secret 이름 목록 (기존 찌꺼기 감지용)
VSO_MANAGED_SECRETS=(
  identity-postgres-superuser
  keycloak-db
  keycloak-db-operator
  auth-server-db
  keycloak-bootstrap-admin
  keycloak-bootstrap-admin-operator
  keycloak-client-auth-server-ingress
  minio-tenant-env
  docker-registry-minio
)

usage() {
  cat >&2 <<EOF
Usage: bin/bootstrap.sh <dev|staging|prod>

Required env (권장 — 쉘 rc 에 선언):
  KUBE_CONTEXT_DEV / KUBE_CONTEXT_STAGING / KUBE_CONTEXT_PROD   env → kubectl context 매핑
  (또는 KUBE_CONTEXT=<name> 로 한 번만 overrides)

Options:
  RESET_STALE_SECRETS=yes   이미 존재하는 VSO-managed Secret 을 삭제 후 재생성
  VAULT_KEYS_FILE=<path>    env=prod 필수 — repo 바깥 경로
  SKIP_DIFF=yes             Phase 3 diff preview 생략 (비권장)
  CONFIRM=yes               대화형 확인 자동 승인 (CI)
EOF
  exit 1
}

precheck_namespace() {
  if ! ns_exists "$NAMESPACE"; then
    log "Precheck: namespace '$NAMESPACE' 없음 — 신규 생성 흐름"
    return 0
  fi
  local phase
  phase="$(ns_phase "$NAMESPACE")"
  if [[ "$phase" == "Terminating" ]]; then
    err "namespace '$NAMESPACE' 가 Terminating 상태입니다."
    err "이전 teardown 이 완료되지 않아 새 리소스 생성이 불가능합니다."
    err ""
    err "복구 절차:"
    err "  1) 이전 teardown 을 마저 끝내기:"
    err "       CONFIRM=yes bash k8s/scripts/bin/teardown.sh $ENV_NAME"
    err "  2) namespace 가 완전히 사라진 걸 확인한 뒤 bootstrap 재실행:"
    err "       kubectl get namespace $NAMESPACE"
    err "       bash k8s/scripts/bin/bootstrap.sh $ENV_NAME"
    die "bootstrap 중단"
  fi
  log "Precheck: namespace '$NAMESPACE' phase=$phase — 계속 진행"
}

phase0_minio_operator() {
  log "[0/9] MinIO Operator 설치 (Tenant CRD 선행)"
  bash "$TASKS_DIR/minio-operator-install.sh"
}

phase1_namespace() {
  log "[1/9] Namespace + PSS 라벨 선행 apply"
  kubectl apply -k "$K8S_ROOT/base/managing/namespace" \
    --server-side --field-manager="$FIELD_MANAGER"
  retry 5 1 kubectl get namespace "$NAMESPACE" >/dev/null
}

phase2_reset_stale_secrets() {
  log "[2/9] 기존 VSO-managed K8s Secret 점검"
  local stale_found=0 s
  for s in "${VSO_MANAGED_SECRETS[@]}"; do
    if kubectl -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1; then
      stale_found=$((stale_found + 1))
      if [[ "${RESET_STALE_SECRETS:-}" == "yes" ]]; then
        log "  삭제: $s (RESET_STALE_SECRETS=yes)"
        kubectl -n "$NAMESPACE" delete secret "$s" --ignore-not-found
      else
        warn "  $s 이미 존재 (VSO 가 덮어쓰지 않음). Vault 값 반영이 필요하면 RESET_STALE_SECRETS=yes 로 재실행하거나 수동 삭제하세요."
      fi
    fi
  done
  (( stale_found == 0 )) && log "  기존 Secret 없음"
}

phase2_5_vso_crds() {
  # overlays/<env>/{database,keycloak,storage}/vault-secrets.yaml 에 VaultStaticSecret
  # CR 들이 포함돼 있어, Phase 3 overlay apply 시점에 CRD 가 없으면 "resource mapping
  # not found" 로 실패. Helm 차트 install 은 Phase 7 이므로 CRD 만 선행 적용.
  log "[2.5/9] VSO CRD 선행 설치"
  local version="${VSO_VERSION:-0.9.0}"
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update hashicorp >/dev/null
  helm show crds hashicorp/vault-secrets-operator --version "$version" \
    | kubectl apply -f - --server-side --field-manager="$FIELD_MANAGER"
}

# cert-manager 전체 (CRD + namespace + controller + webhook) 을 overlay 밖에서
# 선행 설치. 이후 phase 3 에서 overlay 가 참조하는 ClusterIssuer / Certificate CR
# 이 등록될 수 있다. CRD established 대기를 반드시 건다 — deploy/webhook 가
# Ready 되기 전에 Certificate CR apply 시 admission webhook 이 거부함.
phase2_6_cert_manager() {
  log "[2.6/9] cert-manager 선행 설치"
  kubectl apply -k "$K8S_ROOT/overlays/$ENV_NAME/platform/cert-manager" \
    --server-side --field-manager="$FIELD_MANAGER"

  log "  cert-manager CRD established 대기"
  retry 30 2 kubectl wait --for=condition=Established --timeout=10s \
    crd/clusterissuers.cert-manager.io \
    crd/certificates.cert-manager.io \
    crd/certificaterequests.cert-manager.io \
    crd/orders.acme.cert-manager.io \
    crd/challenges.acme.cert-manager.io

  log "  cert-manager Deployment Available 대기"
  retry 30 5 kubectl -n cert-manager wait --for=condition=Available --timeout=10s \
    deploy/cert-manager \
    deploy/cert-manager-webhook \
    deploy/cert-manager-cainjector
}

# Keycloak Operator (CRDs + Operator Deployment) 선행 설치. Keycloak /
# KeycloakRealmImport CR 이 phase 3 에 포함되므로 CRD 등록이 먼저 되어야 한다.
phase2_7_keycloak_operator() {
  log "[2.7/9] Keycloak Operator 선행 설치"
  kubectl apply -k "$K8S_ROOT/overlays/$ENV_NAME/platform/keycloak-operator" \
    --server-side --field-manager="$FIELD_MANAGER"

  log "  Keycloak Operator CRD established 대기"
  retry 30 2 kubectl wait --for=condition=Established --timeout=10s \
    crd/keycloaks.k8s.keycloak.org \
    crd/keycloakrealmimports.k8s.keycloak.org

  log "  Keycloak Operator Deployment Available 대기"
  retry 60 5 kubectl -n "$NAMESPACE" wait --for=condition=Available --timeout=10s \
    deploy/keycloak-operator
}

# kube-system Traefik 커스터마이징 — HelmChartConfig (K3s Helm-controller 가
# 재수렴), Middleware (https-redirect / security-headers), TLSOption (modern-tls).
# root overlay 가 `namespace: mnt` 로 전역 주입하므로 kube-system 타깃 리소스는
# 이 overlay 빌드에 포함시키지 않고 별도 apply 한다.
phase2_8_traefik() {
  log "[2.8/9] Traefik HelmChartConfig + Middleware 적용 (kube-system)"
  kubectl apply -k "$K8S_ROOT/overlays/$ENV_NAME/platform/traefik" \
    --server-side --field-manager="$FIELD_MANAGER"
}

# render → server-side dry-run → diff → confirm → apply
#
# kubectl diff exit codes (GNU man page):
#   0 — 변경 없음
#   1 — 변경 있음 (정상)
#   >1 — 실행 오류 (RBAC / API 연결 / invalid manifest 등)
# 이전 구현은 `|| true` 로 모든 비-0 을 흡수해서 에러가 apply 까지 흘러갔다.
phase3_overlay_apply() {
  log "[3/9] 인프라 overlay 배포 ($OVERLAY_DIR)"

  local tmpdir
  tmpdir="$(mktemp -d -t project-infra-bootstrap.XXXXXX)"
  trap_cleanup_path "$tmpdir"

  local rendered="$tmpdir/rendered.yaml"
  kustomize build "$OVERLAY_DIR" > "$rendered"
  log "  render 완료: $(grep -c '^kind:' "$rendered") resources"

  # --- server-side dry-run: admission / RBAC / schema 를 API server 로 검증 ---
  log "  server-side dry-run 검증"
  if ! kubectl apply -f "$rendered" --dry-run=server \
         --server-side --field-manager="$FIELD_MANAGER" \
         >"$tmpdir/dryrun.out" 2>&1; then
    err "  server-side dry-run 실패 — apply 중단"
    sed 's/^/    /' "$tmpdir/dryrun.out" >&2
    die "dry-run 검증 실패"
  fi

  # --- diff preview — 변경 있음(rc=1)은 정상, 실행 오류(rc>=2)는 die ---
  if [[ "${SKIP_DIFF:-}" == "yes" ]]; then
    warn "  SKIP_DIFF=yes → diff preview 생략"
  else
    log "  server-side diff preview (대용량이면 스크롤)"
    local rc=0
    kubectl diff -f "$rendered" --server-side --field-manager="$FIELD_MANAGER" \
      >"$tmpdir/diff.out" 2>&1 || rc=$?
    case "$rc" in
      0) log "    (변경 없음)" ;;
      1)
        if [[ -s "$tmpdir/diff.out" ]]; then
          sed 's/^/    /' "$tmpdir/diff.out" >&2
        else
          log "    (diff 출력 없음)"
        fi
        ;;
      *)
        err "  kubectl diff 실행 실패 (exit=$rc) — apply 중단"
        sed 's/^/    /' "$tmpdir/diff.out" >&2
        die "diff 실패"
        ;;
    esac
  fi

  confirm "위 변경사항을 env=$ENV_NAME context='$(kubectl config current-context)' 에 apply 하시겠습니까?" \
    || die "사용자 취소"

  kubectl apply -f "$rendered" --server-side --field-manager="$FIELD_MANAGER"
  log "  vault/registry/앱 워크로드 apply 완료"
}

phase4_wait_vault_running() {
  # Vault readiness probe 는 initialized+unsealed 일 때만 통과하므로 초기화 *전*
  # 에는 Ready 가 될 수 없음 → Running 단계까지만 기다림.
  log "[4/9] vault-0 Running 대기 (120s × 재시도 3회)"
  retry 3 10 kubectl -n "$NAMESPACE" wait \
    --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=120s
}

phase5_vault_init() {
  log "[5/9] Vault 초기화 / unseal / auth / policy / role"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vault-init.sh"
}

phase6_seed_apps() {
  log "[6/9] 앱 시크릿 5 개 Vault KV 에 seed"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vault-seed-apps.sh"
}

phase7_vso_install() {
  log "[7/9] VSO Helm upgrade --install"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vso-install.sh"
}

phase8_vso_crs() {
  log "[8/9] VSO CR 적용 ($OVERLAY_DIR/vso/)"
  kubectl apply -k "$OVERLAY_DIR/vso/" \
    --server-side --field-manager="$FIELD_MANAGER"
}

# docker-registry 가 MinIO 를 S3 backend 로 쓰도록 bucket + 서비스 user +
# bucket-scoped policy 를 설정. MinIO Tenant 는 phase 8 에서 minio-tenant-env
# Secret 이 생긴 뒤 기동되므로 이 phase 는 반드시 phase 8 이후에 실행.
phase9_minio_provision_registry() {
  log "[9/9] MinIO docker-registry bucket/user/policy 프로비저닝"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/minio-provision-registry.sh"
}

summary() {
  log "============================================"
  log "  $ENV_NAME 부트스트랩 완료"
  log "============================================"
  log "unseal keys + root token: ${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json} (0600)"
  log "  → 오프라인 / 외부 KMS 로 즉시 이동하세요 (Git 반입 금지)"
  log ""
  log "앱 시크릿 5 개는 Phase 6 에서 입력/seed 됨."
  log "조회: vault kv get -field=password secret/<path>"
  log ""
  log "다음 확인:"
  log "  kubectl -n $NAMESPACE get pods"
  log "  kubectl -n $NAMESPACE get secrets"
  log "  kubectl -n $NAMESPACE get vaultstaticsecret"
}

main() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in
    dev|staging|prod) ;;
    *) usage ;;
  esac

  OVERLAY_DIR="$K8S_ROOT/overlays/$ENV_NAME"
  [[ -d "$OVERLAY_DIR" ]] || die "overlay 디렉토리 없음: $OVERLAY_DIR"

  require_cmd kubectl helm jq kustomize

  # 안전 가드 — 실수 클러스터 apply 방지
  require_kube_context "$ENV_NAME"

  log "============================================"
  log "  Project-Infra 부트스트랩 ($ENV_NAME)"
  log "  context : $(kubectl config current-context)"
  log "============================================"

  precheck_namespace
  phase0_minio_operator
  phase1_namespace
  phase2_reset_stale_secrets
  phase2_5_vso_crds
  phase2_6_cert_manager
  phase2_7_keycloak_operator
  phase2_8_traefik
  phase3_overlay_apply
  phase4_wait_vault_running
  phase5_vault_init
  phase6_seed_apps
  phase7_vso_install
  phase8_vso_crs
  phase9_minio_provision_registry
  summary
}

# Google shell style — 직접 실행일 때만 main 호출 (source 된 경우 함수만 노출).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
