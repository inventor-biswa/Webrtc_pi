#!/bin/bash
# ============================================================
# Pi Streaming Setup Checker
# Run this on your Raspberry Pi BEFORE starting the stream.
# Usage: bash check-setup.sh
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

OK="${GREEN}[OK]${NC}"
WARN="${YELLOW}[WARN]${NC}"
FAIL="${RED}[FAIL]${NC}"

echo ""
echo -e "${CYAN}${BOLD}================================================${NC}"
echo -e "${CYAN}${BOLD}   Pi Video Streaming Setup Checker             ${NC}"
echo -e "${CYAN}${BOLD}================================================${NC}"
echo ""

# ── 1. Operating System ──────────────────────────────────────
echo -e "${BOLD}[ OS INFO ]${NC}"
if [ -f /etc/os-release ]; then
    source /etc/os-release
    echo -e "  OS Name    : $PRETTY_NAME"
    echo -e "  Version    : ${VERSION_ID:-N/A}"
else
    echo -e "  ${WARN} /etc/os-release not found"
fi
echo -e "  Kernel     : $(uname -r)"
echo -e "  Arch       : $(uname -m)"
echo -e "  Hostname   : $(hostname)"
echo ""

# ── 2. USB Devices ───────────────────────────────────────────
echo -e "${BOLD}[ USB DEVICES ]${NC}"
if command -v lsusb &>/dev/null; then
    CAMERA_USB=$(lsusb | grep -i -E "camera|video|logitech|webcam|usb" || true)
    if [ -n "$CAMERA_USB" ]; then
        echo "$CAMERA_USB" | while read -r line; do
            echo -e "  ${OK} $line"
        done
    else
        echo -e "  ${WARN} No obvious camera USB devices detected via lsusb"
        echo -e "       All USB devices:"
        lsusb | while read -r line; do echo -e "         $line"; done
    fi
else
    echo -e "  ${WARN} lsusb not installed. Run: sudo apt install usbutils"
fi
echo ""

# ── 3. Video Devices ─────────────────────────────────────────
echo -e "${BOLD}[ VIDEO DEVICES (/dev/video*) ]${NC}"
VIDEO_DEVICES=$(ls /dev/video* 2>/dev/null || true)
if [ -z "$VIDEO_DEVICES" ]; then
    echo -e "  ${FAIL} No /dev/video* devices found!"
    echo -e "       Make sure the USB camera is plugged in."
else
    for DEV in $VIDEO_DEVICES; do
        echo -e "  ${OK} Found: $DEV"
    done
fi
echo ""

# ── 4. v4l2-ctl details ──────────────────────────────────────
echo -e "${BOLD}[ CAMERA DETAILS (v4l2-ctl) ]${NC}"
if command -v v4l2-ctl &>/dev/null; then
    v4l2-ctl --list-devices 2>/dev/null | while read -r line; do
        echo -e "  $line"
    done
    echo ""
    if [ -e /dev/video0 ]; then
        echo -e "  ${BOLD}Supported formats on /dev/video0:${NC}"
        v4l2-ctl -d /dev/video0 --list-formats-ext 2>/dev/null | \
            grep -E "Index|Type|Pixel|Size|fps" | while read -r line; do
                echo -e "    $line"
            done
    fi
else
    echo -e "  ${WARN} v4l2-ctl not installed. Run: sudo apt install v4l-utils"
fi
echo ""

# ── 5. ffmpeg check ──────────────────────────────────────
echo -e "${BOLD}[ FFMPEG ]${NC}"
if command -v ffmpeg &>/dev/null; then
    FFMPEG_VER=$(ffmpeg -version 2>&1 | head -1)
    echo -e "  ${OK} $FFMPEG_VER"

    # Check WHIP muxer
    if ffmpeg -muxers 2>/dev/null | grep -q "whip"; then
        echo -e "  ${OK} WHIP muxer supported ✓"
    else
        echo -e "  ${WARN} WHIP muxer NOT in this ffmpeg build"
        echo -e "       NOTE: Debian 13 ships ffmpeg without WHIP compiled in."
        echo -e "       This is normal. Use GStreamer whipsink instead (see below)."
    fi

    # Check v4l2 input support
    if ffmpeg -devices 2>/dev/null | grep -q "v4l2"; then
        echo -e "  ${OK} v4l2 input device supported ✓"
    else
        echo -e "  ${WARN} v4l2 input not found"
    fi

    # Check libx264 encoder
    if ffmpeg -encoders 2>/dev/null | grep -q "libx264"; then
        echo -e "  ${OK} libx264 encoder available ✓"
    else
        echo -e "  ${WARN} libx264 not found. Run: sudo apt install libx264-dev"
    fi
else
    echo -e "  ${FAIL} ffmpeg not installed!"
    echo -e "       Run: sudo apt update && sudo apt install ffmpeg"
fi
echo ""

