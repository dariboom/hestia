# modules/sustainability

This module publishes the grid carbon-intensity signal for one `live/<env>/<region>` stack (ADR-008). It creates:

- a collector Lambda `hestia-<env>-<rc>-carbon-signal`, run every 15 minutes by EventBridge Scheduler;
- per bidding zone (`DE-LU`, `FR`), in this region:
  - the CloudWatch metric `Hestia/Carbon` `GridIntensity`, dimension `zone`, in gCO2e/kWh;
  - SSM String `/hestia/<env>/carbon/<zone>/current`: `{"gco2e_per_kwh", "at", "source", "factors"}`;
  - SSM String `/hestia/<env>/carbon/<zone>/best_window`: `{"start", "end", "gco2e_per_kwh"}`, the lowest-intensity window of `best_window_hours` in the next 24 h;
- `signal_read_policy_json`, a read-only policy that carbon-aware batch CronJobs get through `modules/compute/irsa-role`.

Both regions run their own collector, so each region's SSM holds both zones and a batch job reads its own region only.

## How the signal is computed

- **Current:** the newest slot of ENTSO-E actual generation per production type (A75, last 3 h). Pumped-storage consumption series are ignored.
- **Factors:** `EMISSION_FACTORS` in `src/carbon_signal/handler.py`, life-cycle medians from IPCC AR5 WG3 Annex III (Table A.III.2). Types without an IPCC median carry a Hestia estimate, marked `est.` in the code. Unknown types count as "Other" (700, conservative).
- **Forecast:** ENTSO-E forecasts only total generation (A71) and wind/solar per type (A69). The rest of each forecast slot is assumed to keep the intensity of the current non-wind/solar mix.
- **Fail open:** if the forecast fails, `current` is still written and `best_window` keeps its last value. Batch jobs treat a signal older than 1 h as missing and run anyway (ADR-008).
- A zone that fails does not stop the other one. The run then ends in error, so the failure shows in the Lambda `Errors` metric.

## Guarantees

- **Region lock:** `region` must be `eu-central-1` or `eu-west-3`, and a precondition rejects a provider region that differs from it.
- **No secret in Terraform:** only `entsoe_token_secret_arn` is passed. The Lambda reads the token from Secrets Manager at run time and never logs it or the request URL.
- **Outside the VPC (ADR-008):** the collector calls only the public ENTSO-E API and regional AWS APIs and touches no VPC data, so it needs no NAT path. This deviates from the plan's Task 17 text (private subnets plus NAT); ADR-008 wins.
- **Least privilege:** the Lambda role may read the one secret, decrypt it only through Secrets Manager, write logs to its own group, write `/hestia/<env>/carbon/*`, and put metrics only in the `Hestia/Carbon` namespace. The Scheduler role may invoke only this function. Both roles carry the `hestia-<env>-boundary` permissions boundary.
- **Encryption:** environment variables and the schedule use `kms_key_arn`; the log group uses `log_kms_key_arn`.
- **One run at a time:** reserved concurrency is 1. Scheduler retries twice within 10 minutes; after that the next run supersedes the missed one.

## Building the package

The module takes a zip instead of building it, so Terraform needs no `archive` provider. CI builds it before plan:

```sh
zip -qjX build/carbon_signal.zip terraform/modules/sustainability/src/carbon_signal/handler.py
```

`-X` drops file metadata, so the same source gives the same hash and no spurious update. The handler uses only the standard library and the runtime's `boto3`.

Run the unit tests (no network, no AWS):

```sh
cd terraform/modules/sustainability/src/carbon_signal && python3 -m unittest
```

## Keys and secret required

- `entsoe_token_secret_arn`: a secret under `hestia/` in the same region, created and filled out-of-band (`docs/secrets-handling.md`).
- `secrets_kms_key_arn`: the key that encrypts it.
- `kms_key_arn`: its key policy must let the Lambda role use the key for the environment variables (`kms:EncryptionContext:LambdaFunctionName`) and let `scheduler.amazonaws.com` use it.
- `log_kms_key_arn`: the key policy must allow `logs.<region>.amazonaws.com`, with the `kms:EncryptionContext:aws:logs:arn` condition.

## Example

```hcl
module "sustainability" {
  source = "../../../modules/sustainability"

  region                  = "eu-central-1"
  environment             = "prod"
  package_path            = "${path.root}/../../../build/carbon_signal.zip"
  entsoe_token_secret_arn = "<APP_API_KEY_SECRET_ARN>"
  secrets_kms_key_arn     = module.kms_secrets.key_arn # modules/kms-key
  kms_key_arn             = module.kms_compute.key_arn
  log_kms_key_arn         = module.kms_logs.key_arn
}

# A carbon-aware batch CronJob reads the signal through IRSA.
module "batch_irsa" {
  source = "../../../modules/compute/irsa-role"

  name                     = "hestia-prod-de-batch"
  policy_json              = module.sustainability.signal_read_policy_json
  permissions_boundary_arn = "arn:aws:iam::<AWS_ACCOUNT_ID>:policy/hestia-prod-boundary"
  oidc_provider_arn        = module.eks.oidc_provider_arn
  namespace                = "batch"
  service_account          = "renovation-batch"
}
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `region` | string | required | `eu-central-1` or `eu-west-3`. |
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | |
| `package_path` | string | required | Collector `.zip`; see above. |
| `entsoe_token_secret_arn` | string | required | Secret ARN under `hestia/`, in DE or FR. Not a value. |
| `secrets_kms_key_arn` | string | required | Key ARN, not an alias. |
| `kms_key_arn` | string | required | Key ARN for environment variables and the schedule. |
| `log_kms_key_arn` | string | required | Key ARN for the log group. |
| `log_retention_days` | number | `365` | CloudWatch value ≤ 400. Logs hold no personal data. |
| `best_window_hours` | number | `4` | Whole hours, 1 to 12. |

## Outputs

| Name | Description |
|---|---|
| `function_arn` | Collector Lambda. |
| `signal_parameter_path` | `/hestia/<env>/carbon`. |
| `signal_read_policy_json` | `ssm:GetParameter(s)` and `GetParametersByPath` on the signal path, for `irsa-role`. |

## Static checks

- checkov: four inline skips on the Lambda, each justified in the code.
  - `CKV_AWS_117`: outside the VPC by design (ADR-008).
  - `CKV_AWS_116`: no DLQ; Scheduler retries and the next run supersedes a missed one.
  - `CKV_AWS_50`: no X-Ray, which needs `Resource "*"`.
  - `CKV_AWS_272`: no code signing; the code is built from this repository.
- conftest: `no-wildcard-iam` passes with one listed exception, `PutCarbonMetric` (`cloudwatch:PutMetricData` has no resource-level permissions; scoped by namespace).
- gitleaks: clean. No account IDs except the synthetic `000000000000` in scratch fixtures.
- `terraform validate`: run against scratch roots. A valid DE case passes. An invalid case is rejected: region `us-east-1`, a `.tar.gz` package, a secret outside `hestia/` in us-east-1, a KMS alias, 3650-day retention and a 24 h window. The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
