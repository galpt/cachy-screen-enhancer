#!/usr/bin/env bash
#
# install-profile.sh — Install an ICC profile system-wide
#
# Usage:
#   bash tools/install-profile.sh [path/to/profile.icc]
#
# If no path is given, defaults to profiles/icc/cse_200nits_amd.icc
set -euo pipefail

# ── Sudo session keepalive ────────────────────────────────────
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

# ── Determine script location ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PROFILE="$SCRIPT_DIR/profiles/icc/cse_200nits_amd.icc"
PROFILE="${1:-$DEFAULT_PROFILE}"

# ── Dependency self-bootstrap ─────────────────────────────────
REQUIRES=("python" "colord")
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

# Validate profile
if [ ! -f "$PROFILE" ]; then
    echo "✗ Profile not found: $PROFILE"
    exit 1
fi

PROFILE_NAME="$(basename "$PROFILE")"
echo "[*] Installing: $PROFILE_NAME"

# Copy to user-local colord directory (no sudo needed)
COLORD_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icc/colord"
mkdir -p "$COLORD_DIR"
cp "$PROFILE" "$COLORD_DIR/$PROFILE_NAME"
touch "$COLORD_DIR" 2>/dev/null || true

# Poll for up to 5 seconds for colord to auto-register (inotify)
for i in 1 2 3 4 5; do
    PROFILE_ID=$(colormgr get-profiles 2>/dev/null | grep -A1 "Filename:.*$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
    [ -n "$PROFILE_ID" ] && break
    sleep 1
done

# Fallback: restart colord to force rescan
if [ -z "$PROFILE_ID" ]; then
    sudo systemctl restart colord 2>/dev/null || true
    sleep 2
    PROFILE_ID=$(colormgr get-profiles 2>/dev/null | grep -A1 "Filename:.*$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)
fi

if [ -z "$PROFILE_ID" ]; then
    echo "    → Copied to $COLORD_DIR/$PROFILE_NAME"
    echo "    → Open Settings → Display & Monitor → Display Configuration → Color profile"
    echo "    → Add it manually from the list"
    exit 0
fi

echo "    → Registered: $PROFILE_ID"

# Get or create a display device
DEVICE_ID=$(colormgr get-devices 2>/dev/null | grep "Device ID:" | head -1 | awk '{print $NF}' | tr -d '\r' || true)
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(sudo colormgr create-device "display-${PROFILE_NAME%.*}" "system" "display" 2>&1 | grep -oP 'icc-\w+' | head -1 || true)
    sleep 1
fi

if [ -n "$DEVICE_ID" ]; then
    colormgr device-add-profile "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    echo "    → Set as default for display device"
fi

echo "[✓] Profile installed."
