# Ingress / Traefik 운영

dev 환경은 K3s packaged Traefik 을 그대로 유지한다. 단 **`/var/lib/rancher/k3s/server/manifests/traefik.yaml` 는 수정하지 않는다.** 운영 설정은 `k8s/overlays/dev/platform/traefik/` 의 `HelmChartConfig` 로만 오버라이드한다.

## 현재 구성

| 위치 | 역할 |
|---|---|
| `k8s/overlays/dev/platform/traefik/helmchartconfig.yaml` | Traefik replica, 기본 ingressClass, HTTP→HTTPS redirect, metrics, 기본 TLS option 연결 |
| `k8s/overlays/dev/platform/traefik/middleware.yaml` | 공용 `security-headers` Middleware + `modern-tls` TLSOption |
| `k8s/overlays/dev/auth/ingress.yaml` | `project.com` → `auth-server` |
| `k8s/overlays/dev/keycloak/ingress-public.yaml` | `keycloak.dev.example.com` → Keycloak 공개 path (`/realms/`, `/resources/`, `/.well-known/`, `/js/`) |
| `k8s/overlays/dev/platform/cert-manager/` | cert-manager `v1.20.2` CRD/controller 설치 overlay |
| `k8s/overlays/dev/platform/cert-manager-issuers/` | `letsencrypt-staging` / `letsencrypt-prod` ClusterIssuer |
| `k8s/overlays/dev/platform/keycloak-operator/` | Keycloak Operator `26.6.1`. dev 제약상 `mnt` 에 설치해 `mnt` 의 Keycloak CR 을 watch. K8s API egress NetworkPolicy 포함 |
| `k8s/overlays/dev/tls/*.yaml` | cert-manager 설치 후 발급할 `Certificate` 리소스 |
| `k8s/components/forward-auth/` | oauth2-proxy + Traefik ForwardAuth 재사용 component |
| `k8s/overlays/dev/` | 기본 dev overlay. 현재 forward-auth component 를 직접 포함 |
| `k8s/overlays/dev/keycloak-realm/` | `KeycloakRealmImport` 로 realm/client 를 Git 관리 |

## 설계 원칙

- 앱은 `Ingress` 만 선언하고, 공통 보안 정책은 Traefik Middleware / TLSOption 으로 재사용
- Keycloak 은 외부 전체 공개가 아니라 **최소 공개 path** 만 연다. `/admin`, `/metrics`, `/health` 는 비공개
- TLS 리소스는 cert-manager + ClusterIssuer 적용 후 `tls/` overlay 에서 발급
- north-south ingress 는 `kube-system` 의 Traefik Pod 에서만 시작 → app NetworkPolicy 도 그에 맞춰 작성

## ForwardAuth variant

`k8s/components/forward-auth/` 는 oauth2-proxy + ForwardAuth Middleware 를 담은 Kustomize component 다. 현재 `k8s/overlays/dev/` 가 이 component 를 직접 포함한다.

구성:

- `oauth2-proxy` Deployment / Service / ConfigMap / VaultStaticSecret
- `project.com/oauth2/*` 경로용 Ingress
- `oauth2-proxy-auth` Traefik Middleware
- `auth-server` Ingress patch — `project.com/` 요청은 oauth2-proxy 를 거친 인증된 사용자만 통과

흐름: `Traefik ForwardAuth → oauth2-proxy → Keycloak`.

### 적용 전제

- `k8s/overlays/dev/keycloak-realm/` 또는 동등한 방법으로 `platform` realm + `auth-server-ingress` client 가 준비됨
- redirect URI: `https://project.com/oauth2/callback`
- Vault path `secret/oauth2-proxy/forward-auth` 에 `client_secret`, `cookie_secret` 저장
- `project.com`, `keycloak.dev.example.com` 이 실제 Traefik 진입점으로 해석됨

### 브라우저 접속 전제

curl 검증은 `--resolve project.com:443:<ingress-ip>` 와 `-k` 로 DNS/TLS 문제를 우회할 수 있다. 브라우저는 이 옵션이 없으므로 dev 환경에서 직접 접속하려면 운영자가 아래를 별도로 맞춰야 한다.

```text
<ingress-ip>  project.com
<ingress-ip>  keycloak.dev.example.com
```

예: Traefik `LoadBalancer` IP 중 하나가 `10.208.141.123` 이면 로컬 `/etc/hosts` 에 두 host 를 추가한다. dev overlay 는 현재 외부 ACME 발급 대신 `dev-selfsigned` ClusterIssuer 를 사용하므로 브라우저에서는 인증서 경고를 허용하거나 해당 인증서를 로컬 trust store 에 등록해야 한다. 공인 DNS 가 Traefik 진입점으로 향하고 ACME 인증서가 Ready 가 되면 이 임시 조치는 제거한다.

