# ADR-005: Global AWS services, `us-east-1` exceptions, and EU data residency

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-003, ADR-007

## Context

All personal data, derived analytics, logs, backups and audit records must stay in the EU. Hestia deploys only to `eu-central-1` and `eu-west-3`.

Some AWS services are **global**: their control plane, and sometimes their configuration data, lives outside these regions, typically in `us-east-1`. We must state exactly what leaves the EU and how we compensate.

## Decision

### 1. Global services we use, and what metadata they hold

| Service | Why needed | Metadata outside the two EU regions | Personal data? | Compensating measures |
|---|---|---|---|---|
| **IAM / STS** (global) | Identity for everything | Role, policy and user names; policy documents | No. Naming rules forbid personal data in IAM names and tags. | No IAM users for humans (federated SSO). CloudTrail records IAM events into the DE trail. Regional STS endpoints are used. |
| **Route 53** (global; control plane in `us-east-1`) | Public and private DNS, health checks | Zone names, record names and values (ALB DNS names), health check configuration | No. Record names never contain tenant or person identifiers. | Records point to EU ALBs only. DNS query logging, if enabled, goes to DE CloudWatch Logs. |
| **AWS Organizations, SCPs** | Region lock, guardrails | Account names, OU structure, policy text | No | — |
| **Billing / Cost Explorer / BCM Data Exports** (control plane in `us-east-1`) | Per-tenant cost and carbon attribution (ADR-008) | Usage line items, resource IDs, tag values | No. Tag values are pseudonymous tenant IDs, never names. | Export *data* is delivered to a DE S3 bucket. |
| **CloudFront**, optional and **off by default** | Caching only for the anonymized public dashboard | Distribution configuration; edge caches of *anonymized, public* content; TLS terminated at the edge nearest the viewer | No. Only public, anonymized aggregates are routed through CloudFront. | `enable_cloudfront = false` by default. When on: `PriceClass_100`, EU/EEA geo-restriction by default, no cookie or auth-header forwarding, logs to DE. |
| **ACM in `us-east-1`** and **WAF with CLOUDFRONT scope** | Required by CloudFront | Certificate SANs (public hostnames), WAF rule configuration | No | Created only when `enable_cloudfront = true`. Each such resource carries the code comment `# ADR-005 exception`. |

### 2. Public ingress for personal-data flows avoids CloudFront

Tenant portal and API traffic, which carries personal data, terminates TLS on **regional ALBs** in DE or FR, protected by a **regional WAFv2** web ACL. Route 53 only resolves names; it never sees payloads.

### 3. CloudTrail captures global events in the EU

The multi-region trail is homed in `eu-central-1` with `include_global_service_events = true`. Audit records for IAM, Route 53 and the other global services are therefore stored in the DE WORM bucket.

### 4. The allowed `us-east-1` exceptions are closed and enforced

The list is: ACM, WAF CLOUDFRONT scope, CloudFront, and BCM Data Exports. It is enforced by the Rego policy `region-lock.rego` and by the SCP NotAction list (ADR-007). Anything else in `us-east-1` fails policy.

## AWS European Sovereign Cloud

The AWS European Sovereign Cloud is a separate AWS partition with its first region in Brandenburg, Germany. It is operated by EU-resident personnel and keeps its own metadata (IAM, billing) in the EU. It would remove most of the residuals in the table above.

It is **out of scope** for this repository, because the brief allows only `eu-central-1` and `eu-west-3`. It is the documented migration path if a national doctrine requires it, for example a SecNumCloud-style qualification for French public-sector tenants.

The EKS choice (ADR-001) and the module design avoid partition-specific hard-coding, so a move there is mostly a provider change. Module code must use `data.aws_partition` and never hard-code `arn:aws:`.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| CloudFront in front of everything | TLS for personal-data traffic would terminate at edges that may be outside the EU, for non-EU viewers or through routing anomalies. |
| Self-hosted DNS in the EU | Gives up Route 53 health-check failover (ADR-003) for marginal benefit: DNS metadata is not personal data. |

## Consequences

- No personal data enters any global service, *provided* the naming and tagging rules hold. Those rules are enforced by Rego (`gdpr.rego`) and by code review.
- The public dashboard is served from the regional ALB unless CloudFront is explicitly enabled.

## Compliance impact

- **GDPR Chapter V (international transfers):** no transfer of personal data. The residual metadata is non-personal.
- **EU Data Act:** data location is documented and exports are EU-hosted.
