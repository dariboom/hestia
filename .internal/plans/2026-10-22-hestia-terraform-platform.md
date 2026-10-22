# Hestia AWS Terraform Platform (DE + FR) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use beads-superpowers:subagent-driven-development (recommended) or beads-superpowers:executing-plans to implement this plan task-by-task. Each Task becomes a bead (`bd create -t task --parent <epic-id>`). Steps within tasks use checkbox (`- [ ]`) syntax for human readability.

**Goal:** A production-grade, statically validated Terraform repository under `terraform/` that deploys Hestia's GDPR/NIS2-aligned platform to `eu-central-1` (DE, primary) and `eu-west-3` (FR, hot standby) for `dev`, `staging`, `prod`. It also ships the ADRs, runbook, compliance mapping and secrets matrix that a new engineer needs to operate it.

**Architecture:** Reusable modules (`terraform/modules/*`) are composed by directory-based live roots (`terraform/live/<env>/{de,fr,peering,edge}`). Each root has its own isolated state in the region it manages. Write traffic is active-passive: the RDS primary is in DE and a cross-region Multi-AZ read replica sits in FR. The tenant portal serves reads active-active from both regions via Route 53 latency routing. Writes always go to DE over inter-region VPC peering. Compliance is enforced in four layers: variable validation, provider guards, OPA/Rego policy-as-code and Organization SCPs.

**Tech Stack:** Terraform `>= 1.10` (S3-native state locking), AWS provider `~> 6.0`, EKS (private endpoint, IRSA, Graviton managed node groups), RDS PostgreSQL 17 Multi-AZ, S3 + SSE-KMS + Object Lock, GuardDuty / Security Hub / Config / CloudTrail, WAFv2, Route 53, Kinesis Data Firehose, Lambda (Python 3.12, carbon signal), BCM Data Exports + Athena, OPA/conftest, tflint, checkov, gitleaks.

## Global Constraints

