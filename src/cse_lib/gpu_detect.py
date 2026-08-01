"""GPU driver detection for cachy-screen-enhancer.

Detects the active GPU method by interrogating sysfs (DRM) and device
nodes, and provides helpers for finding display EDID paths, display
names, current brightness, and a full hardware report.
"""

from __future__ import annotations

import ctypes
import fcntl
import glob
import os
import struct
from typing import Dict, List, Optional

# ---------------------------------------------------------------------------
# Vendor IDs
# ---------------------------------------------------------------------------

_VENDOR_AMD: str = "0x1002"
_VENDOR_NVIDIA: str = "0x10de"
_VENDOR_INTEL: str = "0x8086"


# ---------------------------------------------------------------------------
# GPU Method Detection
# ---------------------------------------------------------------------------

def detect_gpu_method() -> str:
    """Detect the active GPU driver method.

    Decision logic:
    1. Iterate ``/sys/class/drm/card*/device/vendor``.
    2. For each card that has at least one connected connector, read the
       vendor file.
    3. If vendor is AMD (0x1002): return ``"amd"`` (KMS gamma LUT path).
    4. If vendor is Intel (0x8086): return ``"amd"`` (Intel uses the same
       KMS DRM gamma LUT interface as AMD — no PQ encoding like NVIDIA).
    5. If vendor is NVIDIA (0x10de): return ``"nvidia"`` (proprietary
       driver may apply PQ encoding before gamma LUT on HDR setups).
    6. If no GPU found via DRM, check for ``/dev/nvidia0`` (NVIDIA).
    7. Fallback: ``"generic"``.

    Returns:
        One of ``"amd"``, ``"nvidia"``, or ``"generic"``.
    """
    connected_cards = _get_vendors_of_connected_cards()

    # AMD / Intel check — both use the same KMS DRM GAMMA_LUT property
    # (standard DRM atomic KMS interface, no proprietary PQ encoding).
    # The "amd" method name means "standard KMS gamma LUT computation" —
    # correct for any GPU that exposes GAMMA_LUT through the DRM atomic API.
    for vendor in connected_cards:
        if vendor in (_VENDOR_AMD, _VENDOR_INTEL):
            return "amd"

    # NVIDIA check via DRM
    for vendor in connected_cards:
        if vendor == _VENDOR_NVIDIA:
            return "nvidia"

    # Fallback: check /dev/nvidia0
    if os.path.exists("/dev/nvidia0"):
        return "nvidia"

    return "generic"


# ---------------------------------------------------------------------------
# Plane Color Pipeline Detection
# ---------------------------------------------------------------------------

_DRM_IOCTL_SET_CLIENT_CAP = 0x4010640D
_DRM_CLIENT_CAP_ATOMIC = 3
_DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE = 7
# DRM_MODE_OBJECT_PLANE magic type from drm_mode.h (planes register
# under this type; drmModeObjectGetProperties matches it verbatim).
_DRM_MODE_OBJECT_PLANE = 0xeeeeeeee


