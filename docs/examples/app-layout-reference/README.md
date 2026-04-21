# Example Unit Layout

This directory is a non-deploying example of the scale layout.

Do not add `_examples` to `units/kustomization.yaml`.

Real workloads should follow the same shape without the `_examples` prefix:

```text
units/<unit>/<domain>/<workload-kind>/<workload>/
```

Example scale split:
- `commerce/checkout/services/order-api`
- `commerce/checkout/services/payment-api`
- `commerce/checkout/workers/payment-settlement-worker`
- `commerce/checkout/schedulers/cart-expiry-scheduler`
- `commerce/checkout/stateful/orders-postgres`
- `media/recommendation/services/recommendation-api`
- `media/recommendation/jobs/model-refresh-job`
- `identity/auth/services/auth-api`
- `identity/auth/schedulers/token-cleanup-scheduler`
- `data/ingestion/workers/event-ingest-worker`
