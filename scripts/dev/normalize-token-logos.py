#!/usr/bin/env python3
"""Makes a bundled coin logo what TokenLogo draws well in both appearances: a transparent square holding the coin's disc,
centred and filling it. ios/DyorKit's TokenLogoAssetTests checks every file in ios/DyorHQ/Resources/TokenLogos.

A logo rasterized from the token list's SVG can come out on an opaque square plate, drawn small in one corner; TokenLogo
clips the square to a circle, so the plate shows as a crescent beside the coin (white on a dark card). Per file:
  1. The plate is the colour of the top-left corner. A file whose four corners are already transparent is left alone,
     so running this again changes nothing.
  2. The plate is flood-filled from each corner that has its colour, with a tolerance of 8 (the summed channel
     difference; more eats the pale bevel at the top of USDe), and made transparent.
  3. The coin is cropped to its box and centred on a square.
  4. A circular mask inset 1 px drops the rim pixels that were blended with the plate.
  5. The square is resampled (Lanczos) to the file's own canvas size, and the same circle, anti-aliased, clears anything
     the resampling spread outside it.
The file keeps its exact name (a device looks logos up by exact case), and is written as RGBA.

Usage: python3 scripts/dev/normalize-token-logos.py [--dry-run] [logo-XYZ.png ...]
       With no file, every logo-*.png in ios/DyorHQ/Resources/TokenLogos. Needs Pillow."""
import glob, os, sys
from PIL import Image, ImageChops, ImageDraw

LOGOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ios', 'DyorHQ', 'Resources', 'TokenLogos')
TOLERANCE = 8
SUPERSAMPLE = 4

def circle(side, inset):
    """An anti-aliased disc mask of `side` px, its edge `inset` px in from the square's."""
    big = side * SUPERSAMPLE
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).ellipse([inset * SUPERSAMPLE, inset * SUPERSAMPLE, big - 1 - inset * SUPERSAMPLE, big - 1 - inset * SUPERSAMPLE], fill=255)
    return mask.resize((side, side), Image.LANCZOS)

def normalize(path):
    """The normalized image and a line describing it, or None and the reason it is left alone."""
    image = Image.open(path).convert('RGBA')
    width, height = image.size
    corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    if all(image.getpixel(c)[3] == 0 for c in corners):
        return None, 'already transparent, left alone'
    plate = image.getpixel((0, 0))
    marked = image.copy()
    marker = (255, 0, 255, 0)
    for corner in corners:
        pixel = marked.getpixel(corner)
        if pixel != marker and sum(abs(a - b) for a, b in zip(pixel, plate)) <= TOLERANCE:
            ImageDraw.floodfill(marked, corner, marker, thresh=TOLERANCE)
    kept = marked.getchannel('A').point(lambda a: 255 if a else 0)
    coin = image.copy()
    coin.putalpha(ImageChops.multiply(image.getchannel('A'), kept))
    box = coin.getchannel('A').getbbox()
    if box is None:
        raise SystemExit(f'{os.path.basename(path)}: nothing is left once the plate is removed')
    x0, y0, x1, y1 = box
    side = max(x1 - x0, y1 - y0)
    left, top = round((x0 + x1 - side) / 2), round((y0 + y1 - side) / 2)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.alpha_composite(coin.crop((left, top, left + side, top + side)))
    square.putalpha(ImageChops.multiply(square.getchannel('A'), circle(side, 1)))
    canvas = max(width, height)
    out = square.resize((canvas, canvas), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), circle(canvas, 0)))
    return out, f'plate {plate[:3]} removed; coin {side} px at ({x0},{y0}) centred on {canvas}x{canvas}'

def main(args):
    dry = '--dry-run' in args
    paths = [a for a in args if a != '--dry-run'] or sorted(glob.glob(os.path.join(LOGOS, 'logo-*.png')))
    for path in paths:
        image, note = normalize(path)
        if image is not None and not dry:
            image.save(path, optimize=True)
        print(f'{os.path.basename(path)}: {note}')

if __name__ == '__main__':
    main(sys.argv[1:])
