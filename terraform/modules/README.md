# Terraform Modules

Modules are reusable package boundaries for infrastructure domains.

Contract:
- A module directory must represent one infrastructure domain.
- Module internals must be reusable across environments.
- Environment-specific values belong in `../environments/<env>/`, not in module defaults.
- Placeholder modules must keep an explicit README contract until implemented or removed.
