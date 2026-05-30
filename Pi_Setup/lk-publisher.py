#!/usr/bin/env python3
"""
Pi LiveKit Publisher — Official LiveKit Python SDK
Connects to LiveKit room via WebSocket and publishes USB camera video.
No WHIP, no Ingress — uses LiveKit's native SDK protocol directly.

INSTALL (run once on Pi):
    pip3 install livekit requests --break-system-packages
    sudo apt install -y python3-opencv

RUN:
    BACKEND_URL=http://192.168.1.47:5001 \\
    LIVEKIT_URL=ws://192.168.1.47:7880 \\
    DEVICE_ID=pi-patient-01 \\
    python3 ~/webrtc/lk-publisher.py
"""

import asyncio
import os
import sys

import cv2
import requests
from livekit import rtc

# ─── Configuration ──────────────────────────────────────────
BACKEND_URL  = os.environ.get("BACKEND_URL",  "http://192.168.1.47:5001")
LIVEKIT_URL  = os.environ.get("LIVEKIT_URL",  "ws://192.168.1.47:7880")
DEVICE_ID    = os.environ.get("DEVICE_ID",    "pi-patient-01")
VIDEO_DEVICE = int(os.environ.get("VIDEO_DEVICE_INDEX", "0"))  # 0 = /dev/video0
WIDTH        = int(os.environ.get("WIDTH",   "1280"))
HEIGHT       = int(os.environ.get("HEIGHT",  "720"))
FPS          = int(os.environ.get("FPS",     "30"))
RETRY_DELAY  = 5

CYAN  = "\033[0;36m"
GREEN = "\033[0;32m"
WARN  = "\033[1;33m"
RED   = "\033[0;31m"
BOLD  = "\033[1m"
NC    = "\033[0m"

def log(color, tag, msg):
    print(f"{color}[{tag}]{NC} {msg}", flush=True)


# ─── Convert http:// → ws:// for LiveKit SDK ────────────────
def to_ws_url(url: str) -> str:
    if url.startswith("http://"):
        return "ws://" + url[7:]
    if url.startswith("https://"):
        return "wss://" + url[8:]
    return url  # already ws:// or wss://


# ─── Fetch JWT token from our Express backend ────────────────
def fetch_token() -> tuple[str, str]:
    url = f"{BACKEND_URL}/api/edge/token"
    log(CYAN, "~", f"Fetching token → {url}")
    r = requests.get(url, params={"deviceId": DEVICE_ID}, timeout=10)
    r.raise_for_status()
    data = r.json()
    token = data.get("token", "")
    room  = data.get("room", "")
    if not token:
        raise ValueError("Backend returned empty token")
    return token, room


# ─── Camera → LiveKit ────────────────────────────────────────
async def publish_camera(room: rtc.Room) -> None:
    """Open USB camera, create LiveKit video track, stream frames."""

    # Open V4L2 camera via OpenCV
    log(CYAN, "~", f"Opening /dev/video{VIDEO_DEVICE}  {WIDTH}x{HEIGHT}@{FPS}fps")
    cap = cv2.VideoCapture(VIDEO_DEVICE, cv2.CAP_V4L2)

    # Request MJPEG from camera — avoids USB bandwidth limit at 720p/1080p
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)
    cap.set(cv2.CAP_PROP_FPS,          FPS)

    if not cap.isOpened():
        raise RuntimeError(f"Cannot open camera /dev/video{VIDEO_DEVICE}")

    actual_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    log(GREEN, "OK", f"Camera opened: {actual_w}x{actual_h}")

    # Create LiveKit video source and track
    source = rtc.VideoSource(width=actual_w, height=actual_h)
    track  = rtc.LocalVideoTrack.create_video_track("camera", source)

    options = rtc.TrackPublishOptions(
        source=rtc.TrackSource.SOURCE_CAMERA,
        video_codec=rtc.VideoCodec.H264,
        simulcast=False,
    )
    pub = await room.local_participant.publish_track(track, options)
    log(GREEN, "LIVE", f"Track published — SID: {pub.sid}")
    log(GREEN, "LIVE", f"Streaming {BOLD}{DEVICE_ID}{NC} to room. Press Ctrl+C to stop.\n")

    frame_interval = 1.0 / FPS

    try:
        while True:
            ret, bgr = cap.read()
            if not ret:
                log(WARN, "!", "Camera read failed — stopping")
                break

            # Convert BGR (OpenCV default) → RGBA (LiveKit VideoFrame format)
            rgba = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGBA)

            video_frame = rtc.VideoFrame(
                width=actual_w,
                height=actual_h,
                type=rtc.VideoBufferType.RGBA,
                data=rgba.tobytes(),
            )
            source.capture_frame(video_frame)
            await asyncio.sleep(frame_interval)
    finally:
        cap.release()
        log(CYAN, "~", "Camera released")


# ─── Main retry loop ─────────────────────────────────────────
async def main() -> None:
    ws_url = to_ws_url(LIVEKIT_URL)

    print(f"""
{CYAN}{BOLD}================================================{NC}
{CYAN}{BOLD}  Pi LiveKit Publisher (Python SDK)             {NC}
{CYAN}{BOLD}================================================{NC}
  Device ID   : {BOLD}{DEVICE_ID}{NC}
  Camera      : {BOLD}/dev/video{VIDEO_DEVICE}{NC}
  Resolution  : {BOLD}{WIDTH}x{HEIGHT} @ {FPS}fps{NC}
  Backend     : {BOLD}{BACKEND_URL}{NC}
  LiveKit WS  : {BOLD}{ws_url}{NC}
{CYAN}{BOLD}================================================{NC}
""")

    while True:
        room = None
        try:
            # 1. Token
            token, room_name = fetch_token()
            log(GREEN, "OK", f"Room: {BOLD}{room_name}{NC}")

            # 2. Connect to LiveKit via WebSocket
            room = rtc.Room()

            @room.on("disconnected")
            def on_disconnected(reason=None):
                log(WARN, "!", f"Disconnected from LiveKit: {reason}")

            log(CYAN, "~", f"Connecting to LiveKit: {ws_url}")
            await room.connect(ws_url, token, options=rtc.RoomOptions(
                auto_subscribe=False,  # Publisher only — don't subscribe to others
            ))
            log(GREEN, "OK", f"Connected to room: {BOLD}{room_name}{NC}")

            # 3. Publish camera
            await publish_camera(room)

        except KeyboardInterrupt:
            print(f"\n{WARN}[!]{NC} Stopped by user.")
            if room:
                await room.disconnect()
            sys.exit(0)
        except Exception as exc:
            log(RED, "ERR", str(exc))
        finally:
            if room:
                try:
                    await room.disconnect()
                except Exception:
                    pass

        log(WARN, "~", f"Retrying in {RETRY_DELAY}s ...")
        await asyncio.sleep(RETRY_DELAY)


if __name__ == "__main__":
    asyncio.run(main())
