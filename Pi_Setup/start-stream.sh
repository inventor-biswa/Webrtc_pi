#!/bin/bash
# ============================================================
# Pi USB Camera → LiveKit Streamer
# Camera:  Logitech Brio 100 (or any USB camera on /dev/video0)
# OS:      Debian GNU/Linux 13 (trixie) / Raspberry Pi OS
# Method:  static ffmpeg WHIP  (primary)   ← download from johnvansickle.com
#          GStreamer whipsink   (fallback)
#          system ffmpeg WHIP  (fallback)
#
# SETUP:
#   Option A — Static ffmpeg (recommended, 5 min setup):
#     mkdir -p ~/ffmpeg-static && cd ~/ffmpeg-static
#     wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz
#     tar xf ffmpeg-release-arm64-static.tar.xz --strip-components=1
#     # Verify: ./ffmpeg -muxers 2>/dev/null | grep whip
#
#   Option B — GStreamer (if whipsink is available):
#     sudo apt install gstreamer1.0-plugins-bad
#
#   Then run:  bash start-stream.sh
# ============================================================

set -euo pipefail

# ─── CONFIGURATION (EDIT THESE) ────────────────────────────
BACKEND_URL="${BACKEND_URL:-http://192.168.1.47:5001}"    # Mac/EC2 IP:5001
LIVEKIT_URL="${LIVEKIT_URL:-http://192.168.1.47:7880}"    # Mac/EC2 IP:7880
DEVICE_ID="${DEVICE_ID:-pi-patient-01}"                    # Unique ID per Pi
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"                # USB camera device

# Path to static ffmpeg binary (downloaded from johnvansickle.com)
# Leave as-is if you followed the setup instructions above.
STATIC_FFMPEG="${STATIC_FFMPEG:-$HOME/ffmpeg-static/ffmpeg}"

# ─── VIDEO QUALITY ───────────────────────────────────────────
# Brio 100 supports MJPEG @ 1280x720 30fps — best for streaming
# Options: 640x480, 1280x720, 1920x1080 (lower fps at higher res)
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
BITRATE_KBPS="${BITRATE_KBPS:-2000}"   # kbps (2000 = good 720p quality)
# ─────────────────────────────────────────────────────────────

KEYFRAME_SEC=2    # Send keyframe every 2 seconds (important for WebRTC)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo -e "${CYAN}${BOLD}   Pi → LiveKit Streamer                        ${NC}"
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo -e "  Device ID  : ${BOLD}$DEVICE_ID${NC}"
    echo -e "  Camera     : ${BOLD}$VIDEO_DEVICE${NC}"
    echo -e "  Resolution : ${BOLD}${WIDTH}x${HEIGHT} @ ${FPS}fps${NC}"
    echo -e "  Bitrate    : ${BOLD}${BITRATE_KBPS}kbps${NC}"
    echo -e "  Backend    : ${BOLD}$BACKEND_URL${NC}"
    echo -e "  LiveKit    : ${BOLD}$LIVEKIT_URL${NC}"
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo ""
}

# ─── Pre-flight checks ───────────────────────────────────────
preflight_check() {
    if [ ! -e "$VIDEO_DEVICE" ]; then
        echo -e "${RED}[ERROR]${NC} Camera $VIDEO_DEVICE not found!"
        echo "  Available: $(ls /dev/video* 2>/dev/null | tr '\n' ' ' || echo 'none')"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} curl not installed. Run: sudo apt install curl"
        exit 1
    fi

    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} python3 not installed. Run: sudo apt install python3"
        exit 1
    fi
}

# ─── Detect streaming method ────────────────────────────────
# Priority: static-ffmpeg-WHIP → GStreamer whipsink → system-ffmpeg-WHIP
detect_stream_method() {
    # 1. Static ffmpeg (johnvansickle.com build — has all features)
    if [ -x "$STATIC_FFMPEG" ]; then
        if "$STATIC_FFMPEG" -muxers 2>/dev/null | grep -q "whip"; then
            echo "static-ffmpeg"
            return
        fi
    fi

    # 2. GStreamer whipsink
    if command -v gst-launch-1.0 &>/dev/null; then
        if gst-inspect-1.0 whipsink &>/dev/null 2>&1; then
            echo "gstreamer"
            return
        else
            echo -e "${YELLOW}[WARN]${NC} GStreamer found but whipsink plugin missing." >&2
            echo -e "       Pi OS Debian 13 compiles gst-plugins-bad without libnice (WebRTC)." >&2
            echo -e "       → Use static ffmpeg instead (see setup instructions at top of script)." >&2
        fi
    fi

    # 3. System ffmpeg WHIP muxer
    if command -v ffmpeg &>/dev/null; then
        if ffmpeg -muxers 2>/dev/null | grep -q "whip"; then
            echo "system-ffmpeg"
            return
        else
            echo -e "${YELLOW}[WARN]${NC} System ffmpeg has no WHIP muxer (Debian packaging limitation)." >&2
        fi
    fi

    echo "none"
}

# ─── Fetch JWT token from backend ────────────────────────────
fetch_token() {
    local url="${BACKEND_URL}/api/edge/token?deviceId=${DEVICE_ID}"
    local response

    response=$(curl -sf --max-time 10 "$url" || true)

    if [ -z "$response" ]; then
        return 1
    fi

    TOKEN=$(echo "$response" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true)
    ROOM=$(echo "$response" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('room',''))" 2>/dev/null || true)

    [ -n "$TOKEN" ]
}

