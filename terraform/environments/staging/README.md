# staging Terraform Environment

Contract:
- Owns only staging-specific Terraform root configuration.
- Reuses modules from `../../modules` when modules exist.
- Must not define reusable infrastructure patterns that belong in modules.
- Add Terraform entry files here only when the staging environment is ready to be planned and applied.
