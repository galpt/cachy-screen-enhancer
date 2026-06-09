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
DISPWIN_OK="no"
if command -v dispwin &>/dev/null; then
    if [ -f "$CAL_FILE" ]; then
        # Find the correct display index (dispwin uses 1-based indexing)
        DISP_IDX=$(dispwin -d ? 2>&1 | grep -i 'eDP\|LVDS\|Display' | grep -oP '^\s+\d+' | head -1 | tr -d ' ' || echo "1")
        DISP_IDX="${DISP_IDX:-1}"
        echo "    → dispwin display index: $DISP_IDX"
        if dispwin -d "$DISP_IDX" "$CAL_FILE" 2>&1; then
            echo "    → Gamma correction applied via dispwin"
            DISPWIN_OK="yes"
        else
            echo "    ⚠ dispwin failed. You can try:"
            echo "      dispwin -d 1 \"$CAL_FILE\""
        fi
    else
        echo "    ⚠ No .cal file at $CAL_FILE"
    fi
fi
echo ""
echo "[*] Installing ICC profile..."

# Generate a VCGT-free ICC profile for colord (standard ICC display
# description — no hardware correction tag). Gamma correction is handled
# separately by dispwin above.
ICC_NO_VCGT="$OUTPUT_DIR/${PROFILE_NAME%.icc}_no-vcgt.icc"
python3 "$SCRIPT_DIR/src/cse-gen.py" --white-level $WL --gpu-method $GPU_METHOD --output-dir $OUTPUT_DIR --output "$ICC_NO_VCGT" >/dev/null 2>&1 || true
ICC_FILE="${ICC_NO_VCGT}"
[ ! -f "$ICC_FILE" ] && ICC_FILE="$BEST_FILE"

    # Copy ICC profile to the user-local colord directory (no sudo needed).
    # kscreen-doctor will point KWin's config to this path.
    COLORD_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icc/colord"
    mkdir -p "$COLORD_DIR"
    cp "$ICC_FILE" "$COLORD_DIR/$PROFILE_NAME"
    touch "$COLORD_DIR" 2>/dev/null || true
for i in 1 2 3 4 5; do
    PROFILE_ID=$(colormgr get-profiles 2>/dev/null | grep -A1 "Filename:.*$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
    [ -n "$PROFILE_ID" ] && break
    sleep 1
done

# Fallback: restart colord to force a rescan
if [ -z "$PROFILE_ID" ]; then
    sudo systemctl restart colord 2>/dev/null || true
    sleep 2
    PROFILE_ID=$(colormgr get-profiles 2>/dev/null | grep -A1 "Filename:.*$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
fi

# Set the ICC profile via kscreen-doctor (the proper KDE API for display
# color management). This updates both KScreen's state AND KWin's config,
# so the GUI reflects the change immediately.
KWIN_CONNECTOR="${CONNECTOR#card*-}"
echo "    → Setting ICC profile via kscreen-doctor..."
if command -v kscreen-doctor &>/dev/null; then
    kscreen-doctor "output.$KWIN_CONNECTOR.iccprofile.$COLORD_DIR/$PROFILE_NAME" 2>&1 || \
    echo "    ⚠ kscreen-doctor failed"
    echo "    → ICC profile set for $KWIN_CONNECTOR"
else
    echo "    → Open System Settings → Display & Monitor → Display Configuration"
    echo "    → Click your monitor → Color profile"
    echo "    → Select \"ICC profile\" and browse to: $COLORD_DIR/$PROFILE_NAME"
fi

# Also register profile if it wasn't already (inotify may not have caught it)
sudo systemctl restart colord 2>/dev/null || true

echo ""
echo "+----------------------------------------------------+"
echo "|  All done!                                         |"
echo "|                                                    |"
if [ "$DISPWIN_OK" = "yes" ]; then
    echo "|  + Gamma correction via dispwin                    |"
    echo "|  + ICC profile installed                           |"
else
    echo "|  + ICC profile installed                           |"
fi
echo "|                                                    |"
echo "|  To remove:                                        |"
echo "|    bash tools/remove-profile.sh                    |"
echo "+----------------------------------------------------+"
echo ""
echo "Selected profile: $PROFILE_NAME"
if [ "$DISPWIN_OK" != "yes" ]; then
    echo ""
    echo "Manual gamma correction (if needed):"
    echo "  dispwin -d 1 $CAL_FILE"
fi
echo ""