def detect_plane_color_pipeline(card_name: str) -> Optional[bool]:
    """Probe whether a DRM card exposes plane color pipelines.

    Opens ``/dev/dri/<card_name>`` and asks the kernel to enable
    ``DRM_CLIENT_CAP_ATOMIC`` and ``DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE``,
    then checks whether any plane exposes a property literally named
    ``COLOR_PIPELINE``.  Informational only — the install proceeds
    regardless of the result.

    Returns:
        ``True`` if both client caps were accepted and at least one plane
        exposes ``COLOR_PIPELINE``; ``False`` if a cap was rejected, no
        plane exposes the property, or plane enumeration returned
        NULL/empty; ``None`` if the probe could not run (missing device
        node, unloadable libdrm, or any unexpected failure).
    """
    dev = f"/dev/dri/{card_name}"
    if not os.path.exists(dev):
        return None

    try:
        libdrm = ctypes.CDLL("libdrm.so.2")
    except OSError:
        return None

    try:
        libdrm.drmModeGetPlaneResources.argtypes = [ctypes.c_int]
        libdrm.drmModeGetPlaneResources.restype = ctypes.c_void_p
        libdrm.drmModeFreePlaneResources.argtypes = [ctypes.c_void_p]
        libdrm.drmModeFreePlaneResources.restype = None
        libdrm.drmModeObjectGetProperties.argtypes = [
            ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32,
        ]
        libdrm.drmModeObjectGetProperties.restype = ctypes.c_void_p
        libdrm.drmModeFreeObjectProperties.argtypes = [ctypes.c_void_p]
        libdrm.drmModeFreeObjectProperties.restype = None
        libdrm.drmModeGetProperty.argtypes = [ctypes.c_int, ctypes.c_uint32]
        libdrm.drmModeGetProperty.restype = ctypes.c_void_p
        libdrm.drmModeFreeProperty.argtypes = [ctypes.c_void_p]
        libdrm.drmModeFreeProperty.restype = None
        fd = os.open(dev, os.O_RDWR | os.O_CLOEXEC)
    except (OSError, AttributeError):
        return None

    try:
        # Enable client capabilities in order; if the kernel rejects
        # either one, the driver cannot expose plane color pipelines.
        for cap in (_DRM_CLIENT_CAP_ATOMIC, _DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE):
            try:
                fcntl.ioctl(fd, _DRM_IOCTL_SET_CLIENT_CAP, struct.pack("QQ", cap, 1))
            except OSError:
                return False

        res = libdrm.drmModeGetPlaneResources(fd)
        if not res:
            return False

        # drmModePlaneRes and drmModeObjectProperties both start with a
        # u32 count followed by a pointer; the +8 byte offsets below assume
        # the x86-64 (LP64) ABI — the only Arch/CachyOS target.
        plane_count = ctypes.c_int.from_address(res).value
        planes_ptr = ctypes.c_void_p.from_address(res + 8).value
        if not planes_ptr:
            _free_drm(libdrm, "drmModeFreePlaneResources", res)
            return False
        for i in range(plane_count):
            plane_id = ctypes.c_uint32.from_address(planes_ptr + i * 4).value
            props = libdrm.drmModeObjectGetProperties(
                fd, plane_id, _DRM_MODE_OBJECT_PLANE
            )
            if not props:
                continue
            prop_count = ctypes.c_int.from_address(props).value
            props_ptr = ctypes.c_void_p.from_address(props + 8).value
            if not props_ptr:
                _free_drm(libdrm, "drmModeFreeObjectProperties", props)
                continue
            for j in range(prop_count):
                prop_id = ctypes.c_uint32.from_address(props_ptr + j * 4).value
                prop = libdrm.drmModeGetProperty(fd, prop_id)
                if not prop:
                    continue
                name = ctypes.string_at(prop + 8, 32).split(b"\0", 1)[0]
                if name == b"COLOR_PIPELINE":
                    _free_drm(libdrm, "drmModeFreeProperty", prop)
                    _free_drm(libdrm, "drmModeFreeObjectProperties", props)
                    _free_drm(libdrm, "drmModeFreePlaneResources", res)
                    return True
                _free_drm(libdrm, "drmModeFreeProperty", prop)
            _free_drm(libdrm, "drmModeFreeObjectProperties", props)
        _free_drm(libdrm, "drmModeFreePlaneResources", res)
        return False
    except Exception:
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# EDID Path Detection
# ---------------------------------------------------------------------------

def detect_edid_path() -> Optional[str]:
    """Find the sysfs EDID path for the first connected display.

    Looks at ``/sys/class/drm/*/status`` for ``"connected"``.  Internal
    panels (eDP, LVDS) are preferred over external connectors.

    Returns:
        Absolute path to the EDID file (e.g.
        ``/sys/class/drm/card1-eDP-1/edid``), or ``None`` if no
        connected display is found.
    """
    connected = _get_connected_connectors()
    if not connected:
        return None

    path = os.path.join("/sys/class/drm", connected[0], "edid")
    if os.path.exists(path):
        return path
    return None


# ---------------------------------------------------------------------------
# Display Name
# ---------------------------------------------------------------------------

def detect_display_name() -> str:
    """Return a human-readable display name.

    Reads the first ASCII descriptor block from the EDID if available,
    otherwise falls back to the connector name.

    Returns:
        Display name string (e.g. ``"LEN156FHD"``) or ``"Unknown"``.
    """
    edid_path = detect_edid_path()
    if edid_path is None:
        return _connector_name_fallback()

    try:
        with open(edid_path, "rb") as f:
            edid = f.read()
    except OSError:
        return _connector_name_fallback()

    if len(edid) < 128:
        return _connector_name_fallback()

    # Scan descriptor blocks for monitor name (tag == 0xFC).
    for base in (0x36, 0x48, 0x5A, 0x6C):
        tag = edid[base + 3]
        if tag == 0xFC:  # Monitor descriptor
            raw = edid[base + 5 : base + 18]
            name = raw.rstrip(b"\n\r\x00 ").decode("ascii", errors="replace")
            return name.strip()

    return _connector_name_fallback()


