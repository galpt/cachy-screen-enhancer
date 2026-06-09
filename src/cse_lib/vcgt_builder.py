"""Video Card Gamma Table (VCGT) builder.

Computes 256-entry 1D LUTs for three GPU code paths (AMD, NVIDIA,
generic), writes ArgyllCMS ``.cal`` files, and packs LUT data into
binary format for the ICC ``vcgt`` tag.
"""

from __future__ import annotations

import os
import struct
from typing import List, Optional

from .gamma_math import (
    srgb_eotf,
    srgb_eotf_inverse,
    pq_eotf,
    pq_eotf_inverse,
)


# ---------------------------------------------------------------------------
# VCGT Builders
# ---------------------------------------------------------------------------

def build_vcgt_amd(
    white_level: float = 200.0,
    gamma: float = 2.2,
    black_level: float = 0.0,
    native_gamma: float = 2.2,
) -> List[float]:
    """Compute a 256-entry gamma LUT for the AMD GPU path.

    The VCGT maps sRGB-encoded compositor output to gamma-encoded values
    expected by the display.  The formula for each entry is::

        V_out = srgbEotf(V_in) ^ (1 / display_native_gamma)

    which produces an end-to-end linear system — the display reproduces
    the exact linear luminance intended by the sRGB-encoded content.

    Args:
        white_level: SDR white luminance in nits (unused in AMD path).
        gamma: Target system gamma (default 2.2, kept for API compat;
            the actual correction is always 1/native_gamma).
        black_level: Black floor luminance in nits (unused in AMD path).
        native_gamma: Display's native gamma from EDID (default 2.2).

    Returns:
        List of 256 floats in [0, 1] representing the LUT.
    """
    inv_gamma = 1.0 / native_gamma
    table: List[float] = [0.0] * 256

    for i in range(256):
        v = i / 255.0
        # sRGB-encoded → linear luminance
        L_linear = srgb_eotf(v)
        # linear → gamma-encoded for display
        table[i] = L_linear ** inv_gamma

    return table


def build_vcgt_nvidia(
    white_level: float = 200.0,
    gamma: float = 2.2,
    black_level: float = 0.0,
) -> List[float]:
    """Compute a 256-entry gamma LUT for the NVIDIA GPU path.

    The NVIDIA proprietary driver applies an additional PQ-like encoding
    step.  Pixels whose PQ luminance exceeds *white_level* are passed
    through unchanged; otherwise the value is tone-mapped to the SDR
    range and gamma-corrected.

    Args:
        white_level: SDR white luminance in nits (default 200.0).
        gamma: Target gamma exponent (default 2.2).
        black_level: Black floor luminance in nits (default 0.0).

    Returns:
        List of 256 floats in [0, 1] representing the LUT.
    """
    table: List[float] = [0.0] * 256

    for i in range(256):
        v = i / 255.0
        L_pq = pq_eotf(v)

        if L_pq > white_level:
            # Pass-through above SDR white
            table[i] = v
        else:
            # Normalise to [0, 1] relative to white level
            L_srgb = srgb_eotf_inverse(L_pq / white_level)
            # Apply gamma and rescale to [black_level, white_level]
            L_gamma = (white_level - black_level) * (L_srgb ** gamma) + black_level
            # Encode back through PQ
            table[i] = pq_eotf_inverse(L_gamma)

    return table


def build_vcgt_generic(
    white_level: float = 200.0,
    gamma: float = 2.2,
    black_level: float = 0.0,
) -> List[float]:
    """Compute a 256-entry gamma LUT for the generic GPU path.

    Simple gamma-only correction: ``table[i] = (i / 255) ** (1 / gamma)``.

    This path works on any GPU/driver that applies the VCGT as a
    straightforward gamma remap without any additional encoding.

    Args:
        white_level: SDR white luminance in nits (unused in this path).
        gamma: Target gamma exponent (1/gamma is applied; default 2.2).
        black_level: Black floor luminance in nits (unused in this path).

    Returns:
        List of 256 floats in [0, 1] representing the LUT.
    """
    inv_gamma = 1.0 / gamma
    table: List[float] = [0.0] * 256

    for i in range(256):
        v = i / 255.0
        table[i] = v ** inv_gamma

    return table


