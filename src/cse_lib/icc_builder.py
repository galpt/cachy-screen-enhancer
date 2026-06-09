"""ICC v4 profile builder — constructs a valid display ICC profile from scratch.

Builds a complete ICC v4.2 ``mntr`` profile with all mandatory tags
and embeds a ``vcgt`` tag containing the Video Card Gamma Table LUT.

All multi-byte values are big-endian (``'acsp'`` magic, ICC standard).
"""

from __future__ import annotations

import datetime
import math
import struct
from typing import Dict, List, Optional, Tuple

from .vcgt_builder import vcgt_to_icc_tag

# ---------------------------------------------------------------------------
# ICC Constants
# ---------------------------------------------------------------------------

# Standard D50 illuminant XYZ values (n= 0.9642, 1.0, 0.8249)
_D50_X: float = 0.9642
_D50_Y: float = 1.0
_D50_Z: float = 0.8249

# Standard D65 white point chromaticities
_D65_WX: float = 0.3127
_D65_WY: float = 0.3290

# sRGB default chromaticities
_SRGB_RX: float = 0.6400
_SRGB_RY: float = 0.3300
_SRGB_GX: float = 0.3000
_SRGB_GY: float = 0.6000
_SRGB_BX: float = 0.1500
_SRGB_BY: float = 0.0600

# Bradford D65→D50 chromatic adaptation matrix (3x3).
_BRADFORD_D65_D50: List[List[float]] = [
    [1.047886, 0.022919, -0.050216],
    [0.029582, 0.990484, -0.017067],
    [-0.009234, 0.015043, 0.752131],
]

# Inverse of the Bradford cone-response matrix
_M_BRAD_INV: List[List[float]] = [
    [0.9869929, -0.1470543, 0.1599627],
    [0.4323053, 0.5184003, 0.0492912],
    [-0.0085287, 0.0400428, 0.9684867],
]