Chrome 에서 계속 실패하면 먼저 boundary 를 나눈다.

| Boundary | 확인 |
|---|---|
| 로컬 DNS | `getent hosts project.com keycloak.dev.example.com` 이 Traefik IP 를 반환해야 한다. |
| 브라우저 DNS cache | `/etc/hosts` 수정 후 Chrome 재시작 또는 `chrome://net-internals/#dns` 에서 cache clear. |
| TLS trust | `ERR_CERT_*` 가 나오면 dev self-signed 인증서를 허용하거나 trust store 에 등록한다. |
| 인증 redirect | `curl -k -D - --resolve project.com:443:<ingress-ip> https://project.com/swagger-ui.html` 가 `302 Location: https://keycloak...` 를 반환해야 한다. |
| 로그인 후 app route | 인증 후 `404 PRES-005` 는 ForwardAuth 실패가 아니라 auth-server 에 해당 route 가 없다는 뜻이다. |

### 브라우저 검증 순서

dev ForwardAuth 를 브라우저에서 직접 확인할 때는 아래 순서로 진행한다. 중간 단계를 건너뛰면 "Chrome 이 안 된다" 만 보이고 어느 boundary 가 깨졌는지 알기 어렵다.

#### 1. Traefik 진입 IP 확인

```bash
kubectl -n kube-system get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}{"\n"}'
```

예상 예시:

```text
10.208.141.123 10.208.141.14
```

이 문서의 예시는 `10.208.141.123` 을 사용한다. 실제 클러스터에서 나온 IP 중 하나를 선택한다.

#### 2. curl 로 클러스터 경로 먼저 확인

브라우저를 열기 전에 curl 로 Traefik / oauth2-proxy / Keycloak boundary 가 살아있는지 확인한다.

```bash
curl -k -sS -L \
  -D /tmp/project-infra-login.headers \
  -o /tmp/project-infra-login.body \
  --resolve project.com:443:10.208.141.123 \
  --resolve keycloak.dev.example.com:443:10.208.141.123 \
  https://project.com/swagger-ui.html
```

정상 신호:

```bash
sed -n '1,80p' /tmp/project-infra-login.headers
grep -o '<title>[^<]*' /tmp/project-infra-login.body
```

정상이라면 헤더에는 첫 응답 `HTTP/2 302` 와 `location: https://keycloak.dev.example.com/.../auth` 가 보이고, body title 은 아래처럼 나온다.

```text
<title>Sign in to platform
```

이 단계가 실패하면 브라우저를 볼 필요가 없다. 먼저 `docs/troubleshooting.md` 의 `ForwardAuth 로그인 E2E 검증 실패` 사건에서 해당 boundary 를 찾는다.

#### 3. 빠른 Chrome 임시 프로필로 확인

로컬 `/etc/hosts` 와 인증서 trust 를 건드리기 전에, Chrome 실행 옵션으로 DNS/TLS 를 임시 우회해 본다.

```bash
google-chrome \
  --user-data-dir=/tmp/project-infra-chrome \
  --ignore-certificate-errors \
  --host-resolver-rules="MAP project.com 10.208.141.123, MAP keycloak.dev.example.com 10.208.141.123" \
  https://project.com/swagger-ui.html
```

정상 흐름:

1. `https://project.com/swagger-ui.html` 접속
2. Traefik ForwardAuth 가 미인증 요청을 감지
3. `302` 로 Keycloak 로그인 화면 이동
4. `Sign in to platform` 화면 표시
5. 로그인 성공 후 `project.com` 으로 callback

이 방식으로 성공하면 Kubernetes / Traefik / oauth2-proxy / Keycloak 경로는 정상이다. 평소 Chrome 에서 안 되는 원인은 로컬 DNS cache, `/etc/hosts`, 인증서 trust, 기존 쿠키 중 하나다.

#### 4. 일반 Chrome 으로 볼 수 있게 hosts 등록

임시 Chrome 이 성공하면 로컬 OS resolver 를 맞춘다.

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'

# Project-Infra dev ingress
10.208.141.123 project.com
10.208.141.123 keycloak.dev.example.com
EOF
```

확인:

```bash
getent hosts project.com keycloak.dev.example.com
```

두 host 가 선택한 Traefik IP 를 반환해야 한다.

#### 5. Chrome DNS cache / 기존 세션 정리

hosts 를 바꾼 뒤에도 Chrome 이 이전 DNS / 쿠키를 들고 있을 수 있다.

권장 순서:

1. `chrome://net-internals/#dns` 에서 DNS cache clear
2. `chrome://net-internals/#sockets` 에서 socket pools flush
3. `project.com`, `keycloak.dev.example.com` 사이트 데이터 삭제
4. Chrome 완전 종료 후 재시작

