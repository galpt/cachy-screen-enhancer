#!/usr/bin/env bash
#
# dump-edid.sh — Dump EDID from sysfs for a display connector
#
# Usage:
#   bash tools/dump-edid.sh [connector]
#
# If no connector is given, lists available connected displays.
set -euo pipefail

# ── Sudo session keepalive ────────────────────────────────────
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

# ── Dependency self-bootstrap ─────────────────────────────────
REQUIRES=("edid-decode")
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

# If no connector specified, list available ones
if [ $# -eq 0 ]; then
    echo "[*] Available connected displays:"
    for conn in /sys/class/drm/*/status; do
        status=$(cat "$conn" 2>/dev/null || true)
        conn_path="${conn%/status}"
        conn_name="${conn_path##*/}"
        echo "    $conn_name → $status"
    done
    echo ""
    echo "Usage: $0 <connector>"
    echo "Example: $0 eDP-1"
    exit 0
fi

CONNECTOR="$1"
EDID_PATH="/sys/class/drm/$CONNECTOR/edid"
OUTPUT_FILE="data/edid/${CONNECTOR}_$(date +%Y-%m-%d).bin"

if [ ! -f "$EDID_PATH" ]; then
    echo "✗ EDID not found for connector: $CONNECTOR"
    echo "  Available connectors:"
    ls /sys/class/drm/*/edid 2>/dev/null | sed 's|/sys/class/drm/||;s|/edid||' | while read -r c; do
        status=$(cat "/sys/class/drm/$c/status" 2>/dev/null || true)
        echo "    $c ($status)"
    done
    exit 1
fi

mkdir -p data/edid
cat "$EDID_PATH" > "$OUTPUT_FILE"
echo "[✓] EDID dumped to: $OUTPUT_FILE"
echo ""

# Decode it
echo "[*] EDID summary:"
edid-decode "$EDID_PATH" 2>/dev/null || echo "  (edid-decode not available)"
