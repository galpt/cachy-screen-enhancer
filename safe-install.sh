#!/usr/bin/env bash
#
# safe-install.sh — ★ PRIMARY ENTRY POINT
#
# One-command auto-install for cachy-screen-enhancer.
# Detects your GPU, display, and brightness level, then picks and
# installs the best ICC profile automatically.
#
# Usage:
#   bash safe-install.sh
#
# No arguments needed. It does everything.
set -euo pipefail

# ── Sudo session keepalive ────────────────────────────────────
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

# ── Determine script location ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles/icc"

# ── Dependency self-bootstrap ─────────────────────────────────
REQUIRES=("colord")  # EDID parsing is done via the bundled Python module
MISSING=()
for pkg in "${REQUIRES[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[*] Installing missing packages: ${MISSING[*]}"
    sudo pacman -S --noconfirm "${MISSING[@]}"
fi
# ────────────────────────────────────────────────────────────────

# ── Banner ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        cachy-screen-enhancer — Auto Install      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Detect GPU method ───────────────────────────────
echo "[*] Detecting GPU method..."
GPU_METHOD=""
for card in /sys/class/drm/card*/device/vendor; do
    [ -f "$card" ] || continue
    vendor=$(cat "$card" 2>/dev/null || true)
    if [ "$vendor" = "0x1002" ]; then
        GPU_METHOD="amd"
        break
    elif [ "$vendor" = "0x10de" ]; then
        GPU_METHOD="nvidia"
        break
    fi
done

if [ -z "$GPU_METHOD" ] && [ -e /dev/nvidia0 ]; then
    GPU_METHOD="nvidia"
fi

if [ -z "$GPU_METHOD" ]; then
    GPU_METHOD="generic"
fi

echo "    → Method: $GPU_METHOD"
echo ""

# ── Step 2: Find active display and EDID ─────────────────────
echo "[*] Detecting display..."
CONNECTOR=""
DISPLAY_NAME=""
for conn in /sys/class/drm/*/status; do
    status=$(cat "$conn" 2>/dev/null || true)
    [ "$status" = "connected" ] || continue
    conn_path="${conn%/status}"
    conn_name="${conn_path##*/}"

    # Prefer eDP (internal laptop panel)
    if echo "$conn_name" | grep -q "eDP"; then
        CONNECTOR="$conn_name"
        DISPLAY_NAME="$conn_name"
        break
    fi
    # Fallback: first connected
    if [ -z "$CONNECTOR" ]; then
        CONNECTOR="$conn_name"
        DISPLAY_NAME="$conn_name"
    fi
done

if [ -z "$CONNECTOR" ]; then
    echo "    ⚠ No connected display found. Falling back to default profile."
    BEST_FILE="$PROFILES_DIR/cse_200nits_amd.icc"
else
    EDID_PATH="/sys/class/drm/$CONNECTOR/edid"
    echo "    → Display: $CONNECTOR"

    # Parse EDID using the bundled Python module
    python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/src')
from cse_lib.edid_parser import edid_summary
try:
    with open('$EDID_PATH', 'rb') as f:
        edid = edid_summary(f.read())
    mfr = edid.get('manufacturer', 'unknown')
    gamma = edid.get('gamma', '?')
    w = edid.get('width_cm', '?')
    h = edid.get('height_cm', '?')
    print(f'    → {mfr} panel | gamma {gamma} | {w}×{h} cm')
except Exception as e:
    print(f'    → (EDID parse skipped: {e})')
