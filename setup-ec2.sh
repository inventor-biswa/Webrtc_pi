#!/bin/bash
# ============================================================
# IntelliCure EC2 Setup Script (t3.small)
#
# RUN THIS ON YOUR EC2 INSTANCE:
#   sudo bash setup-ec2.sh
#
# Assumes you have already git cloned the repo and are 
# running this script from the root of the WEBRTC folder.
# ============================================================

set -e

# Configuration
DOMAIN="vid1.clinohealthinnovation.com"
EC2_IP="16.112.166.156"

# Colours
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}   Setting up IntelliCure on EC2 (${DOMAIN})    ${NC}"
echo -e "${CYAN}================================================${NC}"

# 1. Update OS and Install curl/git/wget
echo -e "\n${GREEN}[1/5] Updating OS...${NC}"
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y curl git wget build-essential
elif command -v dnf &> /dev/null; then
    sudo dnf update -y
    sudo dnf install -y curl git wget gcc-c++ make
elif command -v yum &> /dev/null; then
    sudo yum update -y
    sudo yum install -y curl git wget gcc-c++ make
fi

# 2. Install Node.js (v20) & PM2
echo -e "\n${GREEN}[2/5] Installing Node.js & PM2...${NC}"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    if command -v apt-get &> /dev/null; then sudo apt-get install -y nodejs; fi
    if command -v dnf &> /dev/null; then sudo dnf install -y nodejs; fi
    if command -v yum &> /dev/null; then sudo yum install -y nodejs; fi
fi
sudo npm install -g pm2

# 3. Install LiveKit Server
echo -e "\n${GREEN}[3/5] Installing LiveKit Server...${NC}"
if ! command -v livekit-server &> /dev/null; then
    curl -sSL https://get.livekit.io | bash
fi

# 4. Configure Application
echo -e "\n${GREEN}[4/5] Configuring Environment...${NC}"

# Backend dependencies
echo "Installing backend dependencies..."
cd backend
npm install

# Write backend/.env
cat <<EOF > .env
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret_secret_key_12345
PORT=5001
LIVEKIT_URL=http://127.0.0.1:7880
LIVEKIT_WS_URL=ws://${DOMAIN}:7880
EOF

# Write backend/livekit.yaml for EC2
cat <<EOF > livekit.yaml
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: true
keys:
  devkey: "secret_secret_key_12345"
EOF

# 5. Start Services
echo -e "\n${GREEN}[5/5] Starting Services...${NC}"

# Start backend with PM2
pm2 start server.js --name webrtc-backend
pm2 save
pm2 startup | grep -v "\[PM2\]" | sudo bash || true

# Setup LiveKit Systemd Service
echo "Configuring LiveKit systemd service..."
sudo bash -c "cat <<EOF > /etc/systemd/system/livekit.service
[Unit]
Description=LiveKit Server
After=network.target

[Service]
ExecStart=/usr/local/bin/livekit-server --config $(pwd)/livekit.yaml
Restart=always
User=$(whoami)
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable livekit
sudo systemctl restart livekit

echo -e "\n${CYAN}================================================${NC}"
echo -e "${GREEN}   ✅ SETUP COMPLETE!${NC}"
echo -e "${CYAN}================================================${NC}"
echo "Dashboard is available at : http://${DOMAIN}:5001"
echo "LiveKit is running on     : ws://${DOMAIN}:7880"
echo ""
echo "Make sure your AWS Security Group allows inbound:"
echo "- TCP: 5001, 7880, 7881"
echo "- UDP: 7882"
echo "================================================"