- **Allowed regions:** `eu-central-1` (DE, home/primary) and `eu-west-3` (FR, standby). The only exception is `us-east-1`, and only for (a) ACM certs + WAF `CLOUDFRONT` scope when `enable_cloudfront = true`, and (b) the BCM Data Exports API control plane. Both exceptions are documented in ADR-005.
- **Every regional module** validates `contains(["eu-central-1","eu-west-3"], var.region)`.
- **NEVER run** `terraform plan|apply|destroy|import|state|refresh|test`, or any command that touches AWS or remote state. `terraform test` is excluded because it plans internally. Allowed: `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, `tflint`, `checkov`, `conftest`/`opa test` on HCL or synthetic fixtures, `gitleaks`.
- **No fake plan/apply output** anywhere. Rego test fixtures are minimal synthetic JSON, labelled `# SYNTHETIC FIXTURE`, and use the account ID `000000000000`.
- **No secret values anywhere**: no code, tfvars, defaults, outputs, docs, fixtures, CI or comments. Secrets are only Secrets Manager ARNs or SSM SecureString names. RDS uses `manage_master_user_password = true`. App secrets are created as Secrets Manager *containers without versions*; their values are set out-of-band.
- **Sensitive variables** (if any) have no default, `sensitive = true`, and the description says "injected by external CI/CD secret store".
- **Placeholders only:** `<AWS_ACCOUNT_ID>`, `<DB_PASSWORD_SECRET_ARN>`, `<APP_API_KEY_SECRET_ARN>`, `<SSM_PARAMETER_NAME>`, `<STATE_BUCKET_NAME>`. No real account IDs.
- **No hard-coded names:** names are derived as `local.name_prefix = "hestia-${var.environment}-${local.region_code}"` with `region_code = { eu-central-1 = "de", eu-west-3 = "fr" }`.
- **Mandatory tags** (validated): `hestia:environment`, `hestia:region`, `hestia:owner`, `hestia:cost-center`, `hestia:data-classification` (`public|internal|personal|special`), `hestia:tenant` (default `shared`), `hestia:workload`. Applied via provider `default_tags` plus module `tags`.
- **IAM:** no `"*"` action or resource unless listed in `terraform/policies/data/wildcard_exceptions.json` with a `justification`. The Rego policy enforces this.
- **Encryption:** every storage resource uses a customer-managed KMS key with `enable_key_rotation = true`. Every S3 bucket is versioned, uses SSE-KMS with a bucket key, blocks all public access, has BucketOwnerEnforced ownership, denies `aws:SecureTransport=false`, denies Put{BucketPolicy,BucketAcl,ObjectAcl} except to an allow-listed admin role, and has lifecycle rules.
- **Retention floors:** flow logs ≥ 90 d in prod, RDS backups ≥ 7 d (prod 35), CloudTrail/audit WORM ≥ 10 y in prod (subsidy and green-bond audit). Audit WORM uses Object Lock COMPLIANCE in prod and GOVERNANCE in dev/staging.
- **Environments:** directory-based, never workspaces (ADR-002). One AWS account per environment, pinned via the provider's `allowed_account_ids`.
- **State:** S3 backend with `use_lockfile = true` and SSE-KMS. Each regional root's state lives in a bucket *in its own region*, so FR failover never depends on DE (ADR-004).
- **Cross-stack data** flows through non-secret SSM `String` parameters under `/hestia/<env>/<region_code>/...`, never through `terraform_remote_state` (least privilege: consumers can't read whole state files).

---

## Key architecture decisions (each lands as an ADR in Task 1)

| ADR | Decision | Core rationale |
|---|---|---|
| 001 eks-vs-ecs | **EKS** (private endpoint, IRSA, managed Graviton node groups) | EU Data Act switching and EuroStack portability: Kubernetes workloads can move to the AWS European Sovereign Cloud or EU providers. The private API endpoint and IRSA are first-class. Batch and carbon-aware scheduling map naturally onto k8s CronJobs. Cost: more ops than ECS, mitigated by managed node groups and add-ons. |
| 002 directories-vs-workspaces | **Directories** `live/<env>/<stack>` | Isolated state, backend and account per env. Staging/prod diffs are readable. No accidental workspace mix-up. |
| 003 active-passive-vs-active-active | **Active-passive writes, active-active portal reads.** DE primary, FR cross-region Multi-AZ read replica. | Avoids multi-master conflicts on subsidy and financial records (an audit-trail integrity requirement). FR serves reads with low latency. Failover = promote the FR replica and flip the Route 53 failover record. RPO is replica lag (seconds); RTO target is ≤ 1 h. |
| 004 state-locking | **S3 native lockfile** (TF ≥ 1.10), per-region state bucket, versioned, KMS, no DynamoDB | DynamoDB locking is deprecated. Per-region buckets keep FR operable when DE is down. |
| 005 global-services-and-gdpr | **Route 53 + IAM** global by necessity. **CloudFront off by default.** Public ingress = regional ALB + regional WAF. CloudFront (+ us-east-1 ACM/WAF) only for the anonymized public dashboard, behind a toggle. | Lists exactly which metadata leaves the EU (DNS names, IAM principal names, cert SANs, billing metadata) and the compensations: no personal data in names or tags, CloudTrail captures global events in DE. Mentions the AWS European Sovereign Cloud as a future migration path. |
| 006 network-connectivity | **Inter-region VPC peering** (not TGW) | Only two VPCs per env, so TGW cost isn't justified. Traffic stays on the AWS backbone. States honestly that RDS cross-region replication and S3 CRR use AWS-managed paths, not the peering. Peering carries app→DE-writer traffic and ops tooling. |
| 007 policy-as-code | **Four layers:** variable validation → provider `allowed_account_ids` → OPA/conftest on HCL (CI) and plan JSON (human-run gate) → Organization SCPs | Each layer catches what the previous one can't. |
| 008 carbon-aware-scheduling *(new)* | Grid signal from the **ENTSO-E** Transparency Platform (EU-operated) via a Lambda in each region; batch jobs shift in time and between DE/FR within their deadline | Sovereignty: the signal source is EU-run. FR is often lower-carbon, and moving batch work there stays within the EU. |

**Flagged truths to surface in docs (not hidden):**
- EED Article 12 legally binds data-centre *operators* ≥ 500 kW (here, AWS). Hestia's report is a *voluntary, Article-12-aligned* disclosure built from CCFT data and AWS-published regional PUE/WUE.
- Object Lock WORM vs GDPR erasure: audit records hold only pseudonymous IDs. Retention rests on Art. 17(3)(b)/(e). Personal data lives in RDS/app buckets, where erasure is enforced by lifecycle/TTL. Backups bound the erasure window to the backup retention period.
- CloudTrail data events plus a multi-region trail homed in DE also capture us-east-1 global-service events. That keeps them EU-stored.

## Repository layout (locked in)

```text
terraform/
├── .tflint.hcl  .checkov.yaml  .gitignore  Makefile  conftest.toml  .pre-commit-config.yaml  .gitleaks.toml
├── bootstrap/                      # per-account state buckets (DE + FR), CI OIDC deploy role; local state, documented
├── org/                            # optional, run from the management account: SCP guardrails
├── modules/
│   ├── s3-bucket/                  # hardened bucket primitive (used everywhere)
│   ├── kms-key/                    # CMK primitive (rotation, restrictive policy)
│   ├── network/                    # VPC, 3x3 subnets, NAT modes, endpoints, flow logs
│   ├── network-peering/            # cross-region peering (two provider aliases)
│   ├── security/                   # KMS set, GuardDuty, Security Hub, Config, Access Analyzer, alerting, CloudTrail + WORM
│   ├── data/                       # RDS primary|replica, buckets, secret containers, CRR
│   ├── compute/                    # EKS, node groups, IRSA, add-ons, log pipeline
│   │   └── irsa-role/              # reusable least-privilege workload role
│   ├── edge/                       # global: Route 53 zones/records, optional CloudFront + us-east-1 ACM/WAF
│   │   └── regional/               # ALB, regional ACM, regional WAFv2
│   └── sustainability/             # carbon signal Lambda, cost/carbon exports, Athena, EED report, label coefficients
│       └── src/carbon_signal/      # Lambda source + unit test
├── live/{dev,staging,prod}/{de,fr,peering,edge}/   # main.tf backend.tf providers.tf variables.tf terraform.tfvars outputs.tf
├── policies/  gdpr.rego region-lock.rego no-wildcard-iam.rego  *_test.rego  data/wildcard_exceptions.json  fixtures/
├── docs/  architecture.md runbook.md compliance.md secrets-handling.md static-validation-checklist.md  adr/001..008
├── .github/workflows/static-validation.yml
└── README.md
```

**Apply order per env (documented in the runbook, executed only by humans):** `bootstrap` → `de` → `fr` → `peering` → `edge`.

---

### Task 1: Architecture decisions and architecture.md

**Files:** Create `terraform/docs/adr/001-eks-vs-ecs.md` … `008-carbon-aware-scheduling.md` and `terraform/docs/architecture.md`.

**Interfaces:** Produces the decision set above, which every module task cites.

**Acceptance Criteria:**
- 8 ADRs, each with Context / Decision / Alternatives considered / Consequences / Compliance impact sections. Content matches the decision table.
- `architecture.md` has: a Mermaid diagram (two regions, three subnet tiers, peering, edge), the active-passive justification, the data-flow table (what data lives where, how it replicates, which path), the global-service metadata exposure table, the failure modes and the RPO/RTO table.
- Contains no secrets and no real account IDs.

- [ ] Write ADRs 001–008
- [ ] Write architecture.md with Mermaid diagram
- [ ] Self-check: grep for 12-digit numbers and credential-like strings; expect none
- [ ] Commit

### Task 2: Repository skeleton, toolchain and static-validation harness

**Files:** Create `terraform/.gitignore` (`*.tfstate*`, `*.tfplan`, `.terraform/`, `crash.log`, `*.auto.tfvars.json`, `backend.hcl`), `.tflint.hcl` (aws ruleset, `terraform_naming_convention`, `terraform_documented_variables`, `terraform_typed_variables`), `.checkov.yaml`, `.gitleaks.toml`, `.pre-commit-config.yaml`, `Makefile`, `conftest.toml`.

**Interfaces:**
- `make fmt` → `terraform fmt -check -recursive`
- `make validate` → `terraform init -backend=false && terraform validate` per root and module
- `make lint`, `make checkov`, `make policy` (`opa test policies/` + `conftest test --parser hcl2`), `make secrets` (gitleaks), `make all`
- No target invokes plan, apply or any AWS-contacting command. The Makefile has a guard target that fails if `TF_CMD` contains `plan|apply|destroy|import|state|refresh|test`.

**Acceptance Criteria:**
- `make fmt` passes on the empty tree.
- The README "Prerequisites" lists exact tool versions: terraform ≥ 1.10, tflint, checkov, conftest, opa, gitleaks. **Local terraform is 1.5.7 and the other tools are missing. The user must install them; agents must not.**
- `.gitignore` blocks state, plan and backend-config files.

- [ ] Create the files
- [ ] Run `terraform fmt -check -recursive terraform/` (works on 1.5.7)
- [ ] Commit

### Task 3: Foundation primitives — `modules/s3-bucket` and `modules/kms-key`

**Files:** `terraform/modules/{s3-bucket,kms-key}/{main.tf,variables.tf,outputs.tf,versions.tf,README.md}`

**Interfaces:**
- `s3-bucket` inputs: `name` (string), `kms_key_arn`, `tags`, `lifecycle_rules` (list(object{id, prefix, transitions=list(object{days,storage_class}), expiration_days, noncurrent_expiration_days})), `object_lock` (object{mode = "COMPLIANCE"|"GOVERNANCE", days} or null), `policy_admin_role_arns` (list), `additional_policy_statements` (list(any) JSON), `access_log_bucket` (string or null), `force_destroy = false` (validated false when tags env=prod).
- `s3-bucket` outputs: `id`, `arn`, `domain_name`.
- `kms-key` inputs: `alias`, `description`, `tags`, `admin_role_arns`, `usage_role_arns`, `service_principals` (list(object{service, source_arn_like?})), `allowed_account_ids`, `deletion_window_in_days` (7–30, default 30).
- `kms-key` outputs: `key_arn`, `key_id`, `alias_arn`.

**Acceptance Criteria:**
- The bucket always gets: versioning; SSE-KMS with bucket key; all 4 public-access-block flags; BucketOwnerEnforced ownership; a deny-non-TLS statement; a deny on Put{BucketPolicy,BucketAcl,ObjectAcl} / DeleteBucketPolicy for principals not in `policy_admin_role_arns`; a deny on unencrypted PutObject or the wrong KMS key; and at least one lifecycle rule (validation fails on an empty list).
- The KMS key always has `enable_key_rotation = true` and no `kms:*` for `Principal:"*"`. Usage requires `aws:PrincipalAccount` ∈ `allowed_account_ids`. Service principals are scoped with `aws:SourceAccount`/`aws:SourceArn`. The root-account statement is limited to key administration, and its use is justified in a comment.
- `terraform validate` passes with `-backend=false`. checkov reports no failures, except documented skips.

- [ ] Implement the modules, then validate, lint and commit

### Task 4: Policy-as-code — region lock, no-wildcard IAM, GDPR

**Files:** `terraform/policies/{region-lock,no-wildcard-iam,gdpr}.rego`, `*_test.rego`, `data/wildcard_exceptions.json`, `fixtures/*.json` (synthetic).

**Interfaces:**
- Package `hestia.region`: `deny[msg]` on plan JSON (`input.configuration.provider_config.*.expressions.region` and `resource_changes[].change.after.region`) whose region ∉ {eu-central-1, eu-west-3}. Exception: `us-east-1` only for resource types `aws_acm_certificate`, `aws_wafv2_web_acl` with scope CLOUDFRONT, `aws_cloudfront_*`, `aws_bcmdataexports_export`.
- Package `hestia.iam`: deny `aws_iam_policy*` / `aws_iam_role_policy` / `data.aws_iam_policy_document` with `"*"` Action or Resource unless the `{resource_address, justification}` pair is in `wildcard_exceptions.json`.
- Package `hestia.gdpr`: deny S3 without SSE-KMS/versioning/PAB; RDS without `storage_encrypted` or with `publicly_accessible`; EKS with `endpoint_public_access = true`; CloudWatch log groups without `kms_key_id` or retention; missing `hestia:data-classification` tag; any variable named `*password*|*secret*|*token*|*api_key*` that has a default.
- Same packages run with `conftest --parser hcl2` for static HCL checks in CI.

**Acceptance Criteria:** `opa test policies/ -v` passes, with ≥ 1 allow and ≥ 1 deny case per rule. Fixtures are labelled synthetic and use `000000000000`.

- [ ] Write failing tests → rules → passing → commit (needs `opa` installed by the user; if missing, the bead stays open with a `blocked` note)

### Task 5: Bootstrap — state backend and CI deploy identity

**Files:** `terraform/bootstrap/{main.tf,variables.tf,outputs.tf,providers.tf,README.md}`, `terraform/live/*/*/backend.tf` template content.

**Interfaces:**
- Creates, per account and per region (DE + FR providers): a state bucket via `modules/s3-bucket` (no Object Lock, so lockfiles can be deleted; noncurrent versions kept 90 d) and a state KMS key via `modules/kms-key`.
- Creates the CI OIDC provider and `hestia-<env>-tf-deploy` role. The trust is limited to `repo:<ORG>/<REPO>:environment:<env>`.
- Creates `hestia-<env>-tf-readonly` for validate-only jobs.
- Backend blocks use `bucket = "<STATE_BUCKET_NAME>"`, `key = "<env>/<stack>/terraform.tfstate"`, `region` = the stack's own region (edge and peering → DE), `encrypt = true`, `use_lockfile = true`, `kms_key_id` = placeholder.
- Bootstrap itself uses local state, and the runbook documents migrating it into the bucket afterwards.

**Acceptance Criteria:** The deploy role's permissions are documented in `wildcard_exceptions.json` with a justification. The trust policy has no wildcard repo or branch. Validate passes.

### Task 6: Organization SCP guardrails (`terraform/org/`)

**Interfaces:** Input: `target_ou_ids`. SCPs:
1. Deny all actions where `aws:RequestedRegion` ∉ {eu-central-1, eu-west-3}, with NotAction exemptions for global services (iam, organizations, route53, route53domains, cloudfront, waf/wafv2 CLOUDFRONT, acm in us-east-1, sts, support, budgets, ce, cur, bcm-data-exports, health, trustedadvisor).
2. Deny `cloudtrail:StopLogging|DeleteTrail|UpdateTrail`, `guardduty:Delete*|Disassociate*`, `config:Stop*|Delete*`, `securityhub:Disable*`, `s3:PutBucketObjectLockConfiguration`, and `kms:ScheduleKeyDeletion` except for the break-glass role.
3. Deny `organizations:LeaveOrganization`.

**Acceptance Criteria:** Every exemption is commented with its reason. The README says this root is optional and runs from the management account by a human only. Validate passes.

### Task 7: `modules/network`

**Interfaces:**
- Inputs: `region`, `environment` (validated dev|staging|prod), `tags`, `vpc_cidr`, `public_subnet_cidrs`/`private_subnet_cidrs`/`isolated_subnet_cidrs` (each list of 3, validated), `nat_mode` ("per_az"|"single"; validation: prod ⇒ per_az), `flow_log_retention_days` (validation: prod ⇒ ≥ 90), `flow_log_bucket_kms_key_arn`, `peer_vpc_cidr` (nullable), `interface_endpoints` (default: ecr.api, ecr.dkr, sts, logs, kms, secretsmanager, ssm, ec2, elasticloadbalancing, eks, firehose).
- Outputs: `vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`, `isolated_subnet_ids`, `private_route_table_ids`, `isolated_route_table_ids`, `endpoint_security_group_id`, `flow_log_bucket_arn`.
- Isolated subnets have no internet route. A peering route to `peer_vpc_cidr` is added by `network-peering`, not here. The default SG has no rules. NACLs on the isolated tier allow only VPC + peer CIDR. The S3 gateway endpoint carries a policy restricted to the account's buckets. Flow logs (ALL traffic, parquet, hourly partitions) go to a `modules/s3-bucket` bucket with expiration = retention.

**Acceptance Criteria:** prod + `nat_mode = "single"` fails validation, and so does a region outside the allowlist. checkov passes. The README documents the CIDR plan: dev 10.10/10.11, staging 10.20/10.21, prod 10.30/10.31 (/16 each, DE/FR, non-overlapping).

### Task 8: `modules/network-peering` and the `peering` live-root pattern

**Interfaces:**
- Providers `aws.de`, `aws.fr` (configuration_aliases).
- Inputs: `environment`, `tags`, `de_vpc_id`, `fr_vpc_id`, `de_vpc_cidr`, `fr_vpc_cidr`, `de_route_table_ids`, `fr_route_table_ids` (private + isolated only, never public), `allowed_ports` (default [5432, 443]).
- Creates the requester (DE) and accepter (FR) with DNS resolution enabled, routes only on private/isolated tables, and SG rules referencing the peer CIDR on `allowed_ports` only.
- Outputs: `peering_connection_id`.
- Its inputs come from SSM parameters published by the de and fr roots.

**Acceptance Criteria:** No route added to a public route table (asserted with a `precondition` that table IDs ∉ public set). Validate passes.

### Task 9: `modules/security` — detective controls and incident alerting

**Interfaces:**
- Inputs: `region`, `environment`, `tags`, `home_region` (default eu-central-1, validated in allowlist), `alert_email_ssm_parameter_name` (address held in SSM, not hard-coded), `securityhub_standards` (default FSBP + CIS 3.0).
- Creates a GuardDuty detector with S3, EKS audit + runtime, RDS login and malware protection features. Creates Security Hub plus standards. When `region == home_region` it creates the finding aggregator (linked region = the other one) and a Config aggregator. Creates the Config recorder (all supported + global resources only in the home region), delivered to the audit bucket. Creates the IAM Access Analyzer. Routes EventBridge (GuardDuty sev ≥ 7, Security Hub CRITICAL/HIGH) to a KMS-encrypted SNS topic.
- Creates per-region KMS keys `data`, `logs`, `audit` via `modules/kms-key`.
- Outputs: `kms_key_arns` (map), `security_alerts_topic_arn`.

**Acceptance Criteria:** The non-home region creates no aggregators. The SNS topic is KMS-encrypted. Validate and checkov pass.

### Task 10: `modules/security` — CloudTrail and WORM audit store

**Interfaces:**
- Inputs: `audit_retention_days` (validation: prod ⇒ ≥ 3650), `object_lock_mode` (prod ⇒ COMPLIANCE), `cloudtrail_data_event_bucket_arns`, `audit_replication_destination_bucket_arn` (nullable; FR audit bucket).
- The audit bucket uses `modules/s3-bucket` with Object Lock, a lifecycle that moves to Glacier IR at 90 d and Deep Archive at 365 d, plus access logs.
- The multi-region trail is created only in `home_region`, with log file validation, KMS, CloudWatch Logs integration (KMS, retention) and S3 data events for the audit + data buckets.
- Outputs: `audit_bucket_arn`, `cloudtrail_arn`.

**Acceptance Criteria:** prod plus GOVERNANCE fails validation. The trail is `is_multi_region_trail = true` and `include_global_service_events = true`. Bucket policy grants are scoped by `aws:SourceArn` = the trail ARN.

### Task 11: `modules/data` — RDS PostgreSQL primary/replica

**Interfaces:**
- Inputs: `region`, `environment`, `tags`, `db_role` ("primary"|"replica"), `source_db_arn` (required iff replica), `instance_class`, `allocated_storage`/`max_allocated_storage`, `backup_retention_days` (validation ≥ 7; prod ≥ 14), `engine_version` (default "17"), `subnet_ids` (isolated), `allowed_security_group_ids`, `peer_cidr_blocks`, `kms_key_arn`, `enable_backup_replication` + `backup_replication_kms_key_arn`.
- Always on: `multi_az = true`, `storage_encrypted`, `manage_master_user_password = true` (primary; the secret is RDS-managed and KMS-encrypted), IAM DB auth, `deletion_protection = (environment == "prod")`, `publicly_accessible = false`. The parameter group sets `rds.force_ssl=1`, loads pgaudit and `log_connections`. Log exports go to CloudWatch with KMS and retention. Performance Insights and enhanced monitoring use KMS. The final snapshot is required in prod.
- Outputs: `db_instance_arn`, `db_endpoint`, `master_user_secret_arn` (ARN only), `db_security_group_id`.

**Acceptance Criteria:** No `password` argument appears anywhere. A replica without `source_db_arn` fails a precondition. Validate and checkov pass.

### Task 12: `modules/data` — buckets, secret references, cross-region replication

**Interfaces:**
- Inputs: `lifecycle` (object{artifacts, logs, backups} each with transition/expiration days; logs and backups have validated maxima as the GDPR erasure bound), `enable_cross_region_replication` (bool, default false), `replication_destination` (object{bucket_arn, kms_key_arn, region}; validated region ∈ allowlist and ≠ var.region), `app_secret_names` (list(string); creates `aws_secretsmanager_secret` containers only, KMS, no `aws_secretsmanager_secret_version`), `ssm_secure_parameter_names` (documented as created out-of-band; referenced by name only).
- Outputs: `bucket_arns` (map), `app_secret_arns` (map name→ARN).

**Acceptance Criteria:** The repository contains zero `aws_secretsmanager_secret_version` and zero `aws_ssm_parameter` of type SecureString with a `value` (Rego rule plus grep check). Replication uses a dedicated least-privilege role with a destination KMS key.

### Task 13: `modules/compute` — EKS cluster, node groups, IRSA

**Interfaces:**
- Inputs: `region`, `environment`, `tags`, `cluster_version` (default "1.33"), `private_subnet_ids`, `node_groups` (map(object{instance_types, capacity_type, min_size, max_size, desired_size, labels, taints}); validated 0 ≤ min ≤ desired ≤ max ≤ 50), `admin_principal_arns` (EKS access entries), `kms_key_arn`, `log_retention_days`.
- `endpoint_public_access = false` (hard-coded, not a variable), `endpoint_private_access = true`, secrets envelope encryption with KMS, all control-plane log types enabled, `authentication_mode = "API"`, IMDSv2 required with hop limit 1 in the launch template, encrypted EBS.
- Add-ons: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, amazon-cloudwatch-observability. Each one's IRSA role comes from `compute/irsa-role`.
- `compute/irsa-role` inputs: `name`, `oidc_provider_arn`, `namespace`, `service_account`, `policy_json`. The trust uses `StringEquals` on `sub` and `aud`.
- Cluster Autoscaler role scoped by the `k8s.io/cluster-autoscaler/<cluster>` tag condition.
- Outputs: `cluster_name`, `cluster_arn`, `oidc_provider_arn`, `cluster_security_group_id`, `node_security_group_id`.

**Acceptance Criteria:** No static credentials. Wildcard `Resource` appears only where AWS requires it (e.g. autoscaling Describe*), and each one is listed in `wildcard_exceptions.json`. Validate and checkov pass.

### Task 14: `modules/compute` — container log pipeline to EU-resident S3

**Interfaces:**
- CloudWatch log groups `/aws/containerinsights/<cluster>/application` and the control-plane group use KMS and `log_retention_days`.
- A subscription filter sends logs to a Kinesis Firehose (SSE with KMS), which delivers to an `s3-bucket` log-archive bucket (prefix by date, lifecycle Glacier IR 30 d, expire by input).
- Firehose has a least-privilege role.
- Inputs: `log_archive_kms_key_arn`, `log_archive_lifecycle`.
- Outputs: `log_archive_bucket_arn`.

**Acceptance Criteria:** Data stays in-region (the Firehose and the bucket are in `var.region`). Roles have no wildcards.

### Task 15: `modules/edge/regional` — ALB, regional ACM, regional WAF

**Interfaces:**
- Inputs: `region`, `environment`, `tags`, `public_subnet_ids`, `vpc_id`, `domain_name`, `hosted_zone_id` (for DNS validation), `waf_managed_rule_groups` (default: AWSManagedRulesCommonRuleSet, KnownBadInputs, SQLiRuleSet, AmazonIpReputationList), `rate_limit_per_5min`, `access_log_bucket`.
- Creates the ALB with HTTPS only (HTTP → 301), TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06`, drop invalid headers, deletion protection in prod, and access logs to S3. Creates a target group for the EKS LB Controller `TargetGroupBinding` and a WAF REGIONAL ACL with logging (KMS log group, redacted `authorization`/`cookie` fields).
- Outputs: `alb_arn`, `alb_dns_name`, `alb_zone_id`, `target_group_arn`, `alb_security_group_id`.

**Acceptance Criteria:** Validate passes. The WAF log configuration redacts auth headers.

### Task 16: `modules/edge` (global) — Route 53, optional CloudFront

**Interfaces:**
- Providers `aws` (DE) and `aws.us_east_1` (configuration_aliases; used only when `enable_cloudfront`).
- Inputs: `environment`, `tags`, `domain_name`, `internal_domain_name`, `vpc_associations` (list(object{vpc_id, region})), `enable_public_ingress` (bool), `regional_albs` (map(region → object{dns_name, zone_id})), `enable_cloudfront` (default false), `cloudfront_origin_paths` (anonymized dashboard only), `waf_rule_config`.
- Creates a private hosted zone associated with both VPCs. Public records:
  - `portal.<domain>`: latency routing DE/FR with health checks (active-active reads)
  - `api.<domain>`: failover routing, PRIMARY = DE, SECONDARY = FR
- When `enable_cloudfront`: ACM (us-east-1), WAF CLOUDFRONT (us-east-1), and a distribution with `price_class = PriceClass_100`, `geo_restriction` to EU/EEA by default, OAC, logging to the DE bucket, and no forwarding of cookies or auth headers.
- Outputs: `private_zone_id`, `public_zone_id`, `cloudfront_distribution_id` (nullable).

**Acceptance Criteria:** No us-east-1 resource exists when `enable_cloudfront = false`. Every us-east-1 resource carries the comment `# ADR-005 exception`. Validate passes.

### Task 17: `modules/sustainability` — carbon-intensity signal and carbon-aware scheduling

**Interfaces:**
- `src/carbon_signal/handler.py`: fetches ENTSO-E generation-mix data for bidding zones DE-LU and FR and computes gCO2e/kWh from per-fuel emission factors (a table in code with its cited source). It publishes the CloudWatch metric `Hestia/Carbon GridIntensity{zone}` and writes SSM String `/hestia/<env>/carbon/<zone>/current` plus the `best_window` (next 24 h forecast). The ENTSO-E token is read at runtime from the Secrets Manager secret named in env var `ENTSOE_TOKEN_SECRET_ARN`.
- `test_handler.py` holds pure-function tests for intensity math and window selection (stdlib unittest, no network).
- Terraform: Lambda (arm64, KMS env encryption, VPC private subnets with egress via NAT, reserved concurrency 1), EventBridge Scheduler every 15 min, an IRSA-readable policy so batch CronJobs can read `/hestia/<env>/carbon/*`.
- Inputs: `region`, `environment`, `tags`, `entsoe_token_secret_arn` (ARN, not sensitive value), `subnet_ids`.

**Acceptance Criteria:** `python3 -m unittest` passes locally. The ARN placeholder is `<APP_API_KEY_SECRET_ARN>` in examples. ADR-008 is referenced.

### Task 18: `modules/sustainability` — per-tenant carbon attribution, EED Art. 12 report, query carbon label

**Interfaces:**
- `aws_ce_cost_allocation_tag` activates `hestia:tenant` and `hestia:workload`.
- BCM Data Exports: CUR 2.0 with split cost allocation data for EKS, plus the carbon-emissions export. These exports go to a DE `s3-bucket` (ADR-005: the API control plane is us-east-1; the data lands in DE).
- Glue catalog plus an Athena workgroup (KMS results bucket, enforced config). Named queries: `tenant_carbon_monthly` (allocates CCFT emissions by tenant cost share) and `eed_art12_report`.
- An EventBridge Scheduler monthly Lambda (`src/eed_report/`) runs the queries and writes `reports/eed-art12/<yyyy-mm>.json` to the audit bucket. The output combines CCFT data with AWS-published regional PUE/WUE, provided as variables with a source URL.
- The label coefficients for the public dashboard carbon label (gCO2e per vCPU-second and per GB-scanned) are published as SSM String `/hestia/<env>/carbon/label-coefficients`.

**Acceptance Criteria:** The report states it is a *voluntary, Article-12-aligned* disclosure. The Lambda unit test passes. Roles have no wildcards beyond documented Athena/Glue exceptions.

### Task 19: Live environment `dev` (pattern-setting)

**Files:** `terraform/live/dev/{de,fr,peering,edge}/{main.tf,backend.tf,providers.tf,variables.tf,terraform.tfvars,outputs.tf}`

**Interfaces:**
- providers.tf: `required_version = ">= 1.10"`, aws `~> 6.0`, `allowed_account_ids = [var.account_id]` (tfvars holds `"<AWS_ACCOUNT_ID>"`), `default_tags`, and region from a validated local.
- `de` composes network → security (home) → data(primary) → compute → edge/regional → sustainability, then publishes SSM params `/hestia/dev/de/{vpc_id,vpc_cidr,private_rt_ids,isolated_rt_ids,alb_dns,alb_zone_id,db_arn}`.
- `fr` does the same with data(replica) reading `/hestia/dev/de/db_arn` via `data.aws_ssm_parameter` (cross-region provider alias).
- `peering` and `edge` read only SSM params.
- dev uses `nat_mode = "single"`, small instances, `enable_cross_region_replication = false`, and Object Lock GOVERNANCE.

**Acceptance Criteria:** `terraform init -backend=false && terraform validate` passes for all 4 roots. tfvars contain no secrets and only placeholders. conftest HCL passes.

### Task 20: Live environments `staging` and `prod`

**Acceptance Criteria:**
- Same 4 roots per env.
- prod: `nat_mode = "per_az"`, flow logs 365 d, RDS backups 35 d, deletion protection, Object Lock COMPLIANCE 3650 d, CRR enabled for audit + backups DE→FR, node groups min ≥ 2 per AZ-spread.
- staging mirrors prod topology with smaller sizes.
- `diff -r live/staging live/prod` shows only tfvars and backend keys (the readability check from ADR-002).
- All roots validate.

### Task 21: Operational and compliance documentation

**Files:** `terraform/README.md`, `docs/runbook.md`, `docs/compliance.md`, `docs/secrets-handling.md`, `docs/static-validation-checklist.md`

**Acceptance Criteria:**
- **README:** prerequisites (tool versions), repo map, a deploy-a-new-env walkthrough that never requires reading module internals, and the apply order.
- **runbook:**
  - bootstrap and state migration
  - human-only plan/apply procedure with a 4-eyes review
  - DE→FR failover: promote replica, flip the Route 53 failover record, scale FR nodes
  - failback: re-seed DE as a replica
  - DR drill cadence
  - NIS2 incident response (24 h early warning, 72 h notification, 1-month final report; BSI/ANSSI contacts as placeholders)
  - GDPR erasure procedure and erasure-window math
  - key rotation and secret rotation
  - carbon-aware batch operation
- **compliance.md:** a control matrix of regulation article → control → Terraform resource → file path, for GDPR, EPBD Art. 19/2a, NIS2 Art. 21, EU Taxonomy/CSRD, EED Art. 12, AI Act (transparency is app-level, so log model version to the audit bucket), Data Act (switching: open formats, k8s portability, export procedure). Also the WORM-vs-erasure reconciliation and the global-service metadata table.
- **secrets-handling.md:** the matrix (purpose | service | reference mechanism | IAM access path | runtime retrieval) for the RDS master, app API keys, ENTSO-E token, CI deploy (OIDC, no secret), and alert email (SSM). No values.
- **static-validation-checklist.md:** what a human must verify before any future plan/apply.

### Task 22: CI static-validation workflow and full validation pass

**Files:** `terraform/.github/workflows/static-validation.yml`. Note: a workflow under `terraform/.github` won't trigger GitHub; the README documents copying or symlinking it to the repo root, or Task 22 places it at the repo root `.github/` instead. Decide at implementation; default is the repo root.

**Interfaces:** Jobs fmt, validate (matrix over modules and roots, `-backend=false`), tflint, checkov, opa test + conftest (hcl2), gitleaks, and python unittest. No AWS credentials and no OIDC role in this workflow. `permissions: contents: read`.

**Acceptance Criteria:**
- `make all` passes locally once the user has installed the toolchain. Any tool not yet installed is reported as such, never claimed as passing.
- Final secret scan clean: gitleaks, plus grep for `AKIA`, 12-digit IDs, `BEGIN .*PRIVATE KEY`, and `password\s*=` with a literal value.

---

## Spec coverage map

| Spec item | Task(s) |
|---|---|
| 1.1 no plan/apply; static checklist | Global, 2, 21, 22 |
| 1.2/1.3 no secrets; refs only; sensitive vars; matrix | Global, 11, 12, 17, 21 |
| 2 two-region, A/P choice + justification | 1 (ADR-003), 11, 16, 19–20 |
| 3.1 region lock by code | 4, 6, every module validation |
| 3.2 EU sovereignty; global service explanation; ESC | 1 (ADR-005), 16, 18, 21 |
| 3.3 GDPR by design in code | 3, 4, 11, 12, 21 |
| 3.4 per-region VPC; private peering | 7, 8 |
| 3.5 directories | 1 (ADR-002), 19–20 |
| 4.1 network | 7 (+3) |
| 4.2 compute + logs to S3 | 13, 14 |
| 4.3 data | 11, 12 |
| 4.4 security & audit | 9, 10, 4, 6 |
| 4.5 edge | 15, 16 |
| 5 repo structure, ADRs 001–007, docs | 1, 2, 21 |
| Context: WORM audit | 10 |
| Context: NIS2 IR | 9, 21 |
| Context: carbon-aware scheduling | 17 |
| Context: per-tenant carbon, EED Art.12, carbon label | 18 |
| Context: AI Act, Data Act, EPBD, Taxonomy/CSRD | 21 (compliance mapping; app-level obligations noted) |

**Explicit cuts (surfaced, not silent):** Karpenter (use Cluster Autoscaler; revisit for carbon consolidation). Dedicated log-archive account (per-env account + Object Lock COMPLIANCE + SCP instead). Application code for the portal, MRV analytics and carbon-label rendering (infra only). `terraform test` with mock providers (excluded by the no-plan rule).