# ── 5b. GStreamer check (recommended for Debian 13) ────────
echo -e "${BOLD}[ GSTREAMER (recommended for WHIP on Debian 13) ]${NC}"
if command -v gst-launch-1.0 &>/dev/null; then
    GST_VER=$(gst-launch-1.0 --version 2>&1 | head -1)
    echo -e "  ${OK} $GST_VER"

    # Check whipsink (needs gstreamer1.0-plugins-bad)
    if gst-inspect-1.0 whipsink &>/dev/null 2>&1; then
        echo -e "  ${OK} whipsink plugin available ✓  (WHIP streaming works!)"
    else
        echo -e "  ${FAIL} whipsink plugin NOT found"
        echo -e "       Install: sudo apt install gstreamer1.0-plugins-bad"
    fi

    # Check v4l2src
    if gst-inspect-1.0 v4l2src &>/dev/null 2>&1; then
        echo -e "  ${OK} v4l2src plugin available ✓"
    else
        echo -e "  ${WARN} v4l2src not found. Install: sudo apt install gstreamer1.0-plugins-good"
    fi

    # Check jpegdec (for MJPEG input from Brio 100)
    if gst-inspect-1.0 jpegdec &>/dev/null 2>&1; then
        echo -e "  ${OK} jpegdec (MJPEG decoder) available ✓"
    else
        echo -e "  ${WARN} jpegdec not found. Install: sudo apt install gstreamer1.0-plugins-good"
    fi

    # Check x264enc
    if gst-inspect-1.0 x264enc &>/dev/null 2>&1; then
        echo -e "  ${OK} x264enc (H.264 encoder) available ✓"
    else
        echo -e "  ${WARN} x264enc not found. Install: sudo apt install gstreamer1.0-plugins-ugly"
    fi

    # Check rtph264pay
    if gst-inspect-1.0 rtph264pay &>/dev/null 2>&1; then
        echo -e "  ${OK} rtph264pay (RTP packetiser) available ✓"
    else
        echo -e "  ${WARN} rtph264pay not found. Install: sudo apt install gstreamer1.0-plugins-good"
    fi
else
    echo -e "  ${FAIL} GStreamer not installed!"
    echo -e "       Run: sudo apt update && sudo apt install -y \\"
    echo -e "         gstreamer1.0-tools gstreamer1.0-plugins-good \\"
    echo -e "         gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \\"
    echo -e "         gstreamer1.0-libav gstreamer1.0-plugins-base"
fi
echo ""

# ── 6. Network / curl check ──────────────────────────────────
echo -e "${BOLD}[ NETWORK TOOLS ]${NC}"
if command -v curl &>/dev/null; then
    echo -e "  ${OK} curl is available"
else
    echo -e "  ${FAIL} curl not installed. Run: sudo apt install curl"
fi

if command -v python3 &>/dev/null; then
    echo -e "  ${OK} python3 is available (used to parse token JSON)"
else
    echo -e "  ${WARN} python3 not found. Run: sudo apt install python3"
fi
echo ""

# ── 7. Quick camera frame test ───────────────────────────────
echo -e "${BOLD}[ QUICK CAMERA FRAME TEST ]${NC}"
if [ -e /dev/video0 ] && command -v ffmpeg &>/dev/null; then
    echo -e "  Capturing 1 test frame from /dev/video0 to /tmp/test_frame.jpg ..."
    if ffmpeg -hide_banner -loglevel error \
        -f v4l2 -i /dev/video0 -frames:v 1 /tmp/test_frame.jpg -y 2>/dev/null; then
        SIZE=$(du -h /tmp/test_frame.jpg | cut -f1)
        echo -e "  ${OK} Frame captured! Size: $SIZE → /tmp/test_frame.jpg"
    else
        echo -e "  ${FAIL} Frame capture failed. Camera may be in use or unsupported format."
    fi
else
    echo -e "  ${WARN} Skipping — /dev/video0 or ffmpeg not available"
fi
echo ""

# ── 8. Summary ───────────────────────────────────────────────
echo -e "${CYAN}${BOLD}================================================${NC}"
echo -e "${BOLD}  RECOMMENDED NEXT STEPS${NC}"
echo -e "${CYAN}${BOLD}================================================${NC}"
echo ""
echo -e "  1. Install any missing tools shown above:"
echo -e "     ${CYAN}sudo apt update && sudo apt install -y ffmpeg v4l-utils usbutils curl python3${NC}"
echo ""
echo -e "  2. Edit start-stream.sh — set your backend IP:"
echo -e "     ${CYAN}BACKEND_URL=http://<YOUR_MAC_IP>:5000${NC}"
echo -e "     ${CYAN}LIVEKIT_URL=http://<YOUR_MAC_IP>:7880${NC}"
echo ""
echo -e "  3. Run the stream:"
echo -e "     ${CYAN}bash start-stream.sh${NC}"
echo ""