# Bradford cone-response matrix
_M_BRAD: List[List[float]] = [
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_icc_profile(
    desc_text: str,
    vcgt_lut: List[float],
    white_level: float,
    edid_data: Optional[Dict[str, object]] = None,
    gamma: float = 2.2,
) -> bytes:
    """Build a complete ICC v4 display profile.

    Args:
        desc_text: Description string for the ``desc`` tag (e.g.
            ``"cachy-screen-enhancer: sRGB → gamma 2.2 @ 200nits [AMD]"``).
        vcgt_lut: 256-entry 1D LUT from :func:`vcgt_builder.build_vcgt_amd`
            or equivalent.
        white_level: SDR white luminance in nits (used for the ``lumi`` tag).
        edid_data: Optional dictionary from :func:`edid_parser.edid_summary`.
            If provided, the profile uses EDID white point and primaries.
            If ``None``, sRGB defaults are used.
        gamma: Target gamma exponent (default 2.2).

    Returns:
        Complete ICC v4 profile as ``bytes``.

    Raises:
        ValueError: If *vcgt_lut* does not have exactly 256 entries.
    """
    if len(vcgt_lut) != 256:
        raise ValueError(f"vcgt_lut must have 256 entries, got {len(vcgt_lut)}.")

    # ------------------------------------------------------------------
    # Resolve chromaticity data
    # ------------------------------------------------------------------
    if edid_data is not None:
        rx = float(edid_data.get("red_x", _SRGB_RX))
        ry = float(edid_data.get("red_y", _SRGB_RY))
        gx = float(edid_data.get("green_x", _SRGB_GX))
        gy = float(edid_data.get("green_y", _SRGB_GY))
        bx = float(edid_data.get("blue_x", _SRGB_BX))
        by = float(edid_data.get("blue_y", _SRGB_BY))
        wx = float(edid_data.get("white_x", _D65_WX))
        wy = float(edid_data.get("white_y", _D65_WY))
    else:
        rx, ry = _SRGB_RX, _SRGB_RY
        gx, gy = _SRGB_GX, _SRGB_GY
        bx, by = _SRGB_BX, _SRGB_BY
        wx, wy = _D65_WX, _D65_WY

    # White point XYZ (Y normalised to 1.0)
    white_xyz = (wx / wy, 1.0, (1.0 - wx - wy) / wy)

    # ------------------------------------------------------------------
    # Chromatic adaptation matrix — Bradford from display wp → D50
    # ------------------------------------------------------------------
    d50_xyz = (_D50_X, _D50_Y, _D50_Z)
    chad_matrix = _bradford_adaptation(white_xyz, d50_xyz)

    # ------------------------------------------------------------------
    # Compute colourant matrix (RGB → XYZ) and adapted primaries
    # ------------------------------------------------------------------
    raw_colorants = _compute_rgb_to_xyz_matrix(rx, ry, gx, gy, bx, by, wx, wy)

    # Apply chromatic adaptation: M_adapted = chad × M_raw
    adapted_colorants = _mat_mul_3x3(chad_matrix, raw_colorants)

    # Extract column-vector primaries (rXYZ, gXYZ, bXYZ)
    r_xyz = (adapted_colorants[0][0], adapted_colorants[1][0], adapted_colorants[2][0])
    g_xyz = (adapted_colorants[0][1], adapted_colorants[1][1], adapted_colorants[2][1])
    b_xyz = (adapted_colorants[0][2], adapted_colorants[1][2], adapted_colorants[2][2])

    # ------------------------------------------------------------------
    # Build the profile
    # ------------------------------------------------------------------
    now = datetime.datetime.now()

    # -- Tag data payloads (built first to compute sizes/offsets) -------

    tag_data: List[Tuple[str, bytes]] = []

    # desc (textDescriptionType — v2-compatible)
    desc_bytes = _build_text_description(desc_text)
    tag_data.append(("desc", desc_bytes))

    # cprt (textDescriptionType)
    cprt_bytes = _build_text_description("No copyright, use freely")
    tag_data.append(("cprt", cprt_bytes))

    # wtpt (XYZType)
    wtpt_bytes = _build_xyz_type(*white_xyz)
    tag_data.append(("wtpt", wtpt_bytes))

    # chad (S15Fixed16ArrayType — 3x3 matrix)
    chad_bytes = _build_sf32_array(
        [chad_matrix[0][0], chad_matrix[0][1], chad_matrix[0][2],
         chad_matrix[1][0], chad_matrix[1][1], chad_matrix[1][2],
         chad_matrix[2][0], chad_matrix[2][1], chad_matrix[2][2]]
    )
    tag_data.append(("chad", chad_bytes))

    # rXYZ, gXYZ, bXYZ (XYZType)
    tag_data.append(("rXYZ", _build_xyz_type(*r_xyz)))
    tag_data.append(("gXYZ", _build_xyz_type(*g_xyz)))
    tag_data.append(("bXYZ", _build_xyz_type(*b_xyz)))

    # rTRC, gTRC, bTRC (parametricCurveType — type 0: simple gamma)
    trc_bytes = _build_parametric_curve(gamma)
    tag_data.append(("rTRC", trc_bytes))
    tag_data.append(("gTRC", trc_bytes))  # identical for all channels
    tag_data.append(("bTRC", trc_bytes))

    # chrm (chromaticityType)
    chrm_bytes = _build_chromaticity_type(rx, ry, gx, gy, bx, by)
    tag_data.append(("chrm", chrm_bytes))

    # lumi (XYZType)
    # Luminance in cd/m²: Y = white_level, X and Z from D50.
    lum_scale = white_level / _D50_Y
    lumi_bytes = _build_xyz_type(
        _D50_X * lum_scale,
        white_level,
        _D50_Z * lum_scale,
    )
    tag_data.append(("lumi", lumi_bytes))

    # vcgt (proprietary VCGT tag)
    vcgt_bytes = vcgt_to_icc_tag(vcgt_lut)
    tag_data.append(("vcgt", vcgt_bytes))

    # ------------------------------------------------------------------
    # Layout calculation
    # ------------------------------------------------------------------

    # Header occupies the first 128 bytes.
    header_size = 128

    # Tag table: 4 bytes (count) + 12 bytes per tag entry.
    tag_count = len(tag_data)
    tag_table_size = 4 + tag_count * 12

    # Compute data offsets (all tag data starts after header + tag table).
    current_offset = header_size + tag_table_size
    tag_entries: List[Tuple[str, int, int]] = []
    for sig, data in tag_data:
        size = len(data)
        tag_entries.append((sig, current_offset, size))
        current_offset += size

    profile_size = current_offset

    # ------------------------------------------------------------------
    # Write header (128 bytes)
    # ------------------------------------------------------------------
    header = bytearray(128)

    #  0-3:   profile size (uint32)
    struct.pack_into(">I", header, 0, profile_size)

    #  4-7:   CMM type
    header[4:8] = b"appl"

    #  8-11:  profile version 4.2.0.0
    struct.pack_into(">I", header, 8, 0x04200000)

    # 12-15:  device class 'mntr' (monitor display)
    header[12:16] = b"mntr"

    # 16-19:  colour space 'RGB '
    header[16:20] = b"RGB "

    # 20-23:  PCS 'XYZ '
    header[20:24] = b"XYZ "

    # 24-35:  date/time
    struct.pack_into(">HHHHHH", header, 24,
                     now.year, now.month, now.day,
                     now.hour, now.minute, now.second)

    # 36-39:  'acsp' magic
    header[36:40] = b"acsp"

    # 40-43:  platform 'MSFT'
    header[40:44] = b"MSFT"

    # 44-47:  flags
    struct.pack_into(">I", header, 44, 0)

    # 48-51:  device manufacturer
    struct.pack_into(">I", header, 48, 0)

    # 52-55:  device model
    struct.pack_into(">I", header, 52, 0)

    # 56-63:  device attributes (8 bytes)
    struct.pack_into(">Q", header, 56, 0)

    # 64-67:  rendering intent (0 = perceptual)
    struct.pack_into(">I", header, 64, 0)

    # 68-79:  illuminant (D50 XYZ as S15Fixed16, 12 bytes = 3 × 4)
    struct.pack_into(">iii", header, 68,
                     _float_to_s15fixed16(_D50_X),
                     _float_to_s15fixed16(_D50_Y),
                     _float_to_s15fixed16(_D50_Z))

    # 80-83:  profile creator
    header[80:84] = b"cse "

    # 84-127: reserved (zeros)

    # ------------------------------------------------------------------
    # Write tag table
    # ------------------------------------------------------------------
    tag_table = bytearray(tag_table_size)
    struct.pack_into(">I", tag_table, 0, tag_count)

    for i, (sig, offset, size) in enumerate(tag_entries):
        base = 4 + i * 12
        tag_table[base:base + 4] = sig.encode("ascii")
        struct.pack_into(">I", tag_table, base + 4, offset)
        struct.pack_into(">I", tag_table, base + 8, size)

    # ------------------------------------------------------------------
    # Assemble
    # ------------------------------------------------------------------
    profile = bytearray(profile_size)
    profile[:128] = header
    profile[128:128 + tag_table_size] = tag_table

    offset = 128 + tag_table_size
    for _, data in tag_data:
        profile[offset:offset + len(data)] = data
        offset += len(data)

    return bytes(profile)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_icc_profile(icc_bytes: bytes) -> bool:
    """Validate a basic ICC profile structure.

    Checks:
    1. The size field matches the actual ``bytes`` length.
    2. The ``'acsp'`` magic signature is present at offset 36.
    3. The device class is ``'mntr'`` (monitor).

    Args:
        icc_bytes: Raw ICC profile bytes.

    Returns:
        ``True`` if all checks pass, ``False`` otherwise.
    """
    if len(icc_bytes) < 128:
        return False

    try:
        declared_size = struct.unpack_from(">I", icc_bytes, 0)[0]
        if declared_size != len(icc_bytes):
            return False

        if icc_bytes[36:40] != b"acsp":
            return False

        if icc_bytes[12:16] != b"mntr":
            return False

        return True
    except (struct.error, IndexError):
        return False


# ---------------------------------------------------------------------------
# ICC Tag Builders (internal helpers)
# ---------------------------------------------------------------------------

def _build_text_description(text: str) -> bytes:
    """Build a ``textDescriptionType`` tag (v2-compatible ASCII)."""
    data = text.encode("ascii", errors="replace") + b"\x00"
    # Pad to 4-byte boundary
    while len(data) % 4 != 0:
        data += b"\x00"
    desc_len = len(data)
    header = struct.pack(">4sI", b"desc", desc_len)
    return header + data


def _build_xyz_type(x: float, y: float, z: float) -> bytes:
    """Build an ``XYZType`` tag with three S15Fixed16 values."""
    header = struct.pack(">4sI", b"XYZ ", 0)
    data = struct.pack(">iii",
                       _float_to_s15fixed16(x),
                       _float_to_s15fixed16(y),
                       _float_to_s15fixed16(z))
    return header + data


def _build_sf32_array(values: List[float]) -> bytes:
    """Build an ``S15Fixed16ArrayType`` tag from a list of floats.

    Each float is encoded as an S15Fixed16 integer (multiplied by 65536).
    """
    header = struct.pack(">4sI", b"sf32", 0)
    ints = [_float_to_s15fixed16(v) for v in values]
    data = struct.pack(f">{len(ints)}i", *ints)
    return header + data


def _build_parametric_curve(gamma: float) -> bytes:
    """Build a ``parametricCurveType`` tag with type 0 (basic gamma).

    Type 0 formula: ``Y = X ** gamma``
    """
    header = struct.pack(">4sIHH", b"para", 0, 0, 0)
    gamma_int = _float_to_s15fixed16(gamma)
    params = struct.pack(">i", gamma_int)
    return header + params


def _build_chromaticity_type(
    rx: float, ry: float,
    gx: float, gy: float,
    bx: float, by: float,
) -> bytes:
    """Build a ``chromaticityType`` tag for 3-channel RGB.

    Coordinates are stored as ``U16Fixed16`` values.
    Chromaticity type is 0 (unknown).
    """
    header = struct.pack(">4sIII", b"chrm", 0, 3, 0)

    def _u16fixed16(v: float) -> int:
        return round(v * 65536)

    coords = struct.pack(">iiiiii",
                         _u16fixed16(rx), _u16fixed16(ry),
                         _u16fixed16(gx), _u16fixed16(gy),
                         _u16fixed16(bx), _u16fixed16(by))
    return header + coords


# ---------------------------------------------------------------------------
# Math Helpers
# ---------------------------------------------------------------------------

def _float_to_s15fixed16(v: float) -> int:
    """Convert a float to an S15Fixed16 signed 32-bit integer."""
    return round(v * 65536)


def _bradford_adaptation(
    src_xyz: Tuple[float, float, float],
    dst_xyz: Tuple[float, float, float],
) -> List[List[float]]:
    """Compute the 3×3 Bradford chromatic adaptation matrix.

    Args:
        src_xyz: Source white point as ``(X, Y, Z)``.
        dst_xyz: Destination white point as ``(X, Y, Z)``.

    Returns:
        3×3 matrix (list of lists) that adapts from *src_xyz* to *dst_xyz*.
    """
    Xs, Ys, Zs = src_xyz
    Xd, Yd, Zd = dst_xyz

    # Cone responses for source
    Ls = _M_BRAD[0][0] * Xs + _M_BRAD[0][1] * Ys + _M_BRAD[0][2] * Zs
    Ms = _M_BRAD[1][0] * Xs + _M_BRAD[1][1] * Ys + _M_BRAD[1][2] * Zs
    Ss = _M_BRAD[2][0] * Xs + _M_BRAD[2][1] * Ys + _M_BRAD[2][2] * Zs

    # Cone responses for destination
    Ld = _M_BRAD[0][0] * Xd + _M_BRAD[0][1] * Yd + _M_BRAD[0][2] * Zd
    Md = _M_BRAD[1][0] * Xd + _M_BRAD[1][1] * Yd + _M_BRAD[1][2] * Zd
    Sd = _M_BRAD[2][0] * Xd + _M_BRAD[2][1] * Yd + _M_BRAD[2][2] * Zd

    # Diagonal scaling
    def _safe_div(a: float, b: float) -> float:
        return a / b if abs(b) > 1e-15 else 0.0

    rL = _safe_div(Ld, Ls)
    rM = _safe_div(Md, Ms)
    rS = _safe_div(Sd, Ss)

    # D = diag(rL, rM, rS) × M_Brad
    D = [[0.0] * 3 for _ in range(3)]
    for r in range(3):
        scale = [rL, rM, rS][r]
        for c in range(3):
            D[r][c] = scale * _M_BRAD[r][c]

    # M_adapt = M_Brad_inv × D
    result = [[0.0] * 3 for _ in range(3)]
    for i in range(3):
        for j in range(3):
            total = 0.0
            for k in range(3):
                total += _M_BRAD_INV[i][k] * D[k][j]
            result[i][j] = total

    return result


def _compute_rgb_to_xyz_matrix(
    rx: float, ry: float,
    gx: float, gy: float,
    bx: float, by: float,
    wx: float, wy: float,
) -> List[List[float]]:
    """Compute the 3×3 RGB→XYZ matrix from chromaticities and white point.

    The returned matrix maps linear RGB to XYZ in the display's native
    white point.

    Returns:
        3×3 matrix where columns are X, Y, Z for R, G, B primaries.
    """
    # z values
    rz = 1.0 - rx - ry
    gz = 1.0 - gx - gy
    bz = 1.0 - bx - by

    # White point XYZ
    Xw = wx / wy
    Yw = 1.0
    Zw = (1.0 - wx - wy) / wy

    # Chromaticity matrix M
    M = [
        [rx / ry, gx / gy, bx / by],
        [1.0, 1.0, 1.0],
        [rz / ry, gz / gy, bz / by],
    ]

    # Solve M · [Sr, Sg, Sb]^T = [Xw/Yw, 1, Zw/Yw]^T
    target = [Xw / Yw, 1.0, Zw / Yw]

    det_m = _det3x3(M)
    if abs(det_m) < 1e-15:
        # Fallback: use sRGB-like matrix if degenerate
        return [
            [0.4361, 0.3851, 0.1431],
            [0.2225, 0.7169, 0.0606],
            [0.0139, 0.0971, 0.7141],
        ]

    Sr = _det3x3_col_replace(M, target, 0) / det_m
    Sg = _det3x3_col_replace(M, target, 1) / det_m
    Sb = _det3x3_col_replace(M, target, 2) / det_m

    # Colourant matrix
    colorants = [
        [Sr * rx / ry, Sg * gx / gy, Sb * bx / by],
        [Sr,           Sg,           Sb],
        [Sr * rz / ry, Sg * gz / gy, Sb * bz / by],
    ]

    return colorants


def _det3x3(m: List[List[float]]) -> float:
    """Compute the determinant of a 3×3 matrix."""
    return (
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    )


def _det3x3_col_replace(
    m: List[List[float]],
    col: List[float],
    col_idx: int,
) -> float:
    """Compute determinant of *m* with column *col_idx* replaced by *col*."""
    mc = [row[:] for row in m]
    for i in range(3):
        mc[i][col_idx] = col[i]
    return _det3x3(mc)


def _mat_mul_3x3(
    a: List[List[float]],
    b: List[List[float]],
) -> List[List[float]]:
    """Multiply two 3×3 matrices: ``result = a × b``."""
    result = [[0.0] * 3 for _ in range(3)]
    for i in range(3):
        for j in range(3):
            total = 0.0
            for k in range(3):
                total += a[i][k] * b[k][j]
            result[i][j] = total
    return result
