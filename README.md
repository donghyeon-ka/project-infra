# Daily Kata — Day 1: Service · Endpoints 경계 체득

> Kubernetes 의 **Service / Endpoints / Ingress 가 각자 무엇을 책임지고 무엇을 책임지지 않는지**를, 직접 작성하고 **일부러 두 번 깨뜨려서** 체득하는 2시간짜리 수련.

## 성공 기준

이 세 가지를 모두 만족해야 오늘 수련이 끝난다.

- [ ] **학습 계약 4문장**을 노트 없이 말할 수 있다
- [ ] **의도적 장애 2개**를 직접 재현하고, 어느 명령어가 가장 먼저 원인을 드러내는지 안다
- [ ] **숙련도 자기 평가 4항목 모두 4점 이상** (하나라도 4 미만이면 내일 다음 주제로 안 넘어감, 오늘 과제 변형 반복)

소요 시간 기준: **2시간**.

## Prerequisites

| 항목 | 확인 명령 |
|---|---|
| K3s 또는 K8s 클러스터 (단일 노드 OK) | `kubectl cluster-info` |
| `kubectl` 가 클러스터에 접근 가능 | `kubectl get nodes` |
| Traefik IngressClass 가 설치돼 있음 | `kubectl get ingressclass` (이름이 `traefik` 인지 확인) |
| 노드 IP 확인 | `kubectl get nodes -o wide` 의 `INTERNAL-IP` 또는 `EXTERNAL-IP` |

이 README 의 `<node-ip>` 자리는 위 명령으로 얻은 IP 로 치환한다. 예: `10.208.141.123` → `whoami.10.208.141.123.nip.io`.

---

## 0. 학습 계약

> "2시간이 끝났을 때, 아래 4문장을 노트 없이 말할 수 있어야 합니다."

1. **Deployment 는 Pod 를 외부에 노출하지 않는다.** selector 와 Pod template 의 label 이 일치하는 Pod 집합을 지속적으로 만든다.
2. **Service 는 Pod 이름이 아니라 label selector 로 Pod 를 찾고**, 그 결과를 Endpoint 집합으로 만든다.
3. **Endpoints 또는 EndpointSlice 가 비어 있으면** Service 이름은 존재해도 실제로 트래픽을 받을 Pod 가 없다는 뜻이다.
4. **Ingress 는 외부 HTTP 요청의 host/path 를 Service 로 연결**하지만, Pod 를 직접 고르지는 않는다.

---

## 1. 시나리오

플랫폼 팀의 연습용 `whoami` 애플리케이션을 `platform-lab` namespace 에 배포한다. 리소스 이름은 각각 `whoami-deploy`, `whoami-svc`, `whoami-ingress`.

목표는 브라우저 또는 `curl` 로 `http://whoami.<node-ip>.nip.io` 에 접근했을 때:
- Traefik Ingress 가 요청을 받고 → `whoami-svc` 로 넘기고 → Service 가 실제 Pod Endpoint 로 트래픽을 흘리는 구조를
- **직접 구성하고 검증**하는 것.

오늘의 핵심은 하나:

> **Ingress 가 Pod 를 찾는 것이 아니다. Ingress 는 Service 를 가리킨다. Service 가 label selector 로 Pod 를 찾는다.**

이 경계를 모르면 겉으로는 모두 `404`, `503`, `connection failed` 처럼 보인다. 그러나 원인은 서로 다르다. 오늘은 그 차이를 **눈으로 확인**하는 날이다.

---

## 2. 경계 지도

**주요 수련 대상: Service · Endpoints**

| | 책임지는 것 | 책임지지 않는 것 |
|---|---|---|
| **Service** | Pod 집합을 label selector 로 선택. 선택된 Pod IP·port 를 Endpoints/EndpointSlice 로 만듦. 클러스터 내부에 안정적인 DNS 이름과 가상 IP 제공 | Pod 생성 X · 컨테이너 이미지 실행 X · HTTP host/path 라우팅 X · 외부 도메인 소유 X · IngressClass 결정 X |

오늘의 무공:

> Service 는 문파 이름이다.
> Endpoints 는 실제 제자들이 서 있는 위치다.
> 문파 이름만 있고 제자가 없으면, 칼은 허공을 가른다.

---

## 3. 수동 구현 요구사항

> ⚠ 완성본을 복붙하지 않는다. 각 필드가 **어떤 경계를 연결하는지** 생각하면서 직접 채운다.
> ★ 표시는 오늘의 핵심 필드.

### Namespace

- [ ] `apiVersion`
- [ ] `kind`
- [ ] `metadata.name` → `platform-lab`

### Deployment — `whoami-deploy`

