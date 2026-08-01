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

# ── Determine output directory ────────────────────────────────
# When installed via PKGBUILD to /usr/share/, use user-local dir.
# When running from git clone, use local output/ dir.
if [[ "$SCRIPT_DIR" == /usr/share/* ]]; then
    OUTPUT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cachy-screen-enhancer/output"
else
    OUTPUT_DIR="$SCRIPT_DIR/output"
fi

# ── Dependency self-bootstrap ─────────────────────────────────
REQUIRES=("python" "colord" "argyllcms")  # python for profile generation + detection
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

# ── Step 6: Apply gamma correction ─────────────────────────────
# Session type decides the mechanism:
#   Wayland: dispwin is X11-only and its gamma writes land in XWayland's
#            RANDR structures, which KWin never applies — a no-op. The
#            real path is KWin's ICC pipeline (set in step 7).
#   X11:     dispwin writes the .cal LUT directly to the X server's
#            gamma ramp, which genuinely affects the screen.
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
echo "[*] Applying gamma correction (session: $SESSION_TYPE)..."
DISPWIN_OK="no"
if [ "$SESSION_TYPE" != "wayland" ] && command -v dispwin &>/dev/null; then
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
elif [ "$SESSION_TYPE" = "wayland" ]; then
    echo "    → Wayland session: dispwin is a no-op here (X11-only)."
    echo "      Using KWin's ICC pipeline instead (step 7)."
else
    echo "    → dispwin unavailable, using KWin's ICC pipeline instead."
fi
echo ""
echo "[*] Installing ICC profile..."

# Generate a VCGT-free ICC profile (standard ICC display description).
# KWin applies the profile's TRC through its color pipeline; embedding a
# vcgt tag here would double-apply the correction.
ICC_NO_VCGT="$OUTPUT_DIR/${PROFILE_NAME%.icc}_no-vcgt.icc"
python3 "$SCRIPT_DIR/src/cse-gen.py" --white-level $WL --gpu-method $GPU_METHOD --output-dir $OUTPUT_DIR --output "$ICC_NO_VCGT" >/dev/null 2>&1 || true
ICC_FILE="${ICC_NO_VCGT}"
[ ! -f "$ICC_FILE" ] && ICC_FILE="$BEST_FILE"

    # Copy ICC profile to the user-local colord directory (no sudo needed)
    # so color-aware apps (Firefox, GIMP, Krita) can find it.
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

if [ -n "$PROFILE_ID" ]; then
    echo "    → Profile registered with colord: $PROFILE_ID"
fi

# ── Step 7: Activate the ICC profile in KWin ───────────────────
# Set the profile path, the profile source, and the power tradeoff.
#   colorProfileSource.ICC:   tells KWin to use the profile
#   colorPowerTradeoff.preferEfficiency: lets KWin offload the ICC
#     transformation to the KMS hardware color pipeline instead of a
#     shadow buffer — which keeps direct scanout working on GPUs that
#     support the plane color pipeline (AMD with Linux 6.13+).
KWIN_CONNECTOR="${CONNECTOR#card*-}"
echo "    → Activating ICC profile via kscreen-doctor..."
if command -v kscreen-doctor &>/dev/null; then
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.iccprofile.$COLORD_DIR/$PROFILE_NAME" 2>&1 || \
    echo "    ⚠ kscreen-doctor set-iccpath failed (timed out or errored)"
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.colorProfileSource.ICC" 2>&1 || \
    echo "    ⚠ kscreen-doctor set-source failed (timed out or errored)"
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.colorPowerTradeoff.preferEfficiency" 2>&1 || \
    echo "    ⚠ kscreen-doctor set-tradeoff failed (timed out or errored)"
    echo "    → ICC profile activated for $KWIN_CONNECTOR (prefer efficiency)"
else
    echo "    → Open System Settings → Display & Monitor → Display Configuration"
    echo "    → Click your monitor → Color profile → select the profile"
fi

echo ""
echo "+----------------------------------------------------+"
echo "|  All done!                                         |"
echo "|                                                    |"
if [ "$DISPWIN_OK" = "yes" ]; then
    echo "|  + Gamma correction via dispwin (X11)             |"
else
    echo "|  + Gamma correction via KWin ICC pipeline         |"
fi
echo "|  + Profile available to color-aware apps           |"
echo "|                                                    |"
echo "|  To remove:                                        |"
echo "|    bash tools/remove-profile.sh                    |"
echo "+----------------------------------------------------+"
echo ""
echo "Selected profile: $PROFILE_NAME"
echo ""
