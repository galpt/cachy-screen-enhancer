"""EDID (Extended Display Identification Data) binary parser.

Parses the 128-byte base EDID block and extracts display characteristics:
native gamma, chromaticity coordinates, physical size, manufacturer ID,
product code, and serial number.

All functions accept ``bytes`` objects of length >= 128.
"""

from __future__ import annotations

import os
import struct
from typing import Dict, Optional, Tuple


# ---------------------------------------------------------------------------
# EDID Parsing Functions
# ---------------------------------------------------------------------------

def parse_edid_gamma(edid: bytes) -> float:
    """Extract display native gamma from EDID byte 0x17.

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        Native gamma value (e.g. 2.20).

    Raises:
        ValueError: If *edid* is shorter than 128 bytes.

    Notes:
        Gamma is stored as ``(byte_value + 100) / 100``.  A value of
        0xFF means "gamma is defined per timing descriptor" — in that
        case the method returns the common default of 2.2.
    """
    _validate_length(edid)
    raw = edid[0x17]
    if raw == 0xFF:
        return 2.2
    if raw == 0x00:
        return 2.2  # also undefined; use safe default
    return (raw + 100) / 100.0


def parse_edid_chromaticity(edid: bytes) -> Dict[str, float]:
    """Extract chromaticity coordinates from the EDID color characteristics block.

    Parses bytes 0x19–0x22 to reconstruct the 10-bit fractional
    coordinates for red, green, blue, and white primaries.

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        A dict with keys ``red_x``, ``red_y``, ``green_x``, ``green_y``,
        ``blue_x``, ``blue_y``, ``white_x``, ``white_y``.  Each value is a
        float in [0, 1).

    Raises:
        ValueError: If *edid* is shorter than 128 bytes.
    """
    _validate_length(edid)

    # Upper 8 bits (bits 9-2) of each 10-bit coordinate are stored
    # sequentially in bytes 0x19-0x20.
    rx_hi = edid[0x19]
    ry_hi = edid[0x1A]
    gx_hi = edid[0x1B]
    gy_hi = edid[0x1C]
    bx_hi = edid[0x1D]
    by_hi = edid[0x1E]
    wx_hi = edid[0x1F]
    wy_hi = edid[0x20]

    # Lower 2 bits are packed into bytes 0x21-0x22:
    #   0x21: [Rx_lo(2)][Ry_lo(2)][Gx_lo(2)][Gy_lo(2)]
    #   0x22: [Bx_lo(2)][By_lo(2)][Wx_lo(2)][Wy_lo(2)]
    rx_lo = (edid[0x21] >> 6) & 0x3
    ry_lo = (edid[0x21] >> 4) & 0x3
    gx_lo = (edid[0x21] >> 2) & 0x3
    gy_lo = edid[0x21] & 0x3

    bx_lo = (edid[0x22] >> 6) & 0x3
    by_lo = (edid[0x22] >> 4) & 0x3
    wx_lo = (edid[0x22] >> 2) & 0x3
    wy_lo = edid[0x22] & 0x3

    def _to_frac(hi: int, lo: int) -> float:
        return ((hi << 2) | lo) / 1024.0

    return {
        "red_x": _to_frac(rx_hi, rx_lo),
        "red_y": _to_frac(ry_hi, ry_lo),
        "green_x": _to_frac(gx_hi, gx_lo),
        "green_y": _to_frac(gy_hi, gy_lo),
        "blue_x": _to_frac(bx_hi, bx_lo),
        "blue_y": _to_frac(by_hi, by_lo),
        "white_x": _to_frac(wx_hi, wx_lo),
        "white_y": _to_frac(wy_hi, wy_lo),
    }


def parse_edid_physical_size(edid: bytes) -> Tuple[int, int]:
    """Extract physical display size from the EDID.

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        ``(width_cm, height_cm)`` as integers.

    Raises:
        ValueError: If *edid* is shorter than 128 bytes.
    """
    _validate_length(edid)
    width_cm = edid[0x15]
    height_cm = edid[0x16]

    # 0 in either field means size is not specified.
    if width_cm == 0:
        width_cm = 0
    if height_cm == 0:
        height_cm = 0

    return (width_cm, height_cm)


def parse_edid_manufacturer(edid: bytes) -> str:
    """Extract the 3-letter PNP manufacturer ID.

    The ID is stored as a packed 15-bit value across EDID bytes 0x08
    and 0x09 (big-endian).  Each character is 5 bits (1 = 'A' …

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        Manufacturer string (e.g. ``"LEN"``, ``"DEL"``, ``"SAM"``).

    Raises:
        ValueError: If the ID contains invalid character codes.
    """
    _validate_length(edid)
    mfg_id = struct.unpack(">H", edid[0x08:0x0A])[0]

    chars = []
    for shift in (10, 5, 0):
        code = (mfg_id >> shift) & 0x1F
        if code < 1 or code > 26:
            raise ValueError(
                f"Invalid PNP ID character code {code} "
                f"(expected 1–26) in EDID bytes 0x08-0x09."
            )
        chars.append(chr(ord("A") + code - 1))
    return "".join(chars)


def parse_edid_model(edid: bytes) -> int:
    """Extract the product model code.

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        Model code as a 16-bit unsigned integer (little-endian).
    """
    _validate_length(edid)
    return struct.unpack("<H", edid[0x0A:0x0C])[0]


