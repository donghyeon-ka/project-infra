# Project-Infra

Kubernetes 기반 인프라 프로젝트. 클러스터 내 Private Docker Registry와 HashiCorp Vault를 운영하고, Vault Secrets Operator(VSO)로 시크릿을 자동 동기화하며, `auth-server` / `keycloak` / `identity-postgres` / `minio` / `test-server` / `migration-flyway` 워크로드까지 Kustomize 단일 namespace(`mnt`) 체계에서 함께 관리한다.

> 실제 배포·운영 절차는 [guide.md](guide.md) 참조.

---

## 목차

1. [아키텍처](#아키텍처)
2. [폴더 구조](#폴더-구조)
3. [네임스페이스 전략](#네임스페이스-전략)
4. [NetworkPolicy 전략](#networkpolicy-전략)
5. [이미지 정책](#이미지-정책)
6. [Vault](#vault)
7. [Vault Secrets Operator (VSO)](#vault-secrets-operator-vso)
8. [Docker Registry](#docker-registry)
9. [워크로드 목록](#워크로드-목록)
10. [스크립트 구조](#스크립트-구조)
11. [검증](#검증)
12. [환경별 배포](#환경별-배포)

---

## 아키텍처

```
┌─────────────────────────── namespace: mnt ───────────────────────────┐
│                                                                      │
│   [ Vault (StatefulSet) ] ← VSO (Helm-installed Operator)            │
│           │                      │                                   │
│           │ TokenReview          │ reads KV-v2                       │
│           ▼                      ▼                                   │
│   ClusterRoleBinding       VaultStaticSecret (CRD)                   │
│   system:auth-delegator     → K8s Secret                             │
│                                │                                     │
│                                ▼                                     │
│   ┌──────────────────────────────────────────────────────────┐       │
│   │ 워크로드                                                  │       │
│   │  · auth-server      (Deployment)                         │       │
│   │  · keycloak         (Deployment)                         │       │
│   │  · identity-postgres(StatefulSet)                        │       │
│   │  · migration-flyway (Job, ArgoCD PreSync sync-wave=-1)   │       │
│   │  · minio            (Tenant CRD — MinIO Operator)        │       │
│   │  · test-server-1/2/3(Deployment)                         │       │
│   │  · docker-registry  (StatefulSet, htpasswd auth)         │       │
│   └──────────────────────────────────────────────────────────┘       │
│                                                                      │
│   NetworkPolicy: default-deny + DNS egress baseline                  │
│                + 컴포넌트별 ingress/egress allow                      │
└──────────────────────────────────────────────────────────────────────┘
```

시크릿 흐름:

```
Vault KV (secret/…)
   ↓  VSO 가 refreshAfter 주기로 동기화
K8s Secret (mnt namespace)
   ↓  워크로드가 envFrom / volume / imagePullSecrets 로 참조
애플리케이션 Pod
```

---

## 폴더 구조

```
Project-Infra/
├── .gitignore                                  # vault-init-keys.json 제외
├── .kube-linter.yaml                           # kube-linter 규칙 (컨텍스트 오탐 4종 제외)
├── README.md                                   # 본 문서
├── guide.md                                    # 운영 절차
│
├── k8s/
│   ├── base/
│   │   ├── managing/
│   │   │   ├── namespace/                      # mnt namespace 정의 + PSS restricted 라벨
│   │   │   │   ├── namespace.yaml
│   │   │   │   └── kustomization.yaml
│   │   │   ├── migration-flyway/               # Flyway 마이그레이션 Job (공식 이미지)
│   │   │   └── kustomization.yaml              # namespace 만 집계
│   │   │
│   │   ├── app/                                # 애플리케이션 워크로드 (소유권 = 개발팀)
│   │   │   ├── identity/
│   │   │   │   ├── auth/
│   │   │   │   │   ├── stateful/identity-postgres/
│   │   │   │   │   └── stateless/auth-server/        # example 이미지
│   │   │   │   └── keycloak/stateless/keycloak/
│   │   │   ├── storage/minio/stateful/minio/
│   │   │   └── test/stateless/test-server-{1,2,3}/   # example 이미지
│   │   │
│   │   └── plugins/                            # 플랫폼 플러그인 (다른 워크로드가 의존)
│   │       ├── vault/                          # Vault StatefulSet (공식 이미지)
│   │       ├── docker-registry/                # Registry StatefulSet (공식 이미지)
│   │       └── vso/
│   │           ├── kustomization.yaml          # VaultConnection / VaultAuth / VaultStaticSecret
│   │           ├── vault-connection.yaml
│   │           ├── vault-auth.yaml
│   │           ├── serviceaccount.yaml
│   │           ├── vault-static-secret-htpasswd.yaml
│   │           ├── vault-static-secret-pull-cred.yaml
│   │           └── helm/values.yaml            # VSO Operator 설치용 Helm values
│   │
│   ├── overlays/
│   │   └── dev/
│   │       ├── kustomization.yaml              # dev 전체 집계 (namespace: mnt)
│   │       ├── networkpolicy-baseline.yaml     # default-deny + DNS egress
│   │       ├── vault/                          # Vault overlay + NetworkPolicy + storage patch
│   │       ├── registry/                       # Registry overlay + NetworkPolicy + storage patch
│   │       ├── vso/                            # VSO CRDs (Helm 설치 후 별도 apply)
│   │       ├── database/                       # identity-postgres + VaultStaticSecret + NetworkPolicy
│   │       ├── auth/                           # auth-server + flyway + PreSync sync-wave=-1 + NetworkPolicy
│   │       ├── keycloak/                       # keycloak + VaultStaticSecret + hostname patch + NetworkPolicy
│   │       ├── storage/                        # minio + VaultStaticSecret + certConfig FQDN patch + NetworkPolicy
│   │       └── test/                           # test-server 1/2/3 + NetworkPolicy
│   │   staging/                                # 의도적으로 비어둠 (추후 확장)
│   │   prod/                                   # 의도적으로 비어둠 (추후 확장)
│   │
│   └── scripts/
│       ├── bin/                                # 사용자 진입점
│       │   ├── bootstrap.sh                    # 6-phase 부트스트랩
│       │   └── teardown.sh                     # 5-phase 정리 (CONFIRM=yes 지원)
│       ├── ci/
│       │   └── validate.sh                     # kustomize + kubeconform + kube-linter
│       ├── lib/
│       │   ├── common.sh                       # strict/trap/log/die/confirm/retry/mask_secret
│       │   └── vault.sh                        # vault_exec / is_initialized / is_sealed / ...
│       └── tasks/                              # 재사용 가능한 작업 단위
│           ├── vault-init.sh                   # Vault init + unseal + auth + KV + policy/role
│           ├── vault-seed-registry.sh          # htpasswd 생성 → Vault KV 저장
│           └── vso-install.sh                  # helm upgrade --install (idempotent)
│
└── terraform/                                  # (현재 contracts 만, 추후 구현)
```

---

## 네임스페이스 전략

**`mnt` 단일 namespace** 체계. 학습 단계의 단순성 우선이며, 실무에서는 역할별 namespace 분리가 원칙이다.

- Namespace 정의: `k8s/base/managing/namespace/`
- 모든 리소스는 overlay kustomization 의 `namespace: mnt` 로 일괄 주입
- **Pod Security Standards**: `pod-security.kubernetes.io/enforce=restricted` 적용 (audit + warn 동시). Privileged / hostPath / hostNetwork 같은 위험 필드가 admission 에서 자동 거절된다.
- 스케일 업 계획: 추후 역할별 namespace(`auth`, `storage`, `security`, `registry` 등)로 분리 가능하도록 base 는 환경 중립으로 작성되어 있다.

---

## NetworkPolicy 전략

단일 namespace 내부에서도 서비스 간 트래픽은 **최소권한**으로 제한한다.

| 정책 파일 | 역할 |
|---|---|
| `overlays/dev/networkpolicy-baseline.yaml` | `default-deny-all` (전 Pod ingress/egress 기본 차단) + `allow-dns-egress` (kube-system/kube-dns 53) |
| `overlays/dev/database/networkpolicy.yaml` | identity-postgres ingress ← keycloak / auth-server / migration-flyway (5432) |
| `overlays/dev/auth/networkpolicy.yaml` | auth-server egress → postgres(5432) + keycloak(8080); flyway egress → postgres(5432) |
| `overlays/dev/keycloak/networkpolicy.yaml` | keycloak egress → postgres(5432); ingress ← auth-server(8080) |
| `overlays/dev/storage/networkpolicy.yaml` | minio ingress ← `part-of=auth-platform`(9000); 자체 peer(9000/9001) |
| `overlays/dev/test/networkpolicy.yaml` | test-server 3대 내부 상호 통신만 허용 |
| `overlays/dev/vault/networkpolicy.yaml` | vault ingress ← VSO Operator Pod(8200) |
| `overlays/dev/registry/networkpolicy.yaml` | docker-registry ingress ← namespace 내 전 Pod(5000) |

cross-namespace 참조가 필요한 항목은 `namespaceSelector` + `podSelector` 를 한 블록에 조합해 AND 시맨틱으로 작성한다.

---

## 이미지 정책

| 구분 | 이미지 | 근거 |
|---|---|---|
| **공식 upstream** | `hashicorp/vault:1.17.2` | HashiCorp 공식 Docker Hub |
| | `registry:2.8.3` | Docker library 공식 |
| | `postgres:16.4` | PostgreSQL 공식 |
| | `quay.io/keycloak/keycloak:26.0.7` | Keycloak 공식 quay.io (args: `[start]`) |
| | `minio/minio:RELEASE.2025-01-20T14-49-07Z` | MinIO 공식 |
| | `flyway/flyway:10.20.1` | Flyway 공식 |
| **example (사용자 개발)** | `registry.example.com/auth-platform/auth-server:0.1.0` | 조직 개발 서비스 |
| | `registry.example.com/test-platform/test-server-{1,2,3}:0.1.0` | 조직 개발 서비스 |

prod 전환 시에는 공식 이미지도 digest pin(`@sha256:…`)으로 바꾼다.

---

## Vault

| 항목 | 값 |
|---|---|
| 이미지 | `hashicorp/vault:1.17.2` |
| 배포 | StatefulSet (replicas 1, file backend) |
| 실행 | `vault server -config=/vault/config/vault.hcl` |
| 포트 | 8200 (http) / 8201 (cluster) — 내부 ClusterIP 만, NodePort 없음 |
| 저장 | PVC 5Gi (dev overlay에서 1Gi로 patch) |
| UI 접근 | `kubectl -n mnt port-forward svc/vault 8200:8200` (외부 노출 금지) |

### 설계 결정

- **file backend 유지 (learning env)**: 단일 노드 + 학습 목적으로 `storage "file"`. HA 불가. 프로덕션 승격 시에는 `storage "raft"` + KMS 기반 auto-unseal 로 전환한다. ADR 로 별도 기록 예정.
- **`disable_mlock = true`**: 컨테이너에 `IPC_LOCK` capability 를 부여하지 않고 PSS Restricted 프로필을 유지하기 위함. 대신 swap 이 꺼진 노드에서 실행해야 한다.
- **`tls_disable = 1`**: 단일 namespace 내부 통신만 발생하고 cert-manager 전에 부트스트랩이 먼저 끝나야 해서 현재는 비활성화. 클러스터 밖 노출 시 반드시 cert-manager 발급 인증서로 TLS 를 켠다.
- **`api_addr: http://vault:8200` + `cluster_addr: http://vault:8201`**: 짧은 Service 이름. 모든 소비자가 같은 `mnt` namespace 에 있으므로 FQDN 불필요.

### RBAC

**ClusterRoleBinding `vault-tokenreview-binding` ← `system:auth-delegator`**. Vault 의 Kubernetes auth method 는 클라이언트(VSO 등)가 제출한 ServiceAccount JWT 를 `TokenReview` + `SubjectAccessReview` API 로 검증한다. 이 ClusterRoleBinding 이 없으면 VSO 로그인이 `permission denied` 로 실패한다.

Vault Pod 의 ServiceAccount 는 `automountServiceAccountToken: true` (기본값). Vault 는 `/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt}` 를 읽어 `auth/kubernetes/config` 의 `token_reviewer_jwt` / `kubernetes_ca_cert` 를 채운다.

### Kubernetes auth 초기 설정

`tasks/vault-init.sh` 가 수행:

```
vault auth enable kubernetes                              (idempotent 체크)
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

vault secrets enable -path=secret kv-v2                   (idempotent 체크)

# policy 3개 (역할별 least-privilege)
vault policy write vso-registry      - < docker-registry/* read
vault policy write vso-auth-platform - < identity-postgres/* + auth-server/* + keycloak/* read
vault policy write vso-storage       - < minio/* read

# role 3개 (같은 SA, 다른 policy)
vault write auth/kubernetes/role/vso-registry      policies=vso-registry      bound_sa=vault-secrets-operator/mnt ttl=1h
vault write auth/kubernetes/role/vso-auth-platform policies=vso-auth-platform bound_sa=vault-secrets-operator/mnt ttl=1h
vault write auth/kubernetes/role/vso-storage       policies=vso-storage       bound_sa=vault-secrets-operator/mnt ttl=1h
```

### VaultAuth / VaultStaticSecret 매핑

policy 분리에 따라 VaultAuth CR 도 3 개이며 각 VaultStaticSecret 은 자기 도메인의 VaultAuth 를 참조한다:

| VaultAuth CR | Vault role | 참조하는 VaultStaticSecret |
|---|---|---|
| `vault-auth-registry` | `vso-registry` | `docker-registry-htpasswd`, `registry-pull-credential` |
| `vault-auth-auth-platform` | `vso-auth-platform` | `identity-postgres-superuser`, `keycloak-db-creds`, `auth-server-db-creds`, `keycloak-bootstrap-admin` |
| `vault-auth-storage` | `vso-storage` | `minio-tenant-env` |

VSO Operator SA (`vault-secrets-operator`) 는 한 개이지만 Vault 쪽에서 role 별로 policy 가 분리되어 있어 각 도메인의 secret 만 읽을 수 있다. Registry 자격증명이 유출돼도 DB 나 MinIO secret 은 보호된다.

---

## Vault Secrets Operator (VSO)

HashiCorp 공식 Operator. Vault KV → K8s Secret 자동 동기화.

### 배포 순서 (CRD 의존성)

`VaultConnection` / `VaultAuth` / `VaultStaticSecret` 은 VSO Helm 설치로 CRD 가 등록된 뒤에만 apply 할 수 있다. 그래서 `overlays/dev/vso/` 는 `overlays/dev/kustomization.yaml` 집계에 포함되지 않으며, `bin/bootstrap.sh` 마지막 단계에서 별도로 `kubectl apply -k overlays/dev/vso/` 한다.

```
Phase 1 : kubectl apply -k overlays/dev/              (namespace + vault + registry + 앱)
Phase 2 : vault-0 Ready 대기
Phase 3 : tasks/vault-init.sh                          (init + unseal + auth + policy/role)
Phase 4 : tasks/vault-seed-registry.sh                 (htpasswd 생성 → Vault KV)
Phase 5 : tasks/vso-install.sh                         (helm upgrade --install)
Phase 6 : kubectl apply -k overlays/dev/vso/           (CRDs)
```

### VaultConnection address

base 는 `http://vault:8200` (짧은 이름) 만 둔다. VSO Operator Pod 가 같은 `mnt` namespace 에서 실행되면 Kubernetes DNS 가 짧은 이름을 해결한다. 다른 namespace 에서 운영할 때는 overlay 에서 FQDN 으로 patch 한다.

### VSO 가 관리하는 Secret

| VaultStaticSecret (base) | Vault 경로 | K8s Secret | 소비 방식 |
|---|---|---|---|
| `docker-registry-htpasswd` | `secret/docker-registry/auth` | `docker-registry-htpasswd` | volume mount (`/auth/htpasswd`) |
| `registry-pull-credential` | `secret/docker-registry/pull-credentials` | `registry-pull-credential` (`kubernetes.io/dockerconfigjson`) | `imagePullSecrets` 참조 |

| VaultStaticSecret (dev overlay) | Vault 경로 | K8s Secret | 소비 방식 |
|---|---|---|---|
| `identity-postgres-superuser` | `secret/identity-postgres/superuser` | `identity-postgres-superuser` | file mount (`/run/secrets/superuser/`) → `POSTGRES_USER_FILE`, `POSTGRES_PASSWORD_FILE` |
| `keycloak-db-creds` | `secret/keycloak/db` | `keycloak-db` | file mount — postgres initdb + keycloak `KC_DB_PASSWORD_FILE` |
| `auth-server-db-creds` | `secret/auth-server/db` | `auth-server-db` | file mount — auth-server `SPRING_CONFIG_IMPORT=configtree:/etc/secrets/` + Flyway sh wrapper |
| `keycloak-bootstrap-admin` | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` | file mount — `KC_BOOTSTRAP_ADMIN_{USERNAME,PASSWORD}_FILE` |
| `minio-tenant-env` | `secret/minio/tenant-env` | `minio-tenant-env` | MinIO Operator `spec.configuration.name` (env file) |

모든 VaultStaticSecret 은 `destination.overwrite` 기본값(false) 을 사용해 기존 Secret 이 수동으로 존재하면 VSO 가 덮어쓰지 않는다 (Secret 소유권 경합 방지). **Vault 값을 교체한 뒤 즉시 반영하려면 `kubectl -n mnt delete secret <name>` 으로 기존 Secret 을 지우면 VSO 가 다음 reconcile 에 새 값으로 재생성한다.**

### dockerconfigjson `.auth` 필드

Docker 공식 config 스키마는 `.auth = base64("<username>:<password>")` 형태다. 기존에는 password 만 base64 하는 버그가 있었고 현재는 `{{ printf "%s:%s" username password | b64enc }}` 로 수정되어 있다. Docker daemon 이 Registry 에 로그인할 때 이 필드를 디코드하므로 정확한 포맷이 필수.

`refreshAfter: 1h` — Vault 값 변경 시 1 시간 내 K8s Secret 에 자동 반영.

---

## Docker Registry

| 항목 | 값 |
|---|---|
| 이미지 | `registry:2.8.3` (Docker library 공식) |
| 배포 | StatefulSet (replicas 1, volumeClaimTemplate) |
| 서비스 | `docker-registry.mnt.svc.cluster.local:5000` |
| 인증 | htpasswd (`/auth/htpasswd` volume mount) |
| 저장 | PVC 10Gi (dev overlay에서 5Gi로 patch) |
| 계정 | `push-user` (write) / `pull-user` (read-only) — 계정 분리 |

Registry Pod 의 `/auth/htpasswd` 는 VSO 가 `VaultStaticSecret docker-registry-htpasswd` 로부터 합성한 K8s Secret 을 volume mount 한 것이다. Secret 이 생성되기 전까지 Pod 는 `ContainerCreating` 상태로 대기한다. 이는 정상 동작이다.

### Push / Pull

```bash
docker login docker-registry.mnt.svc.cluster.local:5000
docker tag my-app:v1 docker-registry.mnt.svc.cluster.local:5000/my-app:v1
docker push docker-registry.mnt.svc.cluster.local:5000/my-app:v1
```

```yaml
spec:
  imagePullSecrets:
    - name: registry-pull-credential
  containers:
    - name: my-app
      image: docker-registry.mnt.svc.cluster.local:5000/my-app:v1
```

---

## 워크로드 목록

| 워크로드 | 종류 | 위치 | 참조 Secret |
|---|---|---|---|
| `identity-postgres` | StatefulSet | `base/app/identity/auth/stateful/` | `identity-postgres-superuser`, `keycloak-db`, `auth-server-db` |
| `auth-server` | Deployment | `base/app/identity/auth/stateless/` | `auth-server-db` |
| `keycloak` | Deployment | `base/app/identity/keycloak/stateless/` | `keycloak-db`, `keycloak-bootstrap-admin` |
| `minio` | Tenant CRD | `base/app/storage/minio/stateful/` | `minio-tenant-env` |
| `test-server-1/2/3` | Deployment | `base/app/test/stateless/` | — |
| `migration-flyway` | Job | `base/managing/migration-flyway/` | `auth-server-db` (FLYWAY_USER/PASSWORD) |

auth-server 의 ConfigMap 이 `jdbc:postgresql://identity-postgres:5432/auth_server` 로 접속, keycloak 의 ConfigMap 이 `jdbc:postgresql://identity-postgres:5432/keycloak` 로 접속. 모두 같은 namespace 이므로 short name 사용.

### Flyway 실행 순서

dev overlay 가 migration-flyway Job 에 ArgoCD annotation 을 patch 한다:

```
argocd.argoproj.io/sync-wave: "-1"
argocd.argoproj.io/hook: PreSync
```

ArgoCD 배포 시 Job 이 앱보다 먼저 실행되어 스키마 마이그레이션을 마친 뒤 `auth-server` 가 뜬다.

### Keycloak hostname patch

dev overlay 의 JSON patch 가 Keycloak ConfigMap 에 `KC_HOSTNAME=https://keycloak.dev.example.com` / `KC_HOSTNAME_ADMIN=https://keycloak-admin.dev.example.com` 를 주입한다. staging / prod 는 자체 hostname 을 overlay 에서 주입하면 된다.

### MinIO certConfig.dnsNames

base 는 짧은 이름(`minio`, `minio-hl`) 만 두고, dev overlay 가 `minio.mnt.svc.cluster.local` 과 `*.minio-hl.mnt.svc.cluster.local` 을 patch 한다. 이 방식이 base 환경 중립성 원칙을 지킨다.

---

## 스크립트 구조

`k8s/scripts/` 는 `bin / ci / lib / tasks` 4 축으로 구성된다.

| 디렉토리 | 역할 |
|---|---|
| `bin/` | 사용자 진입점. `bootstrap.sh` / `teardown.sh` |
| `ci/` | CI / 로컬 검증. `validate.sh` (kustomize + kubeconform + kube-linter) |
| `lib/` | 공통 Bash 라이브러리. `common.sh` (strict mode / trap / log / confirm / retry / mask_secret) + `vault.sh` (Vault 헬퍼) |
| `tasks/` | 재사용 가능한 작업 단위. `vault-init.sh` / `vault-seed-registry.sh` / `vso-install.sh` |

모든 쉘 스크립트는 `set -Eeuo pipefail` + `IFS=$'\n\t'` + `trap_cleanup` 으로 공통 에러 처리. root token / htpasswd 같은 민감 값은 **stdin 파이프** 로만 전달하고 stdout 에 찍지 않는다.

---

## 검증

```bash
bash k8s/scripts/ci/validate.sh
```

항목:
1. 각 overlay 에 대해 `kustomize build` (환경 중립성 / patch 유효성)
2. 렌더 결과에 `kubeconform -strict -ignore-missing-schemas` (Kubernetes OpenAPI + Datree CRD catalog)
3. 렌더 결과에 `kube-linter lint --config .kube-linter.yaml` (securityContext / 리소스 / PSS / image tag 등)

`.kube-linter.yaml` 은 **블록 단위 분석으로 생기는 컨텍스트 오탐 4 종** (`dangling-service`, `non-existent-service-account`, `mismatching-selector`, `no-anti-affinity`) 을 제외한다. 나머지 체크는 모두 활성.

목표 상태:

```
k8s/overlays/dev             build=ok  schema=ok  lint=ok
k8s/overlays/dev/vso         build=ok  schema=ok  lint=ok
```

---

## 환경별 배포

현재 `dev` overlay 만 완성되어 있다. `staging` / `prod` 는 의도적으로 비어 있으며 추후 확장 예정. validate.sh 는 `kustomization.yaml` 이 없는 환경을 자동으로 스킵한다.

```bash
# dev
VAULT_PUSH_PASSWORD=... VAULT_PULL_PASSWORD=... \
  bash k8s/scripts/bin/bootstrap.sh dev

# teardown
CONFIRM=yes bash k8s/scripts/bin/teardown.sh dev
```

### 계획된 환경별 차등 (향후)

| 리소스 | dev | staging | prod |
|---|---|---|---|
| Vault replicas / storage | 1 / 1Gi | 1 / 5Gi | 3 (HA Raft) / 20Gi |
| Registry replicas / storage | 1 / 5Gi | 1 / 10Gi | 2 / 50Gi |
| PostgreSQL retention policy | Delete | Retain | Retain |
| 이미지 tag 정책 | semver tag | semver tag | `@sha256:` digest pin |
| TLS | 비활성화 | cert-manager | cert-manager + HSTS |

prod 승격 시 Vault storage `file` → `raft` + KMS auto-unseal, Postgres 에 backup CronJob(Velero/pgBackRest) 추가, cert-manager ClusterIssuer 로 TLS 전환이 필수.
