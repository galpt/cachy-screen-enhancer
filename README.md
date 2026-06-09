# cachy-screen-enhancer

> Fix your screen's colors with one command. No calibration hardware needed.

---

## What's this all about?

Ever notice how your laptop screen looks kinda... *washed out*? The colors are there, but blacks look more like dark gray, and shadows feel flat? Like you're watching a movie with the brightness cranked up too high?

Yeah, that's not your eyes playing tricks.

The thing is, your screen expects colors to follow a certain curve — it's called **gamma 2.2**, and it's been the standard for computer displays for like forever. But most Linux desktops (including KDE) send colors using a slightly different curve called **sRGB**. It's not *broken*, but it makes everything look a bit lighter than it should be, especially in darker areas.

This project fixes that. It creates a color profile that:
- Tells color-aware apps (browsers, editors, media players) about your screen's color response
- Applies a gamma correction LUT to your GPU, so the hardware actually shows deeper blacks

The whole thing is automatic — one command detects your hardware, generates a custom profile, and installs everything.

---

## Will this work on my computer?

Quick checklist:

- **OS:** You're on Linux — CachyOS, Arch, or any Arch-based distro
- **Desktop:** You use **KDE Plasma** (on Wayland or X11 — both work)
- **GPU:** You have an **AMD** or **NVIDIA** graphics card

If you checked all three boxes? You're good. Let's go.

If you're on a different distro or desktop environment, check out `docs/TROUBLESHOOTING.md` — there's usually a way to make it work, it just takes an extra step or two.

---

## Make it better (the easy way)

This is the recommended way. One command, auto-detects everything about your system, picks the best profile, and installs it.

```bash
# Clone the repo (if you haven't already)
git clone https://github.com/galpt/cachy-screen-enhancer.git
cd cachy-screen-enhancer

# One command — that's it
bash safe-install.sh
```

Here's what happens when you run it:

