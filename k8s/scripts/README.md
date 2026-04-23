# Kubernetes Scripts

Imperative bootstrap, teardown, and break-glass operations for the `mnt` infra
stack. 선언적 관리(Service/Job/DB rollout 등)는 Kustomize 패키지의 몫이고,
여기 스크립트는 **phase orchestration** 과 **one-shot imperative setup**
(Vault init / unseal, Helm install) 만 담당한다.

## Layout

```
scripts/
├── bin/                  # 사용자가 직접 실행하는 엔트리 포인트 (main "$@")
│   ├── bootstrap.sh      # 전체 스택 부트스트랩
│   └── teardown.sh       # 전체 스택 제거
├── tasks/                # bin/ 이 호출하는 단일 책임 태스크
│   ├── minio-operator-install.sh
│   ├── vault-init.sh         # Vault init + unseal + k8s auth + policy/role
│   ├── vault-seed-apps.sh    # 앱 시크릿 5 개 Vault KV 에 seed
│   ├── vault-setup-admin.sh
│   └── vso-install.sh        # VSO Helm upgrade --install
├── lib/                  # 공유 쉘 라이브러리
│   ├── common.sh         # log/die, retry, confirm, kube-context 가드, finalizer 헬퍼
│   └── vault.sh          # vault_exec 래퍼, 로그인/unseal 유틸
└── ci/
    └── validate.sh       # kustomize build + kubeconform + kube-linter + shellcheck + shfmt
```

## Entry points

```bash
# 부트스트랩 (대화형, bash history 안전)
bash k8s/scripts/bin/bootstrap.sh <dev|staging|prod>

# 제거 (정상 경로)
bash k8s/scripts/bin/teardown.sh <dev|staging|prod>
CONFIRM=yes bash k8s/scripts/bin/teardown.sh <dev|staging|prod>

# 로컬/CI 품질 게이트
bash k8s/scripts/ci/validate.sh
```

## 필수 환경 변수 (안전 가드)

쉘 rc 에 한 번 선언:

```bash
export KUBE_CONTEXT_DEV="homelab"
export KUBE_CONTEXT_STAGING="staging-cluster"
export KUBE_CONTEXT_PROD="prod-cluster"
```

- `bin/bootstrap.sh` 와 `bin/teardown.sh` 는 `ENV_NAME` 에 대응하는
  `KUBE_CONTEXT_<ENV>` 와 `kubectl config current-context` 가 일치하는지
  **실행 전 검증**한다. 매핑이 없으면 대화형으로 현재 context 이름 재입력을
  요구한다.
- `env=prod` destructive 작업은 `ALLOW_PROD_DESTRUCTIVE=yes` 와 namespace
  이름 재입력 TTY 확인이 추가로 필요하다.

## 파괴적 플래그

| 플래그 | 범위 | 효과 |
| --- | --- | --- |
| `CONFIRM=yes` | 두 엔트리 | 대화형 확인 프롬프트 자동 승인 (CI) |
| `SKIP_DIFF=yes` | bootstrap | Phase 3 의 `kubectl diff` preview 생략 (비권장) |
| `RESET_STALE_SECRETS=yes` | bootstrap | VSO-managed K8s Secret 을 선제 삭제 (Vault 값 재주입 유도) |
| `VAULT_KEYS_FILE=<path>` | bootstrap | Vault init key 저장 위치. **env=prod 는 repo 바깥 경로 필수** |
| `FORCE_FINALIZERS=yes` | teardown | Phase 6 활성 — finalizer 강제 제거 + `/finalize` API. Terminating 복구 외 금지 |
| `ALLOW_PROD_DESTRUCTIVE=yes` | teardown | env=prod teardown 허용 (namespace 재입력 추가 확인 필요) |
| `TEARDOWN_VSO_OPERATOR=yes` | teardown | **클러스터 공용** VSO Helm 릴리즈 + 전용 namespace + `vault-tokenreview-binding` 제거. 다른 env 의 Vault/VSO 가 함께 멈춤 |
| `TEARDOWN_VSO_CRDS=yes` | teardown | **클러스터 공용** VSO CRD + ClusterRole/CRB/Webhook 제거. 모든 env 의 VaultStaticSecret 인스턴스가 삭제됨 |
| `TEARDOWN_MINIO_OPERATOR=yes` | teardown | MinIO Operator Helm 릴리즈까지 제거 |

## Rules

- 서비스 단위 스크립트를 새로 만들지 않는다.
- Service / Job / Scheduler / DB rollout 은 Kustomize 패키지에서 선언.
- 스크립트는 phase orchestration 이지 Kubernetes 리소스 스펙의 출처가 아니다.
- 비트리비얼 스크립트는 `functions + main "$@"` 구조를 따른다.
- 모든 `.sh` 는 `ci/validate.sh` 의 `shellcheck -S style` + `shfmt -i 2 -bn -ci`
  를 통과해야 한다.
