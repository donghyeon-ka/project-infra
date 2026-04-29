# Vault / VSO 상세

README 의 Vault·VSO 핵심 섹션을 보충한다. Kubernetes auth 초기화 명령, policy/role 매핑, VaultStaticSecret 카탈로그, dockerconfigjson `.auth` 이슈를 모은다.

## Vault 기본 정보

| 항목 | 값 |
|---|---|
| 이미지 | `hashicorp/vault:1.17.2` |
| 배포 | StatefulSet (replicas 1, file backend) |
| 실행 | `vault server -config=/vault/config/vault.hcl` |
| 포트 | 8200 (http) / 8201 (cluster) — 내부 ClusterIP, NodePort 없음 |
| 저장 | PVC 5Gi (dev overlay 1Gi patch) |
| UI 접근 | `kubectl -n mnt port-forward svc/vault 8200:8200` (외부 노출 금지) |

## 설계 결정

- **file backend (학습 환경 전용)**: 단일 노드 + 학습 목적으로 `storage "file"`. HA 불가. prod 승격 시 `storage "raft"` + KMS 기반 auto-unseal 로 전환.
- **`disable_mlock = true`**: 컨테이너에 `IPC_LOCK` capability 를 부여하지 않고 PSS Restricted 프로필을 유지하기 위함. 대신 swap 이 꺼진 노드에서 실행해야 한다.
- **`tls_disable = 1`**: 단일 namespace 내부 통신만 발생하고 cert-manager 전에 부트스트랩이 끝나야 해서 현재는 비활성화. 클러스터 밖 노출 시 cert-manager 발급 인증서로 TLS 활성화 필수.
- **`api_addr: http://vault:8200` + `cluster_addr: http://vault:8201`**: 짧은 Service 이름. 모든 소비자가 같은 `mnt` namespace 에 있어 FQDN 불필요.

## RBAC

ClusterRoleBinding `vault-tokenreview-binding` ← `system:auth-delegator`. Vault 의 Kubernetes auth method 는 클라이언트(VSO 등)가 제출한 ServiceAccount JWT 를 `TokenReview` + `SubjectAccessReview` API 로 검증한다. 이 ClusterRoleBinding 이 없으면 VSO 로그인이 `permission denied` 로 실패한다.

Vault Pod 의 ServiceAccount 는 `automountServiceAccountToken: true` (기본). Vault 는 `/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt}` 를 읽어 `auth/kubernetes/config` 의 `token_reviewer_jwt` / `kubernetes_ca_cert` 를 채운다.

## Kubernetes auth 초기 설정

`tasks/vault-init.sh` 가 수행:

```bash
vault auth enable kubernetes                              # idempotent 체크
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

vault secrets enable -path=secret kv-v2                   # idempotent 체크

# policy 2개 (역할별 least-privilege)
vault policy write vso-auth-platform - \
  # identity-postgres/* + auth-server/* + keycloak/* read
vault policy write vso-storage - \
  # minio/* read

# role 2개 (같은 SA, 다른 policy)
vault write auth/kubernetes/role/vso-auth-platform \
  policies=vso-auth-platform bound_sa=vault-secrets-operator/mnt ttl=1h
vault write auth/kubernetes/role/vso-storage \
  policies=vso-storage       bound_sa=vault-secrets-operator/mnt ttl=1h
```

## VaultAuth / VaultStaticSecret 매핑

policy 분리에 따라 VaultAuth CR 도 2 개. 각 VaultStaticSecret 은 자기 도메인의 VaultAuth 를 참조한다:

| VaultAuth CR | Vault role | 참조 VaultStaticSecret |
|---|---|---|
| `vault-auth-auth-platform` | `vso-auth-platform` | `identity-postgres-superuser`, `keycloak-db-creds`, `auth-server-db-creds`, `keycloak-bootstrap-admin` |
| `vault-auth-storage` | `vso-storage` | `minio-tenant-env` |

VSO Operator SA(`vault-secrets-operator`) 는 한 개이지만 Vault 쪽에서 role 별 policy 가 분리되어 있다. auth-platform 토큰이 유출돼도 MinIO secret 은 보호된다.

## VSO 가 관리하는 Secret 카탈로그

Registry 는 auth 없이 운영(NetworkPolicy 로 `mnt` 내부 전용 보호)이라 base 에는 VaultStaticSecret 이 없다. dev overlay 에서 BasicAuth / pull credential 두 개를 추가한다.

| VaultStaticSecret (dev overlay) | Vault 경로 | K8s Secret | 소비 방식 |
|---|---|---|---|
| `identity-postgres-superuser` | `secret/identity-postgres/superuser` | `identity-postgres-superuser` | file mount (`/run/secrets/superuser/`) → `POSTGRES_USER_FILE`, `POSTGRES_PASSWORD_FILE` |
| `keycloak-db-creds` | `secret/keycloak/db` | `keycloak-db` | file mount — postgres initdb + keycloak `KC_DB_PASSWORD_FILE` |
| `auth-server-db-creds` | `secret/auth-server/db` | `auth-server-db` | file mount — `SPRING_CONFIG_IMPORT=configtree:/etc/secrets/` + Flyway sh wrapper |
| `keycloak-bootstrap-admin` | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` | file mount — `KC_BOOTSTRAP_ADMIN_{USERNAME,PASSWORD}_FILE` |
| `minio-tenant-env` | `secret/minio/tenant-env` | `minio-tenant-env` | MinIO Operator `spec.configuration.name` (env file) |
| `docker-registry-basic-auth` (dev) | `secret/docker-registry/basic-auth` | `docker-registry-basic-auth` | Traefik Middleware basicAuth |
| `docker-registry-pull-credentials` (dev) | `secret/docker-registry/pull-cred` | `docker-registry-pull-credentials` | imagePullSecret (`.dockerconfigjson`) |

모든 VaultStaticSecret 은 `destination.overwrite` 기본값(`false`) 사용. 기존 Secret 이 수동으로 존재하면 VSO 가 덮어쓰지 않는다 (소유권 경합 방지).

> **Vault 값 교체 후 즉시 반영**: `kubectl -n mnt delete secret <name>` 으로 기존 Secret 을 지우면 VSO 가 다음 reconcile 에 새 값으로 재생성한다.

`refreshAfter: 1h` — Vault 값 변경 시 1 시간 내 K8s Secret 에 자동 반영.

## dockerconfigjson `.auth` 필드

Docker 공식 config 스키마는 `.auth = base64("<username>:<password>")` 형태다. 기존에는 password 만 base64 하던 버그가 있었고 현재는 다음으로 수정되어 있다:

```
{{ printf "%s:%s" username password | b64enc }}
```

Docker daemon 이 Registry 에 로그인할 때 이 필드를 디코드하므로 정확한 포맷이 필수.

## VaultConnection address

base 는 `http://vault:8200` (짧은 이름) 만 둔다. VSO Operator Pod 가 같은 `mnt` namespace 에 있으면 Kubernetes DNS 가 짧은 이름을 해결한다. 다른 namespace 에서 운영할 때는 overlay 에서 FQDN(`http://vault.mnt.svc.cluster.local:8200`) 으로 patch.
