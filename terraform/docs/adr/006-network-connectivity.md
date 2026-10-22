# ADR-006: Inter-region VPC peering for private DE↔FR connectivity

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-003

## Context

Each environment has exactly one VPC in DE and one in FR. Private connectivity is needed for:

- FR application pods writing to the DE RDS writer (ADR-003);
- operational tooling: health probes, failover verification, DB administration from the active region.

None of this traffic may traverse the public internet.

## Decision

- Use **inter-region VPC peering**, one connection per environment, managed by `modules/network-peering` from `live/<env>/peering`.
- **Non-overlapping CIDRs:**

  | Environment | DE | FR |
  |---|---|---|
  | dev | `10.10.0.0/16` | `10.11.0.0/16` |
  | staging | `10.20.0.0/16` | `10.21.0.0/16` |
  | prod | `10.30.0.0/16` | `10.31.0.0/16` |

- **Routes** to the peer CIDR are added **only** to private and isolated route tables. A Terraform `precondition` rejects any public route table.
- **Security groups** allow only `allowed_ports` (default `5432`, `443`) from the peer CIDR.
- **DNS resolution** over the peering is enabled, so private hosted-zone names resolve across regions.

**Which path each flow actually uses:**

| Flow | Path |
|---|---|
| FR app → DE RDS writer | **VPC peering** |
| RDS cross-region read replica replication | AWS-managed, encrypted replication channel on the AWS backbone; **not** the peering |
| S3 Cross-Region Replication | AWS-managed S3 replication; **not** the peering |
| Ops / health probes between regions | **VPC peering** |

## Alternatives considered

| Option | Why not chosen |
|---|---|
| **Transit Gateway** with inter-region TGW peering | Hourly attachment and per-GB processing fees for just two VPCs. Its strengths (transitive routing, many VPCs, central inspection) aren't needed. Revisit if per-workload VPCs or on-prem links (e.g. national agency networks) appear. |
| **Site-to-site VPN over the internet** | Violates the "no public internet" requirement for the private path. |
| **PrivateLink only** | Unidirectional, service-specific, and awkward for PostgreSQL failover in both directions. |

## Consequences

- Peering is non-transitive. That is acceptable, and even desirable for segmentation.
- AWS encrypts inter-region peering traffic. Application traffic to RDS additionally enforces TLS (`rds.force_ssl = 1`).

## Compliance impact

- **NIS2 Art. 21 (network security, segmentation):** the private path, with routes limited to non-public tiers and port-scoped security groups.
- **GDPR Art. 32:** encryption in transit on every leg.
