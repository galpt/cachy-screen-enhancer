#!/usr/bin/env bash
#
# remove-profile.sh — Remove all cachy-screen-enhancer profiles + restore sRGB
#
# Usage:
#   bash tools/remove-profile.sh
#
# Removes:
#   - Any ICC files copied to /usr/share/color/icc/colord/
#   - Any profiles registered in colord's database
#   - Restores sRGB as default for all devices
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

# Step 1: Delete files from system profile directory
COLORD_DIR="/usr/share/color/icc/colord"
CSE_FILES=$(sudo find "$COLORD_DIR" -name 'cse_*.icc' -o -name 'cse_*.cal' 2>/dev/null || true)
if [ -n "$CSE_FILES" ]; then
    echo "$CSE_FILES" | while read -r f; do
        echo "    → Deleting file: $(basename "$f")"
        sudo rm -f "$f"
    done
else
    echo "    → No cse files found in $COLORD_DIR"
fi

# Step 2: Restart colord so it forgets the deleted profiles
echo "    → Restarting colord to refresh profile list..."
sudo systemctl restart colord 2>/dev/null || true
sleep 1

# Step 3: Restore sRGB as default for all display devices
echo "[*] Restoring sRGB as default..."
colormgr get-devices 2>/dev/null | grep "^Device ID:" | awk '{print $NF}' | tr -d '\r' | while read -r did; do
    [ -z "$did" ] && continue
    colormgr device-add-profile "$did" "sRGB" 2>/dev/null || true
    colormgr device-make-profile-default "$did" "sRGB" 2>/dev/null || true
    echo "    → Restored sRGB for $did"
done

echo "[✓] All cachy-screen-enhancer profiles removed. Default sRGB restored."
