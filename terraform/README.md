# Terraform

Terraform is split into environment roots and reusable modules.

Entry rules:
- `environments/<env>/` is the only place that should be planned or applied directly.
- `modules/<domain>/` is reusable implementation only and must not be applied directly.
- Empty package directories must carry a README contract until real Terraform entry files are added.
- Do not create new top-level Terraform package families without updating this contract and the root documentation.
