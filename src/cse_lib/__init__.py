"""cse_lib — Core library for cachy-screen-enhancer ICC profile generation."""

from .gamma_math import (
    SRGB_X1,
    SRGB_X2,
    PQ_M1,
    PQ_M2,
    PQ_C1,
    PQ_C2,
    PQ_C3,
    srgb_eotf,
    srgb_eotf_inverse,
    pure_gamma_eotf,
    pure_gamma_eotf_inverse,
    pq_eotf,
    pq_eotf_inverse,
    eetf,
)

from .edid_parser import (
    parse_edid_gamma,
    parse_edid_chromaticity,
    parse_edid_physical_size,
    parse_edid_manufacturer,
    parse_edid_model,
    parse_edid_serial,
    edid_summary,
    read_edid_from_sysfs,
)

from .gpu_detect import (
    detect_gpu_method,
    detect_edid_path,
    detect_display_name,
    detect_brightness,
    hardware_report,
)

from .vcgt_builder import (
    build_vcgt_amd,
    build_vcgt_nvidia,
    build_vcgt_generic,
    write_cal_file,
    vcgt_to_icc_tag,
)

from .icc_builder import (
    build_icc_profile,
    validate_icc_profile,
)

__all__ = [
    # gamma_math
    "SRGB_X1",
    "SRGB_X2",
    "PQ_M1",
    "PQ_M2",
    "PQ_C1",
    "PQ_C2",
    "PQ_C3",
    "srgb_eotf",
    "srgb_eotf_inverse",
    "pure_gamma_eotf",
    "pure_gamma_eotf_inverse",
    "pq_eotf",
    "pq_eotf_inverse",
    "eetf",
    # edid_parser
    "parse_edid_gamma",
    "parse_edid_chromaticity",
    "parse_edid_physical_size",
    "parse_edid_manufacturer",
    "parse_edid_model",
    "parse_edid_serial",
    "edid_summary",
    "read_edid_from_sysfs",
    # gpu_detect
    "detect_gpu_method",
    "detect_edid_path",
    "detect_display_name",
    "detect_brightness",
    "hardware_report",
    # vcgt_builder
    "build_vcgt_amd",
    "build_vcgt_nvidia",
    "build_vcgt_generic",
    "write_cal_file",
    "vcgt_to_icc_tag",
    # icc_builder
    "build_icc_profile",
    "validate_icc_profile",
]
