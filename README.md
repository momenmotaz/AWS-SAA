# CloudPulse — Scalable Web Application with ALB and Auto Scaling

**AWS Solutions Architect – Associate (SAA) · Graduation Project 1 (EC2-Based)**

> [النسخة العربية (README.ar.md)](README.ar.md)

CloudPulse is a production-style, multi-tier web application architected on **Amazon Web Services (AWS)** across two Availability Zones. All application compute (`Amazon EC2` inside an `Auto Scaling Group`) and relational storage (`Amazon RDS PostgreSQL Multi-AZ`) run inside isolated **private subnets**, behind **Amazon Route 53** *(optional)*, **Amazon CloudFront**, **AWS WAFv2**, and a Multi-AZ **Application Load Balancer (ALB)**. Administrative access is completely bastion-free via **AWS Systems Manager Session Manager**, with full observability through **Amazon CloudWatch** and **Amazon SNS**.

## Solution Architecture Diagram

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/architecture-dark.png">
  <img src="docs/architecture.png" alt="CloudPulse AWS Multi-AZ Architecture Diagram with official AWS icons and VPC CIDRs" width="100%">
</picture>

- **Editable Source (diagrams.net / draw.io):** [`docs/architecture.drawio`](docs/architecture.drawio)
- **Interactive Offline Preview (Light/Dark HTML):** [`docs/architecture.html`](docs/architecture.html)
- **High-Resolution PNGs:** [`docs/architecture.png`](docs/architecture.png) (Light) · [`docs/architecture-dark.png`](docs/architecture-dark.png) (Dark)

---

## Implemented vs. Optional Components

| Component | Status | Notes |
|---|---|---|
| **Multi-AZ VPC (`10.0.0.0/16`), 6 Subnets, IGW, 2x NAT GW, S3 VPC Endpoint, DB NACL** | **Implemented** | Core network deployed unconditionally in Terraform |
| **KMS CMK + Private Versioned S3 Artifact Bucket** | **Implemented** | Encrypts RDS storage, Secrets Manager secret, EBS volumes, and EC2 app releases |
| **ALB + Regional WAFv2 + Origin Protection (`X-CloudFront-Verify` + Prefix List)** | **Implemented** | Prevents direct-to-ALB bypass at both Security Group and ALB Listener levels |
| **EC2 Launch Template (`IMDSv2`) + ASG + Express/PostgreSQL App (`systemd`)** | **Implemented** | Pulls immutable S3 release, installs deps via `npm ci --omit=dev`, checks `/health` |
| **RDS PostgreSQL 16 Multi-AZ + Secrets Manager** | **Implemented** | Primary + synchronous Standby, advisory-locked DDL, TLS CA bundle verification |
| **Systems Manager Session Manager + CloudWatch Dashboard & 3 Alarms + SNS Topic** | **Implemented** | Zero-SSH admin access and automated scaling/alerting |
| **CloudFront Default HTTPS (`*.cloudfront.net`)** | **Implemented** | Works out-of-the-box without a custom domain |
| **Route 53 Alias + Edge Health Check + Custom ACM Certificates** | **Optional** | Enabled when `domain_name`, `hosted_zone_id`, and `cloudfront_acm_certificate_arn` (`us-east-1`) are supplied; `alb_acm_certificate_arn` enables end-to-end HTTPS origin |
| **SNS Email Subscription** | **Optional** | Created when `alert_email` is provided (requires email confirmation click) |

---

## Resource-to-Terraform-File Mapping