그래도 헷갈리면 아래처럼 새 임시 프로필을 쓰는 게 가장 빠르다.

```bash
google-chrome --user-data-dir=/tmp/project-infra-normal https://project.com/swagger-ui.html
```

#### 6. 인증서 경고 처리

dev overlay 는 현재 `dev-selfsigned` ClusterIssuer 로 TLS Secret 을 만든다. 따라서 일반 Chrome 에서는 인증서 경고가 뜰 수 있다.

검증 목적이면 고급 옵션에서 예외를 허용한다. 장기적으로 반복 검증할 예정이면 `project-com-tls`, `keycloak-dev-example-com-tls` 인증서를 로컬 trust store 에 등록한다.

이 경고는 dev self-signed 인증서 때문에 생기는 것으로, ForwardAuth 실패와는 다른 boundary 다.

#### 7. 로그인 후 결과 해석

로그인 후 `swagger-ui.html` 이 열리면 브라우저 검증은 성공이다.

로그인 후 `/api/me` 를 열어 `404 PRES-005` 가 나오면 이것도 ForwardAuth 실패가 아니다. 인증은 통과했고 auth-server 애플리케이션에 `/api/me` route 가 없다는 뜻이다.

판단 기준:

| 결과 | 의미 |
|---|---|
| Keycloak 로그인 화면이 뜸 | 미인증 redirect 정상 |
| 로그인 후 `project.com` 으로 돌아옴 | callback / token exchange / session cookie 정상 |
| `/oauth2/auth` 가 `202` | oauth2-proxy 세션 인증 정상 |
| auth-server 가 `404 PRES-005` 반환 | 인증 통과 후 application route 없음 |
| auth-server 가 `401` 반환 | Authorization header 또는 JWT validation boundary 문제 |

### 인증 실패 처리

Traefik ForwardAuth 는 `/oauth2/auth` 를 호출한다. oauth2-proxy 가 `401` 또는 `403` 을 반환하면 `oauth2-proxy-errors` Middleware 가 `/oauth2/start?rd={url}` 로 넘겨 로그인 흐름을 시작한다.

중요: Traefik errors middleware 는 기본적으로 원래 status code 를 유지할 수 있다. 그러면 oauth2-proxy 가 `Location` 을 내려도 브라우저는 `401` 응답을 자동 redirect 로 처리하지 않는다. dev 구성은 `statusRewrites` 로 `401`/`403` 을 `302` 로 바꿔 브라우저가 바로 Keycloak 로그인 화면으로 이동하게 한다.

## cert-manager / ClusterIssuer

repo 에 `k8s/overlays/dev/platform/cert-manager/` 와 `k8s/overlays/dev/platform/cert-manager-issuers/` 가 추가되어 있다.

- 설치 overlay: 공식 static install `v1.20.2`
- issuer overlay: ACME HTTP-01 용 `letsencrypt-staging` / `letsencrypt-prod`

source-of-truth 관점에서 cert-manager 도 이 repo 의 선언형 관리 대상. 단, **실제 인증서 발급은 DNS 가 Traefik 외부 진입점을 가리키고 80/443 도달이 가능해야** 완료된다.

```bash
kubectl apply -k k8s/overlays/dev/platform/cert-manager
kubectl apply -k k8s/overlays/dev/platform/cert-manager-issuers
kubectl apply -k k8s/overlays/dev/tls
```

운영 보정 필요: `admin@project.com` 은 실제 운영 수신 가능한 메일로 교체.

## Keycloak realm / client Git 관리

`k8s/overlays/dev/keycloak-realm/` 는 `KeycloakRealmImport` 로 `platform` realm 과 `auth-server-ingress` client 를 선언한다. `k8s/overlays/dev/keycloak/` 도 수제 `Deployment` 가 아니라 `Keycloak` CR 기반으로 전환되어 있다.

`KeycloakRealmImport` 는 같은 `mnt` namespace 의 `Keycloak/keycloak` 을 대상으로 동작한다.

### 적용 순서

```bash
kubectl apply -k k8s/overlays/dev/platform/keycloak-operator
# 기존 수제 Deployment/Service/ConfigMap/ServiceAccount keycloak* 정리
kubectl apply -k k8s/overlays/dev
kubectl apply -k k8s/overlays/dev/keycloak-realm
```

## 적용 범위

repo 가 커버하는 것:

- Traefik 운영 정책의 Git 관리
- app ingress host / path / policy 정의
- Traefik → app 방향 ingress allow NetworkPolicy
- TLS `Certificate` 선언 준비
- ForwardAuth variant 와 KeycloakRealmImport 선언

> 미완 항목(DNS / ACME 발급 / end-to-end 테스트)은 README 의 [Limitations](../README.md#limitations-honest-scope) 섹션을 참고.