- [ ] `apiVersion`
- [ ] `kind`
- [ ] `metadata.name` → `whoami-deploy`
- [ ] `metadata.namespace` → `platform-lab`
- [★] `spec.selector.matchLabels` — Pod template label 과 정확히 같은 key/value 집합이어야 한다
- [★] `spec.template.metadata.labels` — Deployment selector 와 Service selector 가 모두 바라볼 수 있는 안정적인 label
- [ ] `spec.replicas` — **2개 이상**
- [ ] `spec.template.spec.containers[].name`
- [ ] `spec.template.spec.containers[].image` — HTTP 응답을 반환하는 단순 whoami 계열 이미지
- [★] `spec.template.spec.containers[].ports[].containerPort` — 컨테이너가 실제로 HTTP 요청을 받는 port 와 일치

### Service — `whoami-svc`

- [ ] `apiVersion`
- [ ] `kind`
- [ ] `metadata.name` → `whoami-svc`
- [ ] `metadata.namespace` → `platform-lab`
- [★] `spec.selector` — Deployment 의 Pod template label 과 일치
- [ ] `spec.type` — Ingress 가 클러스터 내부에서 접근할 수 있는 기본 타입이면 충분
- [★] `spec.ports[].port` — Ingress backend 가 참조할 Service port
- [★] `spec.ports[].targetPort` — Pod 컨테이너의 실제 HTTP port 로 연결

### Ingress — `whoami-ingress`

- [ ] `apiVersion`
- [ ] `kind`
- [ ] `metadata.name` → `whoami-ingress`
- [ ] `metadata.namespace` → `platform-lab`
- [★] `spec.ingressClassName` — 현재 클러스터의 Traefik IngressClass 와 일치
- [★] `spec.rules[].host` — `whoami.<node-ip>.nip.io` 형식
- [★] `spec.rules[].http.paths[].path` — `/` 요청을 받을 수 있어야 한다
- [★] `spec.rules[].http.paths[].pathType` — `/` 경로 매칭 의도와 맞아야 한다
- [★] `spec.rules[].http.paths[].backend.service.name` — 위에서 만든 Service 이름
- [★] `spec.rules[].http.paths[].backend.service.port.number` — Service 의 `spec.ports[].port` 와 일치
  - ❌ Pod 의 `containerPort` 를 직접 넣는 것이 **아니다**

---

## 4. 실행 전 예측 체크포인트

각 명령어를 **실행하기 전에 한 줄 예측을 먼저 적는다**. 다음 형식으로:

```
예측: 이 명령어를 실행하면 _______ 이 보일 것이다.
실제 결과: _______
틀렸다면: 내 머릿속 모델에서 틀린 믿음은 _______ 이었다.
```

### Checkpoint 1 — Deployment / ReplicaSet / Pod

```bash
kubectl get deploy,rs,pod -n platform-lab --show-labels
```

예측 항목:
- Deployment 가 ReplicaSet 을 만들고, ReplicaSet 이 label 이 붙은 Pod 2개를 유지하는가?
- Pod label 이 의도한 값인가?
- Deployment selector 와 Pod label 이 이어지는가?

### Checkpoint 2 — Service

```bash
kubectl get svc whoami-svc -n platform-lab -o wide
```

예측 항목:
- Service 가 ClusterIP 를 가지고 있는가?
- selector 가 Pod label 과 맞는가?

### Checkpoint 3 — Endpoints

```bash
kubectl get endpoints whoami-svc -n platform-lab -o wide
```

예측 항목:
- Endpoint 가 비어 있는가?
- Pod IP 가 표시되는가?
- port 가 의도한 값인가?

### Checkpoint 4 — EndpointSlice

```bash
kubectl get endpointslice -n platform-lab -l kubernetes.io/service-name=whoami-svc
```

예측 항목:
- EndpointSlice 가 생성되었는가?
- Service 이름 기준 label 이 붙어 있는가?
- Endpoint 개수가 Pod 개수와 논리적으로 맞는가?

### Checkpoint 5 — Ingress

```bash
kubectl describe ingress whoami-ingress -n platform-lab
```

예측 항목:
- host 가 의도한 값인가?
- backend service 이름이 맞는가?
- backend service port 가 Service 의 port 와 맞는가?
- IngressClass 가 Traefik 과 맞는가?

### Checkpoint 6 — End-to-end HTTP

```bash
curl -i http://whoami.<node-ip>.nip.io
```

예측 항목:
- HTTP status code 는?
- 응답이 whoami Pod 에서 온 것처럼 보이는가?
- 실패한다면 어느 경계에서 끊겼는가?

---

## 5. 의도적 장애 2개

> 오늘은 일부러 두 번 망가뜨린다. 그냥 성공만 하면 수련이 얕다.
> 고수는 **장애가 난 위치를 출력으로 가른다**.

### 장애 1 — Service selector 계층 장애

**망가뜨릴 내용**: Service 의 `spec.selector` 중 label value 하나를 Deployment Pod label 과 다르게 바꾼다.

