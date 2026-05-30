# 📡 Pi → LiveKit → Browser — Complete System Guide

> **Project:** IntelliCure — Raspberry Pi Camera → LiveKit WebRTC → Browser Viewer
> **Stack:** Python · Node.js · LiveKit SFU · Plain HTML + LiveKit JS SDK
> **Tested on:** Raspberry Pi (Debian 13 / trixie) + Mac M-series (will move to EC2)

---

## 🔑 The Most Important Thing to Understand First

**Video never goes through the Express backend.**

```
❌ What people assume:
   Pi Camera → Backend (Node.js) → Browser

✅ How it actually works:
   Pi Camera → LiveKit SFU ← Browser
                    ↑
             Backend only provides JWT tokens
             Video never touches Express at all
```

The backend has **one job only**: issue signed JWT tokens that prove
"this Pi is allowed to publish" and "this browser is allowed to watch".
All video data flows directly between Pi ↔ LiveKit ↔ Browser over encrypted UDP.

---

## 📁 Project Structure

```
WEBRTC/
├── Pi_Setup/
│   ├── lk-publisher.py     ← ✅ ACTIVE — Python LiveKit SDK publisher
│   ├── check-setup.sh      ← Run on Pi to diagnose camera + OS readiness
│   ├── start-stream.sh     ← (Legacy ffmpeg/GStreamer attempt — won't work on Debian 13)
│   ├── whip-publisher.py   ← (Dead end — LiveKit has no /rtc/whip endpoint)
│   ├── main.go             ← (Legacy) Go SDK attempt — incomplete
│   └── go.mod              ← Go module file for main.go
│
├── backend/
│   ├── server.js           ← Express API — token issuance + room listing ONLY
│   ├── livekit.yaml        ← LiveKit SFU server configuration
│   ├── .env                ← Environment variables (keys, ports, URLs)
│   ├── package.json        ← Node.js dependencies
│   └── Dockerfile          ← For EC2 containerised deployment
│
├── frontend/
│   └── index.html          ← Browser viewer dashboard (plain HTML + LiveKit JS SDK)
│
└── SYSTEM_GUIDE.md         ← This file
```

---

## 🧠 What Each Component Does

### 1. `livekit-server` — The Media Brain (SFU)

**What it is:** A **Selective Forwarding Unit** — a media relay server.
It receives encrypted video from the Pi and forwards it to browser viewers.

**Why it exists:** WebRTC is peer-to-peer, but direct Pi→Browser connections
fail across different networks and NAT. The SFU sits in the middle and handles
ICE, DTLS, SRTP — all the WebRTC plumbing.

**Critical insight:** The SFU doesn't decode or re-encode video. It receives
encrypted RTP packets from the Pi and forwards those exact same encrypted
packets to viewers. This is why it's called "selective forwarding" — it's
very efficient, low CPU, low latency.

**Ports:**
| Port | Protocol | Purpose |
|------|----------|---------|
| `7880` | TCP / WebSocket | Signaling — clients connect here to negotiate |
| `7882` | **UDP** | Media — actual encrypted video packets flow here |
| `7881` | TCP | TURN/TLS fallback (if UDP is blocked) |

**Config:** [`backend/livekit.yaml`](backend/livekit.yaml)
```yaml
port: 7880
rtc:
  udp_port: 7882
  use_external_ip: false   # ← Change to TRUE on EC2
keys:
  devkey: "secret_secret_key_12345"
```

**How to start:**
```bash
livekit-server --config backend/livekit.yaml
```

---

### 2. `backend/server.js` — The JWT Token Gatekeeper

**What it is:** A tiny Express (Node.js) server.

**What it does:** Issues signed JWT tokens. That's it. No video data passes
through it ever.

**Why tokens are needed:** LiveKit requires every participant (Pi publishers
and browser viewers) to prove their identity and permissions before joining.
The backend is the only place holding `LIVEKIT_API_SECRET`, so only it can
create valid tokens.

**Endpoints:**
| Endpoint | Called by | Returns |
|----------|-----------|---------|
| `GET /api/edge/token?deviceId=pi-01` | **Pi** (on startup) | JWT: publish-only |
| `GET /api/viewer/token?patientId=pi-01` | **Browser** (on Watch click) | JWT: subscribe-only |
| `GET /api/rooms` | **Browser** (auto-poll) | List of active LiveKit rooms |
| `GET /api/config` | **Browser** (on load) | LiveKit WS URL for browser |
| `GET /health` | Monitoring | `{ status: "ok" }` |

Also serves `frontend/index.html` as a static file on port `5001`.

