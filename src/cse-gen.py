#!/usr/bin/env python3
"""cse-gen — sRGB to gamma 2.2 ICC profile generator for CachyOS.

Usage:
    cse-gen --all                           # Generate all 7 luminance levels
    cse-gen --white-level 200 --gpu-method amd  # Single profile
    cse-gen --report                         # Print hardware detection report
    cse-gen --verify /path/to/profile.icc    # Validate an ICC profile
"""

import argparse
import json
import os
import sys
from pathlib import Path

# Add src to path for direct script execution
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cse_lib import (
    build_vcgt_amd, build_vcgt_nvidia, build_vcgt_generic,
    build_icc_profile, validate_icc_profile,
    write_cal_file, vcgt_to_icc_tag,
    detect_gpu_method, detect_edid_path, detect_display_name,
    detect_brightness, hardware_report,
    edid_summary, read_edid_from_sysfs,
)

# Luminance levels (in nits) for --all mode
ALL_LUMINANCE_LEVELS = [80, 100, 120, 200, 300, 400, 480]

# Valid luminance range
MIN_LUMINANCE = 80
MAX_LUMINANCE = 480
LUMINANCE_STEP = 10


def build_profile(white_level, gamma, gpu_method, output_path, black_level=0.0):
    """Build a single ICC profile and write it to disk.

    Returns the path of the written file.
    """
    if gpu_method == "amd":
        vcgt_func = build_vcgt_amd
    elif gpu_method == "nvidia":
        vcgt_func = build_vcgt_nvidia
    else:
        vcgt_func = build_vcgt_generic

    lut = vcgt_func(white_level=white_level, gamma=gamma, black_level=black_level)
    icc_data = build_icc_profile(
        desc_text=f"cse_{white_level}nits_{gpu_method}",
        vcgt_lut=lut,
        white_level=white_level,
        gamma=gamma,
        black_level=black_level,
    )

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(icc_data)

    return str(output_path)


def build_cal(white_level, gamma, gpu_method, output_path, black_level=0.0):
    """Build a single .cal file and write it to disk.

    Returns the path of the written file.
    """
    if gpu_method == "amd":
        vcgt_func = build_vcgt_amd
    elif gpu_method == "nvidia":
        vcgt_func = build_vcgt_nvidia
    else:
        vcgt_func = build_vcgt_generic

    lut = vcgt_func(white_level=white_level, gamma=gamma, black_level=black_level)
    cal_content = write_cal_file(lut, gamma=gamma, white_level=white_level)

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(cal_content)

    return str(output_path)


def generate_all(output_dir, gpu_method, gamma, black_level, cal_only):
    """Generate profiles for all standard luminance levels."""
    output_dir = Path(output_dir)
    results = []

    for wl in ALL_LUMINANCE_LEVELS:
        method = gpu_method or detect_gpu_method()
        if cal_only:
            out_name = f"cse_{wl}nits_{method}.cal"
            out_path = output_dir / out_name
            path = build_cal(wl, gamma, method, out_path, black_level)
        else:
            out_name = f"cse_{wl}nits_{method}.icc"
            out_path = output_dir / out_name
            path = build_profile(wl, gamma, method, out_path, black_level)
        results.append(path)
        print(f"  ✓ {path}")

    return results


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="cse-gen",
        description="sRGB to gamma 2.2 ICC profile generator for CachyOS/Linux",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  cse-gen --all                           Generate all 7 luminance levels\n"
            "  cse-gen --white-level 200 --gpu-method amd  Single profile for AMD GPU\n"
            "  cse-gen --report                         Print hardware detection report\n"
            "  cse-gen --verify profile.icc             Validate an ICC profile\n"
            "  cse-gen --cal-only --all                 Generate .cal files instead of .icc\n"
        ),
    )

    # Mutually exclusive mode group
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--all", action="store_true",
        help="Generate profiles for all standard luminance levels (80, 100, 120, 200, 300, 400, 480 nits)",
    )
    mode.add_argument(
        "--report", action="store_true",
        help="Print hardware detection report",
    )
    mode.add_argument(
        "--verify", metavar="FILE", type=str,
        help="Validate an ICC profile at the given path",
    )

    # Profile generation options
    parser.add_argument(
        "--white-level", type=int, default=None,
        metavar="N",
        help=f"White level in nits ({MIN_LUMINANCE}-{MAX_LUMINANCE}, step {LUMINANCE_STEP})",
    )
    parser.add_argument(
        "--gamma", type=float, default=2.2,
        metavar="G",
        help="Target gamma (default: 2.2)",
    )
    parser.add_argument(
        "--gpu-method", choices=["amd", "nvidia", "generic", "auto"],
        default="auto",
        help="GPU VCGT method to use (default: auto-detect)",
    )
    parser.add_argument(
        "--black-level", type=float, default=0.0,
        metavar="B",
        help="Black level offset (default: 0.0)",
    )
    parser.add_argument(
        "--output", "-o", type=str, default=None,
        metavar="FILE",
        help="Output file path (auto-generated if not specified)",
    )
    parser.add_argument(
        "--output-dir", type=str, default=None,
        metavar="DIR",
        help="Output directory (default: ./output/)",
    )
    parser.add_argument(
        "--edid", type=str, default=None,
        metavar="PATH",
        help="Path to EDID file for display information",
    )
    parser.add_argument(
        "--cal-only", action="store_true",
        help="Generate .cal dispwin/gputool files instead of .icc profiles",
    )

    return parser.parse_args(argv)


