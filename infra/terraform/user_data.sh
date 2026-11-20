#!/bin/bash
set -euo pipefail

# Bootstrap Amazon Linux 2023 EC2 instance inside Private App Subnet (outbound via NAT Gateway)
dnf update -y
dnf install -y nodejs npm jq awscli

# Create unprivileged service user and application directories
id -u cloudpulse >/dev/null 2>&1 || useradd --system --home /opt/cloudpulse --shell /sbin/nologin cloudpulse
mkdir -p /opt/cloudpulse/public

# Deploy the real CloudPulse Express + PostgreSQL + IMDSv2 application from repository sources
echo '${package_json_b64gz}' | base64 -d | gunzip > /opt/cloudpulse/package.json
echo '${server_js_b64gz}'    | base64 -d | gunzip > /opt/cloudpulse/server.js
echo '${index_html_b64gz}'   | base64 -d | gunzip > /opt/cloudpulse/public/index.html
echo '${styles_css_b64gz}'   | base64 -d | gunzip > /opt/cloudpulse/public/styles.css

# Install production Node.js dependencies (express, pg)
cd /opt/cloudpulse
npm install --omit=dev --no-audit --no-fund
chown -R cloudpulse:cloudpulse /opt/cloudpulse

# Fetch RDS master credentials securely via IAM Instance Profile + AWS Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${aws_region}" \
  --secret-id "${db_secret_arn}" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET_JSON" | jq -r '.username | @uri')
DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password | @uri')
DATABASE_URL="postgresql://$${DB_USER}:$${DB_PASS}@${db_host}:${db_port}/${db_name}"

# Store credentials in a root/service-readable env file rather than inline systemd unit text
cat <<EOF > /etc/cloudpulse.env
PORT=8080
DATABASE_URL=$${DATABASE_URL}
DB_SSL=true
EOF
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudpulse

# Verify local application & RDS PostgreSQL connectivity before completing bootstrap
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8080/health | grep -q '"database":"connected"'; then
    echo "CloudPulse healthy and connected to RDS PostgreSQL."
    exit 0
  fi
  sleep 3
done

echo "WARNING: CloudPulse started, but RDS health check did not return connected within 60s." >&2
exit 1
