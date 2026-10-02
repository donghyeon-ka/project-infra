# Kubernetes Packaging

This tree is organized for many independently owned workloads.

Entry points:
- `overlays/<env>/` renders the whole environment skeleton.
- `overlays/<env>/<domain>/` renders one namespace/domain boundary.
- `overlays/<env>/managing/vault-secrets-operator/` is applied after the VSO CRDs are installed.
- `scripts/env/` contains environment bootstrap and teardown orchestration.
- `scripts/` contains imperative bootstrap and break-glass operations only.
- `vso/` contains Vault Secrets Operator installation lifecycle files.

Scale rules:
- Do not place hundreds of workloads directly under one package.
- Add workloads under `base/app/units/<unit>/<domain>/<workload-kind>/<workload>/`.
- Add matching environment overrides under `overlays/<env>/app/units/<unit>/<domain>/<workload-kind>/<workload>/` only when that workload has environment-specific differences.
- A workload package owns its Kubernetes object files together, such as `deployment.yaml`, `service.yaml`, `configmap.yaml`, `cronjob.yaml`, `statefulset.yaml`, or `pvc.yaml`.
- Do not create kind-based package roots such as `deployments/`, `services/`, or `configmaps/`.

Example for a 1000-workload organization:

```text
base/app/units/
├── commerce/
│   ├── checkout/
│   │   ├── services/order-api/
│   │   ├── services/payment-api/
│   │   ├── workers/payment-settlement-worker/
│   │   ├── schedulers/cart-expiry-scheduler/
│   │   └── stateful/orders-postgres/
│   └── catalog/
│       ├── services/catalog-api/
│       ├── workers/search-index-worker/
│       └── jobs/catalog-backfill-job/
├── identity/
│   ├── auth/
│   │   ├── services/auth-api/
│   │   ├── services/token-api/
│   │   └── schedulers/token-cleanup-scheduler/
│   └── profile/
│       ├── services/profile-api/
│       └── workers/profile-event-worker/
├── media/
│   ├── playback/
│   │   ├── services/playback-api/
│   │   └── workers/session-event-worker/
│   └── recommendation/
│       ├── services/recommendation-api/
│       ├── workers/model-feature-worker/
│       └── jobs/model-refresh-job/
└── data/
    ├── ingestion/
    │   ├── workers/event-ingest-worker/
    │   └── stateful/ingest-kafka/
    └── analytics/
        ├── schedulers/daily-report-scheduler/
        └── jobs/monthly-rollup-job/
```
