#!/usr/bin/env bash
#
# inspect-profile.sh — Inspect an ICC profile's tags and metadata
#
# Usage:
#   bash tools/inspect-profile.sh [path/to/profile.icc]
#
# If no path is given, inspects the default 200nits profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PROFILE="$SCRIPT_DIR/profiles/icc/cse_200nits_amd.icc"
PROFILE="${1:-$DEFAULT_PROFILE}"

if [ ! -f "$PROFILE" ]; then
    echo "✗ Profile not found: $PROFILE"
    exit 1
fi

echo "=== ICC Profile Inspection ==="
echo "File: $(basename "$PROFILE")"
echo "Size: $(wc -c < "$PROFILE") bytes"
echo ""

# Parse ICC header using Python
python3 -c "
import struct, sys

with open('$PROFILE', 'rb') as f:
    data = f.read()

if len(data) < 128:
    print('ERROR: File too small for ICC header')
    sys.exit(1)

# Header fields
size = struct.unpack_from('>I', data, 0)[0]
cmm = data[4:8].decode('ascii', errors='replace')
version_major = data[8]
version_minor = data[9]
device_class = data[12:16].decode('ascii', errors='replace')
color_space = data[16:20].decode('ascii', errors='replace')
pcs = data[20:24].decode('ascii', errors='replace')
magic = data[36:40].decode('ascii', errors='replace')
platform = data[40:44].decode('ascii', errors='replace')
rendering_intent = struct.unpack_from('>I', data, 64)[0]

print(f'Profile size:  {size} bytes')
print(f'CMM:           {cmm}')
print(f'Version:       {version_major}.{version_minor}.0.0')
print(f'Device class:  {device_class}')
print(f'Color space:   {color_space}')
print(f'PCS:           {pcs}')
print(f'Platform:      {platform}')
print(f'Rendering int: {rendering_intent}')
print('')

# Tag table
tag_count = struct.unpack_from('>I', data, 128)[0]
print(f'Tags: {tag_count}')
print(f'{\"Signature\":<12} {\"Offset\":<10} {\"Size\":<10} {\"Content Preview\":<30}')
print('-' * 62)

for i in range(tag_count):
    base = 132 + i * 12
    sig = data[base:base+4].decode('ascii', errors='replace')
    offset = struct.unpack_from('>I', data, base+4)[0]
    size = struct.unpack_from('>I', data, base+8)[0]
    
    preview = ''
    if size > 8 and size < 80:
        preview = data[offset:offset+min(size, 28)].hex(' ', 1)[:28]
    
    print(f'{sig:<12} {offset:<10} {size:<10} {preview}')
" 2>&1