# ---------------------------------------------------------------------------
# Brightness Detection
# ---------------------------------------------------------------------------

def detect_brightness() -> int:
    """Read current backlight brightness as a percentage.

    Iterates ``/sys/class/backlight/*/`` and reads ``actual_brightness``
    and ``max_brightness``.  Returns ``round(actual / max * 100)``.

    Returns:
        Brightness percentage (0–100).  Defaults to **50** if no
        backlight interface is found.
    """
    backlight_dirs = sorted(
        glob.glob("/sys/class/backlight/*")
    )
    if not backlight_dirs:
        return 50

    for bl_dir in backlight_dirs:
        max_path = os.path.join(bl_dir, "max_brightness")
        actual_path = os.path.join(bl_dir, "actual_brightness")
        if not (os.path.isfile(max_path) and os.path.isfile(actual_path)):
            continue
        try:
            with open(max_path) as f:
                max_val = int(f.read().strip())
            with open(actual_path) as f:
                actual_val = int(f.read().strip())
        except (OSError, ValueError):
            continue
        if max_val == 0:
            continue
        return round(actual_val / max_val * 100)

    return 50


# ---------------------------------------------------------------------------
# Hardware Report
# ---------------------------------------------------------------------------

def hardware_report() -> Dict[str, object]:
    """Return a summary of detected hardware characteristics.

    Returns:
        Dictionary with keys:

        - ``gpu_method`` (str) — ``"amd"``, ``"nvidia"``, or ``"generic"``
        - ``display_name`` (str) — human-readable display name
        - ``connectors`` (list[str]) — all connected connector names
        - ``brightness_pct`` (int) — current backlight brightness (0–100)
        - ``edid_path`` (str or None) — path to the active EDID
    """
    connected = _get_connected_connectors()
    return {
        "gpu_method": detect_gpu_method(),
        "display_name": detect_display_name(),
        "connectors": connected,
        "brightness_pct": detect_brightness(),
        "edid_path": detect_edid_path(),
    }


# ---------------------------------------------------------------------------
# Internal Helpers
# ---------------------------------------------------------------------------

def _free_drm(libdrm: ctypes.CDLL, name: str, ptr: Optional[int]) -> None:
    """Free a libdrm allocation, tolerating missing symbols and NULL."""
    free_fn = getattr(libdrm, name, None)
    if free_fn is not None and ptr:
        free_fn(ptr)


def _get_connected_connectors() -> List[str]:
    """Return a sorted list of connected DRM connector names.

    Internal panels (eDP, LVDS) are listed before external connectors.
    """
    drm_base = "/sys/class/drm"
    if not os.path.isdir(drm_base):
        return []

    edp_list: List[str] = []
    other_list: List[str] = []

    try:
        entries = sorted(os.listdir(drm_base))
    except OSError:
        return []

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
                edp_list.append(entry)
            else:
                other_list.append(entry)

    return edp_list + other_list


def _get_vendors_of_connected_cards() -> List[str]:
    """Return vendor IDs for DRM cards that have connected connectors.

    For each ``card`` under ``/sys/class/drm/card*/device/vendor``,
    if at least one connector of that card is connected, the vendor ID
    is included.
    """
    drm_base = "/sys/class/drm"
    if not os.path.isdir(drm_base):
        return []

    # Collect per-card connected connectors
    card_connected: Dict[str, bool] = {}

    try:
        entries = sorted(os.listdir(drm_base))
    except OSError:
        return []

    for entry in entries:
        status_path = os.path.join(drm_base, entry, "status")
        if not os.path.isfile(status_path):
            continue
        try:
            with open(status_path) as f:
                status = f.read().strip()
        except OSError:
            continue

        # Extract card prefix (e.g. "card1" from "card1-eDP-1")
        card = entry.split("-")[0] if "-" in entry else entry
        if status == "connected":
            card_connected.setdefault(card, False)
            card_connected[card] = True

    # Read vendor for each card with a connected display
    vendors: List[str] = []
    for card in card_connected:
        if card_connected[card]:
            vendor_path = os.path.join(drm_base, card, "device", "vendor")
            if os.path.isfile(vendor_path):
                try:
                    with open(vendor_path) as f:
                        vendor = f.read().strip()
                    if vendor:
                        vendors.append(vendor)
                except OSError:
                    continue

    return vendors


def _connector_name_fallback() -> str:
    """Return the connector name of the first connected display."""
    connected = _get_connected_connectors()
    if connected:
        return connected[0]
    return "Unknown"
