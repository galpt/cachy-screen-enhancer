#!/usr/bin/env bash
#
# remove-profile.sh — Remove all cachy-screen-enhancer profiles from colord
#
# Usage:
#   bash tools/remove-profile.sh
#
# Restores the default sRGB profile.
set -euo pipefail

# ── Sudo session keepalive ────────────────────────────────────
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

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

echo "[*] Removing cachy-screen-enhancer profiles..."

# Get all profiles
PROFILES=$(colormgr get-profiles 2>/dev/null || true)

# Find cse profiles
echo "$PROFILES" | grep -i "cachy-screen-enhancer" -B2 | grep "Profile ID" | awk '{print $NF}' | tr -d '\r' | while read -r pid; do
    [ -z "$pid" ] && continue
    echo "    → Removing $pid"
    colormgr delete-profile "$pid" 2>/dev/null || true
done

# Find device IDs and restore sRGB
DEVICES=$(colormgr get-devices 2>/dev/null || true)
echo "$DEVICES" | grep "Device ID" | awk '{print $NF}' | tr -d '\r' | while read -r did; do
    [ -z "$did" ] && continue
    # Try to add sRGB as default
    colormgr device-add-profile "$did" "sRGB" 2>/dev/null || true
    colormgr device-make-profile-default "$did" "sRGB" 2>/dev/null || true
    echo "    → Restored sRGB for $did"
done

echo "[✓] cachy-screen-enhancer profiles removed. Default sRGB restored."