```yaml
spec:
  selector:
    app: <원래 Pod label 과 다른 값>   # 직접 결정
```

**적용 전 예측 (먼저 작성)**:

```
예측 증상:
가장 먼저 문제를 드러낼 명령어:
왜 그 명령어가 먼저 드러내는가:
```

**기대 방향**:
- Pod 는 살아 있다
- Service 도 존재한다
- 하지만 Service 가 선택한 Pod 가 없다
- 따라서 Endpoint 가 비어야 한다

**진단 명령어 순서**:

```bash
kubectl get pod -n platform-lab --show-labels
kubectl get svc whoami-svc -n platform-lab -o yaml
kubectl get endpoints whoami-svc -n platform-lab -o wide
kubectl get endpointslice -n platform-lab -l kubernetes.io/service-name=whoami-svc
curl -i http://whoami.<node-ip>.nip.io
```

**작성해야 할 root cause 문장** (한 문장 직접 채우기):

> Service 는 Pod 를 이름으로 찾는 것이 아니라 _______ 로 찾는데, 이번 장애에서는 _______ 와 _______ 가 불일치해서 Endpoint 집합이 비었다.

### 장애 2 — Ingress backend service port 계층 장애

**망가뜨릴 내용**: Ingress 의 `backend.service.port.number` 를 Service 의 `spec.ports[].port` 와 다르게 바꾼다.

**중요**:
- Pod 는 정상이어야 한다
- Service selector 도 정상이어야 한다
- Endpoint 도 정상이어야 한다
- **오직 Ingress 가 Service port 를 잘못 참조해야 한다**

**적용 전 예측 (먼저 작성)**:

```
예측 증상:
가장 먼저 문제를 드러낼 명령어:
왜 그 명령어가 먼저 드러내는가:
```

**기대 방향**:
- `kubectl get endpoints` 는 정상
- Service 는 Pod 를 잘 찾고 있어야 함
- 외부 HTTP 요청만 실패
- 원인은 Ingress 가 Service port 를 잘못 바라본 것

**진단 명령어 순서**:

```bash
kubectl get pod -n platform-lab --show-labels
kubectl get endpoints whoami-svc -n platform-lab -o wide
kubectl get svc whoami-svc -n platform-lab -o yaml
kubectl describe ingress whoami-ingress -n platform-lab
curl -i http://whoami.<node-ip>.nip.io
```

**작성해야 할 root cause 문장** (한 문장 직접 채우기):

> Ingress 는 Pod 의 containerPort 를 직접 참조하는 것이 아니라 _______ 의 _______ 를 참조해야 하는데, 이번 장애에서는 _______ 가 불일치해서 외부 HTTP 라우팅이 실패했다.

---

## 6. 숙련도 확인

### a. 학습 계약 암송

노트 없이 아래 4문장을 말한다.

1. Deployment 는 무엇을 책임지는가?
2. Service 는 Pod 를 어떻게 찾는가?
3. Endpoint 가 비었다는 것은 무엇을 뜻하는가?
4. Ingress 는 Pod 와 직접 연결되는가, 아니면 Service 와 연결되는가?

### b. 장애 설명

각 장애를 **가상의 선배 개발자에게 2분 안에 설명**한다.

장애 1 설명에 반드시 포함:
- `spec.selector`
- `spec.template.metadata.labels`
- `kubectl get endpoints`
- `kubectl get pod --show-labels`

장애 2 설명에 반드시 포함:
- `backend.service.port.number`
- `spec.ports[].port`
- `spec.ports[].targetPort`
- `kubectl describe ingress`

### c. 자기 평가

각 항목 1~5점.

| 항목 | 점수 |
|---|---|
| Deployment 와 Pod label 관계를 설명할 수 있다 | __/5 |
| Service selector 와 Endpoint 관계를 설명할 수 있다 | __/5 |
| Endpoint 가 비었을 때 어디를 봐야 하는지 안다 | __/5 |
| Ingress 가 Service port 를 참조한다는 것을 설명할 수 있다 | __/5 |

> **하나라도 4점 미만이면 내일 다음 주제로 넘어가지 않는다.** 오늘 과제의 변형을 다시 한다.

---

## 작업 산출물 위치 (참고)

이 branch (`daily-kata/day-1`) 에 다음 파일을 만들어 commit 하면 학습 기록이 남는다:

```
.
├── README.md                               # 이 문서
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-deployment.yaml
│   ├── 20-service.yaml
│   └── 30-ingress.yaml
└── notes/
    ├── checkpoint-predictions.md           # 4 의 예측-실제-틀린 믿음 기록
    ├── failure-1-rootcause.md              # 5 장애1 의 root cause 문장
    ├── failure-2-rootcause.md              # 5 장애2 의 root cause 문장
    └── self-assessment.md                  # 6c 자기 평가
```

수련이 끝나면 위 파일들이 모두 채워져 있어야 한다.
