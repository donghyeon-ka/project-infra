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
| `k8s/overlays/dev-with-forward-auth/` | 기본 dev 에 forward-auth component 를 결합한 variant overlay |
| `k8s/overlays/dev/keycloak-realm/` | `KeycloakRealmImport` 로 realm/client 를 Git 관리 |

## 설계 원칙

- 앱은 `Ingress` 만 선언하고, 공통 보안 정책은 Traefik Middleware / TLSOption 으로 재사용
- Keycloak 은 외부 전체 공개가 아니라 **최소 공개 path** 만 연다. `/admin`, `/metrics`, `/health` 는 비공개
- TLS 리소스는 cert-manager + ClusterIssuer 적용 후 `tls/` overlay 에서 발급
- north-south ingress 는 `kube-system` 의 Traefik Pod 에서만 시작 → app NetworkPolicy 도 그에 맞춰 작성

## ForwardAuth variant

`k8s/components/forward-auth/` 는 oauth2-proxy + ForwardAuth Middleware 를 담은 Kustomize component 다. `k8s/overlays/dev-with-forward-auth/` 는 기본 `dev` 전체를 포함한 뒤 이 component 를 결합하는 얇은 variant overlay 다.

구성:

- `oauth2-proxy` Deployment / Service / ConfigMap / VaultStaticSecret
- `project.com/oauth2/*` 경로용 Ingress
- `oauth2-proxy-auth` Traefik Middleware
- `auth-server` Ingress patch — `project.com/` 요청은 oauth2-proxy 를 거친 인증된 사용자만 통과

흐름: `Traefik ForwardAuth → oauth2-proxy → Keycloak`.

### 적용 전제

- `k8s/overlays/dev/keycloak-realm/` 또는 동등한 방법으로 `platform` realm + `auth-server-ingress` client 가 준비됨
- redirect URI: `https://project.com/oauth2/callback`
- Vault path `secret/oauth2-proxy/forward-auth` 에 `client-secret`, `cookie-secret` 저장
- `project.com`, `keycloak.dev.example.com` 이 실제 Traefik 진입점으로 해석됨

### 알려진 임시값

dev variant 의 oauth2-proxy 는 `ssl_insecure_skip_verify=true` 를 사용한다. 이유: cert-manager 발급 인증서 체인이 아직 완성되지 않았기 때문. cert-manager 도입 후 제거가 목표.

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

> 미완 항목(DNS / ACME 발급 / end-to-end 테스트 / `ssl_insecure_skip_verify` 제거)은 README 의 [Limitations](../README.md#limitations-honest-scope) 섹션을 참고.
