# prod Terraform Environment

Contract:
- Owns only prod-specific Terraform root configuration.
- Reuses modules from `../../modules` when modules exist.
- Must not define reusable infrastructure patterns that belong in modules.
- Add Terraform entry files here only when the prod environment is ready to be planned and applied.
