"""Transfer function mathematics for ICC profile generation.

Provides sRGB EOTF/inverse, pure gamma EOTF/inverse,
PQ (ST.2084) EOTF/inverse, and the Electrical-Electrical
Transfer Function (EETF) for black-level handling.

All functions operate on float values in [0, 1] range unless
otherwise noted.
"""

from __future__ import annotations

import math

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# sRGB piecewise breakpoints (IEC 61966-2-1:1999)
SRGB_X1: float = 0.0404482362771082
"""sRGB linear breakpoint — value of L at V == 0.04045 (V/12.92)."""

SRGB_X2: float = 0.00313066844250063
"""sRGB nonlinear breakpoint — L threshold at which encoding switches."""

# Perceptual Quantizer (ST.2084 / BT.2100) constants (SMPTE ST 2084:2014)
PQ_M1: float = 0.1593017578125
"""PQ m1 = 2610/16384."""
PQ_M2: float = 78.84375
"""PQ m2 = 2523/32."""
PQ_C1: float = 0.8359375
"""PQ c1 = 3424/4096."""
PQ_C2: float = 18.8515625
"""PQ c2 = 2413/128."""
PQ_C3: float = 18.6875
"""PQ c3 = 2392/128."""


# ---------------------------------------------------------------------------
# sRGB Transfer Functions
# ---------------------------------------------------------------------------

def srgb_eotf(V: float) -> float:
    """sRGB Electro-Optical Transfer Function (EOTF) — to linear.

    Converts an sRGB-encoded nonlinear value *V* to linear luminance *L*.

    Args:
        V: Nonlinear sRGB signal value in [0, 1].

    Returns:
        Linear luminance *L* in [0, 1].

    Example:
        >>> srgb_eotf(0.0)
        0.0
        >>> srgb_eotf(1.0)
        1.0
        >>> srgb_eotf(0.5)
        0.214041140...

    Formula:
        L = V / 12.92                        if V <= 0.04045
        L = ((V + 0.055) / 1.055) ** 2.4     otherwise
    """
    if V <= SRGB_X1:
        return V / 12.92
    return ((V + 0.055) / 1.055) ** 2.4


def srgb_eotf_inverse(L: float) -> float:
    """sRGB inverse EOTF (OETF) — to nonlinear.

    Converts linear luminance *L* to an sRGB-encoded nonlinear value *V*.

    Args:
        L: Linear luminance in [0, 1].

    Returns:
        Nonlinear sRGB signal value *V* in [0, 1].

    Example:
        >>> srgb_eotf_inverse(0.0)
        0.0
        >>> srgb_eotf_inverse(1.0)
        1.0
        >>> srgb_eotf_inverse(0.214041140)
        0.5

    Formula:
        V = 12.92 * L                             if L <= 0.0031308
        V = 1.055 * L ** (1 / 2.4) - 0.055        otherwise
    """
    if L <= SRGB_X2:
        return 12.92 * L
    return 1.055 * (L ** (1.0 / 2.4)) - 0.055


# ---------------------------------------------------------------------------
# Pure Gamma Transfer Functions
# ---------------------------------------------------------------------------

def pure_gamma_eotf(V: float, gamma: float = 2.2) -> float:
    """Pure gamma EOTF — to linear.

    Args:
        V: Nonlinear signal value in [0, 1].
        gamma: Target gamma exponent (default 2.2).

    Returns:
        Linear luminance *L* = V ** gamma.

    Example:
        >>> pure_gamma_eotf(0.5, 2.2)
        0.217637641...
    """
    return V ** gamma


def pure_gamma_eotf_inverse(L: float, gamma: float = 2.2) -> float:
    """Pure gamma inverse EOTF — to nonlinear.

    Args:
        L: Linear luminance in [0, 1].
        gamma: Target gamma exponent (default 2.2).

    Returns:
        Nonlinear signal value *V* = L ** (1 / gamma).

    Example:
        >>> pure_gamma_eotf_inverse(0.217637641, 2.2)
        0.5
    """
    return L ** (1.0 / gamma)


# ---------------------------------------------------------------------------
# Perceptual Quantizer (ST.2084 / BT.2100)
# ---------------------------------------------------------------------------

def pq_eotf(V: float) -> float:
    """Perceptual Quantizer EOTF — ST.2084 nonlinear to luminance.

    Converts a PQ-encoded signal value *V* to absolute luminance in
    **nits** (cd/m²).

    Args:
        V: PQ nonlinear signal value in [0, 1].

    Returns:
        Absolute luminance in nits, in [0, 10000].

    Example:
        >>> pq_eotf(0.0)
        0.0
        >>> pq_eotf(1.0)
        10000.0

    Formula (ST.2084):
        L = 10000 * (max(V**(1/m2) - c1, 0) / (c2 - c3 * V**(1/m2))) ** (1/m1)
    """
    if V <= 0.0:
        return 0.0
    if V >= 1.0:
        return 10000.0
    v_pow = V ** (1.0 / PQ_M2)
    num = max(v_pow - PQ_C1, 0.0)
    den = PQ_C2 - PQ_C3 * v_pow
    return 10000.0 * (num / den) ** (1.0 / PQ_M1)


def pq_eotf_inverse(L: float) -> float:
    """Perceptual Quantizer inverse EOTF (OETF) — luminance to nonlinear.

    Converts absolute luminance *L* (in nits) to a PQ-encoded signal value.

    Args:
        L: Absolute luminance in nits, in [0, 10000].

    Returns:
        PQ nonlinear signal value *V* in [0, 1].

    Example:
        >>> pq_eotf_inverse(10000.0)
        1.0
        >>> pq_eotf_inverse(0.0)
        0.0

    Formula (ST.2084):
        V = ((c1 + c2 * (L/10000)**m1) / (1 + c3 * (L/10000)**m1)) ** m2
    """
    if L <= 0.0:
        return 0.0
    if L >= 10000.0:
        return 1.0
    y = (L / 10000.0) ** PQ_M1
    return ((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y)) ** PQ_M2


# ---------------------------------------------------------------------------
# Electrical-Electrical Transfer Function (EETF)
# ---------------------------------------------------------------------------

def eetf(
    V: float,
    Lb: float,
    Lw: float,
    Lmin: float,
    Lmax: float,
) -> float:
    """Electrical-Electrical Transfer Function for black-level handling.

    Maps an input signal *V* (in the range [Lmin, Lmax]) to an output
    range [Lb, Lw].  Values below *Lmin* are clamped to *Lb*; values
    above *Lmax* are clamped to *Lw*.  In between the mapping is a
    linear remap.

    This function is used in the NVIDIA GPU code path to account for
    black-level lifting and white-level clipping when converting between
    PQ-encoded HDR signals and the SDR display's native range.

    Args:
        V: Input signal value (linear luminance).
        Lb: Black level luminance to map to.
        Lw: White level luminance to map to.
        Lmin: Minimum input luminance to consider.
        Lmax: Maximum input luminance to consider.

    Returns:
        Mapped output value in [Lb, Lw].

    Example:
        >>> eetf(0.0, 0.0, 200.0, 0.0, 10000.0)
        0.0
        >>> eetf(10000.0, 0.0, 200.0, 0.0, 10000.0)
        200.0
    """
    if V <= Lmin:
        return Lb
    if V >= Lmax:
        return Lw

    # Linear remap from [Lmin, Lmax] -> [Lb, Lw]
    t = (V - Lmin) / (Lmax - Lmin)
    return Lb + (Lw - Lb) * t
