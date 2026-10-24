# Indexed BMP profile

The native decoder now admits uncompressed 8-bit `BITMAPINFOHEADER` images
through BMP, XX-embedded BMP and EMA wrappers. `biClrUsed` defines RGBQUAD
palette length; zero selects 256 entries. Palette reserved bytes do not become
alpha. All output is opaque RGBA, with normal top/bottom row handling and
four-byte scanline padding. Palette spans and every pixel index are validated
before destination writes, including an invalid index late in the image.

This resolves an actual first-map texture using a 46-entry palette. The C
decoder matches 120 self-authored Windows GDI DIB conversions across palette
sizes, row directions and padding. A private scan of 84 recognized/standalone
XX inputs decodes 2,951 textures without image-profile failures; 21 indexed
images also match host GDI pixel output exactly. The unrecognized PP archive
remains outside that scan. Original pixels are kept in memory only, with
counts and hashes retained locally. No original texture is uploaded.

This is bounded image-format validation and CPU conversion. Texture filtering,
color/effect state, original GPU appearance and complete-game compatibility
require separate evidence.
