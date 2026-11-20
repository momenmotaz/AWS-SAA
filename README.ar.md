# CloudPulse — تطبيق ويب قابل للتوسع على AWS (EC2 + ALB + ASG + RDS Multi-AZ)

**مشروع التخرج الأول — شهادة AWS Solutions Architect – Associate (SAA)**

> [English Documentation (README.md)](README.md)

## نظرة عامة

**CloudPulse** هو مشروع معماري متكامل لتشغيل تطبيق ويب على **AWS** بدرجة عالية من الاعتمادية (High Availability) وقابلية التوسع (Scalability) عبر منطقتي توافر (**Availability Zones: `us-east-1a` و `us-east-1b`**):

- جميع خوادم التطبيق (**Amazon EC2** داخل **Auto Scaling Group**) وقاعدة البيانات (**Amazon RDS PostgreSQL Multi-AZ**) معزولة تماماً داخل **Private Subnets**.
- **المسار الموحّد للترافيك:** **Route 53 (Alias اختياري)** ← **CloudFront** (كاش `/static/*` وحقن هيدر سري `X-CloudFront-Verify`) ← **AWS WAFv2** (`REGIONAL` مع قواعد OWASP Top 10 و Rate Limiting بالاعتماد على `X-Forwarded-For`) ← **Application Load Balancer (ALB)** مقفول على IP ranges الخاصة بـ CloudFront فقط ← **EC2** ← **RDS Multi-AZ**.
- **نشر التطبيق الحقيقي:** يقوم Terraform برفع ملفات [`app/`](app/) (بما فيها `package-lock.json`) إلى Bucket S3 خاص مشفر بـ KMS ومُفعّل عليه Versioning، وتقوم خوادم EC2 في `user_data.sh` بسحب الإصدار عبر **S3 Gateway VPC Endpoint** وتثبيت الحزم بـ `npm ci --omit=dev` وتشغيل `app/server.js` عبر `systemd` بمستخدم غير مُميز (`cloudpulse`)، مع جلب بيانات RDS من **Secrets Manager** والتحقق من `/health`.
- **تشفير كامل وموثوق:** تشفير Storage وSecrets وS3 عبر مفتاح **KMS CMK**، والتحقق من اتصال PostgreSQL عبر شهادة AWS RDS CA الرسمية، ومنع تضارب إنشاء الجداول بين الخوادم باستخدام `pg_advisory_lock`.
- الدخول الإداري للخوادم يتم بدون Bastion Host وبدون فتح بورت SSH عبر **AWS Systems Manager (Session Manager)**.
- المراقبة والتنبيهات تتم عبر **Amazon CloudWatch** (Dashboard + 3 Alarms) مع **Amazon SNS**.

## مخطط المعمارية (Architecture Diagram)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/architecture-dark.png">
  <img src="docs/architecture.png" alt="مخطط معمارية AWS لمشروع CloudPulse" width="100%">
</picture>

- **ملف قابل للتعديل بالماوس (draw.io):** [`docs/architecture.drawio`](docs/architecture.drawio)
- **نسخة HTML تفاعلية (تعمل Offline):** [`docs/architecture.html`](docs/architecture.html)

## تقسيم الشبكة (VPC & CIDR Plan)

| الطبقة | `us-east-1a` | `us-east-1b` | الوظيفة |
|---|---|---|---|
| **VPC** | `10.0.0.0/16` | `10.0.0.0/16` | الشبكة الافتراضية الأساسية |
| **Public Subnets** | `10.0.1.0/24` | `10.0.2.0/24` | تحتوي على ALB و NAT Gateways |
| **Private App Subnets** | `10.0.11.0/24` | `10.0.12.0/24` | خوادم EC2 (خروج الإنترنت عبر NAT GW + S3 VPC Endpoint) |
| **Private DB Subnets** | `10.0.21.0/24` | `10.0.22.0/24` | معزولة تماماً لـ RDS Primary و Standby مع Network ACL |

