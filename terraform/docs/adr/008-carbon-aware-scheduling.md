# ADR-008: Carbon-aware scheduling and carbon accounting

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-001, ADR-005

## Context

Hestia must measure and minimize its own footprint:

- carbon-aware scheduling of batch workloads (EPC normalization, MRV analytics, nightly aggregates);
- per-tenant carbon attribution;
- an automated report on its own data-centre energy and water use, aligned with EED Article 12;
- a public carbon label showing the carbon cost of user queries.

## Decision

### 1. Grid signal

- **Source:** the **ENTSO-E Transparency Platform**, operated by the European Network of Transmission System Operators. It is EU-run, so the signal source is sovereign.
- **Collector:** a Lambda in each region, triggered every 15 minutes by EventBridge Scheduler. It fetches generation per production type for bidding zones **DE-LU** and **FR** and computes gCO2e/kWh from per-fuel emission factors. The factor table and its source citation live in code.
- **Outputs:**
  - CloudWatch metric `Hestia/Carbon` `GridIntensity{zone}`;
  - SSM `String` parameters `/hestia/<env>/carbon/<zone>/current` and `.../best_window` (lowest-intensity window in the next 24 h).
- **Credential:** the ENTSO-E API token lives in Secrets Manager. The Lambda reads it at run time by ARN, and no value is ever stored in Terraform.
- **Network:** the collector Lambda needs no VPC access, so it runs **outside the VPC**. This avoids a NAT dependency and an open egress path (`hestia-89g.23` item 5).

### 2. Scheduling

Batch CronJobs read the SSM signal through IRSA and choose:

- **Time shifting:** run inside `best_window` if that is before the job's deadline; otherwise run now.
- **Region shifting:** run in the lower-intensity region (DE or FR). Both are EU regions, so residency is unaffected. Region shifting applies only to jobs that are read-only against the database replica, or that write to region-local scratch storage.

### 3. Attribution

- Cost allocation tags `hestia:tenant` and `hestia:workload` are activated.
- **BCM Data Exports** produce CUR 2.0 with EKS split cost allocation data, plus AWS carbon emissions data. Both are delivered to a DE S3 bucket; ADR-005 covers the `us-east-1` control plane.
- Athena queries allocate emissions to tenants by cost share.

### 4. EED Article 12 report

- **Legal scope:** EED Article 12 obligations fall on **data-centre operators** above the 500 kW threshold. For Hestia's footprint that operator is AWS. Hestia's monthly report is therefore a **voluntary, Article-12-aligned disclosure**.
- **Contents:** AWS Customer Carbon Footprint Tool data, combined with AWS-published regional PUE/WUE figures. Those figures are input variables with a source URL, never invented. The report lands in the audit bucket.

### 5. Query carbon label

Coefficients (gCO2e per vCPU-second and per GB scanned, per region) are published as SSM `String` `/hestia/<env>/carbon/label-coefficients`. The dashboard application multiplies them by per-query resource metrics. The label rendering is application code and out of scope here.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Electricity Maps / WattTime | Good APIs, but commercial and non-EU-operated. ENTSO-E is the primary EU source. A fallback provider can be added behind the same SSM interface. |
| Embedding the signal in Kubernetes (KEDA scaler) | Couples the signal to one cluster. SSM plus CloudWatch is consumable by Kubernetes, Lambda and humans alike. |

## Consequences

- Batch jobs gain a scheduling dependency on the SSM signal. If the signal is stale (older than 1 h), jobs **fail open** and run immediately, so deadlines are never missed.
- Emission factors are estimates. Reports state their methodology and uncertainty.

## Compliance impact

- **CSRD / ESRS E1:** own-operations emissions data.
- **EED Art. 12:** voluntary alignment, with the legal scope stated correctly.
- **AI Act transparency:** not applicable to this component.