# ─── GStreamer stream ─────────────────────────────────────────
# Pipeline explanation:
#   v4l2src            → reads from USB camera
#   image/jpeg,...     → request MJPEG from camera (avoids USB bandwidth limit)
#   jpegdec            → decode MJPEG to raw frames
#   videoconvert       → convert colour space for encoder
#   x264enc            → encode to H.264 (browser-compatible)
#   rtph264pay         → packetise H.264 into RTP (required for WebRTC)
#   whipsink           → push via WHIP protocol to LiveKit
run_gstreamer() {
    local token="$1"
    local keyframe_int=$(( FPS * KEYFRAME_SEC ))
    local whip_url="${LIVEKIT_URL}/rtc/whip"

    echo -e "${GREEN}[GST]${NC} Starting GStreamer pipeline → WHIP"
    echo -e "      Pipeline: v4l2src(MJPEG) → jpegdec → x264enc → rtph264pay → whipsink"
    echo ""

    gst-launch-1.0 -e \
        v4l2src device="$VIDEO_DEVICE" \
            do-timestamp=true \
            ! image/jpeg,width="${WIDTH}",height="${HEIGHT}",framerate="${FPS}/1" \
            ! jpegdec \
            ! videoconvert \
            ! x264enc \
                tune=zerolatency \
                speed-preset=ultrafast \
                bitrate="${BITRATE_KBPS}" \
                key-int-max="${keyframe_int}" \
            ! rtph264pay config-interval=-1 \
            ! whipsink \
                location="${whip_url}" \
                auth-token="${token}"
}

# ─── ffmpeg stream (static or system) ──────────────────────────────
run_ffmpeg() {
    local token="$1"
    local ffmpeg_bin="$2"   # path to ffmpeg binary
    local keyframe_int=$(( FPS * KEYFRAME_SEC ))
    local whip_url="${LIVEKIT_URL}/rtc/whip"

    echo -e "${GREEN}[FFM]${NC} Starting ffmpeg stream → WHIP  ($ffmpeg_bin)"
    echo ""

    "$ffmpeg_bin" \
        -hide_banner \
        -loglevel warning \
        -f v4l2 \
        -input_format mjpeg \
        -framerate "$FPS" \
        -video_size "${WIDTH}x${HEIGHT}" \
        -i "$VIDEO_DEVICE" \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -b:v "${BITRATE_KBPS}k" \
        -maxrate "${BITRATE_KBPS}k" \
        -bufsize "$(( BITRATE_KBPS * 2 ))k" \
        -g "$keyframe_int" \
        -f whip \
        -headers "Authorization: Bearer $token" \
        "$whip_url"
}

# ─── Main ────────────────────────────────────────────────────
print_banner
preflight_check

METHOD=$(detect_stream_method)

if [ "$METHOD" = "none" ]; then
    echo -e "${RED}[ERROR]${NC} No working WHIP stream method found!"
    echo ""
    echo "  ─── RECOMMENDED FIX (5 min) ──────────────────────────────"
    echo "  Download static ffmpeg for ARM64 (includes all features):"
    echo ""
    echo "  mkdir -p ~/ffmpeg-static && cd ~/ffmpeg-static"
    echo "  wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz"
    echo "  tar xf ffmpeg-release-arm64-static.tar.xz --strip-components=1"
    echo "  # Verify WHIP: ./ffmpeg -muxers 2>/dev/null | grep whip"
    echo "  ─────────────────────────────────────────────────"
    exit 1
fi

if [ "$METHOD" = "static-ffmpeg" ]; then
    echo -e "  Stream method : ${BOLD}static ffmpeg WHIP${NC}  ($STATIC_FFMPEG)"
elif [ "$METHOD" = "gstreamer" ]; then
    echo -e "  Stream method : ${BOLD}GStreamer whipsink${NC}"
else
    echo -e "  Stream method : ${BOLD}system ffmpeg WHIP${NC}"
fi
echo ""

# ─── Retry loop ──────────────────────────────────────────────
RETRY_DELAY=5
ATTEMPT=0
TOKEN=""
ROOM=""

while true; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    echo -e "${CYAN}[Attempt $ATTEMPT]${NC} Fetching token for device: ${BOLD}$DEVICE_ID${NC}"

    if ! fetch_token; then
        echo -e "${YELLOW}[WARN]${NC} Backend unreachable at $BACKEND_URL — retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
        continue
    fi

    echo -e "${GREEN}[OK]${NC} Token received for room: ${BOLD}$ROOM${NC}"

    # Run the appropriate streamer
    if [ "$METHOD" = "static-ffmpeg" ]; then
        run_ffmpeg "$TOKEN" "$STATIC_FFMPEG" || true
    elif [ "$METHOD" = "gstreamer" ]; then
        run_gstreamer "$TOKEN" || true
    else
        run_ffmpeg "$TOKEN" "ffmpeg" || true
    fi

    echo ""
    echo -e "${YELLOW}[WARN]${NC} Stream ended. Retrying in ${RETRY_DELAY}s ..."
    sleep "$RETRY_DELAY"
done
