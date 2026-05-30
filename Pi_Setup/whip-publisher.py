#!/usr/bin/env python3
"""
Pi WHIP Publisher — aiortc-based
Captures from USB camera (/dev/video0) and streams to LiveKit via WHIP.

INSTALL (run once on Pi):
    sudo apt install -y libsrtp2-dev libopus-dev python3-pip
    pip3 install aiortc aiohttp --break-system-packages

RUN:
    python3 whip-publisher.py

    # Or with env vars:
    BACKEND_URL=http://192.168.1.47:5001 \\
    LIVEKIT_URL=http://192.168.1.47:7880 \\
    DEVICE_ID=pi-patient-01 \\
    python3 whip-publisher.py
"""

import asyncio
import logging
import os
import sys

import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.media import MediaPlayer

# ─── Configuration ──────────────────────────────────────────
BACKEND_URL  = os.environ.get("BACKEND_URL",  "http://192.168.1.47:5001")
LIVEKIT_URL  = os.environ.get("LIVEKIT_URL",  "http://192.168.1.47:7880")
DEVICE_ID    = os.environ.get("DEVICE_ID",    "pi-patient-01")
VIDEO_DEVICE = os.environ.get("VIDEO_DEVICE", "/dev/video0")
WIDTH        = os.environ.get("WIDTH",        "1280")
HEIGHT       = os.environ.get("HEIGHT",       "720")
FPS          = os.environ.get("FPS",          "30")
RETRY_DELAY  = 5

# Suppress verbose aiortc/aioice logs — set to DEBUG to troubleshoot
logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")

CYAN  = "\033[0;36m"
GREEN = "\033[0;32m"
WARN  = "\033[1;33m"
RED   = "\033[0;31m"
BOLD  = "\033[1m"
NC    = "\033[0m"

def log(color, tag, msg):
    print(f"{color}[{tag}]{NC} {msg}", flush=True)


# ─── Fetch JWT token from backend ───────────────────────────
async def fetch_token(session: aiohttp.ClientSession) -> tuple[str, str]:
    url = f"{BACKEND_URL}/api/edge/token"
    log(CYAN, "~", f"Fetching token from {url}")
    async with session.get(url, params={"deviceId": DEVICE_ID},
                           timeout=aiohttp.ClientTimeout(total=10)) as r:
        r.raise_for_status()
        data = await r.json()
        token = data.get("token", "")
        room  = data.get("room", "")
        if not token:
            raise ValueError("Backend returned empty token")
        return token, room


# ─── WHIP HTTP signaling ─────────────────────────────────────
# WHIP = WebRTC HTTP Ingest Protocol
# Step 1: POST SDP offer → get SDP answer back (just HTTP)
# Step 2: WebRTC UDP media flow begins using the negotiated ICE/DTLS params
async def whip_exchange(session: aiohttp.ClientSession,
                        token: str,
                        sdp_offer: str) -> str:
    whip_url = f"{LIVEKIT_URL}/rtc/whip"
    log(CYAN, "~", f"WHIP signaling → {whip_url}")
    async with session.post(
        whip_url,
        headers={
            "Content-Type":  "application/sdp",
            "Authorization": f"Bearer {token}",
        },
        data=sdp_offer,
        timeout=aiohttp.ClientTimeout(total=15),
    ) as r:
        body = await r.text()
        if r.status not in (200, 201):
            raise RuntimeError(
                f"WHIP endpoint returned HTTP {r.status}:\n{body}"
            )
        log(GREEN, "OK", "SDP answer received from LiveKit")
        return body


# ─── Single streaming session ────────────────────────────────
async def run_once() -> None:
    async with aiohttp.ClientSession() as session:

        # 1. Token
        token, room = await fetch_token(session)
        log(GREEN, "OK", f"Room: {BOLD}{room}{NC}")

        # 2. Camera — use MJPEG format for max fps from Brio 100
        log(CYAN, "~", f"Opening {VIDEO_DEVICE}  {WIDTH}x{HEIGHT}@{FPS}fps (MJPEG)")
        player = MediaPlayer(
            VIDEO_DEVICE,
            format="v4l2",
            options={
                "video_size":   f"{WIDTH}x{HEIGHT}",
                "framerate":    FPS,
                "input_format": "mjpeg",   # MJPEG → avoids USB bandwidth limit
            },
        )

        if player.video is None:
            raise RuntimeError(
                f"No video track from {VIDEO_DEVICE}. "
                "Try a lower resolution or check the device."
            )

        # 3. WebRTC peer connection
        pc = RTCPeerConnection()
        pc.addTrack(player.video)

        @pc.on("connectionstatechange")
        async def on_state():
            state = pc.connectionState
            if state == "connected":
                log(GREEN, "LIVE", f"Streaming {DEVICE_ID} → {room}")
            elif state in ("failed", "closed", "disconnected"):
                log(WARN, "!", f"Connection state: {state}")

        # 4. SDP offer
        log(CYAN, "~", "Creating SDP offer...")
        offer = await pc.createOffer()
        await pc.setLocalDescription(offer)

        # Wait for ICE candidates to be gathered (max 10s)
        ice_complete = asyncio.Event()

        @pc.on("icegatheringstatechange")
        def on_ice_state():
            if pc.iceGatheringState == "complete":
                ice_complete.set()

        if pc.iceGatheringState != "complete":
            try:
                await asyncio.wait_for(ice_complete.wait(), timeout=10.0)
            except asyncio.TimeoutError:
                log(WARN, "!", "ICE gathering took >10s — proceeding anyway")

        # 5. WHIP exchange (SDP offer → answer)
        answer_sdp = await whip_exchange(session, token, pc.localDescription.sdp)
        await pc.setRemoteDescription(
            RTCSessionDescription(sdp=answer_sdp, type="answer")
        )

        log(GREEN, "OK", f"WebRTC connected. Streaming... (Ctrl+C to stop)\n")

        # 6. Stay alive until disconnected
        while True:
            state = pc.connectionState
            if state in ("failed", "closed"):
                log(WARN, "!", f"Connection ended ({state})")
                break
            await asyncio.sleep(2)


# ─── Main retry loop ─────────────────────────────────────────
async def main() -> None:
    print(f"""
{CYAN}{BOLD}================================================{NC}
{CYAN}{BOLD}  Pi WHIP Publisher (aiortc)                    {NC}
{CYAN}{BOLD}================================================{NC}
  Device ID   : {BOLD}{DEVICE_ID}{NC}
  Camera      : {BOLD}{VIDEO_DEVICE}{NC}
  Resolution  : {BOLD}{WIDTH}x{HEIGHT} @ {FPS}fps{NC}
  Backend     : {BOLD}{BACKEND_URL}{NC}
  LiveKit     : {BOLD}{LIVEKIT_URL}{NC}
{CYAN}{BOLD}================================================{NC}
""")

    while True:
        try:
            await run_once()
        except KeyboardInterrupt:
            print(f"\n{WARN}[!]{NC} Stopped by user.")
            sys.exit(0)
        except Exception as exc:
            log(RED, "ERR", str(exc))

        log(WARN, "~", f"Retrying in {RETRY_DELAY}s ...")
        await asyncio.sleep(RETRY_DELAY)


if __name__ == "__main__":
    asyncio.run(main())
