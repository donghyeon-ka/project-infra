# Project-Infra 운영 가이드

아키텍처 · 폴더 구조 · 설계 결정은 [README.md](README.md) 를 먼저 읽는다. 본 문서는 실제 배포·운영 절차에 집중한다.

---

## 목차

1. [사전 준비](#1-사전-준비)
2. [최초 부트스트랩 — 자동](#2-최초-부트스트랩--자동)
3. [최초 부트스트랩 — 수동 (단계별)](#3-최초-부트스트랩--수동-단계별)
4. [Vault 시크릿 관리](#4-vault-시크릿-관리)
5. [Docker Registry 사용법](#5-docker-registry-사용법)
6. [앱에서 시크릿 사용하기](#6-앱에서-시크릿-사용하기)
7. [마이그레이션 실행 (Flyway)](#7-마이그레이션-실행-flyway)
8. [Vault UI 접근](#8-vault-ui-접근)
9. [환경별 배포](#9-환경별-배포)
10. [검증 / 린트 / 스키마 체크](#10-검증--린트--스키마-체크)
11. [정리 / 롤백 (teardown)](#11-정리--롤백-teardown)
12. [트러블슈팅](#12-트러블슈팅)

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

### 필요한 환경 변수 (자동 부트스트랩 시)

| 변수 | 의미 |
|---|---|
| `VAULT_PUSH_PASSWORD` | Docker Registry `push-user` 계정 비밀번호 |
| `VAULT_PULL_PASSWORD` | Docker Registry `pull-user` 계정 비밀번호 |
| `CONFIRM=yes` | (teardown 전용) 대화형 확인 자동 yes 처리 |

비대화 모드에서 `VAULT_PUSH_PASSWORD` / `VAULT_PULL_PASSWORD` 가 없으면 부트스트랩이 중단된다. 대화형 TTY 에서는 직접 입력 프롬프트가 뜬다.

### 클러스터 전제

- Kubernetes 1.25+ (Pod Security Admission 사용)
- `local-path` StorageClass (K3s 기본) 또는 동등한 RWO 프로비저너
- `kubernetes.io/metadata.name` namespace 라벨이 자동으로 붙는 1.22+ 환경

---

## 2. 최초 부트스트랩 — 자동

```bash
VAULT_PUSH_PASSWORD='<push용 비밀번호>' \
VAULT_PULL_PASSWORD='<pull용 비밀번호>' \
bash k8s/scripts/bin/bootstrap.sh dev
```

`bin/bootstrap.sh` 가 6 단계를 순서대로 실행한다:

| 단계 | 내용 |
|---|---|
| [1/6] 인프라 리소스 배포 | `kubectl apply -k k8s/overlays/dev/` (namespace + vault + registry + 앱 워크로드) |
| [2/6] vault-0 Ready 대기 | `kubectl wait ...` 최대 3 × 120s 재시도 |
| [3/6] Vault 초기화 | `tasks/vault-init.sh` — init / unseal / k8s auth / KV v2 / policy / role |
| [4/6] Registry 시크릿 seed | `tasks/vault-seed-registry.sh` — htpasswd 생성 → Vault KV 저장 |
| [5/6] VSO Helm | `tasks/vso-install.sh` — `helm upgrade --install --wait --atomic` |
| [6/6] VSO CRDs | `kubectl apply -k k8s/overlays/dev/vso/` |

스크립트는 idempotent 다. 이미 진행된 단계는 자동 스킵된다.

### 생성되는 파일

- `vault-init-keys.json` — **unseal keys (5 개) + root token**. 권한 0600 으로 저장. **반드시 오프라인 금고 / 외부 KMS 로 이동**하고 원본은 삭제한다. `.gitignore` 에 등록되어 있으나 실수로도 커밋하지 말 것.

### 완료 확인

```bash
kubectl -n mnt get pods
kubectl -n mnt get secrets | grep -E 'docker-registry-htpasswd|registry-pull-credential|keycloak-db|auth-server-db|minio-tenant-env'
kubectl -n mnt get vaultstaticsecret
```

---

## 3. 최초 부트스트랩 — 수동 (단계별)

자동 스크립트가 중간에 실패했을 때, 또는 학습 목적으로 단계별 진행이 필요할 때.

### 3-1. 인프라 배포

```bash
kubectl apply -k k8s/overlays/dev/
```

`mnt` namespace 와 Vault / Registry / 앱 워크로드가 선언된다. **Registry Pod 는 `docker-registry-htpasswd` Secret 이 생기기 전까지 `ContainerCreating` 상태로 대기하는 것이 정상**이다. Secret 은 VSO 가 생성하므로 5~6 단계 이후에 생성된다.

### 3-2. Vault Pod Ready 대기

```bash
kubectl -n mnt wait --for=condition=Ready pod/vault-0 --timeout=120s
```

### 3-3. Vault 초기화

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
- `vault-secrets-operator` policy 생성 (항상 재적용)
- `vault-secrets-operator` role 생성 (항상 재적용)

### 3-4. Registry 시크릿 seed

```bash
REPO_ROOT="$(pwd)" \
VAULT_PUSH_PASSWORD='<push>' \
VAULT_PULL_PASSWORD='<pull>' \
bash k8s/scripts/tasks/vault-seed-registry.sh
```

- htpasswd 는 `httpd:2.4-alpine` 임시 Pod 에서 생성 (로컬 Docker 데몬 불필요)
- Vault KV 에 `secret/docker-registry/auth` (htpasswd 전체 파일) + `secret/docker-registry/pull-credentials` (username/password) 저장
- 비밀번호는 argv / stdout 에 절대 노출되지 않음

### 3-5. VSO Helm 설치

```bash
REPO_ROOT="$(pwd)" bash k8s/scripts/tasks/vso-install.sh
```

`helm upgrade --install --wait --atomic --timeout 5m` 으로 실행. 실패 시 자동 롤백. `--values` 는 `k8s/base/plugins/vso/helm/values.yaml` 사용.

### 3-6. VSO CRDs 적용

```bash
kubectl apply -k k8s/overlays/dev/vso/
```

`VaultConnection` / `VaultAuth` / `VaultStaticSecret` 이 적용되면 VSO Operator 가 Vault KV 를 읽어 K8s Secret 을 생성한다. `docker-registry-htpasswd` 가 만들어지면 Registry Pod 가 `ContainerCreating` → `Running` 으로 전환된다.

---

## 4. Vault 시크릿 관리

### 애플리케이션 시크릿 저장

현재 dev overlay 의 VaultStaticSecret 들은 아래 Vault 경로에 실제 값이 저장되어 있다고 전제한다. 부트스트랩 직후에는 비어 있으므로 관리자가 한 번 채워야 한다.

```bash
# port-forward 로 vault CLI 사용 (개발 편의)
kubectl -n mnt port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token vault-init-keys.json)"

# Postgres superuser
vault kv put secret/identity-postgres/superuser \
  username=postgres \
  password='<강한-비밀번호>'

# Keycloak DB
vault kv put secret/keycloak/db password='<pw>'

# Auth-server DB
vault kv put secret/auth-server/db \
  SPRING_DATASOURCE_USERNAME=auth_server \
  SPRING_DATASOURCE_PASSWORD='<pw>'

# Keycloak bootstrap admin
vault kv put secret/keycloak/bootstrap-admin \
  KEYCLOAK_ADMIN=admin \
  KEYCLOAK_ADMIN_PASSWORD='<pw>'

# MinIO root creds
vault kv put secret/minio/tenant-env \
  config.env='export MINIO_ROOT_USER="admin"
export MINIO_ROOT_PASSWORD="<pw>"'
```

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

## 5. Docker Registry 사용법

### Push

```bash
docker login docker-registry.mnt.svc.cluster.local:5000
# username: push-user
# password: <VAULT_PUSH_PASSWORD 로 저장한 값>

docker tag my-app:0.1.0 docker-registry.mnt.svc.cluster.local:5000/my-app:0.1.0
docker push docker-registry.mnt.svc.cluster.local:5000/my-app:0.1.0
```

클러스터 외부에서 push 하려면 별도 Ingress + TLS + NodePort 구성이 필요하다 (현재 Registry 는 ClusterIP 만).

### Pull (Pod)

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      imagePullSecrets:
        - name: registry-pull-credential
      containers:
        - name: my-app
          image: docker-registry.mnt.svc.cluster.local:5000/my-app:0.1.0
```

`registry-pull-credential` 은 VSO 가 `secret/docker-registry/pull-credentials` 로부터 `kubernetes.io/dockerconfigjson` 타입으로 합성한 Secret 이다. `.auth` 필드는 `base64("<username>:<password>")` 로 올바르게 인코딩된다.

---

## 6. 앱에서 시크릿 사용하기

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

## 7. 마이그레이션 실행 (Flyway)

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

## 8. Vault UI 접근

`service-ui` NodePort 는 보안상 제거되었다. 관리자는 port-forward 로만 접근한다.

```bash
kubectl -n mnt port-forward svc/vault 8200:8200
# 브라우저에서 http://127.0.0.1:8200/ui
# Token 입력: $(jq -r .root_token vault-init-keys.json)
```

root token 은 최초 설정 / 비상 복구 외에는 사용하지 않는다. 평시 접근은 개인 AppRole 또는 OIDC auth 로 분리하는 것을 권장.

---

## 9. 환경별 배포

현재 `dev` 만 구성되어 있다.

```bash
VAULT_PUSH_PASSWORD=... VAULT_PULL_PASSWORD=... \
  bash k8s/scripts/bin/bootstrap.sh dev
```

staging / prod overlay 는 비어 있으며, 추후 다음 요소를 추가한다:
- Vault storage `file` → `raft` 전환
- Postgres backup CronJob
- cert-manager ClusterIssuer + Certificate
- 환경별 hostname (Keycloak / 공개 Ingress)
- `persistentVolumeClaimRetentionPolicy` 를 prod 는 `Retain` 유지 (dev 는 overlay 에서 `Delete` 로 patch)

---

## 10. 검증 / 린트 / 스키마 체크

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

## 11. 정리 / 롤백 (teardown)

```bash
# 대화형 (y/N 확인)
bash k8s/scripts/bin/teardown.sh dev

# 비대화 (CI)
CONFIRM=yes bash k8s/scripts/bin/teardown.sh dev
```

5 단계:

| 단계 | 내용 |
|---|---|
| [1/5] | VSO CRDs 삭제 (`kubectl delete -k overlays/dev/vso/`) |
| [2/5] | VSO Helm uninstall |
| [3/5] | 인프라 리소스 삭제 (`kubectl delete -k overlays/dev/`) |
| [4/5] | 남은 PVC 모두 삭제 (`mnt` namespace) |
| [5/5] | `vault-tokenreview-binding` ClusterRoleBinding 삭제 |

teardown 후에도 `vault-init-keys.json` 은 보존된다. 완전 초기화하려면 수동으로 삭제한다.

---

## 12. 트러블슈팅

### Registry Pod 가 계속 `ContainerCreating`

Secret `docker-registry-htpasswd` 가 아직 생성되지 않은 상태. VSO 가 Vault KV 를 읽어서 만든다.

```bash
kubectl -n mnt describe vaultstaticsecret docker-registry-htpasswd
kubectl -n mnt logs -l app.kubernetes.io/name=vault-secrets-operator --tail=100
```

자주 보는 에러:
- `permission denied` → Vault policy 또는 role 설정 오류. `tasks/vault-init.sh` 재실행.
- `no matching vault path` → Vault KV 에 값이 저장되지 않음. `tasks/vault-seed-registry.sh` 재실행.

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
VAULT_PUSH_PASSWORD=... VAULT_PULL_PASSWORD=... \
  bash k8s/scripts/bin/bootstrap.sh dev
```

각 단계가 idempotent 이므로 그대로 다시 실행해도 된다. 이미 완료된 단계는 스킵된다.

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

## 13. etcd encryption at rest

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

## 14. Vault 운영자 토큰 관리

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
