# HerNess logo

`herness-logo.webp` is the approved orange octopus chef mascot, generated with
the built-in Imagegen tool and stored losslessly at 1254 × 1254 with transparency.
The original generation prompt is `output/imagegen/chef-mascot-v2-prompt.txt`.

Run `tools/sync_brand_assets.py` using Python with Pillow on macOS to regenerate
the app icons, tray icons, and in-app logos for macOS, Windows, Linux, iOS, and
Android. Existing resource names and packaging references are preserved.

Native resources are resized to their required resolutions with Lanczos and
encoded as PNG, lossless WebP, multi-resolution ICO, or ICNS. Resizing changes
pixel dimensions; lossless encoding preserves the pixels of each resized image.
iOS and Android launcher icons use an opaque dark background. In-app logos and
desktop icons preserve transparency. The macOS menu bar uses the mascot colors.

Format and resize API reference: https://pillow.readthedocs.io/en/stable/handbook/image-file-formats.html
and https://pillow.readthedocs.io/en/stable/reference/Image.html (Pillow 12.3.0).