1. It asks for your sudo password **once** (and keeps the session alive so it won't keep bugging you)
2. It auto-installs `colord` (for profile management) and `argyllcms` (for dispwin gamma LUT) if missing
3. It figures out what GPU you have (AMD / NVIDIA / generic)
4. It finds your display, reads its EDID, and detects your current brightness level
5. It generates a custom ICC profile (with accurate TRC and white point) and a `.cal` gamma LUT
6. It applies the gamma correction to your GPU via `dispwin` — this is what changes the blacks
7. It registers the ICC profile with colord and opens KDE Display Settings so you can select it

And then you get a nice summary like this:

```
+----------------------------------------------------+
|       cachy-screen-enhancer — Auto Install         |
+----------------------------------------------------+

[*] Detecting GPU method...
    → Method: amd
[*] Detecting display...
    → Display: card2-eDP-1
[*] Detecting brightness...
    → Brightness: ~42%

[*] Generating profile for your hardware...
  ✓ output/cse_200nits_amd.icc
    → Profile: cse_200nits_amd.icc

[*] Applying gamma correction...
    → dispwin display index: 1
    → Gamma correction applied via dispwin

[*] Installing ICC profile...
    → Registered: icc-e048bcdc248b2a0f13da5b25a5009661
    → Opening color settings...

A KDE settings window will open. If the profile appears in the
"Color profile" dropdown, select it. Otherwise:

  1. Click the dropdown → select "ICC profile"
  2. Browse to: /usr/share/color/icc/colord/cse_200nits_amd.icc
  3. Click OK

+----------------------------------------------------+
|  All done!                                         |
|                                                    |
|  + Gamma correction via dispwin                    |
|  + ICC profile installed                           |
|                                                    |
|  To remove:                                        |
|    bash tools/remove-profile.sh                    |
+----------------------------------------------------+

Selected profile: cse_200nits_amd.icc
```

That's it. The gamma correction is already active on your display (via dispwin). For color-aware apps to use the profile, select it in the KDE settings as described above. If something looks off, undo everything:

```bash
bash tools/remove-profile.sh
```

No harm done.

---

## Make it better (the manual way)

If you'd rather pick the profile yourself (or you want to understand what the numbers mean), here's how.

### Short answer

If you're not sure, grab **`cse_200nits_amd.icc`**. It's the default for a reason — works for most people in most rooms.

### What the numbers mean

The `080`, `100`, `120`, `200`, `300`, `400`, `480` in the filename is the **brightness level** your screen is set to. Pick the one closest to how you use your laptop:

| File | Brightness | Best for... |
|---|---|---|
| `cse_080nits_amd.icc` | Lowest | Using your laptop in a dark room at night with the screen dimmed way down |
| `cse_100nits_amd.icc` | Low | Dim indoor lighting — like a coffee shop in the evening |
| `cse_120nits_amd.icc` | Low-medium | Typical office with moderate overhead lights |
| **`cse_200nits_amd.icc`** | **Medium** | **Default — works for most people in most rooms** |
| `cse_300nits_amd.icc` | High | Bright room with lots of windows |
| `cse_400nits_amd.icc` | Very high | Outdoors or very bright environment |
| `cse_480nits_amd.icc` | Maximum | Screen brightness maxed out, full daylight |

### Not sure what brightness level your screen is at?

Open **KDE System Settings → Display → Brightness**. If your slider is roughly at:

| Slider position | Use this file |
|---|---|
| 0–10% | `cse_080nits_amd.icc` or `cse_100nits_amd.icc` |
| 10–20% | `cse_120nits_amd.icc` |
| 20–50% | `cse_200nits_amd.icc` ← most common |
| 50–75% | `cse_300nits_amd.icc` |
| 75%+ | `cse_400nits_amd.icc` or `cse_480nits_amd.icc` |

### How to install manually

1. Pick a file from `profiles/icc/` (use the tables above)
2. Open **System Settings → Display & Monitor → Display Configuration → Color profile** (on CachyOS/KDE; other distros: **KDE System Settings → Color Management**)
3. Click **"Add"** → **"Browse..."** → select the `.icc` file
4. Select the profile from the list and click **"Set as Default Profile"**
5. Done

Still unsure? Just pick `cse_200nits_amd.icc`. If the screen looks too dark (crushed shadows), switch to a higher number. If it looks slightly washed out, try a lower number. No harm in experimenting — switching profiles takes like 10 seconds.

---

## So, what did that actually do?

Okay, here's the non-boring explanation.

Your screen has a natural "curve" for how bright each pixel should be. Think of it like a volume knob, but for light. Most laptop screens expect **gamma 2.2** — it's been the standard since CRTs were a thing.

But your desktop environment (KDE) sends colors using a slightly different curve called **sRGB**. The sRGB curve is very similar to gamma 2.2, except in the dark areas — where it makes things *lighter*. That's the "washed out" look people talk about.

The ICC profile you just installed simply tells your graphics card: **"When you're sending colors to this screen, convert the sRGB curve to gamma 2.2."**

That's it. One conversion. It doesn't change the color *balance* (red/green/blue stays the same), it doesn't add fake contrast, it doesn't mess with your wallpaper or theme. It just fixes the math so the signal matches what the screen expects.

If you want the *real* technical details (transfer functions, PQ EOTFs, parametric curves, all that fun stuff), check out `docs/HOW_IT_WORKS.md`. Bring coffee.

---

## Something looks weird

**Blacks look crushed (too dark)** → Try a higher brightness profile. If you used `cse_200nits_amd.icc`, try `cse_300nits_amd.icc`.

**Colors look washed out** → Try a lower brightness profile. If you used `cse_200nits_amd.icc`, try `cse_120nits_amd.icc`.

**Nothing changed at all** → Make sure the profile is set as default in **System Settings → Display & Monitor → Display Configuration → Color profile**. Or just run `bash safe-install.sh` again.

**I want to undo everything** → `bash tools/remove-profile.sh`. This restores the default sRGB profile.

**It broke after I woke my laptop from sleep** → This is a known quirk with Wayland and colord — the profile sometimes gets lost on resume. Just run `safe-install.sh` again. Or check `docs/TROUBLESHOOTING.md` for a workaround that auto-reapplies it.

**Something else?** → Open an issue on GitHub! Include your EDID dump (`bash tools/dump-edid.sh`) so we can help.

---

## I want to customize things

For power users and contributors who want to tweak the profiles or understand the code:

### Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

### Regenerate all profiles

```bash
cse-gen --all
```

This generates all 7 luminance levels for your detected GPU method and puts them in `output/`.

### Generate a single custom profile

```bash
cse-gen --white-level 200 --gamma 2.2 --gpu-method amd
```

Parameters:
- `--all`: Generate all 7 luminance levels (80/100/120/200/300/400/480)
- `--white-level N`: SDR white luminance (80–480 nits, step 10)
- `--gamma G`: Target gamma power (default: 2.2)
- `--gpu-method {amd,nvidia,generic,auto}`: GPU VCGT method (default: auto)
- `--black-level B`: Black floor compensation (default: 0.0)
- `--output FILE, -o FILE`: Output file path (auto-generated if not set)
- `--output-dir DIR`: Output directory (default: ./output/)
- `--edid PATH`: Path to EDID file for display-specific colorimetry
- `--cal-only`: Generate `.cal` LUT files instead of `.icc`
- `--report`: Print hardware detection report
- `--verify FILE`: Validate an ICC profile

### Hardware report

```bash
cse-gen --report
```

Prints everything the tool detected about your system.

### Run tests

```bash
./tests/run_all.sh
```

### Project structure

```
.
│
├── safe-install.sh              ★ One-command auto-install (start here!)
│
├── src/
│   ├── cse-gen.py               CLI tool for generating profiles
│   └── cse_lib/                 Core library (Python package)
│       ├── gamma_math.py        Transfer function math (sRGB, PQ, gamma)
│       ├── edid_parser.py       EDID binary parser
│       ├── gpu_detect.py        GPU driver & display detection
│       ├── vcgt_builder.py      VCGT LUT computation + .cal writer
│       └── icc_builder.py       ICC v4 profile builder
│
├── profiles/
│   ├── icc/                     Prebuilt ICC profiles (grab & go)
│   └── cal/                     ArgyllCMS .cal LUT files
│
├── tools/
│   ├── install-profile.sh       Install an ICC file via colord
│   ├── remove-profile.sh        Remove profiles, restore sRGB
│   ├── dump-edid.sh             Dump EDID from your display
│   ├── inspect-profile.sh       Inspect ICC profile metadata
│   └── verify.sh                Generate visual test patterns
│
├── tests/                       Automated test suite
│   ├── test_basic.py            9 sanity tests
│   └── run_all.sh               One-command test runner
├── docs/                        Supplementary documentation
│   ├── TROUBLESHOOTING.md       Common issues and fixes
│   └── HOW_IT_WORKS.md          Technical deep-dive
├── data/edid/                   Reference EDID dumps
├── scripts/                     Automation helpers
├── output/                      Generated files (gitignored)
│
├── pyproject.toml               Python project metadata
├── .gitignore
└── LICENSE                      BSD 3-Clause
```

---

## Repository map

Here's every file and directory in the project and what it's for.

Same as the tree above in "I want to customize things." Key directories at a glance:

| Directory | Contents |
|---|---|
| `src/` | All Python code: CLI tool + library modules |
| `profiles/` | Prebuilt ICC profiles (`icc/`) and ArgyllCMS .cal LUTs (`cal/`) |
| `tools/` | Utility scripts (install, remove, dump EDID, inspect, verify) |
| `tests/` | Python test suite (`test_basic.py` + `run_all.sh`) |
| `docs/` | Usage guides and technical deep-dives |
| `data/edid/` | Reference EDID dumps for display hardware |
| `output/` | Generated profiles (gitignored — safe-install.sh writes here) |

---

## License

BSD 3-Clause. In plain English:

- **You can use this freely** — for anything.
- **You can share it** — just keep the original copyright notice.
- **You can modify it** — just credit the original if you redistribute it.
- **You can't sue me** — this software is provided "as is" with no warranty.
- **You can't use my name** to promote your own versions without permission.

See the [LICENSE](LICENSE) file for the full legal text.