# ---------------------------------------------------------------------------
# .cal File Writer (ArgyllCMS format)
# ---------------------------------------------------------------------------

def write_cal_file(lut: List[float], path: str) -> None:
    """Write an ArgyllCMS ``.cal`` LUT file.

    The file contains 1024 entries (interpolated from the 256-entry LUT)
    with RGB-I (index) and RGB-R, RGB-G, RGB-B columns.

    Args:
        lut: 256-entry 1D LUT (float values in [0, 1]).
        path: Output file path.

    Raises:
        ValueError: If *lut* does not have exactly 256 entries.
    """
    if len(lut) != 256:
        raise ValueError(f"LUT must have exactly 256 entries, got {len(lut)}.")

    # Linear interpolation to 1024 entries
    cal_entries: List[float] = []
    for j in range(1024):
        pos = j / 1023.0 * 255.0
        idx = int(pos)
        frac = pos - idx
        if idx >= 255:
            val = lut[255]
        else:
            val = lut[idx] * (1.0 - frac) + lut[idx + 1] * frac
        cal_entries.append(val)

    lines: List[str] = [
        "CAL",
        "ORIGINATOR \"vcgt\"",
        "DEVICE_CLASS \"DISPLAY\"",
        "COLOR_REP \"RGB\"",
        "NUMBER_OF_FIELDS 4",
        "BEGIN_DATA_FORMAT",
        "RGB_I RGB_R RGB_G RGB_B",
        "END_DATA_FORMAT",
        f"NUMBER_OF_SETS {len(cal_entries)}",
        "BEGIN_DATA",
    ]

    for j, val in enumerate(cal_entries):
        index = j / 1023.0
        lines.append(f"{index:.4f} {val:.4f} {val:.4f} {val:.4f}")

    lines.append("END_DATA")
    lines.append("")  # trailing newline

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines))


# ---------------------------------------------------------------------------
# VCGT → ICC Binary Tag
# ---------------------------------------------------------------------------

def vcgt_to_icc_tag(
    lut: List[float],
    channels: int = 3,
    entry_bits: int = 16,
) -> bytes:
    """Pack a VCGT LUT into binary format for an ICC ``vcgt`` tag.

    The binary layout follows the VideoCardGammaTableType specification:

    +----------------+-------------------------------------+
    | Offset (bytes) | Content                             |
    +----------------+-------------------------------------+
    | 0–3            | ``'vcgt'`` tag signature            |
    | 4–7            | Reserved (0)                        |
    | 8–11           | ``channels``  (uint32)              |
    | 12–15          | ``entry_bits`` (uint32)             |
    | 16–19          | ``entries``   (uint32)              |
    | 20–end         | LUT data                            |
    +----------------+-------------------------------------+

    Each LUT entry is an unsigned 16-bit value (when *entry_bits* == 16):
    ``round(lut[i] * 65535)``.  The same LUT is replicated for all
    *channels*.

    Args:
        lut: 256-entry 1D LUT (float values in [0, 1]).
        channels: Number of colour channels (default 3 for RGB).
        entry_bits: Bit depth of each table entry (default 16).

    Returns:
        Raw bytes suitable for embedding as the ``vcgt`` tag data in an
        ICC profile.

    Raises:
        ValueError: If *lut* is empty.
    """
    if not lut:
        raise ValueError("LUT must contain at least one entry.")

    entries = len(lut)
    scale = (1 << entry_bits) - 1  # e.g. 65535 for 16-bit
    entry_bytes = entry_bits // 8

    # Build the replicated channel data
    data = bytearray()
    for _ in range(channels):
        for val in lut:
            # Clamp to [0, 1] and quantise
            clamped = max(0.0, min(1.0, val))
            quantised = round(clamped * scale)
            if entry_bits == 16:
                data.extend(struct.pack(">H", quantised))
            elif entry_bits == 8:
                data.extend(struct.pack(">B", quantised))
            else:
                raise ValueError(f"Unsupported entry_bits: {entry_bits}")

    # Tag header: 'vcgt' signature + 4 reserved bytes + VCGT data header
    tag_sig = b"vcgt"
    reserved = struct.pack(">I", 0)
    vcgt_header = struct.pack(">III", channels, entry_bits, entries)

    return tag_sig + reserved + vcgt_header + bytes(data)
