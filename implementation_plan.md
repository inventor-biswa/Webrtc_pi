# Migrate System to AWS EC2 (t3.small)

This plan covers migrating the Backend (Express + Frontend) and the LiveKit SFU to a fresh EC2 instance. We will use PM2 to keep the Node.js backend running and standard systemd for LiveKit.

## User Review Required

> [!IMPORTANT]
> Since I do not have direct SSH access to your AWS account, I will write an automated setup script (`setup-ec2.sh`) that you can copy to your EC2 instance and run. 
> 
> **You must configure your EC2 Security Group in the AWS Console.** The setup will fail if the firewall blocks the video traffic.

## Open Questions

> [!WARNING]
> 1. Do you have a domain name (e.g., `stream.mywebsite.com`) or will we just use the raw EC2 Public IP address? 
> 2. For the setup script, how do you plan to transfer the code? (e.g. `scp` from your Mac, or cloning from a GitHub repo directly on the EC2?)

## Proposed Changes

We will create a deployment package and script for the EC2 instance.

### 1. AWS Security Group Configuration (Manual Action Required)
You will need to open these inbound ports on your EC2 Security Group:
- `22` (TCP) - SSH (already open)
- `5001` (TCP) - Backend API & Frontend Dashboard
- `7880` (TCP) - LiveKit WebSocket (Signaling)
- `7881` (TCP) - LiveKit TURN/TLS
- `7882` (**UDP**) - LiveKit Media (CRITICAL: Must be UDP)

### 2. EC2 Setup Script
#### [NEW] [setup-ec2.sh](file:///Users/thynxai/Downloads/WEBRTC/scripts/setup-ec2.sh)
We will create a bash script that you can run on the fresh EC2 instance. It will:
1. Install Node.js v22 and PM2 (for the backend).
2. Install LiveKit server.
3. Automatically detect the EC2 Public IP using `curl ifconfig.me`.
4. Generate the correct `livekit.yaml` with `use_external_ip: true`.
5. Generate the correct `.env` file with the Public IP.
6. Start both services in the background and ensure they start on boot.

## Verification Plan

### Manual Verification
1. You will run the `setup-ec2.sh` script on your EC2 instance.
2. You will visit `http://<EC2-PUBLIC-IP>:5001` in your browser on your Mac to verify the dashboard loads.
3. You will update the Pi's `BACKEND_URL` and `LIVEKIT_URL` to point to the EC2 Public IP.
4. You will start the Pi publisher and verify the video stream appears on the dashboard.
