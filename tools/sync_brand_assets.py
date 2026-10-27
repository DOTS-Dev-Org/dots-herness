#!/usr/bin/env python3
"""Generate platform logo resources from the approved lossless brand master.

Requires Pillow. Run from any directory; preserves native resource names.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "shared/branding/herness-logo.webp"


def main():
    master = Image.open(MASTER).convert("RGBA")

    def raster(size, opaque=False):
        # Native icon resolutions are derived from the full-resolution master.
        mark = master.resize((size, size), Image.Resampling.LANCZOS)
        if opaque:
            backdrop = Image.new("RGBA", mark.size, (25, 25, 25, 255))
            mark = Image.alpha_composite(backdrop, mark).convert("RGB")
        return mark

    def png(path, size, opaque=False):
        path = ROOT / path
        raster(size, opaque).save(path, optimize=True, compress_level=9)
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size} bytes")

    png("macos/DotsHarness/Sources/DotsHarnessUI/Resources/WelcomeLogo.png", 512)
    for scale, suffix in [(1, ""), (2, "@2x"), (3, "@3x")]:
        png(f"macos/DotsHarness/Sources/DotsHarness/Resources/TrayIcon{suffix}.png", 18 * scale)
    png("linux/DotsHarness/src/DotsHarness/Resources/DotsHarness.png", 512)
    png("linux/DotsHarness/src/DotsHarness/Resources/TrayIcon.png", 32)
    for platform in ["windows", "linux"]:
        path = ROOT / f"{platform}/DotsHarness/src/DotsHarness/Resources/DotsHarness.ico"
        raster(256).save(path, sizes=[(s, s) for s in [16, 24, 32, 48, 64, 128, 256]])
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size} bytes")

    png("mobile/ios/Resources/Assets.xcassets/HerNessLogo.imageset/HerNessLogo.png", 512)
    png("mobile/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", 1024, True)
    for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        png(f"mobile/android/app/src/main/res/mipmap-{density}/ic_launcher.png", size, True)
    path = ROOT / "mobile/android/app/src/main/res/drawable-nodpi/herness_logo.webp"
    raster(512).save(path, lossless=True, exact=True, quality=100, method=6)
    assert Image.open(path).convert("RGBA").tobytes() == raster(512).tobytes()
    print(f"{path.relative_to(ROOT)}: {path.stat().st_size} bytes")

    if not shutil.which("iconutil"):
        raise RuntimeError("Run on macOS with iconutil to regenerate the macOS app icon")
    with tempfile.TemporaryDirectory(prefix="herness-brand-") as directory:
        iconset = Path(directory) / "AppIcon.iconset"
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                suffix = "@2x" if scale == 2 else ""
                raster(size * scale).save(iconset / f"icon_{size}x{size}{suffix}.png", optimize=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "macos/DotsHarness/Resources/AppIcon.icns")], check=True)


if __name__ == "__main__":
    main()
