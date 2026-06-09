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
# EDID parsing uses the bundled Python module — no external deps needed.
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

# Decode it using the bundled Python EDID parser
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[*] EDID summary:"
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/src')
from cse_lib.edid_parser import edid_summary
try:
    with open('$EDID_PATH', 'rb') as f:
        edid = edid_summary(f.read())
    print(f'  Manufacturer: {edid.get(\"manufacturer\", \"?\")}')
    print(f'  Model:        {edid.get(\"model_code\", \"?\")}')
    print(f'  Gamma:        {edid.get(\"gamma\", \"?\")}')
    print(f'  Size:         {edid.get(\"width_cm\", \"?\")} cm × {edid.get(\"height_cm\", \"?\")} cm')
    rx, ry = edid.get('red_x', 0), edid.get('red_y', 0)
    gx, gy = edid.get('green_x', 0), edid.get('green_y', 0)
    bx, by = edid.get('blue_x', 0), edid.get('blue_y', 0)
    if rx != 0:
        print(f'  Primaries:    R({rx:.3f},{ry:.3f}) G({gx:.3f},{gy:.3f}) B({bx:.3f},{by:.3f})')
except Exception as e:
    print(f'  (EDID parse skipped: {e})')
" 2>&1
