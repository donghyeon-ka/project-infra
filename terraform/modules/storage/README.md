# storage Terraform Module

Contract:
- Owns reusable storage resources only.
- Must expose inputs and outputs before an environment depends on it.
- Must not contain environment-specific values.
- Replace this contract with Terraform files when the module is implemented.