> ⚠️ macOS port 5000 is taken by AirPlay Receiver — we use **5001** instead.

**Config:** [`backend/.env`](backend/.env)
```env
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret_secret_key_12345
PORT=5001
LIVEKIT_URL=http://localhost:7880        # Backend → LiveKit (REST API)
LIVEKIT_WS_URL=ws://localhost:7880      # Browser → LiveKit (WebSocket)
```

---

### 3. `Pi_Setup/lk-publisher.py` — The Camera Sender

**What it is:** A Python script using the official LiveKit Python SDK.

**What it does:**
1. Fetches a JWT token from the backend (`/api/edge/token`)
2. Connects to LiveKit over **WebSocket** on port 7880
3. Opens the USB camera via OpenCV (uses MJPEG format for max fps)
4. Creates a LiveKit video track and publishes it to the room
5. Streams camera frames at 30fps; auto-retries if connection drops

**Why Python SDK (not ffmpeg/WHIP):**

We tried 4 other approaches — all failed on Raspberry Pi OS Debian 13:
| Approach | Why it failed |
|----------|--------------|
| System ffmpeg `--whip` | Debian build excludes WHIP muxer |
| Static ffmpeg (johnvansickle) | Also no WHIP in that build |
| GStreamer `whipsink` | Pi OS compiles plugins-bad without `libnice` (no WebRTC) |
| `aiortc` + WHIP URL | LiveKit server has NO `/rtc/whip` endpoint (needs separate Ingress service) |

The Python SDK connects via **WebSocket** (same as the browser and the Go SDK),
which works because no special system library is required — the SDK handles
all WebRTC internally in Rust (compiled into the wheel).

**Install:**
```bash
pip3 install livekit requests --break-system-packages
sudo apt install -y python3-opencv
```

**Run:**
```bash
BACKEND_URL=http://MAC_IP:5001 \
LIVEKIT_URL=ws://MAC_IP:7880 \
DEVICE_ID=pi-patient-01 \
python3 ~/webrtc/lk-publisher.py
```

---

### 4. `frontend/index.html` — The Viewer Dashboard

**What it is:** A single plain HTML file, no build tools.
Uses the LiveKit JS SDK loaded from CDN.

**What it does:**
- Shows a live grid of Pi stream cards (auto-refreshes every 8s)
- Each card: device ID, room name, participant count, "since" time
- Click **Watch** → opens a modal with live WebRTC video
- Uses `/api/config` to get the LiveKit WebSocket URL
- Uses `/api/viewer/token` to get a subscribe-only JWT on Watch click
- Connects directly to LiveKit via WebSocket → receives video track

**Accessed at:** `http://localhost:5001`

---

## 🔄 Complete Data Flow — What Actually Happens

### Startup sequence

```
 1. livekit-server starts
    → Listens :7880 (WebSocket) and :7882/udp (media)
    → Waits for publishers and viewers

 2. npm start (backend) starts
    → Listens :5001
    → Serves frontend HTML
    → Can issue tokens once livekit-server is reachable

 3. lk-publisher.py starts on Pi
    → Fetches token
    → Connects to livekit-server
    → Starts sending camera frames
```

---

### Pi Publisher — what happens under the hood

```
Raspberry Pi
│
│  Step 1: HTTP GET http://MAC_IP:5001/api/edge/token?deviceId=pi-patient-01
▼
Express Backend (port 5001)
│
│  Creates JWT:
│  {
│    room: "room-pi-patient-01",
│    roomJoin: true,
│    canPublish: true,
│    canSubscribe: false       ← publisher only, can't see others
│  }
│  Signs it with LIVEKIT_API_SECRET
│  Returns { token: "eyJ...", room: "room-pi-patient-01" }
▼
Python SDK on Pi
│
│  Step 2: WebSocket → ws://MAC_IP:7880
│  Sends: JWT token (proves identity)
│
│  LiveKit server verifies signature, creates room "room-pi-patient-01"
│
│  Step 3: WebRTC negotiation over WebSocket
│  Pi SDK:    "I want to send H264 video"   → SDP Offer
│  LiveKit:   "OK, send it here (ICE/DTLS)" → SDP Answer
│  Exchange ICE candidates (network paths)
│
│  Step 4: DTLS handshake over UDP :7882
│  Pi and LiveKit exchange encryption keys
│  Now all media is encrypted (SRTP)
│
│  Step 5: Streaming begins
│  OpenCV reads frames from /dev/video0 (MJPEG @ 30fps)
│  LiveKit SDK encodes frames → H264
│  Sends encrypted RTP packets → UDP :7882
│
▼
LiveKit SFU (port 7882)
│
│  Receives encrypted packets
│  Buffers them in the room "room-pi-patient-01"
│  Waiting for subscribers...
```

