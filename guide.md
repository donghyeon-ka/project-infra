# Project-Infra 운영 가이드

아키텍처 · 폴더 구조 · 설계 결정은 [README.md](README.md) 를 먼저 읽는다. 본 문서는 실제 배포·운영 절차에 집중한다.

---

## 목차

1. [사전 준비](#1-사전-준비)
2. [최초 부트스트랩 — 자동](#2-최초-부트스트랩--자동)
3. [최초 부트스트랩 — 수동 (단계별)](#3-최초-부트스트랩--수동-단계별)
4. [Traefik / Ingress 운영](#4-traefik--ingress-운영)
5. [TLS / cert-manager 적용](#5-tls--cert-manager-적용)
6. [Keycloak Operator / RealmImport 적용](#6-keycloak-operator--realmimport-적용)
7. [Vault 시크릿 관리](#7-vault-시크릿-관리)
8. [Docker Registry 사용법](#8-docker-registry-사용법)
9. [앱에서 시크릿 사용하기](#9-앱에서-시크릿-사용하기)
10. [마이그레이션 실행 (Flyway)](#10-마이그레이션-실행-flyway)
11. [Vault UI 접근](#11-vault-ui-접근)
12. [환경별 배포](#12-환경별-배포)
13. [검증 / 린트 / 스키마 체크](#13-검증--린트--스키마-체크)
14. [정리 / 롤백 (teardown)](#14-정리--롤백-teardown)
15. [트러블슈팅](#15-트러블슈팅)
16. [etcd encryption at rest](#16-etcd-encryption-at-rest)
17. [Vault 운영자 토큰 관리](#17-vault-운영자-토큰-관리)
18. [bash history 에 비밀번호 남기지 않기](#18-bash-history-에-비밀번호-남기지-않기)
19. [트러블슈팅 — PodSecurity 위반 경고](#19-트러블슈팅--podsecurity-위반-경고)
20. [트러블슈팅 — 기존 K8s Secret 이 남아있을 때](#20-트러블슈팅--기존-k8s-secret-이-남아있을-때)
21. [트러블슈팅 — namespace 가 Terminating 에 걸림](#21-트러블슈팅--namespace-가-terminating-에-걸림)
22. [트러블슈팅 — vault-0 이 Ready 안 됨](#22-트러블슈팅--vault-0-이-01-running-에서-멈춤)
23. [트러블슈팅 — `helm upgrade` 가 `has no deployed releases` 로 실패](#23-트러블슈팅--helm-upgrade-가-has-no-deployed-releases-로-실패)

---

## 1. 사전 준비

### 필요한 CLI

| 도구 | 용도 |
|---|---|
| `kubectl` | 클러스터 조작 |
| `helm` | VSO Operator 설치 |
| `jq` | JSON 파싱 (scripts 내부) |
| `kustomize` | (선택) 로컬 렌더 |
| `kubeconform` | (선택) 스키마 검증 |
| `kube-linter` | (선택) 안티패턴 린트 |
| `yq` | (선택) YAML 가공 |

validate.sh 는 `~/bin` 에 설치된 도구도 자동으로 PATH 에 추가한다.

### 필요한 환경 변수

| 변수 | 의미 |
|---|---|
| `CONFIRM=yes` | (teardown 전용) 대화형 확인 자동 yes 처리 |
| `RESET_STALE_SECRETS=yes` | (bootstrap 전용) 기존 VSO-managed Secret 삭제 후 재생성 |
| `AUTO_GENERATE=yes` | (vault-seed-apps 전용) 비대화 + env 없음 시 랜덤 비밀번호 생성 |

Registry auth 가 제거되어 `VAULT_PUSH_PASSWORD` / `VAULT_PULL_PASSWORD` 는 더 이상 사용하지 않는다. 앱 시크릿 5 개는 Phase 6 에서 대화형으로 입력받거나 env var 로 주입 (guide §7).

### 클러스터 전제

- Kubernetes 1.25+ (Pod Security Admission 사용)
- `local-path` StorageClass (K3s 기본) 또는 동등한 RWO 프로비저너
- `kubernetes.io/metadata.name` namespace 라벨이 자동으로 붙는 1.22+ 환경
- dev 클러스터의 K3s 기본 Traefik 이 `kube-system` namespace 에 존재해야 함

---

## 2. 최초 부트스트랩 — 자동

대화형 실행 (권장 — Phase 6 에서 앱 시크릿 5 개 비밀번호를 무음 입력. bash history 에 남지 않음):

```bash
bash k8s/scripts/bin/bootstrap.sh dev
# Phase 6 진행 중:
#   Postgres superuser 비밀번호: *******
#   Postgres superuser 비밀번호 한 번 더: *******
#   Keycloak DB 비밀번호: *******
#   ... (5 개 시크릿, 각각 확인 재입력 포함)
```

비대화 (CI) 실행이 필요하면 env var 로 주되 **반드시 `HISTFILE=/dev/null` 접두어** 로 history 저장을 차단한다:

```bash
HISTFILE=/dev/null \
POSTGRES_SUPERUSER_PASSWORD='...' \
KEYCLOAK_DB_PASSWORD='...' \
AUTH_SERVER_DB_PASSWORD='...' \
KEYCLOAK_ADMIN_PASSWORD='...' \
MINIO_ROOT_PASSWORD='...' \
bash k8s/scripts/bin/bootstrap.sh dev

# 또는 비대화 + 랜덤 생성 (운영자가 값을 몰라도 됨, Vault 에서 나중에 조회):
AUTO_GENERATE=yes bash k8s/scripts/bin/bootstrap.sh dev
```

`bin/bootstrap.sh` 가 8 단계를 순서대로 실행한다:

| 단계 | 내용 |
|---|---|
| [0/8] MinIO Operator 설치 | `tasks/minio-operator-install.sh` — Tenant CRD 선행 등록 (별도 namespace `minio-operator`) |
| [1/8] Namespace + PSS 라벨 | `kubectl apply -k k8s/base/managing/namespace` — 먼저 적용해 의존성 안정화 |
| [2/8] 기존 Secret 점검 | VSO-managed K8s Secret 5 개 중 이미 존재하는 것 탐지. `RESET_STALE_SECRETS=yes` 면 삭제 |
| [3/8] 인프라 리소스 배포 | `kubectl apply -k k8s/overlays/dev/` (vault + registry + 앱 워크로드) |
| [4/8] vault-0 Running 대기 | Ready 가 아니라 **Running** — Vault readiness probe 는 초기화+unseal 후에만 통과하므로 |
| [5/8] Vault 초기화 | `tasks/vault-init.sh` — init / unseal / KV v2 / k8s auth / policy × 2 / role × 2 |
| [6/8] 앱 시크릿 seed | `tasks/vault-seed-apps.sh` — 5 개 시크릿 대화형 입력 (이미 있으면 skip) |
| [7/8] VSO Helm | `tasks/vso-install.sh` — 기존 dirty 릴리즈 자동 uninstall + `helm upgrade --install --wait` |
| [8/8] VSO CRDs | `kubectl apply -k k8s/overlays/dev/vso/` |

스크립트는 idempotent 다. 이미 진행된 단계는 자동 스킵된다.

> 주의: 현재 `bootstrap.sh` 는 `mnt` namespace 자원까지만 자동 배포한다. `k8s/overlays/dev/platform/traefik/` 와 `k8s/overlays/dev/tls/` 는 namespace 가 다르거나 optional dependency 가 있어 운영자가 별도로 적용한다.
>
> `k8s/overlays/dev/platform/cert-manager/`, `k8s/overlays/dev/platform/keycloak-operator/`, `k8s/overlays/dev-with-forward-auth/`, `k8s/overlays/dev/keycloak-realm/` 은 CRD / 외부 DNS / 인증 흐름 의존성이 있어 자동 부트스트랩 대상이 아니다.

### 생성되는 파일

- `vault-init-keys.json` — **unseal keys (5 개) + root token**. 권한 0600 으로 저장. **반드시 오프라인 금고 / 외부 KMS 로 이동**하고 원본은 삭제한다. `.gitignore` 에 등록되어 있으나 실수로도 커밋하지 말 것.

### 완료 확인

```bash
kubectl -n mnt get pods
kubectl -n mnt get secrets | grep -E 'identity-postgres-superuser|keycloak-db|auth-server-db|keycloak-bootstrap-admin|minio-tenant-env'
kubectl -n mnt get vaultstaticsecret
```

---

## 3. 최초 부트스트랩 — 수동 (단계별)

자동 스크립트가 중간에 실패했을 때, 또는 학습 목적으로 단계별 진행이 필요할 때.

### 3-1. MinIO Operator 설치

```bash
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/minio-operator-install.sh
```

### 3-2. 인프라 배포

```bash
kubectl apply -k k8s/base/managing/namespace   # namespace 선행
kubectl apply -k k8s/overlays/dev/
```

`mnt` namespace 와 Vault / Registry / 앱 워크로드가 선언된다. Registry 는 MinIO S3 자격증명 Secret 이 주입되기 전까지 대기할 수 있다. Postgres / Keycloak / auth-server 도 Vault secret 이 주입되기 전까지 `ContainerCreating` 으로 대기한다 (정상).

### 3-3. Vault Pod Running 대기

Vault 는 초기화 전에는 Ready 가 될 수 없으므로 Running 까지만 기다린다 (§19 참고).

```bash
kubectl -n mnt wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=120s
```

### 3-4. Vault 초기화

```bash
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vault-init.sh
```

이 스크립트가 수행하는 것:
- `vault operator init -key-shares=5 -key-threshold=3` (이미 초기화되었으면 스킵)
- `vault-init-keys.json` 생성 (권한 0600)
- Sealed 상태면 자동 unseal
- root token 으로 로그인 (stdin 파이프 — stdout 에 안 찍힘)
- `secret/` 에 KV v2 활성화 (idempotent)
- `kubernetes` auth method 활성화 + `kubernetes_ca_cert` + `token_reviewer_jwt` 설정 (idempotent)
- `vso-auth-platform` / `vso-storage` policy × 2 작성 (항상 재적용)
- `vso-auth-platform` / `vso-storage` k8s auth role × 2 작성 (항상 재적용)

### 3-5. VSO Helm 설치

```bash
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vso-install.sh
```

`helm upgrade --install --wait --timeout 5m` 으로 실행. 시작 시 기존 릴리즈가 `failed`/`pending*`/`uninstalling` 상태면 자동 uninstall 후 재설치 (guide §23 참고). `--values` 는 `k8s/base/plugins/vso/helm/values.yaml`.

### 3-6. VSO CRDs 적용

```bash
kubectl apply -k k8s/overlays/dev/vso/
```

`VaultConnection` / `VaultAuth` × 2 가 등록된다. `VaultStaticSecret` 은 dev overlay 각 서브디렉토리 (`database/`, `keycloak/`, `storage/`) 에서 이미 함께 적용됨. VSO Operator 가 Vault KV 를 읽어 K8s Secret 을 합성 — 단, **해당 Vault KV 경로에 값이 실제로 있어야 성공**. 아직 없으면 VSO 가 permission denied 또는 not found 로 남음. guide §7 의 수동 주입 후 자동 재시도.

---

## 4. Traefik / Ingress 운영

### 왜 별도 overlay 인가

`k8s/overlays/dev/kustomization.yaml` 은 `namespace: mnt` 를 전역으로 주입한다. 반면 K3s 기본 Traefik 은 실제로 `kube-system` 에 존재한다. 그래서 Traefik 운영 리소스는 같은 kustomization 안에 섞지 않고 `k8s/overlays/dev/platform/traefik/` 로 분리했다.

### 적용 대상

| overlay | namespace | 설명 |
|---|---|---|
| `k8s/overlays/dev/platform/traefik` | `kube-system` | `HelmChartConfig` + `Middleware` + `TLSOption` |
| `k8s/overlays/dev/` | `mnt` | `auth-server`, `keycloak` 의 app Ingress 및 app NetworkPolicy |

### Traefik 운영 overlay 적용

```bash
kubectl apply -k k8s/overlays/dev/platform/traefik
```

포함되는 것:

- `HelmChartConfig/traefik`
  `replicas=2`, `ingressClass=traefik`, HTTP→HTTPS redirect, metrics 활성화
- `Middleware/security-headers`
  HSTS, `X-Content-Type-Options`, frame deny 등 공용 헤더
- `TLSOption/modern-tls`
  TLS 1.2+, strict SNI, 허용 cipher suite

### 앱 Ingress 현재 상태

| 리소스 | host | 공개 범위 |
|---|---|---|
| `auth-server` | `project.com` | `/` |
| `keycloak-public` | `keycloak.dev.example.com` | `/realms/`, `/resources/`, `/.well-known/`, `/js/` |

app Pod 는 기본 deny 상태이므로, Traefik 에서 들어오는 8080/TCP 만 NetworkPolicy 로 별도 허용한다.

### 현재 범위 밖

- Traefik 에서 직접 Keycloak 인증을 검사하는 `ForwardAuth` 계층
- 외부 DNS / LB / firewall
- cert-manager 설치 전 실제 TLS secret 생성

최종 목표가 “인증되지 않은 사용자를 ingress 단에서 차단”이라면 다음 단계는 일반적으로 `Traefik ForwardAuth -> oauth2-proxy -> Keycloak` 이다. Keycloak 단독으로 Ingress 가 인증 판단을 직접 수행하진 않는다.

### ForwardAuth variant 적용

repo 에는 선택형 component `k8s/components/forward-auth/` 와 이를 결합한 overlay `k8s/overlays/dev-with-forward-auth/` 가 준비되어 있다. 기본 `dev` 전체를 포함한 뒤 oauth2-proxy 와 `auth-server` 보호 middleware 를 덧씌우는 방식이라, 기본 dev 운영과 인증 실험 구성을 깔끔하게 분리할 수 있다.

적용 전제:

1. `k8s/overlays/dev/keycloak-realm/` 또는 동등한 방법으로 `platform` realm + `auth-server-ingress` client 준비
2. redirect URI 를 `https://project.com/oauth2/callback` 로 등록
3. Vault path `secret/oauth2-proxy/forward-auth` 에 아래 key 저장
   `client-secret`
   `cookie-secret`
4. `project.com`, `keycloak.dev.example.com` 이 실제 Traefik 진입점으로 해석

적용:

```bash
kubectl apply -k k8s/overlays/dev-with-forward-auth
```

이 overlay 가 추가하는 것:

- `oauth2-proxy` Deployment / Service
- `project.com/oauth2/` 경로용 Ingress
- `oauth2-proxy-auth` Traefik `Middleware`
- `auth-server` Ingress patch
  `project.com/` 요청은 oauth2-proxy ForwardAuth 를 먼저 통과해야 함

현재 dev 용 oauth2-proxy 설정은 `ssl_insecure_skip_verify=true` 를 사용한다. 아직 외부 DNS 와 ACME 인증서 발급까지 완료된 상태가 아니라 Keycloak 공개 호스트 인증서 체인이 안정적으로 준비되지 않았기 때문이다. `cert-manager` + 정식 `Certificate` 도입 후에는 이 옵션을 제거해야 한다.

### 이걸 적용하면 끝인가

아직 아니다. `k8s/overlays/dev-with-forward-auth` 까지 적용해도 다음이 남아 있으면 운영 완료로 보지 않는다.

1. `cert-manager` 설치 및 `ClusterIssuer` 준비
2. `project.com`, `keycloak.dev.example.com` DNS 연결
3. Keycloak realm/client 실제 적용
4. Vault secret `secret/oauth2-proxy/forward-auth` 실제 저장
5. 브라우저 로그인, callback, logout 흐름 검증
6. 인증되지 않은 요청이 `auth-server` 에 직접 도달하지 못하는지 negative test
7. `ssl_insecure_skip_verify=true` 제거

즉, 지금 단계는 “배포 가능한 구성 + 문서 + 검증 가능한 뼈대”까지이며, **실제 dev 운영 완료**는 위 체크리스트까지 끝나야 한다.

---

## 5. TLS / cert-manager 적용

cert-manager 는 repo source of truth 로 편입되어 있다. dev 기준 설치 overlay 는 `k8s/overlays/dev/platform/cert-manager/` 이며, 공식 static install `v1.20.2` 를 적용한다. `ClusterIssuer` 는 CRD 등록 이후 `k8s/overlays/dev/platform/cert-manager-issuers/` 로 별도 적용한다.

적용:

```bash
kubectl apply -k k8s/overlays/dev/platform/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
kubectl apply -k k8s/overlays/dev/platform/cert-manager-issuers
```

주의:

- `letsencrypt-prod-clusterissuer.yaml` / `letsencrypt-staging-clusterissuer.yaml` 의 `admin@project.com` 은 실제 수신 가능한 운영 메일로 교체한다.
- HTTP-01 은 `project.com`, `keycloak.dev.example.com` 이 Traefik 외부 진입점으로 해석되고 80/443 이 도달 가능해야 성공한다.

### 준비된 리소스

| 파일 | secretName | host |
|---|---|---|
| `k8s/overlays/dev/tls/project-com-certificate.yaml` | `project-com-tls` | `project.com` |
| `k8s/overlays/dev/tls/keycloak-dev-certificate.yaml` | `keycloak-dev-example-com-tls` | `keycloak.dev.example.com` |

### Certificate 적용

전제:

- `cert-manager` CRD 설치 완료
- `ClusterIssuer/letsencrypt-prod` 또는 동등한 issuer 준비
- DNS 가 실제 Traefik 진입점으로 향함

적용:

```bash
kubectl apply -k k8s/overlays/dev/tls
```

그 다음 Ingress 의 TLS secret 연결과 인증서 Ready 상태를 확인한다. 인증서 발급이 끝난 뒤 `dev-with-forward-auth` 의 `ssl_insecure_skip_verify=true` 를 제거하는 것이 마무리 목표다.

---

## 6. Keycloak Operator / RealmImport 적용

Keycloak 은 권장 흐름에 맞춰 Operator 기반으로 전환한다. dev 제약상 실제 Keycloak 인스턴스와 realm/client 는 `mnt` 에 두며, Keycloak Operator 도 `mnt` 에 설치해 해당 namespace 를 watch 하게 한다.

`mnt` 는 default-deny egress namespace 이므로, `k8s/overlays/dev/platform/keycloak-operator/networkpolicy.yaml` 이 Operator Pod 에서 Kubernetes API 로 나가는 443/6443 만 허용한다. 이 정책이 없으면 Operator informer 가 API server 에 연결하지 못해 CrashLoopBackOff 로 떨어진다.

### 왜 필요한가

- `oauth2-proxy` 는 `auth-server-ingress` client 를 전제로 동작한다
- client / redirect URI 같은 OIDC 계약은 Git 에서 관리되어야 drift 가 줄어든다
- 표준도 Keycloak realm 을 `KeycloakRealmImport` 로 선언형 관리하라고 권장한다

### 적용 순서

1. Keycloak Operator CRD / controller 적용

```bash
kubectl apply -k k8s/overlays/dev/platform/keycloak-operator
kubectl -n mnt rollout status deploy/keycloak-operator --timeout=180s
```

2. 기존 수제 Keycloak 리소스 정리

기존 `Deployment` 기반 Keycloak 과 Operator 기반 Keycloak 이 같은 `Service/keycloak` 이름을 쓰므로, 전환 시 기존 수제 리소스를 정리한다.

```bash
kubectl -n mnt delete deployment/keycloak service/keycloak configmap/keycloak-config serviceaccount/keycloak-sa --ignore-not-found
```

3. dev overlay 적용

`k8s/overlays/dev/keycloak/` 는 이제 `Keycloak` CR, VSO secret 변환, Ingress, NetworkPolicy 를 포함한다.

```bash
kubectl apply -k k8s/overlays/dev
kubectl -n mnt get keycloak keycloak
kubectl -n mnt get pods -l app.kubernetes.io/instance=keycloak
```

4. RealmImport 적용

```bash
kubectl apply -k k8s/overlays/dev/keycloak-realm
kubectl -n mnt get keycloakrealmimport platform-realm
```

### client secret 처리

`auth-server-ingress` 같은 confidential client 의 secret 값 자체는 Git 에 넣지 않는다. realm/client shape 는 Git 에 두고, secret 값은 생성 후 Vault path `secret/oauth2-proxy/forward-auth` 로 넣어 oauth2-proxy 가 소비하게 한다.

---

## 7. Vault 시크릿 관리

### 애플리케이션 시크릿 저장 — 자동화됨 (`tasks/vault-seed-apps.sh`)

5 개 시크릿은 `bin/bootstrap.sh` Phase 6 에서 자동으로 seed 된다. 또는 단독 실행 가능:

```bash
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vault-seed-apps.sh
```

동작:
- **이미 있는 경로는 skip** — 운영자가 회전한 값을 덮어쓰지 않음
- **대화형 입력** (TTY) — `read -r -s` 로 무음 입력 + 확인 재입력. bash history 에 남지 않음
- **비대화 + env 지정** — 해당 env var 를 사용 (`HISTFILE=/dev/null` 접두 권장)
- **비대화 + env 없음 + `AUTO_GENERATE=yes`** — `openssl rand` 로 랜덤 24자 생성

Vault CLI 의 `vault kv put <path> -` 모드로 **JSON stdin 전달** 이라 비밀번호가 argv / process table 어디에도 노출되지 않는다.

### 시크릿 경로 및 키

| 경로 | 키 | 용도 |
|---|---|---|
| `secret/identity-postgres/superuser` | `username` (기본 postgres), `password` | Postgres 슈퍼유저 (`POSTGRES_USER_FILE` / `POSTGRES_PASSWORD_FILE`) |
| `secret/keycloak/db` | `password` | Keycloak 의 DB 비밀번호 + initdb 가 생성하는 keycloak DB role |
| `secret/auth-server/db` | `SPRING_DATASOURCE_USERNAME` (기본 auth_server), `SPRING_DATASOURCE_PASSWORD` | Spring Boot configtree + Flyway |
| `secret/keycloak/bootstrap-admin` | `KEYCLOAK_ADMIN` (기본 admin), `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 초기 관리자 계정 |
| `secret/minio/tenant-env` | `config.env` (env-file 포맷 단일 키) | MinIO Operator Tenant 루트 자격증명 |
| `secret/oauth2-proxy/forward-auth` | `client-secret`, `cookie-secret` | `dev-with-forward-auth` overlay 의 oauth2-proxy confidential client / session cookie |

### 값 조회

```bash
kubectl -n mnt port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
vault login -method=userpass username=alice   # userpass admin 으로 로그인 권장

vault kv get secret/keycloak/bootstrap-admin
# 특정 field 만:
vault kv get -field=KEYCLOAK_ADMIN_PASSWORD secret/keycloak/bootstrap-admin
```

### 값 변경 (비밀번호 교체)

```bash
# 새 값으로 덮어쓰기 (vault kv put) — seed-apps.sh 의 skip 로직 우회
vault kv put secret/keycloak/db password='<새-pw>'

# 60s ~ 1h 내 VSO 가 자동으로 K8s Secret 갱신. 즉시 반영 원하면:
kubectl -n mnt delete secret keycloak-db
# VSO 가 Vault KV 를 읽어 재생성
```

### 주의 — 비밀번호에 `"` 금지

MinIO 의 `config.env` 는 env-file 포맷 (`export KEY="value"`) 이라 값에 `"` 가 들어가면 파싱 깨짐. `vault-seed-apps.sh` 가 프롬프트에서 거부하며 재입력 요구한다.

VSO 가 `refreshAfter: 60s` / `1h` (경로별) 주기로 K8s Secret 에 반영한다. 즉시 반영하려면 해당 VaultStaticSecret 을 삭제·재생성하거나 `kubectl -n mnt annotate vaultstaticsecret <name> refresh=$(date +%s) --overwrite`.

### 시크릿 값 변경 (비밀번호 교체)

```bash
vault kv put secret/keycloak/db password='<새-pw>'
# 60s~1h 내 자동 동기화. 강제 즉시:
kubectl -n mnt delete secret keycloak-db
# VSO 가 감지해서 다시 생성
```

### root token 회전

```bash
vault operator generate-root -init
# 응답의 nonce / otp 저장 → unseal key 로 쿼럼 수집 → root token 디코드
# 새 root token 으로 기존 token revoke
vault token revoke <old-root-token>
```

`vault-init-keys.json` 의 `root_token` 필드를 새 토큰으로 교체하고 파일 백업도 업데이트한다.

---

## 8. Docker Registry 사용법

### Push

```bash
docker login registry.project.com
# username: <DOCKER_REGISTRY_PUSH_USERNAME, 기본 registry-push>
# password: <DOCKER_REGISTRY_PUSH_PASSWORD 로 seed 한 값>

docker tag my-app:0.1.0 registry.project.com/my-app:0.1.0
docker push registry.project.com/my-app:0.1.0
```

외부 push 는 `registry.project.com` Ingress 로 들어오며 Traefik BasicAuth 를 통과해야 한다. BasicAuth 의 htpasswd `users` 값은 Vault path `secret/docker-registry/basic-auth` 에 저장되고 VSO 가 `docker-registry-basic-auth` Secret 으로 동기화한다.

실제 워크로드 이미지는 `registry.project.com/...` 주소를 사용한다. image pull 은 Pod 내부가 아니라 노드의 kubelet/containerd 가 수행하므로, `docker-registry.mnt.svc.cluster.local` 같은 ClusterIP DNS 를 `image:`에 쓰는 방식은 피한다. 앱 ServiceAccount 는 VSO 가 만드는 `docker-registry-pull-credentials` imagePullSecret 을 사용한다.

내부 Service 는 registry Pod 자체 확인이나 클러스터 내부 HTTP 접근이 필요할 때만 사용한다.

```bash
docker tag my-app:0.1.0 docker-registry.mnt.svc.cluster.local:5000/my-app:0.1.0
docker push docker-registry.mnt.svc.cluster.local:5000/my-app:0.1.0
```

### Pull (Pod)

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      serviceAccountName: auth-server-sa
      containers:
        - name: my-app
          image: registry.project.com/my-app:0.1.0
```

`auth-server-sa` / `test-server-*-sa` 는 dev overlay 에서 `docker-registry-pull-credentials` 를 `imagePullSecrets` 로 참조한다.

### auth-server 이미지 빌드 / push / 검증 예시

2026-04-26 dev 환경에서 `auth-server:0.1.0` 을 검증할 때 사용한 명령이다. `registry.project.com` 경로가 노드에서 바로 pull 되려면 DNS/TLS 또는 k3s `registries.yaml` 설정이 먼저 준비되어야 한다. 해당 설정이 없는 로컬 검증에서는 port-forward 로 registry 에 push 한 뒤, 노드 containerd 에 같은 image ref 를 import 해서 Pod 기동을 확인했다.

```bash
# 1. 애플리케이션 이미지 빌드
cd /home/donghyeon/dev/Project-Auth-Server
docker build --provenance=false \
  -f deploy/docker/application/Dockerfile \
  -t localhost:5000/auth-platform/auth-server:0.1.0 .

# 2. 내부 registry 로컬 포트 오픈
cd /home/donghyeon/dev/Project-Infra
kubectl -n mnt port-forward --address 127.0.0.1 svc/docker-registry 5000:5000

# 3. registry BasicAuth 값을 Vault KV 에 저장
HTPASSWD_LINE="testuser:$(openssl passwd -apr1 abcd6845)"
kubectl -n mnt exec vault-0 -- vault kv put secret/docker-registry/basic-auth \
  username=testuser \
  password=abcd6845 \
  users="$HTPASSWD_LINE"

# 4. VSO storage policy 가 registry KV 를 읽을 수 있는지 확인 / 보정
kubectl -n mnt exec vault-0 -- vault policy read vso-storage
printf '%s\n' \
  'path "secret/data/minio/*" {' \
  '  capabilities = ["read"]' \
  '}' \
  'path "secret/data/docker-registry/*" {' \
  '  capabilities = ["read"]' \
  '}' \
  | kubectl -n mnt exec -i vault-0 -- vault policy write vso-storage -

# 5. image push 및 registry 확인
docker push localhost:5000/auth-platform/auth-server:0.1.0
curl http://127.0.0.1:5000/v2/auth-platform/auth-server/tags/list

# 6. source of truth 인 Project-Infra overlay 적용
kubectl apply --server-side --field-manager=codex-dev --force-conflicts -k k8s/overlays/dev/auth
kubectl -n mnt wait --for=create secret/docker-registry-pull-credentials --timeout=120s
kubectl -n mnt get secret docker-registry-pull-credentials -o jsonpath='{.type}{"\n"}'

# 7. registry.project.com pull 이 아직 노드에서 불가할 때의 임시 검증용 import
docker tag localhost:5000/auth-platform/auth-server:0.1.0 registry.project.com/auth-platform/auth-server:0.1.0
docker save registry.project.com/auth-platform/auth-server:0.1.0 -o /tmp/auth-server-0.1.0.tar
kubectl debug node/dev-cp-1 --image=busybox --profile=sysadmin -- sleep 3600
kubectl cp /tmp/auth-server-0.1.0.tar default/<node-debug-pod>:/host/tmp/auth-server-0.1.0.tar
kubectl exec -n default <node-debug-pod> -- chroot /host k3s ctr -n k8s.io images import /tmp/auth-server-0.1.0.tar
# dev-wk-1, dev-wk-2 에도 같은 방식으로 반복한다.

# 8. 배포 / health 검증
kubectl -n mnt delete job migration-flyway
kubectl apply --server-side --field-manager=codex-dev --force-conflicts -k k8s/overlays/dev/auth
kubectl -n mnt wait --for=condition=complete job/migration-flyway --timeout=180s
kubectl -n mnt rollout restart deployment/auth-server
kubectl -n mnt rollout status deployment/auth-server --timeout=240s
kubectl -n mnt get pods -o wide
kubectl -n mnt port-forward svc/auth-server 18081:8081
curl -fsS http://127.0.0.1:18081/actuator/health/readiness
```

정상 결과는 registry tag 응답에 `0.1.0` 이 포함되고, pull secret 타입이 `kubernetes.io/dockerconfigjson` 이며, readiness 응답이 `{"status":"UP"}` 이다.

---

## 9. 앱에서 시크릿 사용하기

### envFrom (권장)

```yaml
spec:
  containers:
    - name: app
      envFrom:
        - secretRef:
            name: auth-server-db    # VSO 가 dev overlay 에서 합성
```

### 개별 key

```yaml
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: identity-postgres-superuser
        key: password
```

### volume mount

```yaml
volumes:
  - name: db-creds
    secret:
      secretName: auth-server-db
containers:
  - volumeMounts:
      - name: db-creds
        mountPath: /etc/secrets
        readOnly: true
```

---

## 10. 마이그레이션 실행 (Flyway)

base 에 정의된 `migration-flyway` Job 은 기본적으로는 배포되지 않는다. dev overlay 가 ArgoCD PreSync / sync-wave=-1 annotation 을 patch 하므로, GitOps 로 배포할 때는 ArgoCD 가 앱보다 먼저 Job 을 실행한다.

`kubectl apply -k` 로 수동 배포 시에는 Job 이 **앱과 동시에** 생성되므로 race 가능하다. 이 경우:

```bash
# migration 먼저
kubectl apply -k k8s/overlays/dev/auth/ -l app.kubernetes.io/component=migration

# 완료 대기
kubectl -n mnt wait --for=condition=complete job/migration-flyway --timeout=300s

# 앱 배포
kubectl apply -k k8s/overlays/dev/
```

ArgoCD 를 쓰면 이 순서가 sync-wave 로 자동화된다.

### 재실행

Flyway Job 은 `backoffLimit: 0` 으로 한 번만 실행된다. 재실행하려면:

```bash
kubectl -n mnt delete job migration-flyway
kubectl apply -k k8s/overlays/dev/auth/
```

---

## 11. Vault UI 접근

`service-ui` NodePort 는 보안상 제거되었다. 관리자는 port-forward 로만 접근한다.

```bash
kubectl -n mnt port-forward svc/vault 8200:8200
# 브라우저에서 http://127.0.0.1:8200/ui
# Token 입력: $(jq -r .root_token vault-init-keys.json)
```

root token 은 최초 설정 / 비상 복구 외에는 사용하지 않는다. 평시 접근은 개인 AppRole 또는 OIDC auth 로 분리하는 것을 권장.

---

## 12. 환경별 배포

현재 `dev` 만 구성되어 있다.

```bash
bash k8s/scripts/bin/bootstrap.sh dev
```

staging / prod overlay 는 비어 있으며, 추후 다음 요소를 추가한다:
- Vault storage `file` → `raft` 전환
- Postgres backup CronJob
- cert-manager ClusterIssuer + Certificate
- 환경별 hostname (Keycloak / 공개 Ingress)
- `persistentVolumeClaimRetentionPolicy` 를 prod 는 `Retain` 유지 (dev 는 overlay 에서 `Delete` 로 patch)

---

## 13. 검증 / 린트 / 스키마 체크

```bash
bash k8s/scripts/ci/validate.sh
```

출력:

```
k8s/overlays/dev       build=ok  schema=ok  lint=ok
k8s/overlays/dev/vso   build=ok  schema=ok  lint=ok
모든 overlay 통과
```

- **build** : `kustomize build` (환경 중립성 / patch / labels)
- **schema** : `kubeconform -strict -ignore-missing-schemas` (K8s OpenAPI + Datree CRD catalog 원격 조회)
- **lint**   : `kube-linter lint --config .kube-linter.yaml` (securityContext / 리소스 요구사항 / PSS / image tag 등)

kustomization.yaml 이 없는 overlay (`staging`, `prod`) 는 자동 스킵된다.

CI 파이프라인에서 이 스크립트를 PR 게이트로 사용한다. 실패 시 `build=fail|schema=fail|lint=fail` 로 표기되고 상세 에러가 stderr 에 출력된다.

---

## 14. 정리 / 롤백 (teardown)

```bash
# 대화형 (y/N 확인)
bash k8s/scripts/bin/teardown.sh dev

# 비대화 (CI)
CONFIRM=yes bash k8s/scripts/bin/teardown.sh dev

# MinIO Operator 까지 제거 (기본은 유지)
TEARDOWN_MINIO_OPERATOR=yes bash k8s/scripts/bin/teardown.sh dev
```

체계적 7 단계:

| 단계 | 내용 |
|---|---|
| [1/7] Precheck | namespace 존재 여부 + phase 확인. 일부 단계는 없으면 skip |
| [2/7] VSO CRD 삭제 | `kubectl delete -k overlays/<env>/vso/` 60s timeout. 타임아웃 시 `VaultStaticSecret / VaultAuth / VaultConnection` finalizer 강제 해제 |
| [3/7] VSO Helm uninstall | `helm uninstall --wait 5m` (Operator 제거) |
| [4/7] 인프라 overlay 삭제 | `kubectl delete -k overlays/<env>/` 120s timeout |
| [5/7] namespace 잔존 리소스 finalizer 정리 | PVC 보호 finalizer + VSO CRD + 전체 namespaced 리소스 일괄 finalizer 제거 |
| [6/7] namespace 삭제 + Terminating 감지 | `kubectl delete namespace` 60s 대기 → 실패 시 `/finalize` API 호출로 강제 종료 |
| [7/7] Cluster-scoped 정리 | `vault-tokenreview-binding` ClusterRoleBinding 제거. `TEARDOWN_MINIO_OPERATOR=yes` 면 MinIO Operator 도 함께 |

**핵심 개선**: controller 없이 남은 CRD finalizer, PVC 보호 finalizer, 전체 namespaced 리소스 finalizer 를 단계별로 선제 해제해서 namespace 가 Terminating 에 걸리지 않도록 처리. 이미 Terminating 에 걸려 있어도 Phase 6 에서 `/finalize` API 직접 호출로 강제 종료.

teardown 후에도 `vault-init-keys.json` 은 보존된다. 완전 초기화하려면 수동으로 삭제한다.

### 강제 종료의 부작용 경고

Phase 6 의 `/finalize` 는 orphan 리소스 (PV / PVC 바인딩) 를 남길 수 있다. 일반적으로:

```bash
# teardown 후 orphan PV 검사
kubectl get pv | grep -E 'Released|Failed'

# 필요시 수동 삭제
kubectl delete pv <name>
```

---

## 15. 트러블슈팅

### Registry Pod 가 계속 `ContainerCreating`

Secret `docker-registry-minio` 또는 `docker-registry-basic-auth` 가 아직 생성되지 않은 상태일 수 있다. VSO 가 Vault KV 를 읽어서 만든다.

```bash
kubectl -n mnt describe vaultstaticsecret docker-registry-minio
kubectl -n mnt describe vaultstaticsecret docker-registry-basic-auth
kubectl -n mnt logs -l app.kubernetes.io/name=vault-secrets-operator --tail=100
```

자주 보는 에러:
- `permission denied` → Vault policy 또는 role 설정 오류. `tasks/vault-init.sh` 재실행.
- `no matching vault path` → Vault KV 에 값이 저장되지 않음. `tasks/vault-seed-apps.sh` 재실행.

### VSO 가 Vault 에 로그인 실패

```bash
kubectl -n mnt logs -l app.kubernetes.io/name=vault-secrets-operator --tail=200 | grep -i error
```

체크 항목:
- Vault ClusterRoleBinding `vault-tokenreview-binding` 존재? `kubectl get clusterrolebinding vault-tokenreview-binding`
- Vault ServiceAccount 에 token 자동 마운트 되어 있음? (기본값 true)
- `vault auth/kubernetes/config` 에 `kubernetes_ca_cert` + `token_reviewer_jwt` 설정됨? → 없으면 `tasks/vault-init.sh` 재실행
- VaultConnection address 가 `http://vault:8200` 이고 같은 namespace 에 실제 `vault` Service 존재?

### `vault operator init` 실패 — 이미 초기화됨

정상. `tasks/vault-init.sh` 는 idempotent 하게 이 경우를 스킵하고 unseal 만 다시 수행한다. `kubectl exec vault-0 -- vault status` 로 상태 확인.

### 부트스트랩 중단 → 재시작

```bash
bash k8s/scripts/bin/bootstrap.sh dev
```

각 단계가 idempotent 이므로 그대로 다시 실행해도 된다. 이미 완료된 단계는 스킵된다. 프롬프트에서 push-user / pull-user 비밀번호를 다시 입력해야 하지만, **Vault KV 에 이미 있으면 Phase 6 이 스킵되므로 비밀번호는 사용되지 않음**.

### Vault UI 가 안 열림

NodePort 는 제거되었다. port-forward 를 사용한다:

```bash
kubectl -n mnt port-forward svc/vault 8200:8200
```

`http://127.0.0.1:8200/ui` 로 접근.

### NetworkPolicy 로 트래픽 차단 의심

```bash
# 모든 NetworkPolicy 확인
kubectl -n mnt get networkpolicy

# 특정 Pod 에 적용된 정책 확인
kubectl -n mnt describe pod <pod-name> | grep -A3 Labels
kubectl -n mnt get networkpolicy -o yaml | grep -A2 podSelector
```

임시 허용 (디버깅):

```bash
kubectl -n mnt delete networkpolicy default-deny-all
# 진단 완료 후 반드시 복구: kubectl apply -k k8s/overlays/dev/
```

---

## 16. etcd encryption at rest

VSO 가 만드는 K8s Secret 은 기본적으로 **etcd 에 base64 로만 저장된다 (평문과 동일)**. 운영 전 반드시 암호화를 켠다.

### K3s 방식 (권장 — 학습/소규모)

최초 설치 시:

```bash
# /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
secrets-encryption: true

# 또는 설치 커맨드
curl -sfL https://get.k3s.io | sh -s - server --secrets-encryption
```

K3s 가 AES-CBC 키를 자동 생성해서 `/var/lib/rancher/k3s/server/cred/encryption-config.json` 에 저장한다.

이미 돌고 있는 클러스터에서 켜는 경우:

```bash
sudo vim /etc/rancher/k3s/config.yaml      # secrets-encryption: true 추가
sudo systemctl restart k3s

# 기존 Secret 을 즉시 재암호화 (없으면 새 Secret 부터 적용)
sudo k3s secrets-encrypt prepare
sudo systemctl restart k3s
sudo k3s secrets-encrypt rotate
sudo systemctl restart k3s
sudo k3s secrets-encrypt reencrypt
```

확인:

```bash
sudo k3s secrets-encrypt status
# Encryption Status: Enabled
# Current Rotation Stage: start
# Server Encryption Hashes: All hashes match
```

### 표준 Kubernetes 방식 (kubeadm 등)

1. `/etc/kubernetes/encryption.yaml` 생성:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:
          keys:
            - name: key-2026-04-21
              secret: <head -c 32 /dev/urandom | base64>
      - identity: {}
```

2. kube-apiserver manifest 에 플래그 추가:

```yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/encryption.yaml
      volumeMounts:
        - name: encryption-config
          mountPath: /etc/kubernetes/encryption.yaml
          readOnly: true
```

3. 기존 Secret 재암호화:

```bash
kubectl get secrets --all-namespaces -o json \
  | kubectl replace -f -
```

### KMS provider (프로덕션 권장)

`aescbc` 대신 KMS plugin(Vault transit / AWS KMS / GCP KMS) 사용. Circular dependency(Vault 도 K8s Secret 에 의존) 회피를 위해 Vault transit 은 **별도 provider Vault** 를 띄워야 한다. 지금 프로젝트는 단일 Vault 이므로 KMS 는 추후 작업.

### 검증

Secret 이 암호화됐는지 확인:

```bash
# K3s
sudo k3s kubectl -n mnt get secret auth-server-db -o yaml \
  | grep -A1 "data:"

# etcd 에 직접 접근해서 암호화 확인 (K3s)
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  get /registry/secrets/mnt/auth-server-db
# 출력이 'k8s:enc:aescbc:v1:...' 로 시작하면 암호화됨
```

---

## 17. Vault 운영자 토큰 관리

root token 은 **비상시(rekey / generate-root / 전체 복구) 전용**으로만 사용한다. 평시 작업은 개인별 계정 + `vault-admin` policy 로 수행한다.

### 초기 설정

부트스트랩 완료 후 한 번만:

```bash
REPO_ROOT="$(pwd)" \
VAULT_ADMIN_USERNAME='alice' \
VAULT_ADMIN_PASSWORD='<초기 비밀번호>' \
bash k8s/scripts/tasks/vault-setup-admin.sh
```

이 스크립트가 수행:
- `userpass` auth method 활성화 (idempotent)
- `vault-admin` policy 작성 (`secret/*`, `auth/*`, `sys/mounts/*`, `sys/audit/*` 등 관리 권한)
- `${VAULT_ADMIN_USERNAME}` 계정 생성 (token TTL 기본 8h / max 24h)

### 운영자 로그인 — root token 사용 중단

```bash
# port-forward 로 vault CLI 접근
kubectl -n mnt port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200

# 로그인 (로그인 시 발급되는 토큰은 8h 후 자동 만료)
vault login -method=userpass username=alice
# Password (will be hidden): <입력>
# Token is displayed and automatically cached in ~/.vault-token
```

첫 로그인 후 비밀번호 변경:

```bash
vault write auth/userpass/users/alice/password password='<새 비밀번호>'
```

### root token 처리

`vault-init-keys.json` 에 있는 root token 은:

1. **즉시 오프라인 금고(1Password Team / 하드웨어 보안 금고 / 봉인 봉투)로 이동**
2. 원본 파일에서 `root_token` 필드 삭제 (unseal keys 는 재부팅 시 필요하므로 유지)
3. root token 이 필요하면:

```bash
# 기존 root token 유효하면 재사용
vault login <root-token>

# 분실/만료됐으면 재발급 (unseal key 쿼럼 필요)
vault operator generate-root -init
# 응답의 nonce 저장, unseal key 보유자들이 otp 로 제출
vault operator generate-root -nonce=<nonce> -otp=<your-otp> <unseal-key-1>
vault operator generate-root -nonce=<nonce> -otp=<your-otp> <unseal-key-2>
vault operator generate-root -nonce=<nonce> -otp=<your-otp> <unseal-key-3>
# 마지막 응답에 Encoded Token 이 나옴 → otp 로 decode
vault operator generate-root -decode=<encoded> -otp=<your-otp>
# 새 root token 확보 후 기존 것 revoke:
vault token revoke <old-root-token>
```

### 운영자 계정 추가 / 제거

```bash
# 추가
REPO_ROOT="$(pwd)" \
VAULT_ADMIN_USERNAME='bob' \
VAULT_ADMIN_PASSWORD='<임시 pw>' \
bash k8s/scripts/tasks/vault-setup-admin.sh

# 제거
vault delete auth/userpass/users/bob
```

### 권한 분리 (추후 확장)

`vault-admin` 은 전권 정책이다. 실무에서는 역할별 분리 권장:

| 역할 | policy 이름 | 권한 범위 |
|---|---|---|
| 인프라 admin | `vault-admin` | 현재 정의된 전권 (rekey 제외) |
| 앱 팀 (read) | `secret-readonly` | `secret/data/*` read 전용 |
| 앱 팀 (write) | `secret-writer` | 팀별 경로 제한 (`secret/data/auth-server/*` 등) |
| 감사자 | `audit-reader` | `sys/audit/*` read + Vault audit log 접근 |

각 policy 를 만들고 userpass user 생성 시 `token_policies=<policy-name>` 로 바인딩한다.

### 감사 로그 활성화 (추후)

Vault 자체 감사 로그는 기본 비활성. 운영에서는 반드시 활성화:

```bash
# file 방식
vault audit enable file file_path=/vault/logs/audit.log

# socket 방식 (중앙집중 수집)
vault audit enable socket address=loki-syslog.monitoring.svc:514 socket_type=tcp
```

`statefulset.yaml` 의 volumeMounts 에 `/vault/logs` 를 추가해야 파일 방식 사용 가능. 별도 작업.

---

## 18. bash history 에 비밀번호 남기지 않기

`VAR=value command` 형태로 env var 를 명령줄에 직접 적으면 **그대로 `~/.bash_history` 에 저장**된다. 대응:

### 선호 — 대화형 입력

```bash
bash k8s/scripts/bin/bootstrap.sh dev
# 프롬프트에서 무음 입력 (echo 안 됨)
```

본 프로젝트의 모든 시크릿 seed 스크립트 (`bootstrap.sh`, `tasks/vault-seed-apps.sh`, `tasks/vault-setup-admin.sh`) 는 env var 가 비어 있으면 TTY 에서 자동으로 `read -r -s` 프롬프트로 전환한다.

### 비대화 (CI) 실행 시

어쩔 수 없이 env var 를 넣어야 할 때:

```bash
# 이번 명령만 history 에 안 남기기
HISTFILE=/dev/null \
VAULT_PUSH_PASSWORD='...' VAULT_PULL_PASSWORD='...' \
bash k8s/scripts/bin/bootstrap.sh dev

# 또는 세션 전체 history 비활성화
set +o history
VAULT_PUSH_PASSWORD='...' bash ...
set -o history
```

`HISTCONTROL=ignorespace` 가 설정된 쉘이면 **명령 앞에 공백 1 칸** 넣어도 저장되지 않는다. 다만 쉘마다 설정이 다르니 `HISTFILE=/dev/null` 이 가장 확실.

---

## 19. 트러블슈팅 — PodSecurity 위반 경고

`kubectl apply` 중 `Warning: would violate PodSecurity "restricted:latest": ...` 메시지가 뜨면 **어떤 Pod 의 어떤 필드** 가 위반인지 확인:

```bash
# 최근 이벤트
kubectl -n mnt get events --sort-by='.lastTimestamp' \
  | grep -i 'podsecurity\|FailedCreate'

# 경고 메시지는 apply 시 stderr 로도 나옴
kubectl apply -k k8s/overlays/dev/ 2>&1 | grep -i warning
```

자주 걸리는 항목 체크리스트:

- `runAsNonRoot: true` 누락 또는 `runAsUser: 0`
- `allowPrivilegeEscalation: false` 누락
- `capabilities.drop: [ALL]` 누락
- `seccompProfile.type: RuntimeDefault` 누락
- `readOnlyRootFilesystem: true` 누락 (선택이지만 권장)
- hostPath / hostNetwork / hostPID / hostIPC 사용
- hostPorts 사용

**base 의 모든 워크로드는 이미 Restricted 통과**. 경고가 뜨는 건 보통 다음 두 가지:

1. **VSO Operator Helm chart** — chart 0.9.0 기본 설정이 `readOnlyRootFilesystem` 을 세팅하지 않을 수 있음. `k8s/base/plugins/vso/helm/values.yaml` 에 securityContext override 추가 가능
2. **MinIO Operator Helm chart** — 자체 chart 의 Operator Pod

양쪽 모두 Operator 의 Pod 이고, 자기 namespace(`vault-secrets-operator-system` / `minio-operator`)에서 돌아가므로 `mnt` 의 PSS 와 무관. `mnt` 안의 Pod 에서 경고가 나면 매니페스트를 수정해야 함.

### 참고 — Registry BasicAuth

외부 push 용 BasicAuth 는 더 이상 임시 `htpasswd-gen-*` Pod 를 만들지 않는다. `tasks/vault-seed-apps.sh` 가 `openssl passwd -apr1` 로 htpasswd 한 줄을 만들고 Vault path `secret/docker-registry/basic-auth` 에 `users` 키로 저장한다. VSO 는 이를 `docker-registry-basic-auth` Secret 으로 동기화하고, Traefik Middleware 가 외부 Ingress 에서 검증한다.

---

## 20. 트러블슈팅 — 기존 K8s Secret 이 남아있을 때

VSO 는 `destination.overwrite: false` 기본값이라 **이미 존재하는 Secret 을 덮어쓰지 않는다**. Vault KV 에 새 값을 넣어도 K8s Secret 은 옛날 값을 유지.

### 확인

```bash
kubectl -n mnt get secret -l 'kubernetes.io/managed-by!=Helm' \
  -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp
```

### 해결 1 — 개별 삭제 후 VSO 재생성

```bash
kubectl -n mnt delete secret docker-registry-minio docker-registry-basic-auth
# VSO 가 1-2 분 내 Vault KV 에서 읽어 재생성
kubectl -n mnt get vaultstaticsecret
```

### 해결 2 — bootstrap 재실행 시 자동 정리

```bash
RESET_STALE_SECRETS=yes bash k8s/scripts/bin/bootstrap.sh dev
# Phase 2 에서 VSO-managed Secret 7 개 전부 삭제 → Phase 7/8 에서 VSO 재생성
```

이 옵션은 **destructive**. 운영자가 명시적으로 지정했을 때만 동작.

---

## 21. 트러블슈팅 — namespace 가 Terminating 에 걸림

`mnt` namespace 가 `Terminating` 에서 오래 멈추면 보통 다음 셋 중 하나다.

- controller 가 이미 사라졌는데 CRD finalizer 가 남아 있음
- PVC protection finalizer 가 남아 있음
- namespaced 리소스 일부가 finalizer 때문에 삭제 완료를 못 함

현재 `teardown.sh` 는 이 상황을 고려해 단계적으로 정리한다.

1. `VaultStaticSecret / VaultAuth / VaultConnection` finalizer 제거
2. PVC 보호 finalizer 제거
3. 남은 namespaced 리소스 finalizer 일괄 제거
4. 마지막에 namespace `/finalize` 호출

수동 확인:

```bash
kubectl get namespace mnt -o yaml
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl -n mnt get --ignore-not-found
```

이미 teardown 을 사용 중이라면 대부분은 스크립트가 자동 처리한다. 수동 개입은 정말 스크립트가 실패했을 때만 한다.

---

## 22. 트러블슈팅 — vault-0 이 `0/1 Running` 에서 멈춤

### 현상

```
NAME      READY   STATUS    RESTARTS   AGE
vault-0   0/1     Running   0          2m
```

계속 `0/1 Running`. `kubectl wait --for=condition=Ready` 가 timeout 으로 실패.

### 원인 — 의도된 동작

Vault 의 readiness probe 는 `/v1/sys/health?sealedcode=503&uninitcode=503` 를 사용한다. 즉:
- **uninitialized** → HTTP 503 → readiness fail
- **sealed** → HTTP 503 → readiness fail
- **initialized + unsealed** → HTTP 200 → Ready

이건 sealed Vault 가 Service Endpoints 에서 제외되어 트래픽이 흘러가지 않도록 하는 **보안 설계**. 초기화 전에는 구조상 Ready 가 될 수 없다.

### 해결 — `vault-init.sh` 실행

```bash
# Pod 이 Running 이면 exec 가능 → 초기화 실행 가능
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vault-init.sh
```

수행되는 것:
1. `vault operator init` — unseal keys + root token 생성
2. unseal 5 shares 중 3 개로 자동 unseal
3. root login → KV v2 + k8s auth + policy × 3 + role × 3

`vault-init.sh` 가 끝나고 몇 초 뒤 Pod 이 자동으로 Ready 로 전환:

```bash
kubectl -n mnt get pod vault-0
# vault-0   1/1   Running
```

### bootstrap.sh 가 Phase 4 에서 Ready 대기로 실패했을 때 — 재개

```bash
# Phase 4 까지는 apply + Pod Running 완료 상태
# 남은 Phase 5~8 만 수동 실행
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vault-init.sh             # Phase 5
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vault-seed-apps.sh        # Phase 6
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vso-install.sh            # Phase 7
kubectl apply -k k8s/overlays/dev/vso/                              # Phase 8
```

또는 bootstrap.sh 를 그냥 다시 실행해도 된다 (idempotent). Phase 4 가 최신 버전에선 Running 만 기다리므로 바로 Phase 5 로 진행된다.

### 참고 — 다른 Pod 들이 `ContainerCreating` 상태

`auth-server`, `keycloak`, `identity-postgres`, `docker-registry`, `migration-flyway` 가 `ContainerCreating` 에 머무는 건 **VSO 가 만드는 K8s Secret 이 아직 없어서** volume mount 가 대기 중인 것. Vault 초기화 + 앱 secret 주입 (guide §7) + VSO sync 가 끝나면 차례로 Running 으로 전환된다. 정상 동작.

### 참고 — `test-server-*` 가 `ImagePullBackOff`

`registry.example.com/test-platform/test-server-*:0.1.0` 은 **예시 이미지** 로, 실제 레지스트리에 존재하지 않는다. 사용자가 실제 이미지를 빌드해서 내부 Registry 에 푸시해야 한다. 지금은 무시해도 된다.

---

## 23. 트러블슈팅 — `helm upgrade` 가 `has no deployed releases` 로 실패

### 현상

bootstrap Phase 7 (VSO Helm) 에서:

```
Error: UPGRADE FAILED: "vault-secrets-operator" has no deployed releases
```

### 원인

이전 `helm upgrade --install` 시도가 `--atomic` 때문에 rollback 되며 릴리즈가 `failed` 또는 `uninstalled` 상태로 남음. Helm 이 metadata 는 보존하는데 실제 배포물은 없는 상태. 이 상태에선 `upgrade --install` 이 **upgrade 로 분기하려다 "deployed release 없음" 으로 실패**.

### 해결

`tasks/vso-install.sh` 는 이제 실행 시 릴리즈 상태를 먼저 검사해서 `failed`/`pending*`/`uninstalling`/`uninstalled` 면 **자동으로 `helm uninstall`** 을 먼저 수행한다. 또한 `--atomic` 플래그를 제거했다 (실패 시 재실행으로 복구가 더 안전).

구버전 스크립트로 이미 이 상태에 빠졌다면 수동 정리:

```bash
helm -n mnt uninstall vault-secrets-operator
# (Error: uninstall: Release not loaded: ... 이 떠도 무시)

bash k8s/scripts/bin/bootstrap.sh dev
# Phase 7 부터 깔끔하게 재개됨
```
