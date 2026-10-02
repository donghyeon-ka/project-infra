# Terraform Environments

Each environment directory is a root module boundary.

Contract:
- `dev`, `staging`, and `prod` use the same entry pattern.
- Environment roots may compose shared modules and set environment-specific values.
- Environment roots must not duplicate reusable module internals.
