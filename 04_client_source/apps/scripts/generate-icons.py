#!/usr/bin/env python3
"""
Generate platform icons for sepsiscare from the brand color palette.
Creates:
  - macOS:  SepsisCare-macOS/scripts/AppIcon.icns
  - Windows: SepsisCare-Windows/build/icon.ico
  - Android: SepsisCare-Android/app/src/main/res/mipmap-*/ic_launcher.png
"""
import os
import shutil
import subprocess
import sys
import struct
from PIL import Image, ImageDraw, ImageFilter

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Brand colors (from AppBrand.swift)
MIDNIGHT = (5, 13, 26)        # 0.02, 0.05, 0.10
DEEP_NAVY = (10, 20, 36)      # 0.04, 0.08, 0.14
CLINICAL_TEAL = (0, 173, 158) # 0.00, 0.68, 0.62
SIGNAL_BLUE = (25, 102, 250)  # 0.10, 0.40, 0.98
OXYGEN_CYAN = (0, 189, 230)   # 0.00, 0.74, 0.90
WHITE = (255, 255, 255)


def draw_logo(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rect background with gradient-ish feel (solid composite for simplicity)
    radius = int(size * 0.21)
    inset = int(size * 0.035)
    rect = [inset, inset, size - inset, size - inset]
    # Use a solid deep navy-teal blend
    bg_color = (8, 30, 60)
    draw.rounded_rectangle(rect, radius=radius, fill=bg_color)

    # Subtle border
    draw.rounded_rectangle(rect, radius=radius, outline=(255, 255, 255, 45), width=max(1, size // 100))

    # Grid lines
    grid_color = (255, 255, 255, 20)
    step_start = int(size * 0.18)
    step_end = int(size * 0.82)
    step_stride = int(size * 0.16)
    for s in range(step_start, step_end + 1, step_stride):
        draw.line([(s, int(size * 0.16)), (s, int(size * 0.84))], fill=grid_color, width=max(1, size // 250))
        draw.line([(int(size * 0.16), s), (int(size * 0.84), s)], fill=grid_color, width=max(1, size // 250))

    # Cross (white), placed in the upper-left quadrant to leave room for the ECG signal.
    arm = size * 0.085
    long = size * 0.205
    cx = size * 0.275
    cy = size * 0.265
    draw.rounded_rectangle(
        [cx - arm / 2, cy - long / 2, cx + arm / 2, cy + long / 2],
        radius=max(1, int(size * 0.01)),
        fill=(255, 255, 255, 235)
    )
    draw.rounded_rectangle(
        [cx - long / 2, cy - arm / 2, cx + long / 2, cy + arm / 2],
        radius=max(1, int(size * 0.01)),
        fill=(255, 255, 255, 235)
    )

    # ECG wave: more segments, first oscillation small and second oscillation large.
    wave_color = OXYGEN_CYAN + (255,)
    pts = [
        (size * 0.16, size * 0.60),
        (size * 0.24, size * 0.60),
        (size * 0.28, size * 0.55),
        (size * 0.32, size * 0.64),
        (size * 0.36, size * 0.60),
        (size * 0.45, size * 0.60),
        (size * 0.51, size * 0.38),
        (size * 0.58, size * 0.78),
        (size * 0.66, size * 0.30),
        (size * 0.74, size * 0.60),
        (size * 0.84, size * 0.60),
    ]
    lw = max(2, int(size * 0.035))
    for i in range(len(pts) - 1):
        draw.line([pts[i], pts[i + 1]], fill=wave_color, width=lw)
    # Round caps
    for p in [pts[0], pts[-1]]:
        r = lw / 2
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=wave_color)

    return img


def make_macos_icns():
    out_dir = os.path.join(BASE_DIR, "SepsisCare-macOS", "scripts")
    os.makedirs(out_dir, exist_ok=True)
    iconset_dir = os.path.join(out_dir, "AppIcon.iconset")
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir, exist_ok=True)

    macos_icon_specs = [
        (16, 1),
        (16, 2),
        (32, 1),
        (32, 2),
        (128, 1),
        (128, 2),
        (256, 1),
        (256, 2),
        (512, 1),
        (512, 2),
    ]
    for base_size, scale in macos_icon_specs:
        pixel_size = base_size * scale
        suffix = "@2x" if scale == 2 else ""
        img = draw_logo(pixel_size)
        img.save(os.path.join(iconset_dir, f"icon_{base_size}x{base_size}{suffix}.png"))

    icns_path = os.path.join(out_dir, "AppIcon.icns")
    try:
        subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        largest = Image.open(os.path.join(iconset_dir, "icon_512x512@2x.png"))
        largest.save(
            icns_path,
            format="ICNS",
            sizes=[(16, 16), (32, 32), (128, 128), (256, 256), (512, 512), (1024, 1024)],
        )
    print(f"[macOS] Created {icns_path}")


def make_windows_ico():
    out_path = os.path.join(BASE_DIR, "SepsisCare-Windows", "build", "icon.ico")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]

    # Pillow save multi-size ICO
    draw_logo(256).convert("RGBA").save(out_path, format="ICO", sizes=[(s, s) for s in sizes])
    print(f"[Windows] Created {out_path}")


def make_android_icons():
    res_dir = os.path.join(BASE_DIR, "SepsisCare-Android", "app", "src", "main", "res")
    dpi_map = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for dpi, sz in dpi_map.items():
        d = os.path.join(res_dir, f"mipmap-{dpi}")
        os.makedirs(d, exist_ok=True)
        img = draw_logo(sz)
        img.save(os.path.join(d, "ic_launcher.png"))
        # Also create ic_launcher_foreground and ic_launcher_round (same for now)
        img.save(os.path.join(d, "ic_launcher_foreground.png"))
        img.save(os.path.join(d, "ic_launcher_round.png"))
    print(f"[Android] Created launcher icons in {res_dir}")


if __name__ == "__main__":
    print("Generating sepsiscare icons...")
    make_macos_icns()
    make_windows_ico()
    make_android_icons()
    print("Done.")
