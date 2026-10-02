#!/usr/bin/env python3
"""Makes the store screenshots and Play's feature graphic (#112).

Run from anywhere; needs Pillow (`pip install pillow`). Reads the raw
captures in branding/store/screenshots/raw/ and writes:

  branding/store/screenshots/play/*.png       1200x2400, Google Play phone
      screenshots (Play rejects a long side over twice the short one, and
      the emulator's 1080x2400 is 2.22:1, so each sits on a 2:1 canvas)
  branding/store/screenshots/app-store/*.png  1320x2868, App Store 6.9"
  branding/store/feature-graphic.png          1024x500, Google Play

Each screenshot gets a caption above it, from CAPTIONS. See
branding/store/README.md for how the raw captures were taken.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT / 'branding' / 'store'
RAW = STORE / 'screenshots' / 'raw'

# The launcher icon's background (scripts/make_icons.py), and the title
# color from the group list header.
BACKGROUND = (0xD0, 0xF0, 0xEA)
TITLE = (0x56, 0xBC, 0x9C)
INK = (0x0F, 0x3D, 0x36)
MUTED = (0x3B, 0x6B, 0x63)

FONT_DIR = Path('/System/Library/Fonts/Supplemental')
BOLD = FONT_DIR / 'Arial Bold.ttf'
REGULAR = FONT_DIR / 'Arial.ttf'

# Keyed by the raw file's name without extension; per platform where the
# shot differs.
CAPTIONS = {
    '01-groups': 'All your groups,\non any Spliit server',
    '02-expenses': 'Works offline:\nadd expenses anywhere',
    '03-details': 'Every detail,\nreceipts included',
    '04-balances': 'See who owes whom,\nsettle in one tap',
    '05-stats': 'Where the money went',
    '07-split': 'Split evenly, by shares,\npercent or amount',
}
PLATFORM_CAPTIONS = {
    ('android', '06-add-expense'): 'Scan a receipt to\nfill in the expense',
    ('iphone', '06-add-expense'): 'Split evenly, by shares,\npercent or amount',
}

# (raw folder, output folder, canvas size)
TARGETS = [
    ('android', 'play', (1200, 2400)),
    ('iphone', 'app-store', (1320, 2868)),
]


def rounded(image, radius):
    """[image] with transparent rounded corners."""
    mask = Image.new('L', image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), image.size], radius, fill=255)
    out = image.convert('RGBA')
    out.putalpha(mask)
    return out


def framed(shot, caption, size):
    width, height = size
    canvas = Image.new('RGB', size, BACKGROUND)
    draw = ImageDraw.Draw(canvas)

    font = ImageFont.truetype(str(BOLD), round(width * 0.062))
    top = round(height * 0.045)
    draw.multiline_text((width / 2, top), caption, font=font, fill=INK,
                        anchor='ma', align='center', spacing=round(width * 0.02))
    text_bottom = draw.multiline_textbbox((width / 2, top), caption, font=font,
                                          anchor='ma', spacing=round(width * 0.02))[3]

    # The phone below, as large as fits: the screen in a dark bezel. The
    # screen's own corners stay nearly square, or they clip the clock.
    gap = round(height * 0.035)
    bezel = round(width * 0.018)
    available = height - text_bottom - gap - 2 * bezel - round(height * 0.03)
    scale = min(available / shot.height, width * 0.84 / shot.width)
    screen = shot.convert('RGB').resize(
        (round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    radius = round(screen.width * 0.02)
    x = (width - screen.width) // 2
    y = text_bottom + gap + bezel
    draw.rounded_rectangle([x - bezel, y - bezel, x + screen.width + bezel,
                            y + screen.height + bezel],
                           radius + bezel * 3, fill=INK)
    screen = rounded(screen, radius)
    canvas.paste(screen, (x, y), screen)
    return canvas


def screenshots():
    for raw_dir, out_dir, size in TARGETS:
        out = STORE / 'screenshots' / out_dir
        out.mkdir(parents=True, exist_ok=True)
        for path in sorted((RAW / raw_dir).glob('*.png')):
            caption = PLATFORM_CAPTIONS.get((raw_dir, path.stem), CAPTIONS.get(path.stem))
            if caption is None:
                raise SystemExit(f'No caption for {raw_dir}/{path.name}')
            framed(Image.open(path), caption, size).save(out / path.name, optimize=True)
            print(out / path.name)


def feature_graphic():
    width, height = 1024, 500
    canvas = Image.new('RGB', (width, height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)

    icon = Image.open(STORE / 'play-icon-512.png').convert('RGBA').resize((300, 300), Image.LANCZOS)
    canvas.paste(icon, (70, 100), rounded(icon, 66))

    left = 420
    draw.text((left, 128), 'Spliit2Go', font=ImageFont.truetype(str(BOLD), 92), fill=TITLE)
    draw.multiline_text((left, 252), 'Share expenses with friends,\neven offline.',
                        font=ImageFont.truetype(str(BOLD), 40), fill=INK, spacing=12)
    draw.text((left, 378), 'An unofficial client for Spliit',
              font=ImageFont.truetype(str(REGULAR), 28), fill=MUTED)
    path = STORE / 'feature-graphic.png'
    canvas.save(path, optimize=True)
    print(path)


if __name__ == '__main__':
    screenshots()
    feature_graphic()
