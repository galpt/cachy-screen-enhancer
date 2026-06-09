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
REQUIRES=("colord")
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

# Copy to system profile directory and restart colord
COLORD_DIR="/usr/share/color/icc/colord"
sudo mkdir -p "$COLORD_DIR"
sudo cp "$PROFILE" "$COLORD_DIR/$PROFILE_NAME"
sudo systemctl restart colord 2>/dev/null || true
sleep 1

# Find the registered profile ID
PROFILE_ID=$(colormgr get-profiles 2>/dev/null | grep -B1 "$PROFILE_NAME" | grep "Profile ID:" | awk '{print $NF}' | tr -d '\r' | head -1 || true)

if [ -z "$PROFILE_ID" ]; then
    echo "    → Copied to $COLORD_DIR/$PROFILE_NAME"
    echo "    → Open Settings → Display & Monitor → Display Configuration → Color profile"
    echo "    → Select it from the list"
    exit 0
fi

echo "    → Registered: $PROFILE_ID"

# Set as default for the first display device
DEVICE_ID=$(colormgr get-devices 2>/dev/null | grep "Device ID:" | head -1 | awk '{print $NF}' | tr -d '\r' || true)
if [ -n "$DEVICE_ID" ]; then
    colormgr device-add-profile "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    echo "    → Set as default for $DEVICE_ID"
fi

echo "[✓] Profile installed."
