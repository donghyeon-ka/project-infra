# Project-Infra

K3s 기반 백엔드 실행 환경을 Git으로 관리하는 개인 프로젝트입니다.  
[Project-Auth-Server](https://github.com/donghyeon-ka/project-auth-server)가 실제로 실행될 때 필요한 인증 게이트, secret 전달, DB 마이그레이션, 네트워크 정책을 Kubernetes 리소스로 구성했습니다.

이 프로젝트에서 확인하고 싶었던 질문은 네 가지입니다.

- 로그인 / 세션 처리를 애플리케이션 밖으로 빼면 ingress와 backend의 책임은 어떻게 나뉘는가?
- secret을 Vault에 두면서도 Pod는 Kubernetes-native하게 실행할 수 있는가?
- default-deny NetworkPolicy 환경에서 백엔드 워크로드가 어떤 통신을 명시해야 하는가?
- dev에 집중하되, staging / prod 승격 시 달라질 정책 지점을 overlay 구조로 남길 수 있는가?

| | |
|---|---|
| **Runtime** | K3s 1.30, Kustomize, Helm, Bash |
| **Ingress / Auth** | Traefik, oauth2-proxy, Keycloak Operator |
| **Secrets** | HashiCorp Vault, Vault Secrets Operator |
| **Data** | PostgreSQL, Flyway, MinIO, Docker Registry |
| **Policy** | NetworkPolicy default-deny, PSS Restricted |
| **Validation** | `kustomize build`, `kubeconform -strict`, `kube-linter` |
| **Scope** | dev overlay 중심. staging / prod는 의도적으로 미구현 |

---

## Architecture

![System Overview](docs/diagrams/architecture/01-overall.png)

큰 흐름은 두 가지입니다.

- 요청 흐름: `Traefik → oauth2-proxy → auth-server → PostgreSQL / MinIO`
- secret 흐름: `Vault → VSO → Kubernetes Secret → Pod envFrom`

상세 다이어그램:

- [ForwardAuth cold path](docs/diagrams/sequence/forward-auth-cold.md) / [warm path](docs/diagrams/sequence/forward-auth-warm.md)
- [Secret pipeline bootstrap](docs/diagrams/sequence/secret-pipeline-bootstrap.md) / [runtime reconcile](docs/diagrams/sequence/secret-pipeline-runtime.md)
- [전체 아키텍처 설명](docs/architecture.md)

---

## Engineering Decisions

### 1. 인증은 Ingress에서 먼저 막고, 백엔드는 JWT를 다시 검증

Traefik `ForwardAuth → oauth2-proxy → Keycloak` 조합으로 미인증 요청을 ingress 계층에서 먼저 차단합니다.  
그 뒤 auth-server는 Keycloak JWT를 Spring Security Resource Server로 다시 검증합니다.

이 구조는 로그인 / 세션 처리와 API 권한 검증을 분리하기 위한 선택입니다. 인증 정책 변경은 애플리케이션 코드보다 Kubernetes manifest 변경으로 다룰 수 있습니다.

![인증·인가 흐름](docs/diagrams/architecture/02-auth-flow.png)

### 2. Vault는 source of truth, Pod는 Kubernetes Secret만 소비

Pod마다 Vault Agent sidecar를 붙이지 않고, Vault Secrets Operator가 Vault KV 값을 Kubernetes Secret으로 동기화합니다.

```text
Vault KV-v2 → VSO reconcile → Kubernetes Secret → Pod envFrom
```

Pod는 Vault endpoint, token, template rendering을 직접 알지 않습니다. 대신 secret이 Kubernetes Secret으로 존재하므로, etcd encryption-at-rest가 다음 검증 항목으로 남습니다.

### 3. Vault role / policy는 도메인별로 분리

VSO Operator의 ServiceAccount는 하나지만, Vault 쪽 role과 policy는 `vso-auth-platform` / `vso-storage`로 나눴습니다.  
각 `VaultStaticSecret`은 자기 도메인의 `VaultAuth`만 참조합니다.

auth-platform 권한으로 storage secret 경로에 접근하지 못하게 하려는 결정입니다.

상세 매핑은 [docs/vault-vso.md](docs/vault-vso.md#vaultauth--vaultstaticsecret-매핑)를 참고합니다.

### 4. NetworkPolicy는 default-deny에서 시작

`mnt` namespace 안에서도 모든 Pod 간 ingress / egress를 기본 차단합니다.  
새 워크로드를 추가하려면 필요한 통신을 NetworkPolicy로 명시해야 합니다.

이 마찰은 의도한 것입니다. wide-open으로 시작하는 실수를 줄이고, 워크로드 간 통신 관계를 코드로 남기기 위함입니다.

상세 매트릭스는 [docs/networking.md](docs/networking.md)를 참고합니다.

### 5. K3s packaged Traefik manifest는 직접 수정하지 않음

K3s가 관리하는 Traefik manifest를 직접 수정하면 재부팅 / 재적용 시 덮어써질 수 있습니다.  
그래서 `HelmChartConfig` overlay와 Middleware / TLSOption 리소스로 운영 정책을 관리합니다.

![Traefik 파이프라인](docs/diagrams/architecture/07-traefik-pipeline.png)

---

## Repository Layout

Kustomize `base / components / overlays` 구조입니다.

| Path | Role |
|---|---|
| `k8s/base/` | 환경 중립 매니페스트 |
| `k8s/components/` | 재사용 component. 현재 ForwardAuth component |
| `k8s/overlays/dev/` | 기본 dev 환경 |
| `k8s/overlays/dev-with-forward-auth/` | dev + ForwardAuth variant |
| `k8s/overlays/{staging,prod}/` | 의도적으로 비워둔 승격 지점 |
| `k8s/scripts/` | bootstrap / validation / reusable tasks |
| `terraform/` | contracts만 존재. 추후 구현 |
| `docs/` | 상세 설계와 운영 문서 |

---

## Validation

```bash
bash k8s/scripts/ci/validate.sh
```

`validate.sh`는 주요 overlay에 대해 세 단계를 수행합니다.

1. `kustomize build` — overlay 조립과 patch 유효성 확인
2. `kubeconform -strict` — Kubernetes / CRD schema 확인
3. `kube-linter` — securityContext, resources, image tag 등 정적 점검

목표 상태:

```text
k8s/overlays/dev      build=ok  schema=ok  lint=ok
k8s/overlays/dev/vso  build=ok  schema=ok  lint=ok
```

운영 절차는 [docs/operations.md](docs/operations.md), 실행 매뉴얼은 [guide.md](guide.md)를 참고합니다.

---

## Current Status

| Area | Status |
|---|---|
| dev overlay 매니페스트 | 구성됨 (kustomize / kubeconform / kube-linter 검증 가능) |
| Vault + VSO 부트스트랩 | idempotent script 로 구성 |
| Traefik HelmChartConfig + Middleware | 구성됨 |
| NetworkPolicy default-deny | 구성됨 |
| ForwardAuth variant overlay | manifest 준비됨 |
| KeycloakRealmImport | overlay 준비됨. 실제 적용 결과 확인 필요 |
| cert-manager + ClusterIssuer | manifest 준비됨. 외부 DNS 필요 |
| staging / prod overlay | 의도적으로 비워둠 |
| Terraform | 디렉토리 contracts만 존재 |

---

## Limitations

운영 완료 상태가 아니라 dev 환경에서 실행 구조를 검증한 프로젝트입니다.

- Vault는 file backend 단일 노드입니다. dev에서는 secret 전달 경로와 VSO reconcile을 검증하는 데 충분하다고 보고 선택했습니다. prod에서는 `raft` storage와 KMS auto-unseal로 전환해야 합니다.
- cert-manager / ClusterIssuer manifest는 있지만, 실제 ACME 인증서 발급은 외부 DNS가 Traefik 진입점을 가리켜야 완료됩니다.
- oauth2-proxy의 `ssl_insecure_skip_verify=true`는 dev 임시 설정입니다. 인증서 발급 후 제거해야 합니다.
- ForwardAuth 로그인 / 로그아웃 / deny-allow E2E 검증은 인증서와 DNS 정리 후 진행할 항목입니다.
- Postgres 백업, Terraform 실제 모듈, staging/prod overlay는 아직 구현하지 않았습니다.

---

## Documentation

- [docs/architecture.md](docs/architecture.md) — 전체 구조, 워크로드 표, 이미지 정책
- [docs/networking.md](docs/networking.md) — NetworkPolicy 매트릭스 / 작성 규칙
- [docs/ingress-traefik.md](docs/ingress-traefik.md) — Traefik, ForwardAuth, cert-manager, KeycloakRealmImport
- [docs/vault-vso.md](docs/vault-vso.md) — Vault auth, policy/role, VSO Secret catalog
- [docs/operations.md](docs/operations.md) — bootstrap 단계, validate.sh, 환경별 차등
- [docs/troubleshooting.md](docs/troubleshooting.md) — 운영 중 만난 함정 7건 (사건 카탈로그)
- [docs/diagrams/architecture/](docs/diagrams/architecture/) — draw.io 아키텍처 그림
- [docs/diagrams/sequence/](docs/diagrams/sequence/) — Mermaid sequence diagrams
- [guide.md](guide.md) — 실제 실행 매뉴얼
