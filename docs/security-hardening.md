# Security Hardening

운영 절차가 아닌 **정책 / 거버넌스** 영역. guide.md 가 *"오늘 oncall 이 따라할 절차"* 라면 이 문서는 *"이 클러스터를 책임진다면 알아야 할 보안 결정"* 이다.

## 목차

1. [etcd encryption at rest](#1-etcd-encryption-at-rest)
2. [Vault 운영자 토큰 관리](#2-vault-운영자-토큰-관리)
3. [bash history 에 비밀번호 남기지 않기](#3-bash-history-에-비밀번호-남기지-않기)

---

## 1. etcd encryption at rest

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

`aescbc` 대신 KMS plugin (Vault transit / AWS KMS / GCP KMS) 사용. circular dependency (Vault 도 K8s Secret 에 의존) 회피를 위해 Vault transit 은 **별도 provider Vault** 를 띄워야 한다. 현 프로젝트는 단일 Vault 이므로 KMS 는 추후 작업.

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

## 2. Vault 운영자 토큰 관리

root token 은 **비상시 (rekey / generate-root / 전체 복구) 전용**으로만 사용한다. 평시 작업은 개인별 계정 + `vault-admin` policy 로 수행한다.

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

1. **즉시 오프라인 금고 (1Password Team / 하드웨어 보안 금고 / 봉인 봉투) 로 이동**
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

## 3. bash history 에 비밀번호 남기지 않기

`VAR=value command` 형태로 env var 를 명령줄에 직접 적으면 **그대로 `~/.bash_history` 에 저장** 된다. 대응:

### 권장 — 대화형 입력

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
POSTGRES_SUPERUSER_PASSWORD='...' \
KEYCLOAK_DB_PASSWORD='...' \
AUTH_SERVER_DB_PASSWORD='...' \
KEYCLOAK_ADMIN_PASSWORD='...' \
MINIO_ROOT_PASSWORD='...' \
bash k8s/scripts/bin/bootstrap.sh dev

# 또는 세션 전체 history 비활성화
set +o history
POSTGRES_SUPERUSER_PASSWORD='...' bash ...
set -o history
```

> **Tip**: `HISTCONTROL=ignorespace` 가 설정된 쉘이면 **명령 앞에 공백 1 칸** 넣어도 저장되지 않는다. 다만 쉘마다 설정이 다르니 `HISTFILE=/dev/null` 이 가장 확실.
