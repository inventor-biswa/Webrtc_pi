#!/bin/bash
# ============================================================
# IntelliCure EC2 Domain & SSL Setup (Caddy)
#
# RUN THIS ON YOUR EC2 INSTANCE:
#   sudo bash setup-domain.sh
# ============================================================

set -e

DOMAIN_WEB="vid1.clinohealthinnovation.com"
DOMAIN_RTC="livekit.clinohealthinnovation.com"

echo "================================================"
echo "   Setting up HTTPS via Caddy Proxy             "
echo "================================================"

# 1. Install Caddy (Ubuntu/Debian)
echo "[1/4] Installing Caddy..."
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy

# 2. Configure Caddyfile
echo "[2/4] Configuring Caddyfile..."
sudo bash -c "cat <<EOF > /etc/caddy/Caddyfile
${DOMAIN_WEB} {
    reverse_proxy localhost:5001
}

${DOMAIN_RTC} {
    reverse_proxy localhost:7880
}
EOF"

sudo systemctl restart caddy

# 3. Update Backend Environment
echo "[3/4] Updating backend .env..."
cd /home/ubuntu/Webrtc_pi/backend

# Update LIVEKIT_WS_URL using sed safely
sudo sed -i "s|LIVEKIT_WS_URL=.*|LIVEKIT_WS_URL=wss://${DOMAIN_RTC}|g" .env

# 4. Restart Backend
echo "[4/4] Restarting Backend..."
sudo pm2 restart webrtc-backend --update-env

echo "================================================"
echo " ✅ DOMAIN SETUP COMPLETE!"
echo "================================================"
echo "It may take 1-2 minutes for Caddy to fetch the SSL certificates."
echo "You can view Caddy logs to ensure SSL succeeded using:"
echo "  sudo journalctl -u caddy --no-pager | tail -n 20"
echo ""
echo "Dashboard is now at : https://${DOMAIN_WEB}"
echo "LiveKit is now at   : wss://${DOMAIN_RTC}"
echo "================================================"
