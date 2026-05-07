# 운영 중 만난 함정 8건 — 사건 카탈로그

K3s 기반 로컬 클러스터에서 Project-Infra 를 부트스트랩 / 운영하면서 실제로 만났던 사건들의 narrative 정리.
운영자 절차서 톤은 [`guide.md`](../guide.md) 의 15장 (`15.1` ~ `15.11`) 에 있고, 이 문서는 사건 단위로 "무엇을 보고 / 왜 그랬고 / 어떻게 풀었는지" 를 짧게 쓰기 위한 자료다.

| # | 사건 | guide.md cross-ref |
|---|---|---|
| 1 | Registry image pull 실패 (`ImagePullBackOff`) | (별건 — guide.md 15.1 은 ContainerCreating 사건) |
| 2 | `vault-0` 가 `0/1 Running` 에서 멈춤 | [15.10](../guide.md#1510-vault-0-이-01-running-에서-멈춤) |
| 3 | `helm upgrade` 가 `has no deployed releases` 로 실패 | [15.11](../guide.md#1511-helm-upgrade-가-has-no-deployed-releases-로-실패) |
| 4 | VSO 가 기존 K8s Secret 을 덮어쓰지 않음 | [15.8](../guide.md#158-기존-k8s-secret-이-남아있을-때) |
| 5 | ForwardAuth 로그인 E2E 검증 실패 | (현장 검증 사건) |
| 6 | namespace 가 `Terminating` 에 걸림 | [15.9](../guide.md#159-namespace-가-terminating-에-걸림) |
| 7 | PodSecurity 위반 경고 (admission) | [15.7](../guide.md#157-podsecurity-위반-경고) |
| 8 | VSO 가 Vault 로그인 실패 | [15.2](../guide.md#152-vso-가-vault-에-로그인-실패) |

---

## 1. Registry image pull 실패 (`ImagePullBackOff`)

### 한 줄 요약

사설 registry 도메인(`registry.project.com`) 이 클러스터 노드의 호스트 OS DNS 에 등록되지 않아, 노드의 containerd 가 image pull 단계에서 도메인을 해석하지 못하고 모든 Pod 이 `ImagePullBackOff` 로 멈췄다.

### 배경

- 클러스터 안에 사설 OCI registry (MinIO + 도메인 `registry.project.com`) 를 띄우고, 다른 앱이 그 registry 의 이미지를 pull 하도록 구성.
- 도메인은 K8s service DNS 에는 보이지만 클러스터 외부 DNS / 호스트 OS DNS 에는 없음.

### 증상

```
Failed to pull image "registry.project.com/...": rpc error: code = Unknown
desc = failed to resolve reference: failed to do request: ... no such host
```

`kubectl describe pod` 의 Events 에 `ErrImagePull` → `ImagePullBackOff`. Pod 자체는 스케줄링 됐지만 컨테이너가 시작되지 못함.

### Root Cause

K8s 의 service DNS (CoreDNS) 와 **노드의 image pull 경로는 분리되어 있다**.

- Pod 이 런타임에 `registry.project.com` 으로 HTTP 호출 → CoreDNS 가 해석 (✅ 동작함)
- 노드의 **containerd 가 image pull** → 호스트 OS 의 `/etc/resolv.conf` 만 본다 (CoreDNS 안 봄)

따라서 호스트 OS 에서 `registry.project.com` 을 해석하지 못하면, 클러스터 안에 service / endpoint 가 정상이어도 image pull 은 실패한다.

### 해결

K3s 가 사용하는 containerd 에 mirror 또는 host 매핑을 직접 알려준다.

**A. registries.yaml mirror (권장)**

```yaml
# /etc/rancher/k3s/registries.yaml (각 노드)
mirrors:
  registry.project.com:
    endpoint:
      - "https://<클러스터 내부 ingress 주소>"
configs:
  registry.project.com:
    tls:
      insecure_skip_verify: true   # 사설 인증서일 경우
```

설정 후 `systemctl restart k3s`.

**B. 임시 우회 — `/etc/hosts`**

```
<ingress IP>  registry.project.com
```

### 검증

노드에서 직접:

```bash
sudo crictl pull registry.project.com/<image>:<tag>
```

성공하면 Pod 의 `ImagePullBackOff` 도 자동으로 회복된다 (`kubelet` 의 backoff retry).

### 교훈

- **K8s service DNS 가 보인다고 image pull 도 된다고 가정하지 말 것.** image pull 은 노드의 컨테이너 런타임이 직접 수행하고, 호스트 OS 의 resolver 를 따른다.
- 사설 registry 를 클러스터 안에 두면 **bootstrap 순서 의존성** 이 생긴다 (registry 가 떠야 다른 이미지 pull 가능). 이 의존성은 mirror config / hosts 매핑으로만 풀린다.

---

## 2. `vault-0` 가 `0/1 Running` 에서 멈춤

### 한 줄 요약

Vault Pod 의 readiness probe 는 `vault status` 가 `sealed: false` 여야만 통과한다. 처음 띄운 Vault 는 `sealed/uninitialized` 상태이므로 의도적으로 `0/1` 로 멈추고, 운영자가 init + unseal 을 명시적으로 해야 Ready 가 된다.

### 배경

- Vault Helm chart 의 기본 readiness probe 는 `vault status` 의 health 코드 기반.
- Sealed Vault 가 트래픽을 받으면 안 되므로, **Sealed = NotReady 가 정상**.

### 증상

```
NAME      READY   STATUS    RESTARTS   AGE
vault-0   0/1     Running   0          5m
```

`kubectl logs vault-0` 에는 에러 없음. `kubectl exec -it vault-0 -- vault status` 하면 `Initialized: false` 또는 `Sealed: true`.

### Root Cause

- Vault 는 첫 기동 시 자동으로 init / unseal 되지 않는다 — unseal key 를 누가 / 어떻게 보관할지가 운영 정책 영역이기 때문.
- 따라서 첫 부트스트랩에는 반드시 운영자 / 자동화 스크립트의 init 절차가 필요하다.

### 해결

```bash
REPO_ROOT="$(pwd)" ENV_NAME=dev bash k8s/scripts/tasks/vault-init.sh
```

이 스크립트는 idempotent — 다음을 차례로 처리한다.

1. `vault operator init` (이미 init 됐으면 skip)
2. unseal keys 를 사용해 unseal
3. `kubernetes` auth method enable + `kubernetes_ca_cert` + `token_reviewer_jwt` 설정
4. policy / role 등록

unseal 이 끝나면 readiness probe 가 통과하고 Pod 이 `1/1 Ready` 로 전환된다.

### 검증

```bash
kubectl get pod -n mnt vault-0
# vault-0   1/1   Running

kubectl exec -n mnt vault-0 -- vault status
# Sealed: false
```

### 교훈

- Pod 이 `Running` 인데 `0/1` 일 때, 무한 대기하지 말고 readiness probe 의 의미부터 본다 — 많은 경우 **의도된 NotReady** 다.
- Vault 같이 운영자 수동 절차가 필요한 컴포넌트는, 이 절차를 스크립트로 idempotent 하게 묶어두는 게 부트스트랩 / 재부팅 / DR 복구를 단순하게 만든다.

---

## 3. `helm upgrade` 가 `has no deployed releases` 로 실패

### 한 줄 요약

이전 `helm upgrade --install` 시도가 `--atomic` 으로 인해 자동 rollback 되면서 release 가 `failed` / `uninstalled` 상태로만 남았고, 다음 호출이 `upgrade` 분기로 진입하려다 deployed release 가 없어 실패했다.

### 증상

```
Error: UPGRADE FAILED: "vault-secrets-operator" has no deployed releases
```

`helm list -A` 로는 release 가 보이지 않거나 `STATUS=failed` / `uninstalled` 로 보임.

### Root Cause

- `helm upgrade --install` 은 release metadata 가 있으면 upgrade 분기로 간다.
- `--atomic` 은 설치 실패 시 자동 rollback. rollback 결과로 metadata 는 남고 실제 배포물은 없는 상태가 되면 다음 `--install` 도 "이미 release 가 있다고 판단 → upgrade → deployed release 없음 → 실패" 로 간다.
- 즉 `--atomic` + 실패 케이스가 쌓이면 멱등성이 무너진다.

### 해결

`tasks/vso-install.sh` 에서 두 가지를 바꿈.

1. **release status 선검사 + 자동 uninstall**

   ```bash
   status=$(helm -n vault-secrets-operator-system status vault-secrets-operator -o json | jq -r '.info.status')
   case "$status" in
     failed|pending-*|uninstalling|uninstalled)
       helm -n vault-secrets-operator-system uninstall vault-secrets-operator || true
       ;;
   esac
   ```

2. **`--atomic` 제거** — 실패 시 자동 rollback 보다 다음 실행에서 cleanup + 재시도가 더 안전.

### 검증

```bash
helm list -n vault-secrets-operator-system
# vault-secrets-operator   ...   STATUS=deployed
```

### 교훈

- `helm --atomic` 은 단발성 install 에는 좋지만, 부트스트랩 스크립트에서 **반복 실행으로 복구되어야 하는** 경로에는 안 어울린다.
- install/upgrade 스크립트에선 항상 **현재 상태를 먼저 검사하고, 망가진 상태면 cleanup 후 재시작** 하는 패턴이 더 견고하다.

---

## 4. VSO 가 기존 K8s Secret 을 덮어쓰지 않음

### 한 줄 요약

Vault KV 에 새 값을 넣었는데 K8s Secret 은 옛날 값을 유지. `VaultStaticSecret` 의 `destination.overwrite` 기본값(`false`) 때문에, **이미 존재하는 Secret 을 보면 VSO 가 손대지 않는** 안전한 default 가 자동화와 충돌한 사건.

### 증상

- Vault KV 의 값을 갱신해도 `kubectl get secret -o yaml` 의 `data` 가 안 바뀜.
- Pod 재시작해도 새 값 반영 안 됨.

### Root Cause

- VSO 는 소유권 경합 방지 목적으로 `destination.overwrite: false` 가 기본.
- 이 기본은 "운영자가 수동으로 만든 Secret 을 VSO 가 무단 덮어쓰지 않는다" 는 안전 장치 — 단, 처음 부트스트랩 전에 stale Secret 이 남아 있으면 그것도 덮어쓰지 않음.

### 해결

bootstrap 스크립트에 명시적 opt-in 환경변수를 둠.

```bash
RESET_STALE_SECRETS=yes bash k8s/scripts/bin/bootstrap.sh dev
```

이 옵션이 있을 때만 VSO-managed K8s Secret 후보들을 선제 삭제 → VSO 가 새로 생성.

수동 우회:

```bash
kubectl delete secret <name> -n <ns>
# VSO reconcile (수 초~수십 초) 대기
```

### 검증

```bash
kubectl get secret <name> -n <ns> -o yaml
# data: 새 값
# metadata.ownerReferences: VaultStaticSecret 으로 설정됨
```

### 교훈

- 안전한 default (`overwrite: false`) 는 자동화 / 운영 흐름과 자주 충돌한다. 깨려면 **명시적 opt-in 플래그** 로 깨야지, default 를 무작정 바꾸면 운영자 수동 자산이 날아간다.
- bootstrap 스크립트의 파괴적 옵션은 환경변수 이름에 의도가 드러나야 한다 (`RESET_STALE_SECRETS=yes` 처럼).

---

## 5. ForwardAuth 로그인 E2E 검증 실패

### 한 줄 요약

oauth2-proxy / Keycloak / Traefik / auth-server 사이의 설정이 각각 조금씩 어긋나 있어, "로그인 화면은 뜨는가" 와 "로그인 후 API 가 인증된 요청으로 통과하는가" 가 단계별로 실패했다. 문제는 하나가 아니라 Traefik CRD 누락, TLS Secret 부재, Keycloak client secret 불일치, oauth2-proxy Authorization header 미전달, auth-server issuer 설정 미반영이 연쇄적으로 겹친 사건이었다.

### 배경

목표 흐름은 다음과 같다.

```text
Browser
  -> https://project.com/*
  -> Traefik Ingress
  -> oauth2-proxy ForwardAuth (/oauth2/auth)
  -> Keycloak OIDC login
  -> oauth2-proxy callback (/oauth2/callback)
  -> auth-server
```

Boundary 기준으로 나누면 다음과 같다.

| Boundary | 정상 신호 | 실패 신호 |
|---|---|---|
| Browser local DNS/TLS | Chrome 이 `project.com` 을 Traefik IP 로 열고 self-signed 인증서를 통과 | public DNS 로 빠짐, `ERR_CERT_*`, HSTS/인증서 경고에서 진행 불가 |
| Traefik routing/TLS | host rule 이 잡히고 TLS Secret 으로 handshake 성공 | Traefik `404`, `unknown TLS options`, `secret ... does not exist`, SNI 실패 |
| Traefik ForwardAuth | 미인증 요청이 oauth2-proxy `/oauth2/auth` 로 위임 | backend 로 바로 감, 또는 항상 `Unauthorized` |
| Traefik error redirect | 미인증 요청이 `302 Location: keycloak...` 로 변환 | `Location` 은 있는데 status 가 `401` 이라 브라우저가 이동하지 않음 |
| oauth2-proxy -> Keycloak authorize | Keycloak 로그인 화면 `200` | authorize URL 생성 실패, 잘못된 redirect URI |
| Keycloak -> oauth2-proxy callback/token | callback 후 oauth2-proxy session cookie 발급 | `unauthorized_client`, invalid client credentials |
| oauth2-proxy -> auth-server header | `/oauth2/auth` 가 `Authorization: Bearer ...` 반환 | auth-server 가 `anonymous` 로 처리 |
| auth-server JWT validation | issuer/JWK 검증 통과 후 application response 반환 | issuer mismatch, JWK 조회 실패, `401` |
| auth-server application route | 실제 API/화면 응답 | 인증은 통과했지만 route 없음, 예: `404 PRES-005` |

dev 환경에서는 실제 공인 DNS / ACME 인증서가 아직 준비되지 않았다. 그래서 CLI 검증은 아래처럼 DNS 와 TLS 검증을 임시 우회했다.

```bash
curl -k \
  --resolve project.com:443:10.208.141.123 \
  --resolve keycloak.dev.example.com:443:10.208.141.123 \
  https://project.com/oauth2/start?rd=https://project.com/api/me
```

브라우저는 `curl --resolve` 와 `-k` 를 쓸 수 없으므로, 직접 웹사이트로 검증하려면 로컬 `/etc/hosts` 와 self-signed 인증서 예외가 필요하다.

```text
10.208.141.123  project.com
10.208.141.123  keycloak.dev.example.com
```

### 증상 1: Ingress 가 404 또는 TLS handshake 실패

Boundary: `Traefik routing/TLS`

처음에는 `https://project.com/api/me` 가 Traefik 기본 `404 page not found` 를 반환했고, Keycloak discovery 도 TLS 단계에서 실패했다.

대표 증상:

```text
HTTP/2 404
404 page not found

curl: (35) OpenSSL: tlsv1 unrecognized name
```

### Root Cause 1

`auth-server`, `oauth2-proxy`, `keycloak-public` Ingress 는 모두 아래 annotation 을 참조하고 있었다.

```text
traefik.ingress.kubernetes.io/router.tls.options: kube-system-modern-tls@kubernetescrd
traefik.ingress.kubernetes.io/router.middlewares: kube-system-https-redirect@kubernetescrd,...
```

하지만 live cluster 에는 `modern-tls`, `https-redirect`, `security-headers` 가 없었다. Traefik 로그에는 다음 오류가 반복됐다.

```text
unknown TLS options: kube-system-modern-tls@kubernetescrd
```

결과적으로 Traefik 가 해당 router 를 정상 구성하지 못했고, host/path 가 맞아도 요청이 backend 로 가지 않았다.

### 해결 1

Traefik packaged manifest 를 직접 수정하지 않고, Git source-of-truth 인 overlay 를 적용했다.

```bash
kubectl apply -k k8s/overlays/dev/platform/traefik
```

적용된 리소스:

- `HelmChartConfig/traefik`
- `Middleware/https-redirect`
- `Middleware/security-headers`
- `TLSOption/modern-tls`

검증:

```bash
kubectl -n kube-system get tlsoption,middleware
kubectl -n kube-system logs deploy/traefik --tail=200
```

### 증상 2: TLS Secret 이 없어 HTTPS 라우팅이 SNI 에서 실패

Boundary: `Traefik routing/TLS` 와 `cert-manager -> Traefik TLS Secret`

Traefik CRD 를 적용한 뒤에도 HTTPS 요청은 `tlsv1 unrecognized name` 으로 실패했다. Traefik 로그에는 아래 메시지가 있었다.

```text
Error configuring TLS: secret mnt/project-com-tls does not exist
Error configuring TLS: secret mnt/keycloak-dev-example-com-tls does not exist
```

### Root Cause 2

dev `Certificate` 리소스가 `letsencrypt-staging` 을 참조하고 있었다. 하지만 현재 dev 도메인(`project.com`, `keycloak.dev.example.com`) 은 외부 공인 DNS 가 Traefik 진입점으로 향하지 않는다. ACME HTTP-01 은 public DNS 와 80/443 도달성이 필요하므로 인증서 발급이 완료될 수 없었다.

또한 `TLSOption` 의 `sniStrict: true` 때문에 TLS Secret 이 없는 host 는 handshake 단계에서 차단됐다. 보안상 의도한 동작이지만, dev 검증에는 별도 인증서가 필요했다.

### 해결 2

dev 전용 `ClusterIssuer/dev-selfsigned` 를 추가하고, dev TLS `Certificate` 들이 이를 참조하도록 바꿨다.

변경 파일:

- `k8s/overlays/dev/platform/cert-manager-issuers/dev-selfsigned-clusterissuer.yaml`
- `k8s/overlays/dev/platform/cert-manager-issuers/kustomization.yaml`
- `k8s/overlays/dev/tls/project-com-certificate.yaml`
- `k8s/overlays/dev/tls/keycloak-dev-certificate.yaml`
- `k8s/overlays/dev/tls/registry-project-com-certificate.yaml`

적용:

```bash
kubectl apply -k k8s/overlays/dev/platform/cert-manager-issuers
kubectl apply -k k8s/overlays/dev/tls
kubectl -n mnt wait --for=condition=Ready certificate/project-com --timeout=120s
kubectl -n mnt wait --for=condition=Ready certificate/keycloak-dev-example-com --timeout=120s
```

검증 결과 Keycloak discovery 가 HTTPS 로 `200` 을 반환했다.

```text
GET https://keycloak.dev.example.com/realms/platform/.well-known/openid-configuration
HTTP/2 200
issuer: https://keycloak.dev.example.com/realms/platform
```

### 증상 3: 로그인 화면은 뜨지만 callback 에서 500

Boundary: `Keycloak -> oauth2-proxy callback/token`

`/oauth2/start` 는 Keycloak authorize URL 로 `302` 되고, Keycloak 로그인 화면까지는 열렸다. 하지만 로그인 후 `/oauth2/callback` 에서 oauth2-proxy 가 `500 Internal Server Error` 를 반환했다.

oauth2-proxy 로그:

```text
Error redeeming code during OAuth2 callback:
token exchange failed: oauth2: "unauthorized_client" "Invalid client or Invalid client credentials"
```

### Root Cause 3

Vault / K8s Secret 의 `auth-server-ingress` client secret 과 Keycloak live realm 의 client secret 이 달랐다.

이유:

- Vault seed 스크립트가 `keycloak/clients/auth-server-ingress` 와 `oauth2-proxy/forward-auth` secret 을 생성했다.
- oauth2-proxy 는 VSO 가 만든 최신 K8s Secret 을 읽었다.
- 하지만 이미 import 된 Keycloak realm/client 는 새 secret 으로 다시 동기화되지 않았다.
- `KeycloakRealmImport` 는 source 에서 secret placeholder 를 보도록 수정했지만, 기존 import 결과가 자동으로 다시 적용되지 않았다.

비교는 값을 출력하지 않고 hash 로 했다.

```text
k8s_client_secret_sha == oauth2_secret_sha
keycloak_client_sha   != oauth2_secret_sha
```

### 해결 3

Keycloak admin API 를 내부 port-forward 로만 열고, `auth-server-ingress` client representation 의 `secret` 을 K8s Secret 값과 동기화했다.

```bash
kubectl -n mnt port-forward svc/keycloak 18080:80
```

그 뒤 admin token 으로 client 를 조회하고 `PUT /admin/realms/platform/clients/{id}` 로 secret 을 반영했다. 반영 후 hash 가 일치했다.

```text
desired_sha  == keycloak_sha
update_status=204
```

주의: Keycloak public ingress 는 의도적으로 `/admin/` 을 노출하지 않는다. admin API 작업은 port-forward, VPN, 또는 내부 운영 경로로만 수행한다.

### 증상 4: 미인증 요청이 Keycloak 으로 자동 이동하지 않음

Boundary: `Traefik ForwardAuth` 와 `Traefik error redirect`

미인증 상태에서 `https://project.com/` 또는 `https://project.com/api/me` 를 열면 oauth2-proxy 의 로그인 시작 응답이 본문에는 보였지만, HTTP status 는 여전히 `401` 이었다. 이 경우 브라우저는 `Location` header 가 있어도 자동으로 따라가지 않는다.

대표 응답:

```text
HTTP/2 401
location: https://keycloak.dev.example.com/realms/platform/protocol/openid-connect/auth?...

<a href="https://keycloak.dev.example.com/...">Found</a>.
```

### Root Cause 4

Traefik `errors` middleware 는 `/oauth2/start?rd={url}` 를 내부 호출해 응답 body/header 를 가져오지만, 기본 동작만으로는 원래 오류 status 를 유지할 수 있다. 그 결과 oauth2-proxy 가 `302 Location` 을 만들었더라도 최종 클라이언트 응답이 `401` 로 남아 브라우저 redirect 가 일어나지 않았다.

또한 errors middleware 가 forwardAuth 의 `401` 을 감싸려면 middleware 순서가 중요하다. `oauth2-proxy-errors` 가 `oauth2-proxy-auth` 앞에 있어야 forwardAuth 실패 응답을 로그인 시작 응답으로 바꿀 수 있다.

### 해결 4

`oauth2-proxy-errors` 에 `statusRewrites` 를 추가하고, auth-server Ingress middleware 순서를 조정했다.

```yaml
spec:
  errors:
    status:
      - "401-403"
    statusRewrites:
      "401": 302
      "403": 302
    service:
      name: oauth2-proxy
      port: 4180
    query: /oauth2/start?rd={url}
```

auth-server Ingress 순서:

```text
kube-system-https-redirect@kubernetescrd,
mnt-oauth2-proxy-errors@kubernetescrd,
mnt-oauth2-proxy-auth@kubernetescrd,
kube-system-security-headers@kubernetescrd
```

검증:

```bash
curl -k -D - \
  --resolve project.com:443:10.208.141.123 \
  https://project.com/
```

정상 응답:

```text
HTTP/2 302
location: https://keycloak.dev.example.com/realms/platform/protocol/openid-connect/auth?...
```

### 증상 5: callback 은 성공하지만 auth-server 가 계속 401

Boundary: `oauth2-proxy -> auth-server header`

Keycloak client secret 을 맞춘 뒤 oauth2-proxy callback 은 성공했고, `_oauth2_proxy` 세션 쿠키도 발급됐다. oauth2-proxy 로그에도 인증 성공이 찍혔다.

```text
[AuthSuccess] Authenticated via OAuth2:
email:dev-login-check@project.local
groups:[role:platform-user ...]
```

하지만 `https://project.com/api/me` 는 계속 401 이었다. auth-server 로그는 사용자를 `anonymous` 로 보고 있었다.

```text
Authentication required. actorId=anonymous method=GET requestPath=/api/me
```

### Root Cause 5

oauth2-proxy 의 `/oauth2/auth` 는 `X-Auth-Request-Access-Token` 은 반환했지만 `Authorization: Bearer ...` 헤더를 반환하지 않았다. auth-server 는 Spring Security Resource Server 이므로 JWT 를 `Authorization` 헤더에서 읽는다. 따라서 ForwardAuth 는 통과해도 backend 는 anonymous 요청으로 처리했다.

### 해결 5

oauth2-proxy config 에 아래 설정을 추가했다.

```hcl
set_authorization_header = true
```

변경 파일:

- `k8s/components/forward-auth/oauth2-proxy-config.yaml`

반영 후 oauth2-proxy 를 재시작했다.

```bash
kubectl -n mnt rollout restart deployment/oauth2-proxy
kubectl -n mnt rollout status deployment/oauth2-proxy --timeout=180s
```

검증:

```bash
curl -k -D - \
  -b /tmp/oauth2-authenticated-cookies.txt \
  --resolve project.com:443:10.208.141.123 \
  https://project.com/oauth2/auth
```

응답에 `Authorization: Bearer ...` 와 `X-Auth-Request-Access-Token` 이 함께 나타나면 정상이다.

### 증상 6: Authorization 은 생겼지만 auth-server 가 issuer mismatch 로 실패

Boundary: `auth-server JWT validation`

Authorization 헤더가 생긴 뒤 auth-server 는 더 이상 단순 anonymous 만 보지 않았다. 대신 JWT decoder 초기화에서 issuer mismatch 를 냈다.

```text
The Issuer "https://keycloak.dev.example.com/realms/platform"
provided in the configuration did not match the requested issuer
"http://keycloak/realms/platform"
```

### Root Cause 6

auth-server 의 live Pod 가 예전 issuer 설정(`http://keycloak/realms/platform`) 을 들고 있었다. Git source 와 live ConfigMap 은 이미 외부 issuer 로 맞춰져 있었지만, Deployment 가 재시작되지 않아 Pod 환경변수에는 반영되지 않았다.

정상 설정:

```text
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI=https://keycloak.dev.example.com/realms/platform
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI=http://keycloak/realms/platform/protocol/openid-connect/certs
```

설계 의도는 issuer claim 검증은 외부 issuer 로 맞추고, JWK 조회는 클러스터 내부 Service 로 수행하는 것이다.

### 해결 6

auth-server Deployment 를 재시작했다.

```bash
kubectl -n mnt rollout restart deployment/auth-server
kubectl -n mnt rollout status deployment/auth-server --timeout=180s
```

### 최종 검증 결과

새 로그인 흐름으로 다음이 확인됐다.

1. `/oauth2/start` → Keycloak authorize URL `302`
2. Keycloak 로그인 화면 `200`
3. 로그인 폼 제출 → authorization code 발급
4. `/oauth2/callback` → oauth2-proxy session cookie 발급
5. oauth2-proxy `/oauth2/auth` → `202`
6. auth response header:
   - `Authorization: Bearer ...`
   - `X-Auth-Request-Access-Token`
   - `X-Auth-Request-Email`
   - `X-Auth-Request-User`
   - `X-Auth-Request-Preferred-Username`
7. 미인증 요청은 `302` 로 Keycloak 로그인 화면으로 이동
8. `/api/me` 요청은 ForwardAuth 를 통과해 auth-server 까지 도달

최종 `/api/me` 응답은 auth-server 의 애플리케이션 `404 PRES-005` 였다.

```json
{
  "success": false,
  "code": "PRES-005",
  "message": "요청한 리소스를 찾을 수 없습니다."
}
```

이는 ForwardAuth 실패가 아니라 auth-server 에 해당 route 가 없다는 의미다. 인증 계층 검증 관점에서는 `401` 이 사라지고 auth-server business response 가 나온 시점이 통과 기준이다.

### 브라우저로 직접 검증하는 방법

curl 로는 DNS 와 TLS 를 아래 옵션으로 우회한다.

```bash
curl -k \
  --resolve project.com:443:10.208.141.123 \
  --resolve keycloak.dev.example.com:443:10.208.141.123 \
  https://project.com/oauth2/start?rd=https://project.com/api/me
```

브라우저는 같은 우회를 옵션으로 줄 수 없으므로 로컬 머신에서 다음을 준비한다.

1. `/etc/hosts` 에 ingress IP 매핑:

   ```text
   10.208.141.123  project.com
   10.208.141.123  keycloak.dev.example.com
   ```

2. `https://project.com/oauth2/start?rd=https://project.com/api/me` 접속
3. dev self-signed 인증서 경고 허용 또는 인증서 trust 등록
4. Keycloak 로그인
5. callback 후 `project.com` 으로 돌아오는지 확인

### 교훈

- ForwardAuth E2E 는 하나의 설정만 맞아서는 동작하지 않는다. Traefik CRD, TLS Secret, oauth2-proxy secret, Keycloak client secret, redirect status, backend issuer/JWK 설정이 모두 같은 세계관이어야 한다.
- "로그인 화면이 뜬다" 는 검증의 중간 지점일 뿐이다. 반드시 callback, token exchange, session cookie, `/oauth2/auth 202`, backend 도달까지 나눠 봐야 한다.
- dev 에서 ACME 가 안 되는 상황은 정상일 수 있다. public DNS 가 없으면 `dev-selfsigned` 로 검증하고, staging/prod 에서 ACME issuer 로 전환한다.
- Keycloak client secret 은 Vault/K8s/oauth2-proxy/Keycloak live realm 네 곳이 한 값으로 수렴해야 한다.
- Spring Resource Server 는 issuer claim 을 엄격히 검증한다. 내부 Service URL 과 외부 issuer URL 을 섞을 때는 `issuer-uri` 와 `jwk-set-uri` 의 역할을 분리해야 한다.

---

## 6. namespace 가 `Terminating` 에 걸림

### 한 줄 요약

VSO controller 가 먼저 사라진 뒤 CRD finalizer / PVC protection finalizer / 일부 namespaced 리소스 finalizer 가 풀리지 못해 namespace 가 `Terminating` 에서 무한 대기. `teardown.sh` 가 finalizer 를 단계적으로 정리하고, 마지막 수단으로 `/finalize` API 를 직접 호출해 풀어준다.

### 증상

```
NAME    STATUS        AGE
mnt     Terminating   3h
```

`kubectl get all,pvc,vaultstaticsecret -n mnt` 에 잔존 리소스 있음.

### Root Cause

namespace 삭제는 그 안의 모든 리소스 finalizer 가 풀려야 끝난다. 멈추는 패턴은 보통 셋:

1. VSO controller 는 이미 삭제됐는데 `VaultStaticSecret` / `VaultAuth` / `VaultConnection` 의 CRD finalizer 가 남음 → 풀어줄 컨트롤러 부재
2. PVC protection finalizer (`kubernetes.io/pvc-protection`) 가 PV 와의 정리 순서 때문에 남음
3. 다른 namespaced 리소스 finalizer 도 컨트롤러 부재로 cleanup 안 됨

### 해결

`teardown.sh` 가 단계적으로 처리:

| Phase | 작업 |
|:---:|---|
| 1 | VSO CRD 삭제 → 60s timeout 시 `VaultStaticSecret` / `VaultAuth` / `VaultConnection` finalizer 강제 해제 |
| 2 | PVC 보호 finalizer 제거 |
| 3 | 전체 namespaced 리소스 finalizer 일괄 제거 |
| 4 | `kubectl delete namespace` 60s 대기 → 실패 시 namespace `/finalize` API 직접 호출 |
| 5 | cluster-scoped 리소스 (`vault-tokenreview-binding` 등) 정리 |

### 검증

```bash
kubectl get ns mnt
# Error from server (NotFound): namespaces "mnt" not found
```

### 교훈

- `Terminating` 무한대기는 **거의 항상 finalizer 누락**. 어떤 컨트롤러가 풀어줘야 하는지 / 그 컨트롤러가 살아있는지부터 확인.
- `/finalize` API 직접 호출은 마지막 수단 — orphan PV / PVC 바인딩이 남을 수 있어, 이후 클러스터 정리에서 별도로 챙겨야 함.
- 정상적인 teardown 순서는 "역의존 순" — 컨트롤러를 마지막에 죽이기. 자동 스크립트가 이를 강제하지 않으면 운영자 손에 버그가 옮겨붙는다.

---

## 7. PodSecurity 위반 경고 (admission)

### 한 줄 요약

namespace 에 `pod-security.kubernetes.io/enforce: restricted` 라벨이 붙어 있어 admission 단에서 securityContext 누락이 모두 거부됨. 모든 워크로드 매니페스트에 Restricted 필드 체크리스트를 적용해서 해결.

### 증상

```
Warning: would violate PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (...)
  unrestricted capabilities (...)
  runAsNonRoot != true (...)
  seccompProfile (...)
```

`kubectl apply` 또는 deploy 시점에 Pod 생성이 거부 / 경고.

### Root Cause

PSS Restricted 는 **default-deny** 에 가깝다. Pod / container 둘 다에서 다음 필드를 명시해야 통과한다.

| Pod | Container |
|---|---|
| `runAsNonRoot: true` | `runAsNonRoot: true` |
| `seccompProfile.type: RuntimeDefault` | `allowPrivilegeEscalation: false` |
| | `capabilities.drop: ["ALL"]` |
| | `seccompProfile.type: RuntimeDefault` |
| `runAsUser` / `runAsGroup` non-zero | (image 가 root 로 빌드됐으면 별도 처리) |

### 해결

모든 Deployment / StatefulSet / Job 매니페스트에 일관된 securityContext 블록 적용. 예시:

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```

이 패턴은 [`docs/security-hardening.md`](./security-hardening.md) 의 체크리스트에 정리되어 있고, [`k8s/scripts/ci/validate.sh`](../k8s/scripts/ci/validate.sh) 가 `kube-linter` 로 회귀를 막는다.

### 검증

```bash
bash k8s/scripts/ci/validate.sh
# build=ok schema=ok lint=ok

kubectl apply -k k8s/overlays/dev
# Warning 없음
```

### 교훈

- PSS Restricted 는 **사후 디버깅이 비싸다** — 매니페스트 작성 시점에 체크리스트로 박는 게 가장 싸다.
- Pod-level + Container-level 양쪽 모두에서 명시해야 한다 (어느 한쪽만 있으면 다른 쪽은 default 로 평가되어 거부될 수 있음).
- 회귀 방지는 `kube-linter` / `kubeconform` / `kustomize build` 3단 검증을 CI 단계로 끌어올리는 게 최소.

---

## 8. VSO 가 Vault 로그인 실패

### 한 줄 요약

VSO 가 자기 ServiceAccount JWT 로 Vault 의 kubernetes auth method 에 로그인하려는데, Vault → kube-apiserver 의 `TokenReview` 호출 권한 (`vault-tokenreview-binding` ClusterRoleBinding) 또는 Vault 쪽 config (`token_reviewer_jwt` / `kubernetes_ca_cert`) 가 빠져 인증이 거부된 사건.

### 증상

VSO Pod logs:

```
permission denied (vault.errors.PermissionDenied)
authentication failed: invalid token (...)
```

K8s Secret 이 sync 되지 않고 빈 상태.

### Root Cause

K8s 인증의 의존 그래프는 두 단:

1. **Vault → kube-apiserver `TokenReview` 호출 권한**
   - 이건 `system:auth-delegator` ClusterRole 을 Vault 의 ServiceAccount 에 묶는 ClusterRoleBinding (`vault-tokenreview-binding`) 으로 부여.
2. **Vault 자체의 kubernetes auth config**
   - `vault write auth/kubernetes/config` 에 `kubernetes_host` + `kubernetes_ca_cert` + `token_reviewer_jwt` (Vault SA 의 JWT) 설정.

둘 중 하나만 빠져도 로그인 실패.

### 해결

```bash
# 1. ClusterRoleBinding 적용
kubectl apply -k k8s/overlays/<env>/vault/

# 2. vault auth/kubernetes/config 설정 (idempotent)
REPO_ROOT="$(pwd)" ENV_NAME=<env> bash k8s/scripts/tasks/vault-init.sh
```

`vault-init.sh` 는 다음을 자동으로 한다:

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

### 검증

```bash
kubectl get clusterrolebinding vault-tokenreview-binding
# 존재해야 함

kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
# successfully authenticated to Vault

kubectl get secret <vso-managed-secret> -o yaml
# data 필드 채워짐
```

### 교훈

- "Vault 로그인 실패" 는 거의 항상 **두 권한 중 하나의 누락**:
  1. Vault SA 가 kube-apiserver 의 TokenReview 를 호출할 수 있나? (RBAC)
  2. Vault config 에 SA token + CA cert 가 있나? (Vault 측 설정)
- 두 단을 한 idempotent 스크립트(`vault-init.sh`) 로 묶어두면 재현 / 복구 / 환경 이전이 단순해진다.

---

## 같이 보기

- [`guide.md` 15장](../guide.md#15-트러블슈팅) — 운영자 절차서 톤의 동일 사건 정리
- [`docs/operations.md`](./operations.md) — bootstrap / teardown / validate 의 설계 의도
- [`docs/security-hardening.md`](./security-hardening.md) — PSS Restricted 체크리스트, NetworkPolicy
- [`docs/vault-vso.md`](./vault-vso.md) — VSO 운영 모델, `destination.overwrite` 정책 근거
