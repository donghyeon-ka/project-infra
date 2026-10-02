# dev Terraform Environment

Contract:
- Owns only dev-specific Terraform root configuration.
- Reuses modules from `../../modules` when modules exist.
- Must not define reusable infrastructure patterns that belong in modules.
- Add Terraform entry files here only when the dev environment is ready to be planned and applied.
