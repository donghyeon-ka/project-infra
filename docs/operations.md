# 운영 / 검증

bootstrap, teardown, validate.sh, 환경별 차등 계획의 **설계 의도** 를 정리한 문서. 단계별 실제 실행 절차는 [guide.md](../guide.md) 에 있다.

## bootstrap 단계

`VaultConnection` / `VaultAuth` / `VaultStaticSecret` 은 VSO Helm 설치로 CRD 가 등록된 뒤에만 apply 할 수 있다. 그래서 `overlays/dev/vso/` 는 dev kustomization 집계에 포함되지 않으며, `bin/bootstrap.sh` 마지막 단계에서 별도로 `kubectl apply -k overlays/dev/vso/` 한다.

| Phase | 작업 | 의존하는 직전 상태 | 멱등 안전? |
|:---:|---|---|---|
| 0 | MinIO Operator Helm install (`tasks/minio-operator-install.sh`) | helm 가능한 클러스터 | ✅ `helm upgrade --install` |
| 1 | `kubectl apply -k base/managing/namespace/` (PSS restricted 라벨 선행) | — | ✅ `kubectl apply` |
| 2 | VSO-managed Secret 점검 | namespace 존재 | ⚠️ `RESET_STALE_SECRETS=yes` 옵션 시 파괴적 |
| 3 | `kubectl apply -k overlays/dev/` (vault + registry + 앱) | namespace + PSS 라벨 | ✅ `kubectl apply` |
| 4 | `vault-0` Pod Running 대기 | Phase 3 의 Vault StatefulSet | ✅ wait 만 |
| 5 | `tasks/vault-init.sh` (init / unseal / auth / policy×2 / role×2) | `vault-0` Running | ✅ 상태 체크 후 차이만 적용 |
| 6 | `tasks/vso-install.sh` (helm upgrade --install) | Vault auth/role 준비 | ✅ `helm upgrade --install` |
| 7 | `kubectl apply -k overlays/dev/vso/` (VaultConnection / VaultAuth / VaultStaticSecret) | Phase 6 의 VSO CRD 등록 | ✅ `kubectl apply` |

Phase 5 의 1 회성 셋업 흐름은 [secret-pipeline-bootstrap 시퀀스](diagrams/sequence/secret-pipeline-bootstrap.md), Phase 7 이후의 정상 reconcile 은 [secret-pipeline-runtime 시퀀스](diagrams/sequence/secret-pipeline-runtime.md) 참고.

```bash
# dev — 비밀번호를 프롬프트에서 무음 입력 (bash history 에 안 남음)
bash k8s/scripts/bin/bootstrap.sh dev

# teardown — 대화형 y/N
bash k8s/scripts/bin/teardown.sh dev
```

## 스크립트 구조

`k8s/scripts/` 는 `bin / ci / lib / tasks` 4 축:

| 디렉토리 | 역할 |
|---|---|
| `bin/` | 사용자 진입점. `bootstrap.sh` / `teardown.sh` |
| `ci/` | CI / 로컬 검증. `validate.sh` (kustomize + kubeconform + kube-linter) |
| `lib/` | 공통 Bash 라이브러리. `common.sh` (strict mode / trap / log / confirm / retry / mask_secret) + `vault.sh` |
| `tasks/` | 재사용 작업. `vault-init.sh` / `vault-seed-apps.sh` / `vso-install.sh` |

모든 쉘 스크립트는 `set -Eeuo pipefail` + `IFS=$'\n\t'` + `trap_cleanup` 으로 공통 에러 처리. root token / registry BasicAuth 같은 민감 값은 **stdin 파이프** 로만 전달하고 stdout 에 찍지 않는다.

## 검증 (validate.sh)

```bash
bash k8s/scripts/ci/validate.sh
```

3 단계:

1. 각 overlay 에 대해 `kustomize build` (환경 중립성 / patch 유효성)
2. 렌더 결과에 `kubeconform -strict -ignore-missing-schemas` (Kubernetes OpenAPI + Datree CRD catalog)
3. 렌더 결과에 `kube-linter lint --config .kube-linter.yaml` (securityContext / resources / PSS / image tag 등)

`.kube-linter.yaml` 은 **블록 단위 분석으로 생기는 컨텍스트 오탐 4 종**(`dangling-service`, `non-existent-service-account`, `mismatching-selector`, `no-anti-affinity`) 만 제외한다. 나머지는 모두 활성.

목표 상태:

```
k8s/overlays/dev             build=ok  schema=ok  lint=ok
k8s/overlays/dev/vso         build=ok  schema=ok  lint=ok
```

## 환경별 배포

현재 `dev` overlay 만 완성. `staging` / `prod` 는 의도적으로 비어 있고 추후 확장 예정. validate.sh 는 `kustomization.yaml` 이 없는 환경을 자동 스킵한다 — 빈 overlay 가 CI 를 빨갛게 만들지 않기 위함.

### 계획된 환경별 차등

| 리소스 | dev | staging | prod |
|---|---|---|---|
| Vault replicas / storage | 1 / 1Gi | 1 / 5Gi | 3 (HA Raft) / 20Gi |
| Registry replicas / storage | 1 / 5Gi | 1 / 10Gi | 2 / 50Gi |
| PostgreSQL retention policy | Delete | Retain | Retain |
| 이미지 tag 정책 | semver tag | semver tag | `@sha256:` digest pin |
| TLS | 비활성화 | cert-manager | cert-manager + HSTS |

prod 승격 시 필수 작업:

- Vault storage `file` → `raft` + KMS auto-unseal
- Postgres backup CronJob (Velero / pgBackRest)
- cert-manager ClusterIssuer 로 TLS 전환
- 이미지 tag → digest pin