" 2>&1 || true

    # ── Step 3: Detect brightness ──────────────────────────────
    echo "[*] Detecting brightness..."
    BRIGHTNESS_PCT=50  # default
    for backlight in /sys/class/backlight/*; do
        [ -d "$backlight" ] || continue
        actual=$(cat "$backlight/actual_brightness" 2>/dev/null || echo "0")
        max=$(cat "$backlight/max_brightness" 2>/dev/null || echo "1")
        if [ "$max" -gt 0 ]; then
            BRIGHTNESS_PCT=$(( actual * 100 / max ))
        fi
        break
    done
    echo "    → Brightness: ~${BRIGHTNESS_PCT}%"

    # ── Step 4: Map brightness to profile ──────────────────────
    if   [ "$BRIGHTNESS_PCT" -le 12 ]; then WL=080
    elif [ "$BRIGHTNESS_PCT" -le 20 ]; then WL=100
    elif [ "$BRIGHTNESS_PCT" -le 30 ]; then WL=120
    elif [ "$BRIGHTNESS_PCT" -le 50 ]; then WL=200
    elif [ "$BRIGHTNESS_PCT" -le 70 ]; then WL=300
    elif [ "$BRIGHTNESS_PCT" -le 88 ]; then WL=400
    else WL=480
    fi

    BEST_FILE="$PROFILES_DIR/cse_${WL}nits_${GPU_METHOD}.icc"
fi

echo ""

# ── Step 5: Validate profile exists ──────────────────────────
echo "[*] Selecting profile..."
if [ ! -f "$BEST_FILE" ]; then
    echo "    ⚠ Profile not found: $BEST_FILE"
    echo "    → Falling back to cse_200nits_amd.icc"
    BEST_FILE="$PROFILES_DIR/cse_200nits_amd.icc"
fi

if [ ! -f "$BEST_FILE" ]; then
    echo "    ✗ ERROR: No profile files found in $PROFILES_DIR"
    echo "      Run 'python3 src/cse-gen.py --all' to generate them."
    exit 1
fi

PROFILE_NAME="$(basename "$BEST_FILE")"
echo "    → $PROFILE_NAME"
echo ""

# ── Step 6: Install via colord ────────────────────────────────
echo "[*] Installing profile via colord..."

# Check if colord service is running
if ! systemctl is-active --quiet colord 2>/dev/null; then
    echo "    → Starting colord service..."
    sudo systemctl start colord 2>/dev/null || true
fi

# Add profile to colord
PROFILE_ID=$(colormgr add-profile "$BEST_FILE" 2>/dev/null | grep -oP 'icc-\w+' | head -1 || true)

if [ -z "$PROFILE_ID" ]; then
    # Try alternative: import with full path
    PROFILE_ID=$(colormgr import-profile "$BEST_FILE" 2>/dev/null | grep -oP 'icc-\w+' | head -1 || true)
fi

if [ -z "$PROFILE_ID" ]; then
    echo "    ⚠ Could not add profile via colord."
    echo "    → Install manually: KDE System Settings → Color Management → Add → Browse"
    echo "    → Select: $BEST_FILE"
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  Manual install required (see path above).       ║"
    echo "╚══════════════════════════════════════════════════╝"
    exit 0
fi

echo "    → Added profile: $PROFILE_ID"

# Get device ID for the display
DEVICE_ID=""
DEVICE_LIST=$(colormgr get-devices 2>/dev/null)
if echo "$DEVICE_LIST" | grep -q "Device ID"; then
    DEVICE_ID=$(echo "$DEVICE_LIST" | grep -B1 "$CONNECTOR" | grep "Device ID" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
fi

if [ -z "$DEVICE_ID" ] && [ -n "$CONNECTOR" ]; then
    DEVICE_ID=$(echo "$DEVICE_LIST" | grep "Device ID" | head -1 | awk '{print $NF}' | tr -d '\r' || true)
fi

if [ -n "$DEVICE_ID" ]; then
    colormgr device-add-profile "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    echo "    → Set as default for $DEVICE_ID"
else
    echo "    → Set as default (device auto-detection)"
    colormgr device-make-profile-default "$(colormgr get-devices 2>/dev/null | grep "Device ID" | head -1 | awk '{print $NF}' | tr -d '\r')" "$PROFILE_ID" 2>/dev/null || true
fi

echo ""

# ── Success ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════╗"
echo "║  Done! Your screen is now using gamma 2.2.       ║"
echo "║                                                   ║"
echo "║  Selected profile: $PROFILE_NAME"
echo "║                                                   ║"
echo "║  If colors look off, re-run:                      ║"
echo "║    bash tools/remove-profile.sh                   ║"
echo "║  to restore the default sRGB profile.             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
