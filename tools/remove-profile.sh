#!/usr/bin/env bash
#
# remove-profile.sh — Remove all cachy-screen-enhancer profiles + restore sRGB
#
# Usage:
#   bash tools/remove-profile.sh
#
# Reverses everything safe-install.sh does:
#   - Clears the GPU gamma LUT (dispwin -c)
#   - Deletes ICC/cal files from /usr/share/color/icc/colord/
#   - Removes profiles from colord's database
#   - Restores sRGB as default for all display devices
#   - Cleans up generated files in output/
set -euo pipefail

# ── Sudo session keepalive ────────────────────────────────────
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

# ── Determine script location ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Dependency self-bootstrap ─────────────────────────────────
REQUIRES=("colord" "argyllcms")  # argyllcms for dispwin -c
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

# Step 1: Clear the GPU gamma LUT (reverse of dispwin load)
echo "    → Clearing GPU gamma LUT..."
if command -v dispwin &>/dev/null; then
    # Find the correct display index
    DISP_IDX=$(dispwin -d ? 2>&1 | grep -i 'eDP\|LVDS\|Display' | grep -oP '^\s+\d+' | head -1 | tr -d ' ' || echo "1")
    DISP_IDX="${DISP_IDX:-1}"
    dispwin -d "$DISP_IDX" -c 2>&1 || true
fi

# Step 2: Delete files from system profile directory
echo "    → Removing files from /usr/share/color/icc/colord/..."
COLORD_DIR="/usr/share/color/icc/colord"
CSE_FILES=$(sudo find "$COLORD_DIR" -name 'cse_*.icc' -o -name 'cse_*.cal' 2>/dev/null || true)
if [ -n "$CSE_FILES" ]; then
    echo "$CSE_FILES" | while read -r f; do
        echo "      Deleted: $(basename "$f")"
        sudo rm -f "$f"
    done
else
    echo "      No cse files found"
fi

# Step 3: Clean up generated files in output/
echo "    → Cleaning up output/..."
rm -f "$SCRIPT_DIR/output/cse_*.icc" "$SCRIPT_DIR/output/cse_*.cal" 2>/dev/null || true

# Step 4: Restart colord so it forgets the deleted profiles
echo "    → Restarting colord..."
sudo systemctl restart colord 2>/dev/null || true
sleep 1

# Step 5: Restore sRGB as default for all display devices
echo "    → Restoring sRGB as default..."
colormgr get-devices 2>/dev/null | grep "^Device ID:" | awk '{print $NF}' | tr -d '\r' | while read -r did; do
    [ -z "$did" ] && continue
    colormgr device-add-profile "$did" "sRGB" 2>/dev/null || true
    colormgr device-make-profile-default "$did" "sRGB" 2>/dev/null || true
    echo "      Restored sRGB for $did"
done

echo ""
echo "[✓] All cachy-screen-enhancer profiles removed. sRGB restored."
