# Project-Infra

Kubernetes 기반 인프라 프로젝트. 클러스터 내 Private Docker Registry와 HashiCorp Vault를 운영하고, Vault Secrets Operator(VSO)로 시크릿을 자동 동기화하며, `auth-server` / `keycloak` / `identity-postgres` / `minio` / `test-server` / `migration-flyway` 워크로드까지 Kustomize 단일 namespace(`mnt`) 체계에서 함께 관리한다.

dev 환경에서는 K3s 기본 packaged Traefik 을 유지하되, 직접 manifest 를 수정하지 않고 별도 `HelmChartConfig` overlay 로 운영 설정을 Git 에서 관리한다. 애플리케이션 쪽에서는 `auth-server` 와 `keycloak` 에 south-north Ingress 를 두고, 해당 트래픽만 NetworkPolicy 로 명시적으로 허용한다.

> 실제 배포·운영 절차는 [guide.md](guide.md) 참조.

---

## 목차

1. [아키텍처](#아키텍처)
2. [폴더 구조](#폴더-구조)
3. [네임스페이스 전략](#네임스페이스-전략)
4. [NetworkPolicy 전략](#networkpolicy-전략)
5. [Ingress / Traefik 전략](#ingress--traefik-전략)
6. [이미지 정책](#이미지-정책)
7. [Vault](#vault)
8. [Vault Secrets Operator (VSO)](#vault-secrets-operator-vso)
9. [Docker Registry](#docker-registry)
10. [워크로드 목록](#워크로드-목록)
11. [스크립트 구조](#스크립트-구조)
12. [검증](#검증)
13. [환경별 배포](#환경별-배포)

---

## 아키텍처

```
┌────────────────────────── namespace: kube-system ──────────────────────────┐
│                                                                            │
│   [ K3s packaged Traefik ]                                                 │
│     · HelmChartConfig overlay 로 운영 설정 override                         │
│     · Middleware / TLSOption 공용 정책 관리                               │
│     · ServiceLB(svclb-traefik) 를 통해 north-south 진입                    │
└────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌──────────────────────────── namespace: mnt ────────────────────────────────┐
│                                                                            │
│   [ Vault (StatefulSet) ] ← VSO (Helm-installed Operator)                  │
│           │                      │                                         │
│           │ TokenReview          │ reads KV-v2                             │
│           ▼                      ▼                                         │
│   ClusterRoleBinding       VaultStaticSecret (CRD)                         │
│   system:auth-delegator     → K8s Secret                                   │
│                                │                                           │
│                                ▼                                           │
│   ┌──────────────────────────────────────────────────────────────┐         │
│   │ 워크로드                                                      │         │
│   │  · auth-server      (Deployment, host=project.com)           │         │
│   │  · keycloak         (Keycloak CR, host=keycloak.dev.example.com)│      │
│   │  · identity-postgres(StatefulSet)                            │         │
│   │  · migration-flyway (Job, ArgoCD PreSync sync-wave=-1)       │         │
│   │  · minio            (Tenant CRD — MinIO Operator)            │         │
│   │  · test-server-1/2/3(Deployment)                             │         │
│   │  · docker-registry  (Deployment, host=registry.project.com)  │         │
│   └──────────────────────────────────────────────────────────────┘         │
│                                                                            │
│   NetworkPolicy: default-deny + DNS egress baseline                        │
│                + Traefik ingress allow + 컴포넌트별 east-west allow         │
└────────────────────────────────────────────────────────────────────────────┘
```

시크릿 흐름:

```
Vault KV (secret/…)
   ↓  VSO 가 refreshAfter 주기로 동기화
K8s Secret (mnt namespace)
   ↓  워크로드가 envFrom / volume 으로 참조
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
│   │   │   ├── storage/minio/stateful/minio/
│   │   │   └── test/stateless/test-server-{1,2,3}/   # example 이미지
│   │   │
│   │   └── plugins/                            # 플랫폼 플러그인 (다른 워크로드가 의존)
│   │       ├── vault/                          # Vault StatefulSet (공식 이미지)
│   │       ├── docker-registry/                # Registry Deployment (공식 이미지)
│   │       ├── oauth2-proxy/                   # Traefik ForwardAuth 용 auth proxy (선택 적용)
│   │       └── vso/
│   │           ├── kustomization.yaml          # VaultConnection / VaultAuth / VaultStaticSecret
│   │           ├── vault-connection.yaml
│   │           ├── vault-auth.yaml
│   │           ├── serviceaccount.yaml
│   │           ├── vault-static-secret-htpasswd.yaml
│   │           ├── vault-static-secret-pull-cred.yaml
│   │           └── helm/values.yaml            # VSO Operator 설치용 Helm values
│   │
│   ├── components/
│   │   └── forward-auth/                       # oauth2-proxy + Traefik ForwardAuth 재사용 component
│   │
│   ├── overlays/
│   │   └── dev/
│   │       ├── kustomization.yaml              # dev 전체 집계 (namespace: mnt)
│   │       ├── networkpolicy-baseline.yaml     # default-deny + DNS egress
│   │       ├── platform/
│   │       │   ├── traefik/                    # kube-system 전용 overlay (HelmChartConfig + Middleware + TLSOption)
│   │       │   ├── cert-manager/               # cert-manager v1.20.2 install overlay
│   │       │   ├── cert-manager-issuers/       # letsencrypt-staging/prod ClusterIssuer overlay
│   │       │   └── keycloak-operator/          # Keycloak Operator 26.6.1 CRD/Controller overlay
│   │       ├── tls/                            # cert-manager 설치 후 적용할 Certificate overlay
│   │       ├── vault/                          # Vault overlay + NetworkPolicy + storage patch
│   │       ├── registry/                       # Registry overlay + NetworkPolicy + storage patch
│   │       ├── vso/                            # VSO CRDs (Helm 설치 후 별도 apply)
│   │       ├── database/                       # identity-postgres + VaultStaticSecret + NetworkPolicy
│   │       ├── auth/                           # auth-server + flyway + Ingress(project.com) + NetworkPolicy
│   │       ├── keycloak/                       # Keycloak CR + public Ingress + NetworkPolicy
│   │       ├── keycloak-realm/                 # KeycloakRealmImport 기반 realm/client Git 관리
│   │       ├── storage/                        # minio + VaultStaticSecret + certConfig FQDN patch + NetworkPolicy
│   │       └── test/                           # test-server 1/2/3 + NetworkPolicy
│   │   dev-with-forward-auth/                  # dev + components/forward-auth variant overlay
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
│           ├── vault-seed-apps.sh              # 앱/MinIO/registry 관련 Vault KV 저장
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
| `overlays/dev/auth/networkpolicy.yaml` | auth-server ingress ← `kube-system/traefik`(8080); egress → postgres(5432) + keycloak(8080); flyway egress → postgres(5432) |
| `overlays/dev/keycloak/networkpolicy.yaml` | keycloak ingress ← `kube-system/traefik`(8080) + auth-server(8080); egress → postgres(5432); Keycloak Pod 간 peer 통신 |
| `overlays/dev/storage/networkpolicy.yaml` | minio ingress ← `part-of=auth-platform`(9000); 자체 peer(9000/9001) |
| `overlays/dev/test/networkpolicy.yaml` | test-server 3대 내부 상호 통신만 허용 |
| `overlays/dev/vault/networkpolicy.yaml` | vault ingress ← VSO Operator Pod(8200) |
| `overlays/dev/registry/networkpolicy.yaml` | docker-registry ingress ← namespace 내 전 Pod(5000) + `kube-system/traefik`(5000); egress → minio(9000) |

cross-namespace 참조가 필요한 항목은 `namespaceSelector` + `podSelector` 를 한 블록에 조합해 AND 시맨틱으로 작성한다.

---

## Ingress / Traefik 전략

dev 환경에서는 K3s 기본 packaged Traefik 을 그대로 유지하되, **`/var/lib/rancher/k3s/server/manifests/traefik.yaml` 는 수정하지 않는다.** 운영 설정은 `k8s/overlays/dev/platform/traefik/` 의 `HelmChartConfig` 로만 오버라이드한다.

### 현재 구성

| 위치 | 역할 |
|---|---|
| `k8s/overlays/dev/platform/traefik/helmchartconfig.yaml` | Traefik replica, 기본 ingressClass, HTTP→HTTPS redirect, metrics, 기본 TLS option 연결 |
| `k8s/overlays/dev/platform/traefik/middleware.yaml` | 공용 `security-headers` Middleware + `modern-tls` TLSOption |
| `k8s/overlays/dev/auth/ingress.yaml` | `project.com` → `auth-server` |
| `k8s/overlays/dev/keycloak/ingress-public.yaml` | `keycloak.dev.example.com` → Keycloak 공개 path(`/realms/`, `/resources/`, `/.well-known/`, `/js/`) |
| `k8s/overlays/dev/platform/cert-manager/` | cert-manager `v1.20.2` CRD/controller 설치 |
| `k8s/overlays/dev/platform/cert-manager-issuers/` | `letsencrypt-staging` / `letsencrypt-prod` ClusterIssuer |
| `k8s/overlays/dev/platform/keycloak-operator/` | Keycloak Operator `26.6.1` CRD + controller. dev 제약상 `mnt` 에 설치해 `mnt` 의 Keycloak CR 을 watch. Kubernetes API egress NetworkPolicy 포함 |
| `k8s/overlays/dev/tls/*.yaml` | cert-manager 설치 후 사용할 `Certificate` 리소스 |
| `k8s/components/forward-auth/` | oauth2-proxy + Traefik ForwardAuth 재사용 component |
| `k8s/overlays/dev-with-forward-auth/` | 기본 dev 에 forward-auth component 를 결합한 선택형 overlay |
| `k8s/overlays/dev/keycloak-realm/` | Keycloak Operator `KeycloakRealmImport` 로 realm/client 를 Git 관리하는 overlay |

### 설계 원칙

- app 쪽은 `Ingress` 만 선언하고, 공통 보안 정책은 Traefik 공용 middleware / TLSOption 으로 재사용한다.
- north-south ingress 는 `kube-system` 의 `traefik` Pod 에서만 시작되므로, app NetworkPolicy 도 실제 클러스터 기준으로 `kube-system` 을 허용한다.
- Keycloak 은 외부 전체 공개가 아니라 **최소 공개 path** 만 연다. `/admin`, `/metrics`, `/health` 는 계속 비공개다.
- TLS 리소스는 `cert-manager` 와 `ClusterIssuer` 적용 후 `k8s/overlays/dev/tls/` 로 발급한다.

### 현재 적용 범위와 남은 과제

현재 repo 는 다음까지 커버한다.

- Traefik 운영 정책의 Git 관리
- app ingress host / path / policy 정의
- Traefik → app 방향 ingress allow NetworkPolicy
- TLS `Certificate` 선언 준비

아직 남아 있는 것은 다음이다.

- `cert-manager` 설치 + `ClusterIssuer` 준비 (`k8s/overlays/dev/platform/cert-manager/`, `k8s/overlays/dev/platform/cert-manager-issuers/`)
- 외부 DNS 가 `project.com`, `keycloak.dev.example.com` 을 실제 Traefik 진입점으로 향하게 하는 작업
- 최종 목표인 **Ingress 단 인증 차단**. 이를 위해 repo 에는 `k8s/components/forward-auth/` 와 `k8s/overlays/dev-with-forward-auth/` 가 추가되어 있으며, 구조는 `Traefik ForwardAuth → oauth2-proxy → Keycloak` 이다.
- Keycloak realm/client 의 실제 operator 기반 적용. 먼저 `k8s/overlays/dev/platform/keycloak-operator/` 를 적용하고, 그 뒤 `k8s/overlays/dev/keycloak-realm/` 를 적용한다.

### ForwardAuth component / variant

`k8s/components/forward-auth/` 는 oauth2-proxy 와 ForwardAuth middleware 를 담은 Kustomize component 다. `k8s/overlays/dev-with-forward-auth/` 는 기본 `dev` 전체를 포함한 뒤 이 component 를 결합하는 얇은 variant overlay 다.

- `oauth2-proxy` Deployment / Service / ConfigMap / VaultStaticSecret
- `project.com/oauth2/*` 경로용 Ingress
- `oauth2-proxy-auth` Traefik Middleware
- `auth-server` Ingress patch
  `project.com/` 요청은 oauth2-proxy 를 거쳐 인증된 사용자만 통과

적용 전제:

- `k8s/overlays/dev/keycloak-realm/` 또는 동등한 방법으로 `platform` realm + `auth-server-ingress` client 가 준비됨
- redirect URI: `https://project.com/oauth2/callback`
- Vault path `secret/oauth2-proxy/forward-auth` 에 `client-secret`, `cookie-secret` 저장
- `project.com` 과 `keycloak.dev.example.com` 이 실제 Traefik 진입점으로 해석

현재 dev variant 의 oauth2-proxy 설정은 `ssl_insecure_skip_verify=true` 를 사용한다. 이유는 아직 cert-manager 가 없어서 Keycloak 공개 호스트 인증서 체인이 완성되지 않았기 때문이다. cert-manager 도입 후에는 이 값을 제거하는 것이 목표다.

### cert-manager / ClusterIssuer 운영 원칙

repo 에 `k8s/overlays/dev/platform/cert-manager/` 와 `k8s/overlays/dev/platform/cert-manager-issuers/` 가 추가되었다. 설치 overlay 는 공식 static install `v1.20.2` 를 관리하고, issuer overlay 는 ACME HTTP-01 용 `letsencrypt-staging` / `letsencrypt-prod` `ClusterIssuer` 를 관리한다.

source-of-truth 관점에서 cert-manager 도 이 repo 의 선언형 관리 대상이다. 단, 실제 인증서 발급은 DNS 가 Traefik 외부 진입점으로 연결되고 80/443 이 도달 가능해야 완료된다.

정리하면:

- 설치: `kubectl apply -k k8s/overlays/dev/platform/cert-manager`
- issuer: `kubectl apply -k k8s/overlays/dev/platform/cert-manager-issuers`
- 인증서: `kubectl apply -k k8s/overlays/dev/tls`
- 운영 보정: `admin@project.com` 은 실제 운영 수신 가능한 메일로 교체 필요

### Keycloak realm / client Git 관리

repo 에는 `k8s/overlays/dev/keycloak-realm/` 가 추가되었다. 이 overlay 는 `KeycloakRealmImport` 로 `platform` realm 과 `auth-server-ingress` client 를 선언한다.

이제 `k8s/overlays/dev/keycloak/` 도 수제 `Deployment` 가 아니라 `Keycloak` CR 기반으로 전환되었다. `KeycloakRealmImport` 는 같은 `mnt` namespace 의 `Keycloak/keycloak` 을 대상으로 동작한다. `mnt` default-deny 정책 때문에 Keycloak Operator 의 Kubernetes API egress 와 Keycloak Pod 간 Infinispan/JGroups peer 통신도 NetworkPolicy 로 명시한다.

적용 순서는:

1. `kubectl apply -k k8s/overlays/dev/platform/keycloak-operator`
2. 기존 수제 `Deployment/Service/ConfigMap/ServiceAccount keycloak*` 정리
3. `kubectl apply -k k8s/overlays/dev`
4. `kubectl apply -k k8s/overlays/dev/keycloak-realm`

### 완료 판정

현재 상태를 두고 `dev 운영 환경이 완전히 끝났다`고 보지는 않는다.

repo 관점에서 완료된 것:

- Kustomize source of truth 정리
- south-north ingress 경로 정의
- Traefik 운영 설정의 Git 관리
- ForwardAuth variant 준비
- 관련 문서화

아직 운영 완료로 보기 어려운 것:

- `cert-manager` 와 실제 `ClusterIssuer`
- Keycloak Operator / Keycloak CR / RealmImport 실제 적용
- 실제 DNS 연결
- Keycloak realm/client 적용 및 oauth2-proxy secret seed
- end-to-end 로그인 테스트
- deny/allow negative test
- `ssl_insecure_skip_verify=true` 제거

즉, 지금은 **구성 초안과 적용 가능한 manifest 는 준비된 상태**이고, 실사용 dev 운영 완성은 외부 의존성과 검증까지 끝나야 한다.

---

## 이미지 정책

| 구분 | 이미지 | 근거 |
|---|---|---|
| **공식 upstream** | `hashicorp/vault:1.17.2` | HashiCorp 공식 Docker Hub |
| | `registry:2.8.3` | Docker library 공식 |
| | `postgres:16.4` | PostgreSQL 공식 |
| | `quay.io/keycloak/keycloak:26.6.1` | Keycloak Operator 26.6.1 이 관리하는 Keycloak 이미지 |
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

# policy 2개 (역할별 least-privilege)
vault policy write vso-auth-platform - < identity-postgres/* + auth-server/* + keycloak/* read
vault policy write vso-storage       - < minio/* read

# role 2개 (같은 SA, 다른 policy)
vault write auth/kubernetes/role/vso-auth-platform policies=vso-auth-platform bound_sa=vault-secrets-operator/mnt ttl=1h
vault write auth/kubernetes/role/vso-storage       policies=vso-storage       bound_sa=vault-secrets-operator/mnt ttl=1h
```

### VaultAuth / VaultStaticSecret 매핑

policy 분리에 따라 VaultAuth CR 도 2 개이며 각 VaultStaticSecret 은 자기 도메인의 VaultAuth 를 참조한다:

| VaultAuth CR | Vault role | 참조하는 VaultStaticSecret |
|---|---|---|
| `vault-auth-auth-platform` | `vso-auth-platform` | `identity-postgres-superuser`, `keycloak-db-creds`, `auth-server-db-creds`, `keycloak-bootstrap-admin` |
| `vault-auth-storage` | `vso-storage` | `minio-tenant-env` |

VSO Operator SA (`vault-secrets-operator`) 는 한 개이지만 Vault 쪽에서 role 별로 policy 가 분리되어 있어 각 도메인의 secret 만 읽을 수 있다. auth-platform 토큰이 유출돼도 MinIO secret 은 보호된다.

---

## Vault Secrets Operator (VSO)

HashiCorp 공식 Operator. Vault KV → K8s Secret 자동 동기화.

### 배포 순서 (CRD 의존성)

`VaultConnection` / `VaultAuth` / `VaultStaticSecret` 은 VSO Helm 설치로 CRD 가 등록된 뒤에만 apply 할 수 있다. 그래서 `overlays/dev/vso/` 는 `overlays/dev/kustomization.yaml` 집계에 포함되지 않으며, `bin/bootstrap.sh` 마지막 단계에서 별도로 `kubectl apply -k overlays/dev/vso/` 한다.

```
Phase 0 : MinIO Operator Helm install                  (tasks/minio-operator-install.sh)
Phase 1 : kubectl apply -k base/managing/namespace/    (PSS 라벨 선행)
Phase 2 : 기존 VSO-managed Secret 점검                  (RESET_STALE_SECRETS=yes 로 삭제)
Phase 3 : kubectl apply -k overlays/<env>/              (vault + registry + 앱)
Phase 4 : vault-0 Running 대기
Phase 5 : tasks/vault-init.sh                           (init + unseal + auth + policy × 2 + role × 2)
Phase 6 : tasks/vso-install.sh                          (helm upgrade --install)
Phase 7 : kubectl apply -k overlays/<env>/vso/          (CRDs)
```

### VaultConnection address

base 는 `http://vault:8200` (짧은 이름) 만 둔다. VSO Operator Pod 가 같은 `mnt` namespace 에서 실행되면 Kubernetes DNS 가 짧은 이름을 해결한다. 다른 namespace 에서 운영할 때는 overlay 에서 FQDN 으로 patch 한다.

### VSO 가 관리하는 Secret

Registry 는 auth 없이 운영 (NetworkPolicy 로 `mnt` 내부 전용 보호) 이라 base 에 VaultStaticSecret 없음.

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
| 배포 | Deployment (replicas 1) |
| 내부 서비스 | `docker-registry.mnt.svc.cluster.local:5000` |
| 외부 Ingress | `registry.project.com` (`/v2` only) |
| 인증 | 내부 Service 는 무인증, 외부 Ingress 와 kubelet pull 은 registry credential 사용 |
| 저장 | MinIO S3 bucket `docker-registry` |

### 인증 경계

운영자 push 와 kubelet image pull 은 `registry.project.com` 을 기준으로 한다. Traefik `Middleware/docker-registry-basic-auth` 는 Vault/VSO 로 생성된 `docker-registry-basic-auth` Secret 의 htpasswd `users` 값을 검증하고, 앱 ServiceAccount 는 `docker-registry-pull-credentials` imagePullSecret 으로 같은 registry credential 을 사용한다.

Registry 자체 auth 는 켜지지 않는다. 인증 경계는 Traefik 외부 Ingress 와 kubelet pull credential 에 둔다. 따라서 `docker-registry-ingress-traefik` NetworkPolicy, BasicAuth Secret, imagePullSecret 이 함께 있어야 push/pull 경로가 안전하다.

### Push / Pull

```bash
# 외부 운영자 push
docker login registry.project.com
docker tag my-app:v1 registry.project.com/my-app:v1
docker push registry.project.com/my-app:v1
```

```bash
# 클러스터 내부 Pod 간 HTTP 확인 등 내부 Service 접근이 필요할 때
docker tag my-app:v1 docker-registry.mnt.svc.cluster.local:5000/my-app:v1
docker push docker-registry.mnt.svc.cluster.local:5000/my-app:v1
```

```yaml
spec:
  serviceAccountName: auth-server-sa
  # auth-server-sa 에 docker-registry-pull-credentials 연결
  containers:
    - name: my-app
      image: registry.project.com/my-app:v1
```

---

## 워크로드 목록

| 워크로드 | 종류 | 위치 | 참조 Secret |
|---|---|---|---|
| `identity-postgres` | StatefulSet | `base/app/identity/auth/stateful/` | `identity-postgres-superuser`, `keycloak-db`, `auth-server-db` |
| `auth-server` | Deployment | `base/app/identity/auth/stateless/` | `auth-server-db` |
| `keycloak` | Keycloak CR / StatefulSet(Operator 생성) | `overlays/dev/keycloak/` | `keycloak-db-operator`, `keycloak-bootstrap-admin-operator` |
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
| `tasks/` | 재사용 가능한 작업 단위. `vault-init.sh` / `vault-seed-apps.sh` / `vso-install.sh` |

모든 쉘 스크립트는 `set -Eeuo pipefail` + `IFS=$'\n\t'` + `trap_cleanup` 으로 공통 에러 처리. root token / registry BasicAuth 값 같은 민감 값은 **stdin 파이프** 로만 전달하고 stdout 에 찍지 않는다.

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
# dev — 비밀번호를 프롬프트에서 무음 입력 (bash history 에 안 남음)
bash k8s/scripts/bin/bootstrap.sh dev

# teardown — 대화형 y/N
bash k8s/scripts/bin/teardown.sh dev
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
