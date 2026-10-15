#!/usr/bin/env bash
# Run on the dedicated Ubuntu test Droplet as root, before uploading secrets.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx unzip curl ca-certificates openssl ufw
id aihaptics-relay >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin aihaptics-relay
install -d -m 750 -o root -g aihaptics-relay /etc/aihaptics-relay
install -d -m 755 /opt/aihaptics-relay
install -d -m 700 /root/aihaptics-deploy
if [ ! -x /opt/dart-sdk/bin/dart ]; then
  cd /root/aihaptics-deploy
  url=https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.5/sdk/dartsdk-linux-x64-release.zip
  curl -fSL --retry 2 "$url" -o dart.zip
  curl -fsSL "$url.sha256sum" -o dart.sha256
  expected=$(cut -d ' ' -f 1 dart.sha256)
  printf '%s  dart.zip\n' "$expected" | sha256sum -c -
  unzip -q dart.zip -d /opt
  /opt/dart-sdk/bin/dart --disable-analytics
  rm -f dart.zip
fi
/opt/dart-sdk/bin/dart --version
ufw allow OpenSSH
ufw allow 443/tcp
ufw --force enable
echo 'Bootstrap complete; only SSH and HTTPS allowed inbound.'