| AWS Resources / Responsibility | Terraform File |
|---|---|
| Provider (`~> 5.70`), default tags, AZ & AL2023 AMI lookups | [`infra/terraform/main.tf`](infra/terraform/main.tf) |
| Input variables & ARN/CIDR validation rules | [`infra/terraform/variables.tf`](infra/terraform/variables.tf) |
| VPC, Public/Private App/Private DB Subnets, IGW, 2x NAT Gateways, Route Tables, DB NACL | [`infra/terraform/vpc.tf`](infra/terraform/vpc.tf) |
| KMS CMK (`alias/cloudpulse-prod`), DB Subnet Group, Multi-AZ RDS PostgreSQL 16 + Secrets Manager | [`infra/terraform/rds.tf`](infra/terraform/rds.tf) |
| Private versioned KMS-encrypted S3 artifact bucket, TLS bucket policy, lifecycle rule, S3 Gateway Endpoint | [`infra/terraform/s3_artifacts.tf`](infra/terraform/s3_artifacts.tf) |
| ALB (`alb-sg`), App (`app-sg`), DB (`db-sg`) Security Groups, CloudFront prefix list, Least-Privilege EC2 IAM Role | [`infra/terraform/security.tf`](infra/terraform/security.tf) |
| Multi-AZ ALB, Target Group (`/health`), HTTP/HTTPS Listeners, `X-CloudFront-Verify` rules, Regional WAFv2 Web ACL | [`infra/terraform/alb_waf.tf`](infra/terraform/alb_waf.tf) |
| EC2 Launch Template (`IMDSv2`, encrypted `gp3` EBS), ASG (`min=2`, `desired=2`, `max=6`), Target Tracking & Step Scaling | [`infra/terraform/compute_asg.tf`](infra/terraform/compute_asg.tf) |
| EC2 bootstrap script (`aws s3 sync`, `npm ci --omit=dev`, RDS CA bundle, `Secrets Manager -> /etc/cloudpulse.env`, `systemd`) | [`infra/terraform/user_data.sh`](infra/terraform/user_data.sh) |
| CloudFront Distribution (`/static/*` cached, dynamic uncached, `X-CloudFront-Verify`), optional Route 53 Alias & Health Check | [`infra/terraform/edge_dns.tf`](infra/terraform/edge_dns.tf) |
| CloudWatch Dashboard, 3 Metric Alarms (`EC2 CPU`, `ALB 5xx`, `RDS CPU`), SNS Topic & Email Subscription | [`infra/terraform/observability.tf`](infra/terraform/observability.tf) |
| Stack outputs (endpoints, bucket, ASG, RDS, KMS, alarms) | [`infra/terraform/outputs.tf`](infra/terraform/outputs.tf) |

---

## VPC & Subnet CIDR Design

| Tier | Availability Zone A (`us-east-1a`) | Availability Zone B (`us-east-1b`) | Route Table / Internet Access |
|---|---|---|---|
| **VPC** | `10.0.0.0/16` | `10.0.0.0/16` | DNS hostnames & resolution enabled |
| **Public Subnets** | `10.0.1.0/24` | `10.0.2.0/24` | `0.0.0.0/0 -> Internet Gateway` (ALB + NAT Gateways) |
| **Private App Subnets** | `10.0.11.0/24` | `10.0.12.0/24` | `0.0.0.0/0 -> Same-AZ NAT Gateway` + S3 Gateway Endpoint (EC2 ASG) |
| **Private DB Subnets** | `10.0.21.0/24` | `10.0.22.0/24` | Local VPC route only — **zero internet egress** (RDS Multi-AZ) |

---

## Repository Structure

```text
.
├── README.md                      # Architecture & deployment documentation (English)
├── README.ar.md                   # Arabic overview & deployment guide
├── docs/
│   ├── architecture.png           # Official AWS icon diagram (Light theme, 2x)
│   ├── architecture-dark.png      # Official AWS icon diagram (Dark theme, 2x)
│   ├── architecture.html          # Self-contained interactive HTML diagram
│   └── architecture.drawio        # Editable draw.io XML with embedded AWS icons
├── app/
│   ├── package.json               # Express + pg app manifest and test script
│   ├── package-lock.json          # Locked dependency tree for reproducible `npm ci`
│   ├── server.js                  # /health (RDS check), /api/status (IMDSv2 + RDS), static assets
│   ├── public/                    # Frontend HTML & CSS cached by CloudFront
│   └── test/server.test.js        # Local Node unit/integration tests (mocked pg pool)
├── infra/
│   └── terraform/                 # Complete modular Terraform Infrastructure as Code
└── scripts/
    ├── deploy.sh                  # Preflight + terraform plan + confirmed apply (or --simulate)
    ├── verify.sh                  # Live AWS CLI + HTTP verification (or --simulate mock mode)
    ├── simulate-load.sh           # Live CloudFront concurrency test (or --simulate walkthrough)
    └── destroy.sh                 # Confirmed terraform destroy (or --simulate mock teardown)
```

---

## Key Architectural & Security Decisions

1. **Canonical Traffic Flow (`Route 53 -> CloudFront -> WAFv2 -> ALB -> EC2 -> RDS`):**
   - Route 53 Alias points to CloudFront (not directly to the ALB) so every request benefits from global edge caching (`/static/*`) and HTTPS termination.
   - Direct ALB bypass is blocked in two layers: `alb-sg` accepts ingress only from the AWS-managed `com.amazonaws.global.cloudfront.origin-facing` prefix list on the active origin port, and ALB listener rules require the shared `X-CloudFront-Verify` custom header (returning `HTTP 403` otherwise).
   - **Why `REGIONAL` WAFv2 on ALB:** Keeping WAFv2 in `REGIONAL` scope allows deploying the stack into **any** AWS region (whereas `CLOUDFRONT` scope restricts Web ACLs to `us-east-1`). Rate limiting uses `FORWARDED_IP` (`X-Forwarded-For`) so limits apply per real client IP rather than per CloudFront POP.
