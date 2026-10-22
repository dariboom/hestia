# modules/network-peering

This module peers one environment's DE VPC (eu-central-1, requester) with its FR VPC (eu-west-3, accepter) in the same account (ADR-006). The peering carries app → DE-writer traffic and ops tooling. RDS cross-region replication and S3 CRR use AWS-managed paths, not this connection.

## Guarantees

- **Regions:** a precondition requires `aws.de` = `eu-central-1` and `aws.fr` = `eu-west-3`.
- **No public routes:** before each route is created, the module reads the target route table. It rejects the table if any route points at an internet gateway (`igw-*`) or if the table belongs to a different VPC. It does not depend on a caller-supplied list of public tables, so a mistyped ID fails at plan time instead of exposing the peer.
- **Narrow ingress:** security group rules allow only TCP `allowed_ports` (default 5432, 443) from the peer VPC CIDR. They go only on the groups you list. There are no all-traffic rules.
- **DNS:** remote VPC DNS resolution is enabled on both sides, so RDS and endpoint hostnames resolve to private IPs across the peering.
- **Isolated tier:** the network module's isolated NACL already allows `peer_vpc_cidr`. Set it in both network roots to the other region's CIDR (see the CIDR plan in `modules/network/README.md`).

## The `peering` live root

Each environment has a third root, `live/<env>/peering`, next to `live/<env>/de` and `live/<env>/fr`. It configures both providers and calls this module once.

- **Order:** apply `de` and `fr` first, then `peering`. Destroy in reverse order.
- **State:** stored in the DE state bucket under the key `<env>/peering/terraform.tfstate`. If DE is down, the FR root still plans and applies on its own; only peering changes wait.
- **Inputs:** read from SSM `String` / `StringList` parameters that the regional roots publish. It never uses `terraform_remote_state`.

| SSM parameter (published by each regional root) | Type | Module input |
|---|---|---|
| `/hestia/<env>/<rc>/network/vpc_id` | String | `de_vpc_id`, `fr_vpc_id` |
| `/hestia/<env>/<rc>/network/vpc_cidr` | String | `de_vpc_cidr`, `fr_vpc_cidr` |
| `/hestia/<env>/<rc>/network/private_route_table_ids` | StringList | `de_route_table_ids`, `fr_route_table_ids` (concatenated with the isolated ones) |
| `/hestia/<env>/<rc>/network/isolated_route_table_ids` | StringList | `de_route_table_ids`, `fr_route_table_ids` (concatenated with the private ones) |
| `/hestia/<env>/<rc>/peering/ingress_security_group_ids` | StringList | `de_ingress_security_group_ids`, `fr_ingress_security_group_ids` |

`<rc>` is `de` or `fr`. These parameters hold IDs and CIDRs only, never secrets. Read them with `insecure_value`, because the provider marks `value` as sensitive, which would hide them in plan output for no reason.

```hcl
data "aws_ssm_parameter" "de" {
  provider = aws.de
  for_each = toset(["vpc_id", "vpc_cidr", "private_route_table_ids", "isolated_route_table_ids"])
  name     = "/hestia/${var.environment}/de/network/${each.key}"
}

# ...same for "fr" with provider = aws.fr, plus the peering/ingress_security_group_ids parameters

module "peering" {
  source    = "../../../modules/network-peering"
  providers = { aws.de = aws.de, aws.fr = aws.fr }

  environment = var.environment
  tags        = local.tags
  de_vpc_id   = data.aws_ssm_parameter.de["vpc_id"].insecure_value
  de_vpc_cidr = data.aws_ssm_parameter.de["vpc_cidr"].insecure_value
  de_route_table_ids = concat(
    split(",", data.aws_ssm_parameter.de["private_route_table_ids"].insecure_value),
    split(",", data.aws_ssm_parameter.de["isolated_route_table_ids"].insecure_value),
  )
  # fr_* likewise
}
```

## Inputs

| Name | Type | Default |
|---|---|---|
| `environment` | string, `dev`, `staging` or `prod` | required |
| `tags` | map(string) | `{}` |
| `de_vpc_id`, `fr_vpc_id` | string, `vpc-*` | required |
| `de_vpc_cidr`, `fr_vpc_cidr` | string, CIDR; the two must differ | required |
| `de_route_table_ids`, `fr_route_table_ids` | list(string), `rtb-*`, non-empty; private and isolated tables only | required |
| `de_ingress_security_group_ids`, `fr_ingress_security_group_ids` | list(string) | `[]` |
| `allowed_ports` | list(number) | `[5432, 443]` |

Providers: `aws.de` and `aws.fr`, passed through `providers = { ... }`.

## Outputs

`peering_connection_id`.

## Static checks

The module declares `configuration_aliases`, so it cannot be validated on its own. `examples/basic` is the validation root, and `make validate` skips the module directory itself. That example is never planned or applied.
