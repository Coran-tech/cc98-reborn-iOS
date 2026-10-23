"""Render the 1024×1024 TapSound app icon with Pillow."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "TapSound" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"

S = 2048  # Render at 2× and downsample for clean edges.
RGB = np.zeros((S, S, 3), dtype=np.float64)
yy, xx = np.mgrid[0:S, 0:S]
x = xx / (S - 1)
y = yy / (S - 1)

# Deep navy → violet base gradient, slightly diagonal.
top = np.array([5, 6, 14], dtype=np.float64)
bottom = np.array([20, 7, 36], dtype=np.float64)
blend = np.clip(0.55 * y + 0.18 * x, 0, 1)[..., None]
RGB[:] = top * (1 - blend) + bottom * blend


def add_glow(cx: float, cy: float, radius: float, color: tuple[int, int, int], strength: float) -> None:
    distance = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    falloff = np.exp(-(distance**2) / (2 * radius**2)) * strength
    target = np.array(color, dtype=np.float64)
    RGB[:] = RGB * (1 - falloff[..., None]) + target * falloff[..., None]


add_glow(0.18, 0.12, 0.38, (124, 58, 237), 0.58)
add_glow(0.88, 0.78, 0.42, (14, 165, 233), 0.34)
add_glow(0.55, 1.02, 0.34, (236, 72, 153), 0.22)

# Gentle vignette keeps the icon readable on light and dark home screens.
vignette = np.clip(1.15 - 0.62 * np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2), 0.55, 1.02)
RGB *= vignette[..., None]

background = Image.fromarray(np.clip(RGB, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

# --- Waveform bars -------------------------------------------------------
bar_heights = [0.28, 0.46, 0.63, 0.43, 0.25]
bar_width = 0.078 * S
gap = 0.040 * S
total_width = len(bar_heights) * bar_width + (len(bar_heights) - 1) * gap
start_x = (S - total_width) / 2
center_y = S * 0.50

mask = Image.new("L", (S, S), 0)
draw = ImageDraw.Draw(mask)
rects = []
for index, height_ratio in enumerate(bar_heights):
    bar_height = height_ratio * S
    left = start_x + index * (bar_width + gap)
    top_y = center_y - bar_height / 2
    bottom_y = center_y + bar_height / 2
    radius = bar_width / 2
    draw.rounded_rectangle(
        (left, top_y, left + bar_width, bottom_y),
        radius=radius,
        fill=255,
    )
    rects.append((left, top_y, left + bar_width, bottom_y))

# Horizontal gradient for the bars: cyan → periwinkle → pink.
stops = [
    (0.00, np.array([34, 211, 238])),
    (0.45, np.array([99, 102, 241])),
    (0.72, np.array([168, 85, 247])),
    (1.00, np.array([236, 72, 153])),
]
gradient = np.zeros((S, S, 3), dtype=np.float64)
for index in range(len(stops) - 1):
    start, start_color = stops[index]
    end, end_color = stops[index + 1]
    local = np.clip((x - start) / (end - start), 0, 1)[..., None]
    section = start_color * (1 - local) + end_color * local
    gradient = np.where((x >= start)[..., None] & (x <= end)[..., None], section, gradient)
bars = Image.fromarray(np.clip(gradient, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
bars.putalpha(mask)

# Colored halo behind the waveform.
halo = bars.filter(ImageFilter.GaussianBlur(radius=S * 0.055))
halo.putalpha(halo.getchannel("A").point(lambda value: int(value * 0.70)))
background = Image.alpha_composite(background, halo)
background = Image.alpha_composite(background, bars)

# A soft highlight along the top of every bar for a glassy finish.
highlight = Image.new("RGBA", (S, S), (0, 0, 0, 0))
highlight_draw = ImageDraw.Draw(highlight)
for left, top_y, right, bottom_y in rects:
    inset = bar_width * 0.22
    highlight_draw.rounded_rectangle(
        (left + inset, top_y + bar_width * 0.20, right - inset, top_y + bar_width * 0.36),
        radius=bar_width * 0.10,
        fill=(255, 255, 255, 90),
    )
highlight = highlight.filter(ImageFilter.GaussianBlur(radius=3))
background = Image.alpha_composite(background, highlight)

# A tiny four-point sparkle adds a playful "sound" accent.
sparkle_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sparkle = ImageDraw.Draw(sparkle_layer)
cx, cy = int(S * 0.765), int(S * 0.285)
long_radius, short_radius = int(S * 0.042), int(S * 0.010)
sparkle.polygon(
    [
        (cx, cy - long_radius),
        (cx + short_radius, cy - short_radius),
        (cx + long_radius, cy),
        (cx + short_radius, cy + short_radius),
        (cx, cy + long_radius),
        (cx - short_radius, cy + short_radius),
        (cx - long_radius, cy),
        (cx - short_radius, cy - short_radius),
    ],
    fill=(255, 255, 255, 225),
)
sparkle_layer = sparkle_layer.filter(ImageFilter.GaussianBlur(radius=1.5))
background = Image.alpha_composite(background, sparkle_layer)

# No rounded corners or alpha: iOS applies the icon mask itself.
final = background.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
OUT.parent.mkdir(parents=True, exist_ok=True)
final.save(OUT, "PNG", optimize=True)
print(f"Wrote {OUT} ({OUT.stat().st_size / 1024:.1f} KiB)")
