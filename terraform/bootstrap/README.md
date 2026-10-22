# Bootstrap

One-time, per-account setup that everything else depends on (ADR-004). Run it once for each of
dev, staging and prod, in that environment's account.

| Creates | Purpose |
|---|---|
| `hestia-<env>-{de,fr}-tfstate-<AWS_ACCOUNT_ID>` S3 buckets + KMS keys | Terraform state, one per region |
| GitHub Actions OIDC provider | CI authenticates without long-lived keys |
| `hestia-<env>-tf-deploy` role | plan/apply, only from GitHub environment `<env>` |
| `hestia-<env>-tf-readonly` role | reads state, only from GitHub environment `<env>-readonly` |
| `hestia-<env>-boundary` policy | permissions boundary for every role CI creates |

Only humans run bootstrap, from a workstation, with an admin or break-glass role. CI cannot
modify the roles or boundary created here: the boundary explicitly denies it.

> **Static validation only in this repository.** Agents and CI validation jobs never run
> `plan`/`apply`/`state` here. The commands below are the operator runbook for a human with
> authorised access to the target account.

## Prerequisites

- Terraform >= 1.10, which the S3-native lockfile (`use_lockfile`) needs. `make validate` needs it too.
- An authenticated admin session for the target account. Credentials come from your SSO or
  identity tooling; never put them in files, tfvars or shell history.
- Inputs, supplied as environment variables. Do not commit tfvars that contain the account ID:
  ```bash
  export TF_VAR_account_id=<AWS_ACCOUNT_ID>
  export TF_VAR_environment=dev
  export TF_VAR_owner=<OWNER_TEAM>
  export TF_VAR_cost_center=<COST_CENTER>
  export TF_VAR_github_org=<GITHUB_ORG>
  export TF_VAR_github_repo=<GITHUB_REPO>
  export TF_VAR_admin_role_arns='["arn:aws:iam::<AWS_ACCOUNT_ID>:role/<ADMIN_ROLE_NAME>"]'
  ```
  The admin roles must already exist, because KMS rejects key policies that name missing principals.

## 1. First apply (local state)

The state buckets don't exist yet, so the first run keeps its state on the operator's disk:

```bash
cd terraform/bootstrap
terraform init
terraform plan -out=bootstrap.tfplan    # review: 2 buckets, 2 keys, OIDC, 2 roles, boundary
terraform apply bootstrap.tfplan
rm -f bootstrap.tfplan
```

`*.tfstate` and `*.tfplan` are git-ignored. Never commit them, attach them to tickets or paste them.
The state holds the account ID and resource ARNs.

## 2. State migration

Move bootstrap's own state into the DE bucket, so the local copy isn't the only record:

```bash
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    bucket       = "<STATE_BUCKET_NAME>"      # output state_buckets.de
    key          = "<env>/bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    kms_key_id   = "<STATE_KMS_KEY_ARN>"      # output state_kms_key_arns.de
    use_lockfile = true
  }
}
EOF
terraform init -migrate-state
terraform plan                               # must report no changes
shred -u terraform.tfstate terraform.tfstate.backup
```

`backend.tf` holds only placeholders, so it is git-ignored for bootstrap. Fill it in locally. Don't
commit it with real values.

## 3. GitHub environments

In the repository settings, create the environments `<env>` and `<env>-readonly`. Add required
reviewers to `<env>`; for `staging` and `prod` there must be at least one person other than
the author. Store each role ARN (outputs `tf_deploy_role_arn`, `tf_readonly_role_arn`) as an
environment variable for `aws-actions/configure-aws-credentials`. The ARNs identify roles, they
aren't credentials, but they still never go into the repository.

## Live stack backend template

Every root under `live/<env>/<stack>/` declares the backend below. Values are placeholders that CI
fills from the bootstrap outputs with `terraform init -backend-config=...`:

```hcl
terraform {
  backend "s3" {
    bucket       = "<STATE_BUCKET_NAME>"   # de, peering, edge -> DE bucket; fr -> FR bucket
    key          = "<env>/<stack>/terraform.tfstate"
    region       = "<STATE_BUCKET_REGION>" # eu-central-1 or eu-west-3, matching the bucket
    encrypt      = true
    kms_key_id   = "<STATE_KMS_KEY_ARN>"
    use_lockfile = true                    # S3-native locking, no DynamoDB table (ADR-004)
  }
}
```

Cross-stack values are passed through SSM parameters under `/hestia/<env>/<region_code>/...`, not
`terraform_remote_state`, so a stack only needs read access to its own state.

## Provider lock files

Generate `.terraform.lock.hcl` for every platform CI and engineers use. A plain `init` records
hashes for the current platform only:

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 \
  -platform=darwin_amd64 -platform=darwin_arm64
```

## Roles created later

The deploy role may only create roles that carry the boundary. Every module that creates an IAM
role must set:

```hcl
permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:policy/hestia-${var.environment}-boundary"
```

## Teardown

Not automated. The state buckets hold every environment's state, so delete them only after
every live stack in the account has been destroyed, and only through break-glass.
