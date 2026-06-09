"""Basic sanity tests for cse_lib."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from cse_lib.gamma_math import (
    srgb_eotf, srgb_eotf_inverse,
    pure_gamma_eotf, pure_gamma_eotf_inverse,
    pq_eotf, pq_eotf_inverse,
)
from cse_lib.vcgt_builder import build_vcgt_amd, vcgt_to_icc_tag
from cse_lib.icc_builder import build_icc_profile, validate_icc_profile


def test_srgb_eotf_boundaries():
    assert abs(srgb_eotf(0.0)) < 1e-10
    assert abs(srgb_eotf(1.0) - 1.0) < 1e-10


def test_srgb_eotf_mid():
    result = srgb_eotf(0.5)
    assert abs(result - 0.214041140) < 1e-6


def test_srgb_eotf_inverse_roundtrip():
    for v in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]:
        L = srgb_eotf(v)
        v2 = srgb_eotf_inverse(L)
        assert abs(v - v2) < 1e-10


def test_pure_gamma():
    result = pure_gamma_eotf(0.5, 2.2)
    assert abs(result - 0.217637641) < 1e-6
    L = pure_gamma_eotf(0.5, 2.2)
    v = pure_gamma_eotf_inverse(L, 2.2)
    assert abs(v - 0.5) < 1e-10


def test_pq_boundaries():
    assert abs(pq_eotf(0.0)) < 1e-10
    assert abs(pq_eotf(1.0) - 10000.0) < 1e-6
    assert abs(pq_eotf_inverse(10000.0) - 1.0) < 1e-10
    assert abs(pq_eotf_inverse(0.0)) < 1e-10


def test_vcgt_amd():
    lut = build_vcgt_amd(white_level=200.0, gamma=2.2)
    assert len(lut) == 256
    assert abs(lut[0]) < 1e-10  # first entry should be ~0
    assert abs(lut[255] - 1.0) < 1e-4  # last entry should be ~1
    # Verify the VCGT mapping is correct: sRGB→linear→gamma encode
    # For v=128 (mid-gray sRGB), the correct output is srgbEotf(v)^(1/2.2)
    # This should be ~0.498, NOT 0.737 (the old inverted result).
    assert abs(lut[128] - 0.498) < 0.005, (
        f"VCGT[128] = {lut[128]:.4f}, expected ~0.498. "
        "The VCGT mapping was inverted — srgb_eotf_inverse was used "
        "instead of srgb_eotf."
    )


def test_vcgt_tag():
    lut = build_vcgt_amd()
    tag = vcgt_to_icc_tag(lut)
    assert len(tag) > 0
    # Tag header: 4 bytes sig + 4 bytes reserved
    assert tag[:4] == b'vcgt'


def test_build_icc():
    lut = build_vcgt_amd(white_level=200.0)
    icc = build_icc_profile(
        desc_text="cse test",
        vcgt_lut=lut,
        white_level=200.0,
        gamma=2.2,
    )
    assert len(icc) > 128  # minimum ICC header size
    assert validate_icc_profile(icc)


def test_validate_bad_profile():
    assert not validate_icc_profile(b"")
    assert not validate_icc_profile(b"\x00" * 128)


if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-v"])
