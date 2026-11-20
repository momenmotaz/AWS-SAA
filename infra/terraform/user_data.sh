#!/bin/bash
set -euo pipefail

# Log non-secret bootstrap progress to /var/log/cloudpulse-bootstrap.log and system journal
exec > >(tee -a /var/log/cloudpulse-bootstrap.log | logger -t cloudpulse-bootstrap -s 2>/dev/console) 2>&1

echo "[cloudpulse] Starting EC2 bootstrap for app release ${app_version}..."

# Install runtime dependencies on Amazon Linux 2023 (outbound via NAT Gateway / S3 VPC Endpoint)
dnf update -y
dnf install -y nodejs npm jq awscli

# Create unprivileged service user and directories
id -u cloudpulse >/dev/null 2>&1 || useradd --system --home /opt/cloudpulse --shell /sbin/nologin cloudpulse
mkdir -p /opt/cloudpulse/public /etc/pki/cloudpulse

# Download official AWS RDS global CA bundle for strict PostgreSQL TLS verification
curl -fsSL "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem" \
  -o /etc/pki/cloudpulse/rds-global-bundle.pem
chmod 644 /etc/pki/cloudpulse/rds-global-bundle.pem

# Sync immutable, versioned application release artifact from private S3 bucket
aws s3 sync "s3://${artifact_bucket}/releases/${app_version}/" /opt/cloudpulse/ \
  --region "${aws_region}" \
  --no-progress

# Reproducible dependency installation from package-lock.json
cd /opt/cloudpulse
npm ci --omit=dev --no-audit --no-fund
chown -R cloudpulse:cloudpulse /opt/cloudpulse

# Fetch RDS master credentials securely at runtime via IAM Instance Profile + Secrets Manager
set +x
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${aws_region}" \
  --secret-id "${db_secret_arn}" \
  --query SecretString --output text)

DB_USER=$(printf '%s' "$SECRET_JSON" | jq -r '.username | @uri')
DB_PASS=$(printf '%s' "$SECRET_JSON" | jq -r '.password | @uri')
DATABASE_URL="postgresql://$${DB_USER}:$${DB_PASS}@${db_host}:${db_port}/${db_name}"
unset SECRET_JSON DB_USER DB_PASS

# Store runtime secrets only in a root-owned, service-group-readable env file (chmod 640)
umask 0137
cat <<EOF > /etc/cloudpulse.env
PORT=8080
DATABASE_URL=$${DATABASE_URL}
DB_SSL=true
DB_SSL_CA_PATH=/etc/pki/cloudpulse/rds-global-bundle.pem
EOF
unset DATABASE_URL
chown root:cloudpulse /etc/cloudpulse.env
chmod 640 /etc/cloudpulse.env

cat <<'EOF' > /etc/systemd/system/cloudpulse.service
[Unit]
Description=CloudPulse Scalable Web App (Express + RDS PostgreSQL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cloudpulse
Group=cloudpulse
EnvironmentFile=/etc/cloudpulse.env
WorkingDirectory=/opt/cloudpulse
ExecStart=/usr/bin/node /opt/cloudpulse/server.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cloudpulse

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudpulse

# Verify local application & RDS PostgreSQL connectivity before completing bootstrap
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8080/health | grep -q '"database":"connected"'; then
    echo "[cloudpulse] Healthy and connected to RDS PostgreSQL."
    exit 0
  fi
  sleep 3
done

echo "[cloudpulse] ERROR: RDS health check did not become connected within 60s. Recent journal logs:" >&2
journalctl -u cloudpulse -n 40 --no-pager >&2 || true
exit 1
