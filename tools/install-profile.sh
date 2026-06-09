#!/usr/bin/env bash
#
# install-profile.sh — Install an ICC profile via colord
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

echo "[*] Installing: $(basename "$PROFILE")"

# Start colord if not running
if ! systemctl is-active --quiet colord 2>/dev/null; then
    echo "    → Starting colord..."
    sudo systemctl start colord 2>/dev/null || true
fi

PROFILE_ID=$(colormgr add-profile "$PROFILE" 2>/dev/null | grep -oP 'icc-\w+' | head -1 || true)
if [ -z "$PROFILE_ID" ]; then
    PROFILE_ID=$(colormgr import-profile "$PROFILE" 2>/dev/null | grep -oP 'icc-\w+' | head -1 || true)
fi

if [ -z "$PROFILE_ID" ]; then
    echo "✗ Failed to add profile to colord. Try:"
    echo "    KDE System Settings → Color Management → Add → Browse"
    exit 1
fi

echo "    → Profile ID: $PROFILE_ID"

# Add to first available device
DEVICE_ID=$(colormgr get-devices 2>/dev/null | grep "Device ID" | head -1 | awk '{print $NF}' | tr -d '\r' || true)
if [ -n "$DEVICE_ID" ]; then
    colormgr device-add-profile "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
    echo "    → Set as default for $DEVICE_ID"
fi

echo "[✓] Profile installed successfully."
