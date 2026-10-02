# Application Base

This package owns the `app` namespace and the contract for application workloads.

For large scale, workloads are grouped by unit, domain, workload kind, and workload:

```text
base/app/units/<unit>/<domain>/<workload-kind>/<workload>/
```

Examples:
- `base/app/units/commerce/checkout/services/order-api/`
- `base/app/units/commerce/checkout/workers/payment-settlement-worker/`
- `base/app/units/identity/auth/schedulers/token-cleanup-scheduler/`
- `base/app/units/data/storage/stateful/orders-postgres/`

Rules:
- The unit folder is the broad ownership boundary for a business unit, platform area, or organization.
- The domain folder is the bounded context inside a unit.
- The workload-kind folder groups similar operating models inside one domain.
- The workload folder is the smallest independently deployable package.
- Kubernetes object files stay together inside the workload package.
- Shared namespace-level objects go in `shared/`.
