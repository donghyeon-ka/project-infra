# Architecture 상세

README 의 Architecture / Key Components 를 보충하는 문서. 폴더 구조 전체와 워크로드, 이미지 정책을 모은다.

## 폴더 구조

```
Project-Infra/
├── .gitignore                                  # vault-init-keys.json 제외
├── .kube-linter.yaml                           # kube-linter 규칙 (컨텍스트 오탐 4종 제외)
├── README.md                                   # 본 프로젝트 진입 문서
├── guide.md                                    # 운영 절차서
├── docs/                                       # README 보조 분할 문서
│
├── k8s/
│   ├── base/
│   │   ├── managing/
│   │   │   ├── namespace/                      # mnt namespace + PSS restricted 라벨
│   │   │   └── migration-flyway/               # Flyway Job (공식 이미지)
│   │   │
│   │   ├── app/                                # 애플리케이션 워크로드 (소유권 = 개발팀)
│   │   │   ├── identity/auth/
│   │   │   │   ├── stateful/identity-postgres/
│   │   │   │   └── stateless/auth-server/
│   │   │   ├── storage/minio/stateful/minio/
│   │   │   └── test/stateless/test-server-{1,2,3}/
│   │   │
│   │   └── plugins/                            # 플랫폼 플러그인 (다른 워크로드가 의존)
│   │       ├── vault/                          # Vault StatefulSet (공식 이미지)
│   │       ├── docker-registry/                # Registry Deployment (공식 이미지)
│   │       ├── oauth2-proxy/                   # ForwardAuth 용 auth proxy
│   │       └── vso/                            # VSO CRD 리소스 (VaultConnection / VaultAuth / VaultStaticSecret)
│   │
│   ├── components/
│   │   └── forward-auth/                       # oauth2-proxy + Traefik ForwardAuth 재사용 component
│   │
│   ├── overlays/
│   │   ├── dev/
│   │   │   ├── kustomization.yaml              # dev 전체 집계 (namespace: mnt)
│   │   │   ├── networkpolicy-baseline.yaml     # default-deny + DNS egress
│   │   │   ├── platform/
│   │   │   │   ├── traefik/                    # HelmChartConfig + Middleware + TLSOption
│   │   │   │   ├── cert-manager/               # cert-manager v1.20.2
│   │   │   │   ├── cert-manager-issuers/       # letsencrypt-staging/prod ClusterIssuer
│   │   │   │   └── keycloak-operator/          # Keycloak Operator 26.6.1
│   │   │   ├── tls/                            # cert-manager 적용 후 Certificate
│   │   │   ├── vault/                          # Vault overlay + NetworkPolicy + storage patch
│   │   │   ├── registry/                       # Registry overlay + NetworkPolicy + storage patch
│   │   │   ├── vso/                            # VSO CRDs (Helm 설치 후 별도 apply)
│   │   │   ├── database/                       # identity-postgres + VaultStaticSecret
│   │   │   ├── auth/                           # auth-server + Ingress(project.com) + flyway
│   │   │   ├── keycloak/                       # Keycloak CR + public Ingress
│   │   │   ├── keycloak-realm/                 # KeycloakRealmImport (Git-managed realm/client)
│   │   │   ├── storage/                        # minio + VaultStaticSecret + certConfig FQDN patch
│   │   │   └── test/                           # test-server 1/2/3
│   │   ├── dev-with-forward-auth/              # dev + components/forward-auth variant
│   │   ├── staging/                            # 의도적으로 비어둠
│   │   └── prod/                               # 의도적으로 비어둠
│   │
│   └── scripts/
│       ├── bin/                                # 사용자 진입점 (bootstrap.sh / teardown.sh)
│       ├── ci/validate.sh                      # kustomize + kubeconform + kube-linter
│       ├── lib/                                # 공통 라이브러리 (common.sh / vault.sh)
│       └── tasks/                              # 재사용 작업 (vault-init / vault-seed-apps / vso-install)
│
└── terraform/                                  # contracts 만 존재, 추후 구현
```

## 네임스페이스 전략

`mnt` 단일 namespace. 학습 단계의 단순성 우선. 실무에서는 역할별 namespace(`auth`, `storage`, `security`, `registry`) 분리가 원칙이며, base 는 환경 중립이라 overlay 재구성으로 분리 가능하다.

- Pod Security Standards: `pod-security.kubernetes.io/enforce=restricted` (audit + warn 동시).
- 모든 리소스는 overlay 의 `namespace: mnt` 로 일괄 주입.

