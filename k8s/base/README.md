# Base Packages

Base packages contain shared Kubernetes definitions.

Boundaries:
- `managing/` owns infrastructure management resources in the `mnt` namespace.
- `app/` owns application namespace resources and large-scale workload package contracts.
- `plugins/` owns plugin namespace resources.

Rules:
- Base packages must not contain environment-specific values.
- A base package can be rendered with `kubectl kustomize` through its own `kustomization.yaml`.
- Parent packages compose child packages; child packages own their internal Kubernetes object files.
