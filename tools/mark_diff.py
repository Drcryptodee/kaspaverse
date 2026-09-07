#!/usr/bin/env python3
"""Difference the drawn mark against the artwork it was transcribed from (D-294).

The mark in `kv_mark.dart` is a transcription of the founder's SVG, and a
transcription is a claim. This is what proves it: render the widget at the
artwork's own scale, then compare the two rasters pixel for pixel.

    KV_PREVIEW=1 flutter test test/preview/mark_artwork_probe_test.dart \
        --update-goldens
    tools/mark_diff.py <artwork.png>

The artwork lives in the internal record and is not in the public clone, so the
path is an argument rather than a constant. Ink area is the number that matters:
a geometry that has drifted by even half a pixel moves it by whole percent,
where two rasterisers disagreeing about antialiasing move it by hundredths.
"""

import sys
from PIL import Image, ImageChops

DISC = 939.52  # 1024 * 146.8 / 160 — the artwork's disc at its export size
GROUND = (10, 13, 13, 255)
OURS = "build/preview/probe__mark_artwork__probe.png"


def flatten(path):
    im = Image.open(path).convert("RGBA")
    base = Image.new("RGBA", im.size, GROUND)
    base.alpha_composite(im)
    return base.convert("RGB")


def ink(image):
    """Pixels inside the disc that are closer to the K's ink than to the disc."""
    px = image.load()
    w, h = image.size
    r = DISC / 2 - 4  # 4 px in from the rim, so its antialiasing is not counted
    return sum(
        1
        for y in range(h)
        for x in range(w)
        if (x - w / 2) ** 2 + (y - h / 2) ** 2 < r * r and px[x, y][1] < 110
    )


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    art, ours = flatten(argv[1]), flatten(OURS)
    if art.size != ours.size:
        print(f"FAIL  sizes differ: artwork {art.size}, ours {ours.size}")
        return 1
    a, o = ink(art), ink(ours)
    drift = 100 * (o - a) / a
    worst = max(ImageChops.difference(art, ours).getextrema(), key=lambda t: t[1])[1]
    print(f"artwork K ink {a} px · ours {o} px · drift {drift:+.3f} %")
    print(f"worst channel delta anywhere: {worst}")
    # A tenth of a percent is far below one pixel of edge on a ~4,000 px
    # perimeter; anything above it is geometry, not antialiasing.
    ok = abs(drift) < 0.1
    print("PASS" if ok else "FAIL  the transcription has drifted")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
