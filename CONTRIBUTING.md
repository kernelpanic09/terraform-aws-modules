# Contributing

Pull requests are welcome. This is a personal portfolio project, so if you're planning something bigger than a bug fix or small improvement, please open an issue first so we can discuss the approach.

## Dev setup

You'll need Terraform 1.5+ and the AWS CLI. No real AWS account is needed just to work on module structure, but you'll want one for `terraform plan` output.

```bash
# Validate module structure (no AWS calls)
cd modules/<name>
terraform init
terraform validate

# Run examples (requires AWS credentials)
cd examples/<name>
cp terraform.tfvars.example terraform.tfvars
# fill in real values
terraform init
terraform plan
```

Variable validation catches most mistakes at `plan` time. If a variable has a `validation` block, expect a clear error message rather than a cryptic AWS API error.

When adding a new module:

1. Create `modules/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`, and `README.md`
2. Add a matching example under `examples/<name>/`
3. Add a row to the module table in the root `README.md`
4. Add the module name to the `validate` and `tflint` job matrices in `.github/workflows/ci.yml` (the CI matrix is not auto-discovered, so a module left out of it is never validated or linted)

## Commit style

This repo follows [Conventional Commits](https://www.conventionalcommits.org/). Examples:

- `fix: correct confused-deputy condition in bedrock-knowledge-base`
- `feat: add secrets-manager module`
- `docs: add cross-region replica example for rds-aurora`
- `chore: bump aws provider minimum to 5.50`