def parse_edid_serial(edid: bytes) -> str:
    """Extract the serial number from EDID descriptor blocks.

    Scans the four descriptor blocks (starting at offset 0x36, each
    18 bytes) for a serial-number descriptor (tag == 0xFF) and returns
    its ASCII content.  If no serial descriptor is found, the 32-bit
    serial number from offset 0x0C is returned as a decimal string.

    Args:
        edid: Raw EDID block (>= 128 bytes).

    Returns:
        Serial number string, or ``""`` if unavailable.
    """
    _validate_length(edid)

    # Try descriptor blocks (tagged descriptors at offsets 0x36, 0x48,
    # 0x5A, 0x6C, each 18 bytes).
    for base in (0x36, 0x48, 0x5A, 0x6C):
        tag = edid[base + 3]
        if tag == 0xFF:  # Serial number descriptor
            # Text is bytes 5-17 (13 chars), null-terminated/padded.
            raw = edid[base + 5 : base + 18]
            serial = raw.rstrip(b"\n\r\x00 ").decode("ascii", errors="replace")
            return serial.strip()

    # Fallback: 32-bit serial number at offset 0x0C.
    serial32 = struct.unpack("<I", edid[0x0C:0x10])[0]
    if serial32 != 0:
        return str(serial32)

    return ""


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def edid_summary(edid: bytes) -> Dict[str, object]:
    """Return a single dict with all parsed EDID fields.

    Args:
        edid: Raw EDID block.

    Returns:
        Dictionary with keys:

        - ``manufacturer`` (str)
        - ``model_code`` (int)
        - ``serial`` (str)
        - ``width_cm`` (int)
        - ``height_cm`` (int)
        - ``gamma`` (float)
        - ``red_x``, ``red_y``, ``green_x``, ``green_y``,
          ``blue_x``, ``blue_y``, ``white_x``, ``white_y`` (float)
    """
    gamma = parse_edid_gamma(edid)
    chroma = parse_edid_chromaticity(edid)
    w, h = parse_edid_physical_size(edid)
    return {
        "manufacturer": parse_edid_manufacturer(edid),
        "model_code": parse_edid_model(edid),
        "serial": parse_edid_serial(edid),
        "width_cm": w,
        "height_cm": h,
        "gamma": gamma,
        **chroma,
    }


# ---------------------------------------------------------------------------
# Sysfs Reading
# ---------------------------------------------------------------------------

def read_edid_from_sysfs(connector: Optional[str] = None) -> bytes:
    """Read EDID from sysfs for a connected display.

    If *connector* is given, reads directly from
    ``/sys/class/drm/{connector}/edid``.  Otherwise auto-detects the
    first connected display connector.

    On Wayland systems this is the standard path for reading display
    EDID without special privileges.

    Args:
        connector: DRM connector name (e.g. ``"card1-eDP-1"``).
            If ``None``, auto-detect.

    Returns:
        Raw EDID bytes (typically 128 or 256 bytes).

    Raises:
        FileNotFoundError: If no connected display is found or the
            EDID file does not exist.
        ValueError: If the EDID data is too short.
    """
    if connector is not None:
        edid_path = f"/sys/class/drm/{connector}/edid"
        if not os.path.exists(edid_path):
            raise FileNotFoundError(
                f"EDID file not found: {edid_path}"
            )
        with open(edid_path, "rb") as f:
            data = f.read()
        if len(data) < 128:
            raise ValueError(f"EDID too short ({len(data)} bytes) from {edid_path}")
        return data

    # Auto-detect: iterate DRM connectors, find first connected display.
    drm_base = "/sys/class/drm"
    if not os.path.isdir(drm_base):
        raise FileNotFoundError(f"DRM sysfs directory not found: {drm_base}")

    # Collect connected connectors.  Prefer eDP (internal panel).
    connected: list[str] = []
    edp_connected: list[str] = []

    try:
        entries = sorted(os.listdir(drm_base))
    except OSError as exc:
        raise FileNotFoundError(
            f"Cannot list {drm_base}: {exc}"
        ) from exc

    for entry in entries:
        status_path = os.path.join(drm_base, entry, "status")
        if not os.path.isfile(status_path):
            continue
        try:
            with open(status_path) as f:
                status = f.read().strip()
        except OSError:
            continue
        if status == "connected":
            if "eDP" in entry or "LVDS" in entry:
                edp_connected.append(entry)
            else:
                connected.append(entry)

    # Prioritise eDP, then first connected external.
    ordered = edp_connected + connected
    if not ordered:
        raise FileNotFoundError(
            "No connected display found in /sys/class/drm/*/status"
        )

    edid_path = os.path.join(drm_base, ordered[0], "edid")
    if not os.path.exists(edid_path):
        raise FileNotFoundError(
            f"EDID file not found for connected connector {ordered[0]}: "
            f"{edid_path}"
        )

    with open(edid_path, "rb") as f:
        data = f.read()
    if len(data) < 128:
        raise ValueError(
            f"EDID too short ({len(data)} bytes) from {edid_path}"
        )
    return data


# ---------------------------------------------------------------------------
# Internal Helpers
# ---------------------------------------------------------------------------

def _validate_length(edid: bytes) -> None:
    """Raise ``ValueError`` if *edid* is shorter than 128 bytes."""
    if len(edid) < 128:
        raise ValueError(
            f"EDID block must be at least 128 bytes, got {len(edid)}."
        )