2. **Immutable Versioned S3 Application Delivery:**
   - Instead of embedding application code in size-limited `user_data` (16 KB cap) or cloning an unpinned branch, Terraform hashes `app/` files into a content-addressed release prefix (`releases/<sha256-16>/`) in a private, KMS-encrypted, versioned S3 bucket (`force_destroy = true`).
   - EC2 instances pull their release over a zero-cost **S3 Gateway VPC Endpoint**, run `npm ci --omit=dev` against `package-lock.json`, fetch RDS credentials from **Secrets Manager** into `/etc/cloudpulse.env` (`chmod 640`, `root:cloudpulse`), download the official AWS RDS global CA bundle (`rds-global-bundle.pem`), and run `app/server.js` under `systemd`.
3. **Concurrent Schema Safety & Sanitized Health Checks:**
   - Multiple EC2 instances booting simultaneously serialize `CREATE TABLE IF NOT EXISTS page_visits` using a PostgreSQL advisory lock (`pg_advisory_lock(84729103)`).
   - `/health` verifies actual RDS connectivity (`SELECT 1`) and returns HTTP `503` with sanitized `"database": "unavailable"` on errors (never exposing DB hostnames, credentials, or stack traces).
4. **Encryption in Transit (Lab Mode vs. Production Mode):**
   - **Users → CloudFront:** Always **HTTPS (`TLSv1.2+`)** via `redirect-to-https`.
   - **CloudFront → ALB:** **HTTPS (`https-only`, `ELBSecurityPolicy-TLS13-1-2-2021-06`)** in production when `alb_acm_certificate_arn` (in `var.aws_region`) is provided. Falls back to HTTP (`port 80`) **only** in lab/demo deployments without an ACM certificate.
   - **EC2 → RDS PostgreSQL:** Always **TLS (`SSL`)** verified against AWS's RDS global CA bundle.

---

## Local Validation & App Tests

```bash
# 1. Run Node.js unit/HTTP tests (no AWS account required)
cd app && npm ci --omit=dev && npm test && cd ..

# 2. Validate shell scripts & Terraform formatting/syntax
bash -n scripts/*.sh infra/terraform/user_data.sh
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate

# 3. Optional: walk through offline MOCK simulation (clearly labeled simulated; creates NO AWS resources)
./scripts/deploy.sh --simulate --region us-east-1
./scripts/verify.sh --simulate
./scripts/simulate-load.sh --simulate
./scripts/destroy.sh --simulate
```

---

## Live AWS Deployment, Verification & Cleanup

**Prerequisites:** AWS CLI v2 configured (`aws sts get-caller-identity` succeeds), Terraform `>= 1.6.0`, and `jq`.

```bash
# 1. Review execution plan first (no resources created)
./scripts/deploy.sh --region us-east-1 --plan-only

# 2. Deploy interactively (runs preflight checks, shows cost warning, prompts 'yes' after plan)
./scripts/deploy.sh --region us-east-1 --email ops-alerts@example.com

# Optional Production HTTPS + Custom Domain (CF cert MUST be in us-east-1; ALB cert in --region)
./scripts/deploy.sh \
  --region us-east-1 \
  --domain app.example.com \
  --zone-id Z0123456789EXAMPLE \
  --alb-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  --cf-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

# 3. Verify live AWS resources (CloudFront Deployed, ALB bypass blocked, /health, /api/status RDS visits, WAF 403, ASG, SSM, RDS Multi-AZ, Alarms)
./scripts/verify.sh

# 4. Run live HTTP concurrency test against CloudFront
./scripts/simulate-load.sh --requests 200

# 5. Destroy all billable resources when done (prompts 'DESTROY')
./scripts/destroy.sh --region us-east-1
```

---

## Cost Awareness & Limitations

- **Estimated Continuous Cost (`us-east-1`, on-demand):** ~**$145/month** if left running 24/7 (2x NAT Gateways ~\$65, Multi-AZ `db.t3.micro` ~\$28, ALB ~\$22, 2x `t3.micro` EC2 ~\$15, WAFv2 ~\$9, CloudFront/CloudWatch/S3/KMS ~\$6). Verify with the [AWS Pricing Calculator](https://calculator.aws/).
- **Known Limitations:**
  - `deletion_protection = false` and `skip_final_snapshot = true` are set on RDS/ALB for clean lab teardown (`destroy.sh`); enable both before real production use.
  - CloudFront `forwarded_values` blocks are used for broad Terraform provider compatibility; future updates may migrate to managed `cache_policy_id` / `origin_request_policy_id`.
  - Live AWS deployment has not been executed in this repository environment; all live tests must be run in the owner's AWS account.

## License & Attribution

- Project code and IaC templates are licensed under the [MIT License](LICENSE).
- Architecture diagrams use the official **AWS Architecture Icons** package for documentation purposes. All AWS service names and icons are trademarks of Amazon Web Services, Inc.
