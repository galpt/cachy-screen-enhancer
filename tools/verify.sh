#!/usr/bin/env bash
#
# verify.sh — Generate visual test patterns for gamma verification
#
# Usage:
#   bash tools/verify.sh
#
# Creates PNG test patterns in output/test-patterns/ for visual
# comparison of gamma reproduction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output/test-patterns"
mkdir -p "$OUTPUT_DIR"

echo "[*] Generating visual test patterns..."

# Generate test patterns using Python/Pillow if available, or skip
python3 -c "
import struct, zlib, math, os

OUT = os.path.join('$OUTPUT_DIR')

def create_png(width, height, pixels, path):
    \"\"\"Create a minimal PNG from raw RGB pixel data.\"\"\"
    # Raw image data with filter byte per row
    raw = b''
    for y in range(height):
        raw += b'\\x00'  # filter: none
        for x in range(width):
            idx = (y * width + x) * 3
            raw += bytes(pixels[idx:idx+3])
    
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    
    sig = b'\\x89PNG\\r\\n\\x1a\\n'
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    compressed = zlib.compress(raw)
    
    with open(path, 'wb') as f:
        f.write(sig)
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', compressed))
        f.write(chunk(b'IEND', b''))

W, H = 512, 512
pixels = []

# ── Gray ramp (left to right: 0 → 255) ──
for y in range(H):
    for x in range(W):
        v = int(x / W * 255)
        pixels.extend([v, v, v])
create_png(W, H, pixels, os.path.join(OUT, 'gray-ramp.png'))
print('  [OK] gray-ramp.png')

# ── Black crush test (low-end ramp: 0 → 32) ──
pixels = []
for y in range(H):
    for x in range(W):
        v = int(x / W * 32)
        pixels.extend([v, v, v])
create_png(W, H, pixels, os.path.join(OUT, 'black-crush.png'))
print('  [OK] black-crush.png')

# ── Gamma checkerboard (gamma 2.2 vs sRGB) ──
pixels = []
for y in range(H):
    for x in range(W):
        # Left half: pure gamma 2.2, Right half: sRGB
        v_linear = x / W
        v_gamma = int(v_linear ** (1/2.2) * 255)
        # sRGB inverse EOTF
        if v_linear <= 0.0031308:
            v_srgb = int(12.92 * v_linear * 255)
        else:
            v_srgb = int((1.055 * v_linear ** (1/2.4) - 0.055) * 255)
        
        v = v_gamma if (x // 64) % 2 == 0 else v_srgb
        # Alternate rows for checkerboard
        if (y // 64) % 2 == 1:
            v = v_srgb if (x // 64) % 2 == 0 else v_gamma
        
        pixels.extend([v, v, v])
create_png(W, H, pixels, os.path.join(OUT, 'gamma-comparison.png'))
print('  [OK] gamma-comparison.png')

print()
print(f'Test patterns written to: {OUT}')
print('Open them in an image viewer to verify gamma reproduction.')
" 2>&1 || echo "    ⚠ Could not generate patterns (pure python fallback)"