## 워크로드 목록

| 워크로드 | 종류 | 위치 | 참조 Secret |
|---|---|---|---|
| `identity-postgres` | StatefulSet | `base/app/identity/auth/stateful/` | `identity-postgres-superuser`, `keycloak-db`, `auth-server-db` |
| [`auth-server`](https://github.com/donghyeon-ka/project-auth-server/tree/develop) | Deployment | `base/app/identity/auth/stateless/` | `auth-server-db` |
| `keycloak` | Keycloak CR (Operator 생성 StatefulSet) | `overlays/dev/keycloak/` | `keycloak-db-operator`, `keycloak-bootstrap-admin-operator` |
| `minio` | Tenant CRD | `base/app/storage/minio/stateful/` | `minio-tenant-env` |
| `test-server-1/2/3` | Deployment | `base/app/test/stateless/` | — |
| `migration-flyway` | Job (PreSync / sync-wave=-1) | `base/managing/migration-flyway/` | `auth-server-db` |
| `vault` | StatefulSet | `base/plugins/vault/` | — |
| `docker-registry` | Deployment | `base/plugins/docker-registry/` | `docker-registry-basic-auth`, `docker-registry-pull-credentials` |

auth-server / keycloak 모두 `jdbc:postgresql://identity-postgres:5432/<db>` 로 short name 접속 (같은 namespace).

### Flyway 실행 순서

dev overlay 가 migration-flyway Job 에 ArgoCD annotation 을 patch:

```
argocd.argoproj.io/sync-wave: "-1"
argocd.argoproj.io/hook: PreSync
```

ArgoCD 배포 시 Job 이 앱보다 먼저 돌고 스키마 마이그레이션을 마친 뒤 `auth-server` 가 뜬다.

### Keycloak hostname patch

dev overlay JSON patch 가 Keycloak ConfigMap 에 다음을 주입:

- `KC_HOSTNAME=https://keycloak.dev.example.com`
- `KC_HOSTNAME_ADMIN=https://keycloak-admin.dev.example.com`

staging / prod 는 자체 hostname 을 overlay 에서 주입.

### MinIO certConfig.dnsNames

base 는 short name(`minio`, `minio-hl`) 만 둔다. dev overlay 에서 `minio.mnt.svc.cluster.local`, `*.minio-hl.mnt.svc.cluster.local` 을 patch — base 환경 중립성 원칙.

## 이미지 정책

| 구분 | 이미지 | 근거 |
|---|---|---|
| 공식 upstream | `hashicorp/vault:1.17.2` | HashiCorp 공식 |
| | `registry:2.8.3` | Docker library 공식 |
| | `postgres:16.4` | PostgreSQL 공식 |
| | `quay.io/keycloak/keycloak:26.6.1` | Keycloak Operator 26.6.1 관리 |
| | `minio/minio:RELEASE.2025-01-20T14-49-07Z` | MinIO 공식 |
| | `flyway/flyway:10.20.1` | Flyway 공식 |
| 사용자 개발 | `registry.example.com/auth-platform/auth-server:0.1.0` | 조직 개발 서비스 |
| | `registry.example.com/test-platform/test-server-{1,2,3}:0.1.0` | 조직 개발 서비스 |

prod 승격 시 공식 이미지도 digest pin(`@sha256:…`)으로 전환.

## Docker Registry

| 항목 | 값 |
|---|---|
| 이미지 | `registry:2.8.3` |
| 내부 서비스 | `docker-registry.mnt.svc.cluster.local:5000` |
| 외부 Ingress | `registry.project.com` (`/v2` only) |
| 인증 | 내부 Service 무인증, 외부 Ingress + kubelet pull 만 credential 사용 |
| 저장 | MinIO S3 bucket `docker-registry` |

### 인증 경계

Registry 자체 auth 는 켜지 않는다. 인증 경계는 두 곳:

- 외부 Ingress: Traefik `Middleware/docker-registry-basic-auth` 가 VSO 로 생성된 `docker-registry-basic-auth` Secret 의 htpasswd 를 검증
- 내부 pull: 앱 ServiceAccount 에 `docker-registry-pull-credentials` imagePullSecret

따라서 `docker-registry-ingress-traefik` NetworkPolicy + BasicAuth Secret + imagePullSecret 이 함께 있어야 push/pull 양쪽이 안전하다.
