#!/usr/bin/env bash
# Validate all kustomize overlays against schema + lint rules,
# 그리고 scripts/ 전체에 대해 shell 품질 게이트 (shellcheck + shfmt) 를 실행한다.
#
# Runs, for each environment (dev, staging, prod):
#   1. `kustomize build overlays/<env>`           — structural validity
#   2. `kustomize build overlays/<env>/vso`       — VSO CRD overlay (built separately
#                                                    because it requires the VSO Helm
#                                                    release to be installed first)
#   3. `kubeconform -strict -ignore-missing-schemas`  — OpenAPI schema validation
#      with CRD schemas fetched from the Datree catalog.
#   4. `kube-linter lint`                         — anti-pattern lint against
#      root .kube-linter.yaml configuration.
#
# Plus (not per-overlay):
#   5. `shellcheck -S style` over k8s/scripts/**/*.sh  — shell correctness + style
#   6. `shfmt -i 2 -bn -ci -d` over k8s/scripts/       — formatting diff (fail on drift)
#
# Exit codes:
#   0 — everything passed
#   1 — at least one step failed (details printed)
#
# Tools expected on $PATH:
#   kustomize kubeconform kube-linter shellcheck shfmt

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"
KUBE_LINTER_CFG="$REPO_ROOT/.kube-linter.yaml"

# Local-user tooling fallback: when tools aren't installed system-wide,
# allow users to drop them under ~/bin (CI typically installs to a PATH dir).
if [[ -d "$HOME/bin" ]]; then
  export PATH="$HOME/bin:$PATH"
fi

require_cmd kustomize kubeconform kube-linter shellcheck shfmt

ENVS=(dev staging prod)
OVERLAYS_TO_BUILD=()
for env in "${ENVS[@]}"; do
  root_overlay="$K8S_ROOT/overlays/$env"
  vso_overlay="$K8S_ROOT/overlays/$env/vso"
  if [[ -f "$root_overlay/kustomization.yaml" ]]; then
    OVERLAYS_TO_BUILD+=("$root_overlay")
  else
    log "skip (kustomization.yaml 없음): overlays/$env"
  fi
  if [[ -f "$vso_overlay/kustomization.yaml" ]]; then
    OVERLAYS_TO_BUILD+=("$vso_overlay")
  fi
done

# Datree CRD catalog — kubeconform fetches per-CRD JSON schema on demand.
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

WORK_DIR="$(mktemp -d -t project-infra-validate.XXXXXX)"
trap_cleanup_path "$WORK_DIR"

declare -A BUILD_STATUS SCHEMA_STATUS LINT_STATUS

for overlay in "${OVERLAYS_TO_BUILD[@]}"; do
  rel="${overlay#"$REPO_ROOT/"}"
  rendered="$WORK_DIR/$(echo "$rel" | tr '/' '_').yaml"

  # -- 1. kustomize build ----------------------------------------------------
  if kustomize build "$overlay" > "$rendered" 2>"$rendered.err"; then
    BUILD_STATUS[$rel]="ok"
    log "kustomize build $rel — OK ($(grep -c '^kind:' "$rendered") resources)"
  else
    BUILD_STATUS[$rel]="fail"
    err "kustomize build $rel — FAIL"
    cat "$rendered.err" >&2
    continue
  fi

  # -- 2. kubeconform --------------------------------------------------------
  if kubeconform -strict -ignore-missing-schemas \
       -schema-location default \
       -schema-location "$CRD_CATALOG" \
       -summary \
       "$rendered" >"$rendered.kconf" 2>&1; then
    SCHEMA_STATUS[$rel]="ok"
    log "  kubeconform — OK ($(tail -1 "$rendered.kconf"))"
  else
    SCHEMA_STATUS[$rel]="fail"
    err "  kubeconform — FAIL"
    cat "$rendered.kconf" >&2
  fi

  # -- 3. kube-linter --------------------------------------------------------
  if kube-linter lint --config "$KUBE_LINTER_CFG" "$rendered" \
       >"$rendered.klint" 2>&1; then
    LINT_STATUS[$rel]="ok"
    log "  kube-linter — OK"
  else
    LINT_STATUS[$rel]="fail"
    err "  kube-linter — findings:"
    sed 's/^/    /' "$rendered.klint" >&2
  fi
done

# -----------------------------------------------------------------------------
# 5. shellcheck — scripts/**/*.sh 전체
# -----------------------------------------------------------------------------
SHELL_STATUS="skip"
SCRIPTS_ROOT="$K8S_ROOT/scripts"
mapfile -t SHELL_FILES < <(find "$SCRIPTS_ROOT" -type f -name '*.sh' -print | sort)

if (( ${#SHELL_FILES[@]} > 0 )); then
  log "shellcheck — ${#SHELL_FILES[@]} files"
  if shellcheck -S style -x "${SHELL_FILES[@]}" >"$WORK_DIR/shellcheck.out" 2>&1; then
    SHELL_STATUS="ok"
    log "  shellcheck — OK"
  else
    SHELL_STATUS="fail"
    err "  shellcheck — findings:"
    sed 's/^/    /' "$WORK_DIR/shellcheck.out" >&2
  fi
fi

# -----------------------------------------------------------------------------
# 6. shfmt — 포매팅 drift 검증 (수정 없이 diff 만 출력)
# -----------------------------------------------------------------------------
FMT_STATUS="skip"
if (( ${#SHELL_FILES[@]} > 0 )); then
  log "shfmt -i 2 -bn -ci -d"
  if shfmt -i 2 -bn -ci -d "${SHELL_FILES[@]}" >"$WORK_DIR/shfmt.out" 2>&1; then
    FMT_STATUS="ok"
    log "  shfmt — OK"
  else
    FMT_STATUS="fail"
    err "  shfmt — drift 감지 (로컬에서 'shfmt -i 2 -bn -ci -w k8s/scripts' 로 정렬하세요):"
    sed 's/^/    /' "$WORK_DIR/shfmt.out" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo >&2
log "============================================"
log "  Validation summary"
log "============================================"

failed=0
for overlay in "${OVERLAYS_TO_BUILD[@]}"; do
  rel="${overlay#"$REPO_ROOT/"}"
  b="${BUILD_STATUS[$rel]:-skip}"
  s="${SCHEMA_STATUS[$rel]:-skip}"
  l="${LINT_STATUS[$rel]:-skip}"
  printf '  %-40s  build=%-4s  schema=%-4s  lint=%s\n' "$rel" "$b" "$s" "$l" >&2
  [[ "$b" == "fail" || "$s" == "fail" || "$l" == "fail" ]] && failed=$((failed + 1))
done
printf '  %-40s  shellcheck=%-4s  shfmt=%s\n' "scripts/" "$SHELL_STATUS" "$FMT_STATUS" >&2
[[ "$SHELL_STATUS" == "fail" || "$FMT_STATUS" == "fail" ]] && failed=$((failed + 1))

if (( failed > 0 )); then
  err "$failed check(s) 실패"
  exit 1
fi

log "모든 check 통과"
