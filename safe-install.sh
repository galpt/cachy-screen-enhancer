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
REQUIRES=("colord" "argyllcms")  # colord for ICC registration, argyllcms for dispwin gamma LUT
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
echo "+----------------------------------------------------+"
echo "|       cachy-screen-enhancer — Auto Install         |"
echo "+----------------------------------------------------+"
echo ""

# ── Step 1: Detect GPU method (via Python module — uses connected
#          display filters, not just the first DRM card found)
echo "[*] Detecting GPU method..."
GPU_METHOD=$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/src')
from cse_lib.gpu_detect import detect_gpu_method
print(detect_gpu_method())
" 2>/dev/null || echo "generic")
echo "    → Method: $GPU_METHOD"

# ── Step 2: Detect display & brightness ──────────────────────
echo "[*] Detecting display..."
CONNECTOR=""
for conn in /sys/class/drm/*/status; do
    status=$(cat "$conn" 2>/dev/null || true)
    [ "$status" = "connected" ] || continue
    conn_path="${conn%/status}"
    conn_name="${conn_path##*/}"
    if echo "$conn_name" | grep -q "eDP"; then
        CONNECTOR="$conn_name"; break
    fi
    [ -z "$CONNECTOR" ] && CONNECTOR="$conn_name"
done

EDID_PATH=""
if [ -n "$CONNECTOR" ]; then
    EDID_PATH="/sys/class/drm/$CONNECTOR/edid"
    echo "    → Display: $CONNECTOR"
fi

echo "[*] Detecting brightness..."
BRIGHTNESS_PCT=50
for backlight in /sys/class/backlight/*; do
    [ -d "$backlight" ] || continue
    actual=$(cat "$backlight/actual_brightness" 2>/dev/null || echo "0")
    max=$(cat "$backlight/max_brightness" 2>/dev/null || echo "1")
    [ "$max" -gt 0 ] && BRIGHTNESS_PCT=$(( actual * 100 / max ))
    break
done
echo "    → Brightness: ~${BRIGHTNESS_PCT}%"

# Map brightness to white level
if   [ "$BRIGHTNESS_PCT" -le 12 ]; then WL=080
elif [ "$BRIGHTNESS_PCT" -le 20 ]; then WL=100
elif [ "$BRIGHTNESS_PCT" -le 30 ]; then WL=120
elif [ "$BRIGHTNESS_PCT" -le 50 ]; then WL=200
elif [ "$BRIGHTNESS_PCT" -le 70 ]; then WL=300
elif [ "$BRIGHTNESS_PCT" -le 88 ]; then WL=400
else WL=480
fi

echo ""

# ── Step 3: Generate a hardware-specific profile ─────────────
echo "[*] Generating profile for your hardware..."
OUTPUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUTPUT_DIR"

# Generate ICC profile with VCGT hardware correction (for KWin Wayland)
GEN_ARGS="--white-level $WL --gpu-method $GPU_METHOD --output-dir $OUTPUT_DIR --with-vcgt"
python3 "$SCRIPT_DIR/src/cse-gen.py" $GEN_ARGS 2>&1 || true

BEST_FILE="$OUTPUT_DIR/cse_${WL}nits_${GPU_METHOD}.icc"
CAL_FILE="$OUTPUT_DIR/cse_${WL}nits_${GPU_METHOD}.cal"

# Also generate a .cal file (for fallback application methods)
python3 "$SCRIPT_DIR/src/cse-gen.py" --cal-only --white-level $WL --gpu-method $GPU_METHOD --output-dir $OUTPUT_DIR >/dev/null 2>&1 || true

# If generation failed, fall back to prebuilt profiles
if [ ! -f "$BEST_FILE" ]; then
    echo "    ⚠ Profile generation failed. Falling back to prebuilt profiles."
    BEST_FILE="$PROFILES_DIR/cse_${WL}nits_${GPU_METHOD}.icc"
    CAL_FILE="$PROFILES_DIR/cse_${WL}nits_amd.cal"
    if [ ! -f "$BEST_FILE" ]; then
        BEST_FILE="$PROFILES_DIR/cse_${WL}nits_amd.icc"
    fi
    if [ ! -f "$BEST_FILE" ]; then
        BEST_FILE="$PROFILES_DIR/cse_200nits_amd.icc"
        CAL_FILE="$PROFILES_DIR/cse_200nits_amd.cal"
    fi
fi

if [ ! -f "$BEST_FILE" ]; then
    echo "    ✗ ERROR: No profile available. Run 'python3 src/cse-gen.py --all' to generate one."
    exit 1
fi

PROFILE_NAME="$(basename "$BEST_FILE")"
echo "    → Profile: $PROFILE_NAME"
echo ""

# ── Step 6: Try hardware gamma correction via dispwin (ArgyllCMS) ─
echo "[*] Applying gamma correction..."
if command -v dispwin &>/dev/null; then
    if [ -f "$CAL_FILE" ]; then
        dispwin -d 0 "$CAL_FILE" 2>&1 || echo "    ⚠ dispwin failed"
        echo "    → Gamma correction applied via dispwin"
    else
        echo "    ⚠ No .cal file at $CAL_FILE"
    fi
fi
echo ""

# ── Step 7: Install ICC profile (for color-aware applications) ─
echo "[*] Installing ICC profile..."
COLORD_DIR="/usr/share/color/icc/colord"
sudo mkdir -p "$COLORD_DIR"
sudo cp "$BEST_FILE" "$COLORD_DIR/$PROFILE_NAME"
sudo systemctl restart colord 2>/dev/null || true
sleep 1

PROFILE_ID=$(colormgr get-profiles 2>&1 | grep -B1 "$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
if [ -z "$PROFILE_ID" ]; then
    echo "    → Copied to $COLORD_DIR/$PROFILE_NAME"
    echo "    → Settings → Display & Monitor → Display Configuration → Color profile"
    echo "    → Select it as your color profile"
else
    DEVICE_ID=$(colormgr get-devices 2>&1 | grep -B1 "$CONNECTOR" | grep "Device ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
    [ -z "$DEVICE_ID" ] && DEVICE_ID=$(colormgr get-devices 2>&1 | grep "Device ID:" | head -1 | awk '{print $NF}' | tr -d '\r' || true)
    if [ -n "$DEVICE_ID" ]; then
        colormgr device-add-profile "$DEVICE_ID" "$PROFILE_ID" 2>&1 || true
        colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>&1 || true
        echo "    → Registered as default: $PROFILE_ID"
    fi
fi

echo ""
echo "Selected profile: $PROFILE_NAME"
echo ""
echo "+----------------------------------------------------+"
echo "|  Profile installed.                                |"
echo "|                                                    |"
echo "|  For hardware gamma correction (deeper blacks):    |"
echo "|    sudo pacman -S argyllcms                        |"
echo "|    dispwin -d 0 profiles/cal/cse_200nits_amd.cal   |"
echo "|                                                    |"
echo "|  To remove:                                        |"
echo "|    bash tools/remove-profile.sh                    |"
echo "+----------------------------------------------------+"
echo ""