## ربط الموارد بملفات Terraform

| الموارد / المسؤولية | ملف Terraform |
|---|---|
| الـ Provider والوسوم وبيانات AZs و AMI | [`infra/terraform/main.tf`](infra/terraform/main.tf) |
| المتغيرات وقواعد التحقق من الـ ARN والـ CIDR | [`infra/terraform/variables.tf`](infra/terraform/variables.tf) |
| VPC والـ 6 Subnets و IGW و 2x NAT GW و Route Tables و DB NACL | [`infra/terraform/vpc.tf`](infra/terraform/vpc.tf) |
| مفتاح KMS CMK و DB Subnet Group و RDS PostgreSQL 16 Multi-AZ | [`infra/terraform/rds.tf`](infra/terraform/rds.tf) |
| S3 Artifact Bucket (Versioning + KMS + TLS Policy) و S3 Gateway Endpoint | [`infra/terraform/s3_artifacts.tf`](infra/terraform/s3_artifacts.tf) |
| Security Groups (ALB / App / DB) وصلاحيات IAM الأقل امتيازاً | [`infra/terraform/security.tf`](infra/terraform/security.tf) |
| ALB و Target Group و Listeners و `X-CloudFront-Verify` و Regional WAFv2 | [`infra/terraform/alb_waf.tf`](infra/terraform/alb_waf.tf) |
| Launch Template (`IMDSv2`) و ASG و Target Tracking & Step Scaling | [`infra/terraform/compute_asg.tf`](infra/terraform/compute_asg.tf) |
| سكريبت الإقلاع (`aws s3 sync` + `npm ci` + Secrets Manager + `systemd`) | [`infra/terraform/user_data.sh`](infra/terraform/user_data.sh) |
| CloudFront Distribution و Route 53 Alias و Health Check الاختياريين | [`infra/terraform/edge_dns.tf`](infra/terraform/edge_dns.tf) |
| لوحة مراقبة CloudWatch و 3 تنبيهات و SNS Topic | [`infra/terraform/observability.tf`](infra/terraform/observability.tf) |
| مخرجات النشر (`outputs.tf`) | [`infra/terraform/outputs.tf`](infra/terraform/outputs.tf) |

## الاختبار المحلي ووضع المحاكاة (بدون حساب AWS)

```bash
# اختبارات التطبيق والتحقق من Terraform محلياً
cd app && npm ci --omit=dev && npm test && cd ..
bash -n scripts/*.sh infra/terraform/user_data.sh
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate

# وضع المحاكاة (Mock) للتجربة المحلية بدون إنشاء أي موارد على AWS
./scripts/deploy.sh --simulate --region us-east-1
./scripts/verify.sh --simulate
./scripts/simulate-load.sh --simulate
./scripts/destroy.sh --simulate
```

## النشر الفعلي على AWS والتحقق والحذف

> **تحذير التكلفة:** تشغيل البنية الفعلية يكلف حوالي **145 دولار/شهرياً** إذا تُركت تعمل طوال الشهر (بسبب 2 NAT Gateways و Multi-AZ RDS و ALB و WAF). احرص دائماً على تشغيل `destroy.sh` بعد انتهاء التجربة.

```bash
# 1. فحص خطة التنفيذ (Plan) قبل إنشاء أي موارد
./scripts/deploy.sh --region us-east-1 --plan-only

# 2. النشر التفاعلي (يطلب تأكيد كتابي 'yes' بعد عرض الخطة)
./scripts/deploy.sh --region us-east-1 --email ops-alerts@example.com

# 3. التحقق الفعلي عبر AWS CLI و CloudFront (يرفض التشغيل على ملفات المحاكاة)
./scripts/verify.sh

# 4. حذف جميع الموارد وإيقاف الفوترة (يطلب كتابة 'DESTROY')
./scripts/destroy.sh --region us-east-1
```
