#!/bin/bash
set -euo pipefail

# Bootstrap Amazon Linux 2023 EC2 instance inside Private App Subnet (outbound via NAT Gateway)
dnf update -y
dnf install -y nodejs jq awscli

mkdir -p /opt/cloudpulse/public

# Fetch RDS credentials securely at boot via IAM Role + AWS Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${aws_region}" \
  --secret-id "${db_secret_arn}" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
DATABASE_URL="postgresql://$${DB_USER}:$${DB_PASS}@${db_host}:${db_port}/${db_name}"

cat <<'EOF' > /opt/cloudpulse/server.js
const http = require("http");
const os = require("os");
const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ status: "healthy", host: os.hostname() }));
  }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ service: "CloudPulse", host: os.hostname(), status: "ok" }));
});
server.listen(8080, "0.0.0.0");
EOF

cat <<EOF > /etc/systemd/system/cloudpulse.service
[Unit]
Description=CloudPulse Scalable Web App
After=network.target

[Service]
Environment="PORT=8080"
Environment="DATABASE_URL=$${DATABASE_URL}"
WorkingDirectory=/opt/cloudpulse
ExecStart=/usr/bin/node /opt/cloudpulse/server.js
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudpulse
