# Troubleshooting

> Common issues and how to fix them.

**Before trying anything here, make sure you're in the `cachy-screen-enhancer-codebase/` directory:**
```bash
cd cachy-screen-enhancer/cachy-screen-enhancer-codebase
```
All commands below assume you're running them from there.

---

## Profile doesn't seem to be doing anything

**You installed the profile but colors look the same.**

- Open **KDE System Settings → Color Management** and check if the profile is listed and marked as **Default**. If not, select it and click "Set as Default Profile".
- If using the manual method, make sure you checked **"Add as HDR Profile"** when importing.
- Re-run `bash safe-install.sh` — it'll re-detect everything and re-apply.

## Profile resets after sleep / resume

**You wake your laptop from sleep and the colors go back to how they were.**

This is a known quirk with Wayland + colord. The profile sometimes gets detached on resume. You have a few options:

**Option 1: Just re-run safe-install.sh**
```bash
bash safe-install.sh
```
Takes 5 seconds.

**Option 2: Create a systemd service to auto-apply on resume**

Create `/etc/systemd/system/cse-resume.service`:

```ini
[Unit]
Description=Re-apply cachy-screen-enhancer ICC profile after resume
After=sleep.target

[Service]
Type=oneshot
ExecStart=/bin/bash /path/to/cachy-screen-enhancer-codebase/safe-install.sh
User=galpt

[Install]
WantedBy=sleep.target
```

Then enable it:
```bash
sudo systemctl enable cse-resume.service
```

**Option 3: Use dispwin instead of colord (more persistent)**
```bash
# Install argyllcms first
sudo pacman -S argyllcms

# Apply a .cal LUT directly
dispwin -d 0 profiles/cal/cse_200nits_amd.cal
```

This bypasses colord entirely and writes directly to the GPU LUT.

## Blacks look crushed (too dark)

The profile is mapping to a brightness level that's higher than your actual screen brightness. Try a **lower** number:

- If you used `cse_200nits_amd.icc`, try `cse_120nits_amd.icc`
- Or re-run `safe-install.sh` which detects brightness automatically

If even the lowest profile (80 nits) crushes blacks, your panel may have a raised black floor. Generate a custom profile with black level compensation:

```bash
cse-gen --white-level 200 --black-level 0.05
```

Try `0.05`, `0.1`, or `0.2` until the shadow detail looks right.

## Colors look washed out

The profile is mapping to a brightness level lower than your actual screen brightness. Try a **higher** number:

- If you used `cse_200nits_amd.icc`, try `cse_300nits_amd.icc`
- Or re-run `safe-install.sh`

## "Method not found" or "colormgr: command not found"

The automatic dependency installer should have caught this, but if `colord` didn't install properly:

```bash
sudo pacman -S colord
sudo systemctl start colord
```

Then re-run `safe-install.sh`.

## I'm not on CachyOS / Arch

The shell scripts use `pacman` for package management. If you're on a different distro:

- **Fedora**: `sudo dnf install colord edid-decode`
- **Debian/Ubuntu**: `sudo apt install colord edid-decode`
- **openSUSE**: `sudo zypper install colord edid-decode`

After installing the dependencies manually, run:
```bash
bash safe-install.sh
```
The hardware detection and profile installation will still work — only the auto-install of packages will be skipped (you'll see a warning, which is fine).

## I'm not on KDE Plasma

The instructions assume KDE System Settings for manual install. If you use a different desktop:

- **GNOME**: Settings → Color → Add profile
- **XFCE / other**: Install `xcalib` and run: `xcalib /path/to/profile.icc`
- **Sway / Hyprland (Wayland compositors)**: Use `colormgr` directly (same commands as the install script)

## I want to report a bug

The most helpful thing you can include in a bug report is your **EDID dump**:

```bash
bash tools/dump-edid.sh
```

Then paste the output (or just the saved file path) in the GitHub issue. This tells us exactly what display hardware you have.
