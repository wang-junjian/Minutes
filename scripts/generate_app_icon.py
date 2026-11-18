#!/usr/bin/env python3
"""生成「纪要」的 macOS AppIcon 资源（仅设计阶段需要 Pillow）。"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Minutes" / "Assets.xcassets" / "AppIcon.appiconset"
SIZE = 1024
SCALE = 3


def rounded_rectangle(draw, box, radius, fill):
    draw.rounded_rectangle(tuple(int(v * SCALE) for v in box), radius=int(radius * SCALE), fill=fill)


def make_icon():
    side = SIZE * SCALE
    image = Image.new("RGBA", (side, side), (0, 0, 0, 0))

    # 深靛蓝渐变底板：稳重、适合效率工具，也能衬托白色卡片。
    background = Image.new("RGBA", (side, side))
    pixels = background.load()
    assert pixels is not None
    for y in range(side):
        for x in range(side):
            t = min(1.0, max(0.0, (x / side * 0.35 + y / side * 0.65)))
            r = int(22 + (57 - 22) * t)
            g = int(29 + (72 - 29) * t)
            b = int(70 + (172 - 70) * t)
            pixels[x, y] = (r, g, b, 255)
    mask = Image.new("L", (side, side), 0)
    rounded_rectangle(ImageDraw.Draw(mask), (32, 32, 992, 992), 220, 255)
    image.paste(background, (0, 0), mask)

    # 柔和的顶部高光，避免纯色底板显得扁平。
    glow = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        (-180 * SCALE, -280 * SCALE, 760 * SCALE, 520 * SCALE),
        fill=(118, 146, 255, 62),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(110 * SCALE))
    image.alpha_composite(glow)

    # 纸张投影与主体。
    shadow = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    rounded_rectangle(ImageDraw.Draw(shadow), (238, 188, 786, 856), 76, (4, 9, 35, 125))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24 * SCALE))
    image.alpha_composite(shadow)

    card = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(card)
    rounded_rectangle(draw, (238, 164, 786, 832), 76, (249, 251, 255, 255))

    # 顶部标题线 + 录制圆点。
    rounded_rectangle(draw, (320, 278, 580, 306), 14, (91, 105, 176, 255))
    draw.ellipse(
        (656 * SCALE, 266 * SCALE, 708 * SCALE, 318 * SCALE),
        fill=(255, 111, 112, 255),
    )

    # 中央声波是语音输入的核心识别符号。
    heights = [86, 144, 214, 284, 188, 240, 142, 88]
    bar_width = 32
    gap = 22
    total_width = len(heights) * bar_width + (len(heights) - 1) * gap
    start_x = (SIZE - total_width) / 2
    center_y = 500
    colors = [
        (50, 190, 206, 255),
        (49, 174, 211, 255),
        (57, 151, 216, 255),
        (75, 119, 218, 255),
        (91, 104, 207, 255),
        (104, 91, 193, 255),
        (110, 89, 180, 255),
        (113, 91, 170, 255),
    ]
    for index, (height, color) in enumerate(zip(heights, colors)):
        x = start_x + index * (bar_width + gap)
        rounded_rectangle(
            draw,
            (x, center_y - height / 2, x + bar_width, center_y + height / 2),
            bar_width / 2,
            color,
        )

    # 底部纪要正文，保持足够留白。
    rounded_rectangle(draw, (320, 696, 704, 716), 10, (184, 192, 217, 255))
    rounded_rectangle(draw, (320, 746, 624, 766), 10, (198, 205, 226, 255))
    image.alpha_composite(card)
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    icon = make_icon()
    for logical_size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = logical_size * scale
            resized = icon.resize((pixels, pixels), Image.Resampling.LANCZOS)
            resized.save(OUTPUT / f"appicon-{logical_size}@{scale}x.png", optimize=True)
    print(f"Generated AppIcon resources in {OUTPUT}")


if __name__ == "__main__":
    main()