---

### Browser Viewer — what happens under the hood

```
Browser opens http://localhost:5001
│
│  Step 1: index.html loaded from Express (static file)
│  Step 2: GET /api/config → { livekitUrl: "ws://localhost:7880" }
│  Step 3: GET /api/rooms → [{ name: "room-pi-patient-01", numPublishers: 1 }]
│  Renders the Pi card: "pi-patient-01 — LIVE"
│
│  User clicks Watch
│
│  Step 4: GET /api/viewer/token?patientId=pi-patient-01
▼
Express Backend
│
│  Creates JWT:
│  {
│    room: "room-pi-patient-01",
│    canPublish: false,
│    canSubscribe: true         ← viewer only
│  }
│  Returns { token: "eyJ..." }
▼
Browser (LiveKit JS SDK)
│
│  Step 5: WebSocket → ws://localhost:7880 with token
│  LiveKit verifies JWT → joins room as subscriber
│
│  Step 6: WebRTC negotiation over WebSocket
│  LiveKit tells browser: "there's a H264 video track from Pi"
│  SDP offer/answer exchange
│  ICE candidate exchange
│
│  Step 7: DTLS handshake over UDP :7882
│  Browser and LiveKit exchange encryption keys
│
│  Step 8: Video arrives
│  Encrypted RTP packets flow from LiveKit → Browser UDP :7882
│  Browser decodes H264 → renders in <video> element
│  Live video appears ✅
│
│  NOTE: The video data went:
│  Pi → LiveKit (encrypted UDP)
│  LiveKit → Browser (same encrypted packets, just forwarded)
│  Express backend saw ZERO video bytes
```

---

### The Big Picture

```
                     ┌────────────────────────────────────────┐
                     │           Your Mac / EC2               │
                     │                                        │
  Pi Camera          │  ┌──────────┐      ┌────────────────┐ │
  /dev/video0        │  │ Express  │      │  LiveKit SFU   │ │
       │             │  │ :5001    │      │  :7880 (WS)    │ │
       │  ①Token req │  │          │  ③   │  :7882 (UDP)   │ │
       │─────────────┼─▶│ /api/    │─────▶│                │ │
       │  ②Token     │  │ edge/    │Token │  Room:         │ │
       │◀────────────┼──│ token    │      │  room-pi-01    │ │
       │             │  └──────────┘      │                │ │
       │  ④WebSocket │                    │  ④⑤ Publish    │ │
       │─────────────┼────────────────────▶  H264 video    │ │
       │  ⑤UDP video │                    │  via UDP       │ │
       │─────────────┼────────────────────▶               ◀┼─┼── Browser
       │             │                    │    ⑥ Forward  │ │  ⑦ UDP video
       │             │                    │    to viewer  ─┼─┼──▶ <video>
       │             │                    └────────────────┘ │
       │             │                                        │
       │             │  Express never touches ⑤⑥⑦ video!    │
       │             └────────────────────────────────────────┘
```

---

## 📊 Bandwidth & CPU Usage (When nobody is watching)

**Question:** *When no one is looking at the dashboard, does the Pi still use network data?*

**Answer: YES.**

In the current setup, the Pi is a **continuous publisher**. As soon as you run `lk-publisher.py`, the following happens:
1. The Pi's camera turns on and starts capturing 30 frames every second.
2. The Pi encodes these frames to H.264.
3. The Pi sends a continuous 2 Mbps video stream to the LiveKit SFU.

It does this **regardless of whether 0 people or 100 people are watching**. 

**Why?** 
Because when a doctor clicks "Watch" on the dashboard, they expect the video to appear instantly (in milliseconds). If the Pi was "asleep", the viewer would have to wait several seconds for the camera to wake up, encode, and negotiate the connection.

**The Math (per Pi):**
- **Network:** ~2 Megabits per second (Mbps) upload.
- **Data usage:** ~900 Megabytes (MB) per hour.
- **CPU:** The Pi will use some CPU constantly to encode the video.

