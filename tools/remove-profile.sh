#!/usr/bin/env bash
#
# remove-profile.sh — Remove all cachy-screen-enhancer profiles + restore sRGB
#
# Usage:
#   bash tools/remove-profile.sh
#
# Reverses everything safe-install.sh does:
#   - Clears the GPU gamma LUT (dispwin -c)
#   - Deletes ICC/cal files from the user colord directory
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
REQUIRES=("python" "colord" "argyllcms")  # python for colormgr parsing, argyllcms for dispwin -c
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

# Step 1: Delete cse profiles from colord database (explicit)
echo "    → Unregistering profiles from colord..."
python3 -c "
import subprocess, re
out = subprocess.run(['colormgr', 'get-profiles'], capture_output=True, text=True).stdout
records = out.strip().split('\n\n')
cse = [r for r in records if 'cse_' in r]
for r in cse:
    m = re.search(r'Profile ID:\s*(\S+)', r)
    if m:
        pid = m.group(1)
        subprocess.run(['sudo', 'colormgr', 'delete-profile', pid], capture_output=True)
        print(f'      Deleted profile: {pid}')
" 2>&1 || true

# Step 2: Delete cse-created devices from colord database
echo "    → Removing cse-created devices..."
python3 -c "
import subprocess
out = subprocess.run(['colormgr', 'get-devices'], capture_output=True, text=True).stdout
for line in out.split('\n'):
    if 'display-cse_' in line.lower():
        parts = line.split()
        if parts:
            did = parts[-1].strip()
            # Try without sudo first (user-owned device), then with sudo
            subprocess.run(['colormgr', 'delete-device', did], capture_output=True)
            subprocess.run(['sudo', 'colormgr', 'delete-device', did], capture_output=True)
            print(f'      Removed device: {did}')
" 2>&1 || true

# Also check for any display-eDP device
python3 -c "
import subprocess
out = subprocess.run(['colormgr', 'get-devices'], capture_output=True, text=True).stdout
for line in out.split('\n'):
    if 'display-eDP' in line.lower():
        parts = line.split()
        if parts:
            did = parts[-1].strip()
            # Remove profiles from the device before deleting it
            for pid_line in subprocess.run(['colormgr', 'get-device', did],
                capture_output=True, text=True).stdout.split('\n'):
                if 'Profile:' in pid_line:
                    pid = pid_line.split()[-1].strip()
                    subprocess.run(['colormgr', 'device-remove-profile', did, pid], capture_output=True)
            print(f'      Cleaned device: {did} (profile references removed)')
" 2>&1 || true

# Step 3: Deactivate ICC profile in KWin (reverse of kscreen-doctor activation)
KWIN_CONNECTOR=""
for conn in /sys/class/drm/*/status; do
    status=$(cat "$conn" 2>/dev/null || true)
    [ "$status" = "connected" ] || continue
    conn_path="${conn%/status}"
    conn_name="${conn_path##*/}"
    if echo "$conn_name" | grep -q "eDP"; then
        KWIN_CONNECTOR="${conn_name#card*-}"; break
    fi
    [ -z "$KWIN_CONNECTOR" ] && KWIN_CONNECTOR="${conn_name#card*-}"
done
echo "    → Deactivating ICC profile in KWin..."
if command -v kscreen-doctor &>/dev/null && [ -n "$KWIN_CONNECTOR" ]; then
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.colorProfileSource.sRGB" 2>/dev/null || true
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.colorPowerTradeoff.preferAccuracy" 2>/dev/null || true
    timeout 10 kscreen-doctor "output.$KWIN_CONNECTOR.iccprofile." 2>/dev/null || true
fi

# Step 4: Clear the GPU gamma LUT (X11 sessions only; dispwin is a
# no-op on Wayland since it writes to XWayland, which KWin ignores)
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
if [ "$SESSION_TYPE" != "wayland" ] && command -v dispwin &>/dev/null; then
    echo "    → Clearing GPU gamma LUT (X11)..."
    DISP_IDX=$(dispwin -d ? 2>&1 | grep -i 'eDP\|LVDS\|Display' | grep -oP '^\s+\d+' | head -1 | tr -d ' ' || echo "1")
    DISP_IDX="${DISP_IDX:-1}"
    dispwin -d "$DISP_IDX" -c 2>&1 || true
fi

# Step 5: Delete files from user colord directory
COLORD_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icc/colord"
echo "    → Removing files from $COLORD_DIR..."
find "$COLORD_DIR" -name 'cse_*.icc' -o -name 'cse_*.cal' 2>/dev/null | while read -r f; do
    echo "      Deleted: $(basename "$f")"
    rm -f "$f" 2>/dev/null || true
done

# Step 6: Clean up generated files in output/
echo "    → Cleaning up output/..."
rm -f "$SCRIPT_DIR/output/cse_*.icc" "$SCRIPT_DIR/output/cse_*.cal" "$SCRIPT_DIR/output/*_no-vcgt.icc" 2>/dev/null || true

# Step 7: Restart colord to complete cleanup
echo "    → Restarting colord..."
sudo systemctl restart colord 2>/dev/null || true
sleep 1

# Step 8: Restore sRGB as default
echo "    → Restoring sRGB as default..."
colormgr get-devices 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "^Device ID:"; then
        did=$(echo "$line" | awk '{print $NF}' | tr -d '\r')
        [ -z "$did" ] && continue
        colormgr device-add-profile "$did" "sRGB" 2>/dev/null || true
        colormgr device-make-profile-default "$did" "sRGB" 2>/dev/null || true
        echo "      Restored sRGB for $did"
    fi
done

echo ""
echo "[✓] All cachy-screen-enhancer profiles removed. sRGB restored."
