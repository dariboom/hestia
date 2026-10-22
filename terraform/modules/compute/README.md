# modules/compute

This module holds the regional EKS platform for one `live/<env>/<region>` stack (ADR-001):

- a private EKS control plane named `hestia-<env>-<rc>-eks`;
- managed node groups;
- the core add-ons, each with its own IRSA role;
- an IRSA role for the Cluster Autoscaler, which the platform Helm release installs.

The `irsa-role/` submodule builds one IRSA role. Workloads use it for their own service accounts.

## Guarantees

- **Region lock:** `region` must be `eu-central-1` or `eu-west-3`. A precondition on the cluster rejects a provider region that differs from it.
- **Private API only:** `endpoint_public_access = false` and `endpoint_private_access = true` are hard-coded, not inputs. Operators reach the API from inside the VPC or its peer.
- **Secrets encryption:** Kubernetes Secrets are envelope-encrypted with the customer key `kms_key_arn`. Node root volumes and EBS CSI volumes use the same key.
- **Control-plane logs:** all five log types (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`) are on. They go to `/aws/eks/<cluster>/cluster`. The module creates that log group before the cluster, encrypted with `log_kms_key_arn` and kept for `log_retention_days` (≤ 400, the GDPR erasure bound). T14 ships from this group.
- **Access:** `authentication_mode = "API"`, so there is no `aws-auth` ConfigMap, and the cluster creator gets no implicit admin. Only the IAM roles in `admin_principal_arns` get `AmazonEKSClusterAdminPolicy`, through access entries. IAM users are rejected; humans come in through SSO roles.
- **No static credentials:** pods get AWS access only through IRSA.
  - The launch template enforces IMDSv2 with `http_put_response_hop_limit = 1`, so containers cannot reach the node role.
  - The node role has only `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryReadOnly`. `AmazonEKS_CNI_Policy` sits on vpc-cni's IRSA role instead.
- **IRSA roles** (`irsa-role/`):
  - The trust policy pins both `<issuer>:sub = system:serviceaccount:<ns>:<sa>` and `<issuer>:aud = sts.amazonaws.com` with `StringEquals`. Wildcard service accounts are rejected.
  - The permissions boundary `hestia-<env>-boundary` is mandatory, and names must start with `hestia-`.
  - The OIDC provider pins no thumbprint, because IAM validates EKS issuers against its own trusted CAs.
- **Every module role has a boundary:** the cluster, node and add-on roles all carry `hestia-<env>-boundary`. The cluster role trusts `eks.amazonaws.com` only from this account (`aws:SourceAccount`).
- **Add-ons:**

  | Add-on | When | IRSA role | Permissions |
  |---|---|---|---|
  | `vpc-cni` | with nodes | `<cluster>-vpc-cni` (`kube-system/aws-node`) | `AmazonEKS_CNI_Policy` |
  | `kube-proxy` | with nodes | none | |
  | `coredns` | after nodes | none | |
  | `aws-ebs-csi-driver` | after nodes | `<cluster>-ebs-csi` (`kube-system/ebs-csi-controller-sa`) | `AmazonEBSCSIDriverPolicy`, plus use of `kms_key_arn` and grants only for AWS resources |
  | `amazon-cloudwatch-observability` | after nodes | `<cluster>-cloudwatch` (`amazon-cloudwatch/cloudwatch-agent`) | `CloudWatchAgentServerPolicy` |

  Add-on versions are left to the EKS default for the cluster version.
- **Cluster Autoscaler** (`kube-system/cluster-autoscaler`):
  - `SetDesiredCapacity` and `TerminateInstanceInAutoScalingGroup` are allowed only on ASGs tagged `k8s.io/cluster-autoscaler/<cluster> = owned`. EKS sets that tag on managed node group ASGs.
  - `eks:DescribeNodegroup` is scoped to this cluster's node groups.
  - Only the read-only AutoScaling/EC2 Describe calls use `Resource "*"`, because they have no resource-level permissions. That statement (`AutoscalingDescribe`) is listed with a justification in `policies/data/wildcard_exceptions.json`, in both HCL and plan form.
  - Node groups ignore drift in `desired_size`, because the autoscaler owns it.
- **Node groups:** each group needs `0 ≤ min_size ≤ desired_size ≤ max_size ≤ 50`. Groups use the private subnets and gp3 root volumes, and roll with at most 33 % of nodes unavailable. Nodes carry the EKS cluster security group plus a rule-less identity group (`node_security_group_id`), which other stacks reference. For example, the data module's `db_allowed_security_group_ids` admits pod traffic into RDS.

## Key policies required

The module does not edit key policies. The security module's keys must allow:

- `kms_key_arn`: the EKS cluster role (Secrets), `AWSServiceRoleForAutoScaling` (encrypted root volumes) and EBS through grants;
- `log_kms_key_arn`: `logs.<region>.amazonaws.com`, with the `kms:EncryptionContext:aws:logs:arn` condition.

## Example

```hcl
module "compute" {
  source = "../../../modules/compute"

  region               = "eu-central-1"
  environment          = "prod"
  private_subnet_ids   = module.network.private_subnet_ids
  admin_principal_arns = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-prod-platform-admin"]
  kms_key_arn          = module.kms_compute.key_arn # modules/kms-key
  log_kms_key_arn      = module.kms_logs.key_arn

  node_groups = {
    general = { instance_types = ["m7i.large"], min_size = 3, max_size = 12, desired_size = 3 }
    batch = {
      instance_types = ["m7g.large"], ami_type = "AL2023_ARM_64_STANDARD", capacity_type = "SPOT"
      min_size       = 0, max_size = 10, desired_size = 0
      labels         = { workload = "batch" }
      taints         = [{ key = "batch", value = "true", effect = "NO_SCHEDULE" }]
    }
  }
}

# A workload role, e.g. the API reading its app secret at runtime.
module "api_irsa" {
  source = "../../../modules/compute/irsa-role"

  name                     = "hestia-prod-de-api"
  oidc_provider_arn        = module.compute.oidc_provider_arn
  namespace                = "hestia"
  service_account          = "api"
  policy_json              = data.aws_iam_policy_document.api.json # secretsmanager:GetSecretValue on <APP_API_KEY_SECRET_ARN>
  permissions_boundary_arn = "arn:aws:iam::<AWS_ACCOUNT_ID>:policy/hestia-prod-boundary"
}
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `region` | string | required | `eu-central-1` or `eu-west-3`. |
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | |
| `cluster_version` | string | `"1.33"` | `1.NN`. |
| `private_subnet_ids` | list(string) | required | At least two, from the network module's private tier. |
| `admin_principal_arns` | list(string) | required | IAM role ARNs, at least one. |
| `kms_key_arn` | string | required | Key ARN, not an alias. Used for Secrets and EBS. |
| `log_kms_key_arn` | string | required | Key ARN for the control-plane log group. |
| `log_retention_days` | number | `365` | CloudWatch value ≤ 400. |
| `node_groups` | map(object) | required | Fields: `instance_types`, `min_size`, `max_size`, `desired_size`, plus optional `ami_type` (`AL2023_x86_64_STANDARD`), `capacity_type` (`ON_DEMAND` or `SPOT`), `disk_size` (50 GiB, ≥ 20), `labels` and `taints` (`effect` is `NO_SCHEDULE`, `NO_EXECUTE` or `PREFER_NO_SCHEDULE`). |

`irsa-role/` inputs:

| Name | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | `hestia-*`, ≤ 64 chars. |
| `oidc_provider_arn` | string | required | |
| `namespace` | string | required | |
| `service_account` | string | required | Exact name, no `*`. |
| `policy_json` | string | `null` | Inline least-privilege policy. |
| `managed_policy_arns` | list(string) | `[]` | Only for add-ons whose permissions AWS maintains. |
| `permissions_boundary_arn` | string | required | Must be the `hestia-<env>-boundary` policy. |
| `tags` | map(string) | `{}` | |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | EKS cluster name. |
| `cluster_arn` | EKS cluster ARN. |
| `oidc_provider_arn` | IAM OIDC provider ARN, the input of `irsa-role/`. |
| `cluster_security_group_id` | EKS-managed cluster security group. |
| `node_security_group_id` | Worker-node identity security group. |
| `node_role_arn` | Worker-node IAM role ARN. |
| `cluster_autoscaler_role_arn` | IRSA role for the Cluster Autoscaler. |

`irsa-role/` outputs: `role_arn` and `role_name`.

## Static checks

- checkov: two inline skips.
  - `CKV_AWS_339`: the pinned checkov release predates EKS 1.33. `cluster_version` is validated and kept on a supported release.
  - `CKV2_AWS_5`: the node identity group is attached through the launch template, which checkov does not resolve.
- conftest: `no-wildcard-iam` passes only because of the `AutoscalingDescribe` exception. With that entry removed, it fails as expected.
- `terraform validate`: run against a scratch root, with a valid two-group case and an invalid `desired_size > max_size` case, which is rejected. `irsa-role/` was validated separately, with a valid case and a wildcard service account case, which is rejected. The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
