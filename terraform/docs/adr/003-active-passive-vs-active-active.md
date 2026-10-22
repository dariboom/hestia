# ADR-003: Active-passive writes with active-active portal reads (DE primary, FR hot standby)

- **Status:** Accepted (one open question, see the end of this ADR)
- **Date:** 2026-10-22
- **Related:** ADR-004, ADR-006

## Context

- Subsidy programmes (MaPrimeRénov', KfW 261/458, Eco-PTZ, EU programmes) have hard application deadlines, so an outage close to a deadline harms citizens.
- Subsidy and green-bond records need an unambiguous, audit-grade history: one authoritative order of writes.
- The tenant-facing portal is read-heavy: logbooks, roadmaps, dashboards.
- Frankfurt–Paris round-trip latency is low, in the order of 10 ms.

## Decision

**Writes are active-passive. Reads are active-active.**

| Layer | DE (`eu-central-1`) | FR (`eu-west-3`) |
|---|---|---|
| RDS PostgreSQL | Primary, Multi-AZ | Cross-region **read replica**, itself Multi-AZ, encrypted with an FR KMS key |
| EKS / app | Serves reads and writes | Serves reads locally; sends writes to the DE writer over VPC peering (ADR-006) |
| Public DNS `portal.<domain>` | Latency-based record + health check | Latency-based record + health check |
| Public DNS `api.<domain>` (write path) | Failover PRIMARY | Failover SECONDARY |
| S3 (audit, backups) | Source | Replica via S3 CRR, only where enabled per environment (ADR-005) |

**Failover procedure.** It is human-triggered and documented in `docs/runbook.md`.

1. **Automatic.** When DE health checks fail, Route 53 moves `portal` and `api` traffic to FR. FR runs in **read-only degraded mode**: the replica is readable, and writes return a maintenance response. No data diverges.
2. **Manual.** An operator confirms the DE outage and promotes the FR replica. Promotion is irreversible for that replica. The operator then flips FR to read-write and scales FR node groups to prod capacity.
3. **Failback.** Re-seed DE as a replica of FR, cut over in a maintenance window, and restore the original roles.

Promotion is never automatic. An automatic promotion during a network partition would produce two writers (split brain) and break audit-trail integrity.

**Targets (prod):**

| Metric | Target |
|---|---|
| RPO | Replica lag at failure, normally seconds; alarm at > 60 s |
| RTO for reads | Minutes (DNS failover) |
| RTO for writes | ≤ 1 h (human promotion) |

## Alternatives considered

| Option | Why not chosen |
|---|---|
| **Full active-active, multi-writer** (Aurora Global Database write forwarding, or app-level sharding by country) | Aurora's write forwarding still has one writer region, and true multi-master needs conflict resolution. Conflicting subsidy or disbursement records are unacceptable for audit, and the brief mandates RDS PostgreSQL. |
| **Active-passive with a cold or pilot-light FR** | Cheaper, but recovery takes too long near a subsidy deadline, and the portal loses its local FR read path. |
| **Shard by country** (DE data in DE, FR data in FR) | Attractive for residency optics, but both regions are in the EU so this adds no legal benefit. It costs complexity: cross-border buildings, consortium-wide dashboards. Revisit if a national doctrine (e.g. SecNumCloud) mandates it. |

## Consequences

- **Positive:**
  - One authoritative write order.
  - FR users get low-latency reads.
  - Failover is safe because a human gates it.
- **Negative:**
  - FR writes take a cross-region hop.
  - FR capacity is paid for continuously (hot standby).
  - Write RTO depends on on-call response.
- **Mitigations:**
  - Quarterly DR drills (runbook).
  - Replica lag alarm.
  - Read-only degraded mode keeps the portal useful during an incident.

## Compliance impact

- **NIS2 Art. 21 (business continuity):** multi-region, tested failover.
- **EU Taxonomy / CSRD, green-bond audit:** a single writer keeps a single, linear audit history.
- **GDPR:** both regions are in the EU; replication stays inside the EU.

## Open question

The `fr` stack must stay plannable when DE is down, because promotion is a Terraform change in the `fr` root. This means `fr` must not read DE-hosted SSM parameters at plan time; instead it builds the DE source DB ARN deterministically from `account_id` and the naming convention. Tracked in stress-test bead `hestia-89g.23`, item 1. It must be resolved before T19 (`live/dev`) is implemented.