*(Note: LiveKit does have an advanced feature called "Dynacast" which can pause network transmission when there are 0 viewers, but the Pi's camera and CPU will still be active. For a medical monitoring use-case where immediate video access is required, continuous streaming is the standard approach.)*

---

## 🤖 Autostarting on the Pi (Run on Boot)

If the Pi loses power or restarts, you want the camera to start streaming automatically without you having to SSH in. We do this by creating a Linux `systemd` service.

Run this entire block on your Raspberry Pi terminal (make sure to change the `DEVICE_ID` if setting up a second Pi):

```bash
sudo bash -c 'cat <<EOF > /etc/systemd/system/webrtc-stream.service
[Unit]
Description=LiveKit WebRTC Publisher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=test
WorkingDirectory=/home/test/webrtc
Environment="BACKEND_URL=https://vid1.clinohealthinnovation.com"
Environment="LIVEKIT_URL=wss://livekit.clinohealthinnovation.com"
Environment="DEVICE_ID=pi-patient-01"
Environment="FPS=25"

# Apply anti-flicker (50Hz) to the camera right before starting
ExecStartPre=-/usr/bin/v4l2-ctl -d /dev/video0 --set-ctrl=power_line_frequency=1

ExecStart=/usr/bin/python3 /home/test/webrtc/lk-publisher.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF'

# Enable it to start on boot
sudo systemctl daemon-reload
sudo systemctl enable webrtc-stream

# Start it right now
sudo systemctl start webrtc-stream
```

### Useful Commands for the Pi Service
- Check if it's running: `sudo systemctl status webrtc-stream`
- View live logs: `sudo journalctl -u webrtc-stream -f`
- Stop the stream: `sudo systemctl stop webrtc-stream`

---

## 🖥️ How to Run (Mac — Local Testing)

Open **2 terminal tabs** on Mac:

### Tab 1 — LiveKit Server
```bash
cd /Users/thynxai/Downloads/WEBRTC/backend
livekit-server --config livekit.yaml
# Runs on :7880 (WS) and :7882/udp
# Stop: Ctrl+C
```

### Tab 2 — Express Backend
```bash
cd /Users/thynxai/Downloads/WEBRTC/backend
npm start
# Runs on :5001
# Stop: Ctrl+C
```

### On the Pi
```bash
BACKEND_URL=http://192.168.1.47:5001 \
LIVEKIT_URL=ws://192.168.1.47:7880 \
DEVICE_ID=pi-patient-01 \
python3 ~/webrtc/lk-publisher.py
# Stop: Ctrl+C
```

### Browser
```
http://localhost:5001
→ See "pi-patient-01" card
→ Click Watch → live video appears
```

---

## 🛑 How to Stop Everything

```bash
# Stop backend (Express)
kill -9 $(lsof -ti :5001)

# Stop LiveKit
kill -9 $(lsof -ti :7880)

# Or by name
pkill -f "node server.js"
pkill -f livekit-server
```

---

## 👥 Adding More Pis (Multi-Pi)

Just change `DEVICE_ID` on each Pi — everything else is automatic:

```bash
# Pi 1
DEVICE_ID=pi-patient-01 python3 ~/webrtc/lk-publisher.py

# Pi 2
DEVICE_ID=pi-patient-02 python3 ~/webrtc/lk-publisher.py

# Pi 3
DEVICE_ID=pi-patient-03 python3 ~/webrtc/lk-publisher.py
```

Each Pi gets:
- Its own room: `room-pi-patient-01`, `room-pi-patient-02`, etc.
- Its own card in the dashboard (auto-discovered via `/api/rooms`)
- Independently viewable streams — click Watch on any card

---

## ☁️ Moving to EC2

### What changes:

| Setting | Local (Mac) | EC2 |
|---------|-------------|-----|
| `use_external_ip` in livekit.yaml | `false` | **`true`** |
| `LIVEKIT_WS_URL` in .env | `ws://localhost:7880` | `wss://your-ec2-ip:7880` |
| Pi `BACKEND_URL` | `http://192.168.1.47:5001` | `http://EC2-IP:5001` |
| Pi `LIVEKIT_URL` | `ws://192.168.1.47:7880` | `ws://EC2-IP:7880` |

### EC2 Security Group — open these ports:

| Port | Protocol | Why |
|------|----------|-----|
| `5001` | TCP | Backend API (token issuance) |
| `7880` | TCP | LiveKit WebSocket (signaling) |
| `7882` | **UDP** | LiveKit media — **must be UDP!** |
| `80` / `443` | TCP | Frontend HTTP/HTTPS |

### Only livekit.yaml change needed:
```yaml
rtc:
  use_external_ip: true    # ← This tells LiveKit to advertise EC2 public IP in ICE
```

Without this, the browser would try to reach LiveKit at a private IP (10.x.x.x)
and the video would never arrive.

---

## 🔑 Glossary

| Term | Plain English |
|------|--------------|
| **SFU** | Media relay — Pi sends once, SFU forwards to N browsers |
| **WebRTC** | Browser-native real-time video protocol over UDP |
| **JWT** | Signed access token — proves who you are + what room + permissions |
| **ICE** | How WebRTC finds a network path through NAT/firewalls |
| **DTLS** | TLS for UDP — how WebRTC encrypts the connection |
| **SRTP** | Encrypted video packets — what actually carries the video |
| **WHIP** | An HTTP protocol for pushing video into a media server — LiveKit needs a separate Ingress service for this (not our setup) |
| **Room** | A LiveKit session. Each Pi gets one: `room-pi-patient-01` |
| **Publisher** | Sends video (`canPublish: true`) — the Pi |
| **Subscriber** | Receives video (`canSubscribe: true`) — the browser |
| **Signaling** | The WebSocket negotiation phase (SDP/ICE) before video flows |
| **v4l2** | Linux camera API. `/dev/video0` = first USB camera |
| **MJPEG** | Camera output format — Pi requests this to maximise USB bandwidth efficiency |

---

## 🚨 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `EADDRINUSE :5001` | Another server running | `kill -9 $(lsof -ti :5001)` |
| `EADDRINUSE :5000` | macOS AirPlay | Already fixed — we use 5001 |
| Pi publisher: `Connection refused` | LiveKit not running | Start `livekit-server` first |
| Pi publisher: `401 Unauthorized` | Wrong API key/secret | Check `.env` matches `livekit.yaml` |
| Dashboard shows no rooms | Pi not streaming yet | Check Pi terminal for errors |
| Video card appears but Watch fails | Token issue | Check browser console (F12) |
| Video black screen | UDP port blocked | Open 7882/udp in firewall |
| Video freezes/stutters | Network congestion | Lower `BITRATE_KBPS` or `WIDTH`/`HEIGHT` |
| `No module named 'livekit'` on Pi | Not installed | `pip3 install livekit --break-system-packages` |
| `python3-opencv` issues | Version conflict | `sudo apt install python3-opencv` |

---

## 📝 What We Tried (Lessons Learned)

All these were attempted and failed before finding the working solution:

| Approach | Why we tried it | Why it failed |
|----------|----------------|---------------|
| `ffmpeg -f whip` (system) | Standard WHIP push | Debian 13 builds ffmpeg without WHIP muxer |
| Static ffmpeg (johnvansickle) | Pre-built with all features | This build also lacks WHIP |
| GStreamer `whipsink` | Native Linux multimedia | Pi OS `gst-plugins-bad` compiled without `libnice` → no WebRTC support |
| `aiortc` Python WHIP | Pure Python WebRTC | LiveKit server has no `/rtc/whip` endpoint — needs separate LiveKit Ingress service |
| **LiveKit Python SDK** ✅ | Official SDK, WebSocket | **Works perfectly** — SDK handles all WebRTC internally |

**Root cause of all failures:** WHIP requires a LiveKit Ingress service
(separate binary from `livekit-server`). We are using `livekit-server` directly.
The Python SDK bypasses WHIP entirely by connecting via the same WebSocket
protocol that browsers and the Go SDK use.

---

## 🔗 Integrating with Other Dashboards (API)

Because the frontend is entirely decoupled from the video routing, you can easily embed the video feeds into **any other application** (like a React app, Laravel dashboard, or WordPress site) on a completely different server.

### Option 1: Frontend Token Fetching (Easiest)
You can copy the HTML/JavaScript from `frontend/player.html` into your other application. Your new frontend simply makes an HTTP request to your EC2 backend to grab the viewer token.

```javascript
// Fetch the viewer token from your EC2 API
const response = await fetch("https://vid1.clinohealthinnovation.com/api/viewer/token?patientId=pi-patient-01");
const { token } = await response.json();

// Connect the LiveKit Video Player
await room.connect("wss://livekit.clinohealthinnovation.com", token);
```
*(Note: CORS is already enabled on the EC2 backend to allow cross-domain requests).*

### Option 2: Native Backend Integration (Most Secure)
If your new dashboard has its own backend (e.g. where doctors log in securely), you don't need to fetch tokens from the EC2 Express API at all.

1. Install the **LiveKit Server SDK** in your new backend (available for Node.js, Python, PHP, Go, Ruby, Java).
2. Use your `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` to generate Viewer JWT tokens securely on your own server.
3. Pass the generated token down to your frontend to connect directly to `wss://livekit.clinohealthinnovation.com`.
