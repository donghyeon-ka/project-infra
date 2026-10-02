# Environment Overlays

Overlays contain environment-specific differences.

Required shape:

```text
overlays/<env>/
├── kustomization.yaml
├── app/
├── managing/
└── plugins/
```

Rules:
- Overlay packages reuse base packages.
- Overlay packages contain patches, generated config, or environment-specific resources only.
- Do not duplicate base package composition in overlays.
- A workload override belongs at `overlays/<env>/app/units/<unit>/<domain>/<workload-kind>/<workload>/`.
