#!/usr/bin/env bash
# Prerequisite: bootstrap + protected config/key/source uploaded by deploy script.
set -euo pipefail
: "${RELAY_SAN:?Set certificate subjectAltName from your deployment configuration}"
[[ "$RELAY_SAN" =~ ^[A-Za-z0-9:,.-]+$ ]] || { echo 'Invalid certificate SAN'; exit 1; }
cd /opt/aihaptics-relay
if [ -f relay ]; then cp -p relay relay.previous; fi
/opt/dart-sdk/bin/dart compile exe tool/venice_relay.dart -o relay.new
chmod 755 relay.new
mv relay.new relay
if [ ! -f /etc/aihaptics-relay/server.pem ]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
    -keyout /etc/aihaptics-relay/server-key.pem -out /etc/aihaptics-relay/server.pem \
    -subj '/CN=AIHaptics test relay' \
    -addext "subjectAltName=$RELAY_SAN" >/dev/null 2>&1
elif ! openssl x509 -in /etc/aihaptics-relay/server.pem -noout -ext subjectAltName | grep -q 'DNS:relay.internal'; then
  # Repair pre-release IP-only certificate without replacing the private key.
  # Regenerate the private Android defines after activation; no APK was issued.
  cp -p /etc/aihaptics-relay/server.pem /etc/aihaptics-relay/server.pem.previous
  openssl req -x509 -new -sha256 -days 365 \
    -key /etc/aihaptics-relay/server-key.pem -out /etc/aihaptics-relay/server.pem \
    -subj '/CN=AIHaptics test relay' \
    -addext "subjectAltName=$RELAY_SAN"
fi
chown root:aihaptics-relay /etc/aihaptics-relay/*
chmod 640 /etc/aihaptics-relay/*
cat > /etc/systemd/system/aihaptics-relay.service <<'UNIT'
[Unit]
Description=AIHaptics private Venice test relay
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
User=aihaptics-relay
Group=aihaptics-relay
ExecStart=/opt/aihaptics-relay/relay /etc/aihaptics-relay/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
UMask=0077
LimitNOFILE=1024
MemoryMax=256M
TasksMax=64
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/nginx/conf.d/aihaptics-relay.conf <<'NGINX'
limit_req_zone $binary_remote_addr zone=aihaptics_rate:1m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=aihaptics_conn:1m;
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/aihaptics-relay/server.pem;
    ssl_certificate_key /etc/aihaptics-relay/server-key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    error_log /var/log/nginx/aihaptics-error.log warn;
    client_max_body_size 2m;
    client_body_timeout 15s;
    client_header_timeout 10s;
    send_timeout 30s;
    keepalive_timeout 15s;
    limit_conn aihaptics_conn 10;
    limit_conn_status 429;
    limit_req zone=aihaptics_rate burst=20 nodelay;
    limit_req_status 429;
    location /api/v1/ {
        proxy_pass https://127.0.0.1:9443;
        proxy_ssl_trusted_certificate /etc/aihaptics-relay/server.pem;
        proxy_ssl_verify on;
        proxy_ssl_name relay.internal;
        proxy_ssl_session_reuse on;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 70s;
        proxy_connect_timeout 5s;
        proxy_next_upstream off;
    }
    location / { return 404; }
}
NGINX
# Only this dedicated fresh server's packaged default vhost is disabled.
if [ -L /etc/nginx/sites-enabled/default ]; then unlink /etc/nginx/sites-enabled/default; fi
nginx -t
systemctl daemon-reload
systemctl enable --now aihaptics-relay
systemctl restart aihaptics-relay
systemctl enable nginx
systemctl reload nginx
systemctl is-active aihaptics-relay nginx
echo 'Cloud relay activated.'