def main():
    args = parse_args()
    gpu_method = args.gpu_method

    # Resolve GPU method
    if gpu_method == "auto" or args.report:
        method = detect_gpu_method()
    else:
        method = gpu_method
    if gpu_method == "auto":
        gpu_method = method

    # Determine output directory
    output_dir = Path(args.output_dir) if args.output_dir else Path("output")

    # --- REPORT MODE ---
    if args.report:
        report = hardware_report()
        print("=" * 60)
        print("  CachyOS Screen Enhancer — Hardware Report")
        print("=" * 60)
        print(f"  GPU Method:         {report.get('gpu_method', 'unknown')}")
        print(f"  GPU Driver:         {report.get('gpu_driver', 'unknown')}")
        edid = report.get("edid", {})
        if edid:
            print(f"  Display:            {edid.get('monitor_name', 'unknown')}")
            print(f"  EDID Path:          {edid.get('edid_path', 'N/A')}")
            print(f"  Screen Size:        {edid.get('screen_size', 'unknown')}")
            print(f"  Physical Size:      {edid.get('physical_size', 'unknown')}")
            print(f"  Aspect Ratio:       {edid.get('aspect_ratio', 'unknown')}")
        print(f"  Detected Brightness: {report.get('brightness', 'unknown')}")
        print(f"  System:             {report.get('system', 'unknown')}")
        print("-" * 60)
        print("  EDID Raw Summary:")
        for line in edid.get("summary", "").splitlines():
            print(f"    {line}")
        print("=" * 60)
        return

    # --- VERIFY MODE ---
    if args.verify:
        path = Path(args.verify)
        if not path.exists():
            print(f"ERROR: file not found: {path}")
            sys.exit(1)
        data = path.read_bytes()
        valid = validate_icc_profile(data)
        size_kb = len(data) / 1024
        if valid:
            print(f"  ✓ {path.name} ({size_kb:.1f} KB) — VALID ICC profile")
        else:
            print(f"  ✗ {path.name} ({size_kb:.1f} KB) — INVALID ICC profile")
            sys.exit(1)
        return

    # --- ALL MODE ---
    if args.all:
        print(f"Generating {len(ALL_LUMINANCE_LEVELS)} profiles (method: {gpu_method}, gamma: {args.gamma})")
        print(f"Output directory: {output_dir.resolve()}")
        generate_all(output_dir, gpu_method, args.gamma, args.black_level, args.cal_only)
        print("Done.")
        return

    # --- SINGLE PROFILE MODE ---
    if args.white_level is None:
        print("ERROR: specify --white-level N or use --all / --report / --verify")
        sys.exit(1)

    wl = args.white_level
    if wl < MIN_LUMINANCE or wl > MAX_LUMINANCE or (wl % LUMINANCE_STEP) != 0:
        print(
            f"ERROR: --white-level must be between {MIN_LUMINANCE} and "
            f"{MAX_LUMINANCE}, in steps of {LUMINANCE_STEP}"
        )
        sys.exit(1)

    if args.output:
        out_path = Path(args.output)
    else:
        ext = ".cal" if args.cal_only else ".icc"
        out_name = f"cse_{wl}nits_{gpu_method}{ext}"
        out_path = output_dir / out_name

    if args.cal_only:
        path = build_cal(wl, args.gamma, gpu_method, out_path, args.black_level)
        print(f"  ✓ {path}")
    else:
        path = build_profile(wl, args.gamma, gpu_method, out_path, args.black_level)
        print(f"  ✓ {path}")


if __name__ == "__main__":
    main()
