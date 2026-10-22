# ADR-001: EKS over ECS for the container platform

- **Status:** Accepted
- **Date:** 2026-10-22
- **Deciders:** Hestia platform team
- **Related:** ADR-003, ADR-005, ADR-008

## Context

Hestia runs several kinds of workload:

- a tenant-facing portal and APIs
- batch jobs: EPC normalization, MRV analytics, nightly aggregates
- AI-assisted renovation-roadmap and savings-prediction services (limited-risk systems under the EU AI Act)

All of them run in `eu-central-1` and `eu-west-3`. The platform is operated by a non-profit consortium. It is co-funded under EU programmes that emphasise digital sovereignty (EuroStack, Gaia-X alignment), and it must honour EU Data Act switching obligations. Those obligations require that customers, and Hestia itself, can move workloads and data to another provider without disproportionate effort.

Requirements from the platform brief:

- The control-plane API must be private only.
- Workloads must get AWS permissions without static credentials.
- Autoscaling must have explicit lower and upper bounds.
- Container logs go to CloudWatch Logs and are exported to EU-resident S3.
- IAM must be least privilege, with no undocumented wildcards.

## Decision

Use **Amazon EKS** with:

- `endpoint_private_access = true` and `endpoint_public_access = false`, hard-coded in the module and not exposed as a variable;
- **IRSA** (IAM Roles for Service Accounts) for every workload and add-on that calls AWS;
- **managed node groups** on Graviton (arm64) instances, with explicit `min_size` / `max_size`;
- Cluster Autoscaler, scoped by IAM tag conditions to its own cluster;
- EKS access entries (`authentication_mode = "API"`), not the legacy `aws-auth` ConfigMap;
- KMS envelope encryption for Kubernetes Secrets objects;
- all control-plane log types enabled.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| **ECS on Fargate** | Lower operational burden, and task roles are simple. But the task definitions, service discovery and scheduling model are AWS-proprietary, so a Data Act switch or a move to the AWS European Sovereign Cloud or an EU provider means re-platforming. ECS also has no native equivalent of Kubernetes NetworkPolicy, which we want for NIS2 east-west segmentation. |
| **ECS on EC2** | Same lock-in as Fargate, plus node management. |
| **EKS with Karpenter** | Better bin-packing and consolidation, which also helps the carbon goals. Deferred: managed node groups satisfy the explicit min/max requirement with less moving parts. Revisit once carbon attribution data exists (see ADR-008). |
| **EKS Pod Identity instead of IRSA** | Newer and simpler trust setup. The brief names IRSA explicitly, and IRSA is portable across EKS-compatible environments. Migration can be revisited later. |

## Consequences

- **Positive:**
  - Workload manifests are portable Kubernetes: Helm/Kustomize, CronJobs for batch, NetworkPolicies.
  - Carbon-aware batch scheduling maps to CronJobs that read the carbon signal (ADR-008).
- **Negative:**
  - More operational surface: cluster upgrades roughly every 12 months, add-on version management.
  - A per-cluster control-plane fee in each region and each environment.
- **Mitigations:**
  - Managed node groups and managed add-ons.
  - `cluster_version` is a required input, so every upgrade is an explicit, reviewed change.
  - The runbook documents the upgrade cadence.

## Compliance impact

- **NIS2 Art. 21 (segmentation, access control):** private API endpoint, NetworkPolicies, and IRSA per service account.
- **GDPR Art. 32:** KMS envelope encryption of Kubernetes Secrets; no static credentials.
- **EU Data Act (switching):** Kubernetes portability lowers the effort to switch providers.
