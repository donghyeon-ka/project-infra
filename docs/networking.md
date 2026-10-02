# NetworkPolicy 매트릭스

단일 namespace(`mnt`) 내부에서도 서비스 간 트래픽을 **최소권한** 으로 제한한다. baseline 은 모든 Pod 의 ingress/egress 를 차단하고, 컴포넌트별로 필요한 경로만 명시적으로 연다.

## 정책 목록

| 정책 파일 | 역할 |
|---|---|
| `overlays/dev/networkpolicy-baseline.yaml` | `default-deny-all` (전 Pod ingress/egress 기본 차단) + `allow-dns-egress` (kube-system/kube-dns 53) |
| `overlays/dev/database/networkpolicy.yaml` | identity-postgres ingress ← keycloak / auth-server / migration-flyway (5432) |
| `overlays/dev/auth/networkpolicy.yaml` | auth-server ingress ← `kube-system/traefik`(8080); egress → postgres(5432) + keycloak(8080); flyway egress → postgres(5432) |
| `overlays/dev/keycloak/networkpolicy.yaml` | keycloak ingress ← `kube-system/traefik`(8080) + auth-server(8080); egress → postgres(5432); Keycloak Pod 간 peer 통신 (Infinispan/JGroups) |
| `overlays/dev/storage/networkpolicy.yaml` | minio ingress ← `part-of=auth-platform`(9000); 자체 peer(9000/9001) |
| `overlays/dev/test/networkpolicy.yaml` | test-server 3 대 내부 상호 통신만 허용 |
| `overlays/dev/vault/networkpolicy.yaml` | vault ingress ← VSO Operator Pod(8200) |
| `overlays/dev/registry/networkpolicy.yaml` | docker-registry ingress ← namespace 내 전 Pod(5000) + `kube-system/traefik`(5000); egress → minio(9000) |

## 작성 규칙

- cross-namespace 참조가 필요한 항목(예: `kube-system/traefik`)은 `namespaceSelector` + `podSelector` 를 한 블록에 조합해 **AND 시맨틱** 으로 작성한다. 두 selector 를 별도 블록에 두면 OR 가 되어 정책이 헐거워진다.
- north-south ingress 는 `kube-system` 의 Traefik Pod 에서만 시작되므로, app 측 NetworkPolicy 도 실제 클러스터 기준으로 `kube-system` 을 허용해야 한다 (`ingressClassName=traefik` 만으로는 부족).
- baseline default-deny 가 켜져 있는 한, 새 워크로드를 올릴 때마다 ingress / egress 를 **명시적으로** 추가해야 한다. 이게 의도된 마찰이다 (실수로 wide-open 으로 시작하지 않도록).

## Keycloak Operator 추가 고려사항

Keycloak Operator 가 Keycloak Pod 를 만들고 watch 하기 때문에 default-deny 환경에서는 다음 두 가지를 NetworkPolicy 로 명시한다:

- Keycloak Operator 의 Kubernetes API egress (CR reconcile)
- Keycloak Pod 간 Infinispan/JGroups peer 통신 (cluster mode)

해당 정책은 `overlays/dev/keycloak/networkpolicy.yaml` 에 함께 들어 있다.
