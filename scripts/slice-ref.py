#!/usr/bin/env python3
"""
Slice the user-provided Shanks reference sheet into 9 frames for Shanks.app.

Input:  /Users/abhinav/Downloads/shanks.png (2172x724, RGB, 9 chibi Shanks frames on black BG)
Output:
  Clawd/ShanksSheet.png    2880x320 sheet
  Clawd/ShanksAsleep1.png  320x320
  Clawd/ShanksAsleep2.png  320x320
  Clawd/ShanksIcon.png     320x320 (head crop)

Approach:
  1. Flood-fill near-black from each corner -> mark background, preserve the cape
     (which is also black, but isn't connected to the edge).
  2. Mark flood'd pixels as transparent in the RGBA copy.
  3. Compute global content bbox -> trim outer padding.
  4. Slice content into 9 equal vertical strips, tight-crop each.
  5. Place each on a 320x320 canvas, anchored to bottom-center, scaled to fill height.
"""
from PIL import Image, ImageDraw, ImageChops
from pathlib import Path

import os
_ENV_SRC = os.environ.get('SHANKS_REF')
_DEFAULTS = [
    Path(__file__).resolve().parent / 'shanks-source.png',
    Path.home() / 'Downloads' / 'shanks.png',
]
SRC = Path(_ENV_SRC) if _ENV_SRC else next((p for p in _DEFAULTS if p.exists()), _DEFAULTS[0])
OUT_DIR = Path('/Users/abhinav/shanks/Clawd')
FRAME = 320
N = 9
SENTINEL = (255, 0, 255)  # magenta — assumed not present in the art


def key_background(path):
    """Return an RGBA image with bg flood-keyed to transparent.

    The reference has a WHITE outer canvas and characters on a BLACK middle strip.
    The cape (also black) lives inside character bodies and must be preserved, so we
    flood from edges only — never from interior points.
    """
    rgb = Image.open(path).convert('RGB').copy()
    w, h = rgb.size

    def flood_if(point, thresh=30):
        px = rgb.getpixel(point)
        if px == SENTINEL:
            return
        ImageDraw.floodfill(rgb, point, SENTINEL, thresh=thresh)

    # Pass 1: flood white from each corner (outer canvas).
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        flood_if(corner)

    # Pass 2: scan left & right edges for the first remaining dark pixel and flood it
    # (catches the black strip the characters sit on, which isn't connected to white).
    for x_edge in (0, w - 1):
        for y in range(h):
            p = rgb.getpixel((x_edge, y))
            if p != SENTINEL and (p[0] + p[1] + p[2]) < 60:
                ImageDraw.floodfill(rgb, (x_edge, y), SENTINEL, thresh=30)
                break

    # Pass 3: also scan top & bottom edges for any leftover dark seam.
    for y_edge in (0, h - 1):
        for x in range(w):
            p = rgb.getpixel((x, y_edge))
            if p != SENTINEL and (p[0] + p[1] + p[2]) < 60:
                ImageDraw.floodfill(rgb, (x, y_edge), SENTINEL, thresh=30)
                break

    # Build sentinel mask via per-channel thresholding (avoids numpy).
    r, g, b = rgb.split()
    mr = r.point(lambda v: 255 if v == SENTINEL[0] else 0)
    mg = g.point(lambda v: 255 if v == SENTINEL[1] else 0)
    mb = b.point(lambda v: 255 if v == SENTINEL[2] else 0)
    sentinel_mask = ImageChops.multiply(mr, ImageChops.multiply(mg, mb))
    # alpha = 0 where sentinel, 255 elsewhere
    alpha = sentinel_mask.point(lambda v: 0 if v == 255 else 255)

    rgba = Image.open(path).convert('RGBA').copy()
    rgba.putalpha(alpha)
    return rgba


def remove_orphan_components(img, min_size=300):
    """Drop small connected components of non-transparent pixels.

    Each character is one big blob (~30k pixels). Stray particles are <100 pixels.
    Keep components >= min_size, zero out the rest.
    """
    w, h = img.size
    px = img.load()
    visited = [[False] * w for _ in range(h)]
    out = img.copy()
    out_px = out.load()

    for sy in range(h):
        for sx in range(w):
            if visited[sy][sx] or px[sx, sy][3] == 0:
                if px[sx, sy][3] == 0:
                    visited[sy][sx] = True
                continue
            # BFS this component
            comp = []
            stack = [(sx, sy)]
            while stack:
                x, y = stack.pop()
                if visited[y][x]:
                    continue
                if px[x, y][3] == 0:
                    visited[y][x] = True
                    continue
                visited[y][x] = True
                comp.append((x, y))
                for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx] and px[nx, ny][3] > 0:
                        stack.append((nx, ny))
            if len(comp) < min_size:
                for (x, y) in comp:
                    out_px[x, y] = (0, 0, 0, 0)

    return out


def remove_side_blobs(frame_img, head_fraction=0.45, off_center=38):
    """Remove warm-light pixels in the head zone that are far from the head's centroid.

    The head's centroid (computed from ALL opaque pixels in the head zone) reliably
    sits near the face. The 'ear' blobs are warm/light/skin-tone clusters detached
    spatially from the face on the sides. Anything skin-or-light outside the
    ±`off_center` band gets cleared. Red hair is preserved because the color
    filter explicitly excludes saturated reds.
    """
    w, h = frame_img.size
    px = frame_img.load()
    head_h = int(h * head_fraction)

    def is_warm_light(p):
        """Skin / cream / pinkish-light — NOT saturated red hair, NOT dark."""
        if p[3] == 0:
            return False
        r, g, b = p[0], p[1], p[2]
        # Exclude saturated red hair (R far above G and B)
        if r - g > 75 and r - b > 75:
            return False
        # Exclude dark / cape / outline
        if r + g + b < 280:
            return False
        # Warm light tones: R bright-ish, R >= G >= B (with small tolerance)
        return r >= 170 and g >= 130 and b >= 100 and r >= g - 5 and g >= b - 15

    # Centroid of all opaque pixels in the head zone — robust to stray blobs
    opaque_xs = [x for y in range(head_h) for x in range(w) if px[x, y][3] > 0]
    if len(opaque_xs) < 50:
        return frame_img

    # Use median for robustness to outliers
    opaque_xs.sort()
    center_x = opaque_xs[len(opaque_xs) // 2]

    out = frame_img.copy()
    out_px = out.load()
    removed = 0
    for y in range(head_h):
        for x in range(w):
            if abs(x - center_x) <= off_center:
                continue
            if is_warm_light(px[x, y]):
                out_px[x, y] = (0, 0, 0, 0)
                removed += 1
    if removed:
        print(f"    cleared {removed}px outside ±{off_center}px of head center x={center_x}")
    return out


def fit_to_frame(char_img, frame=FRAME, headroom_top=8, floor_pad=6):
    """Place character on a FRAMExFRAME transparent canvas, anchored to bottom-center."""
    cw, ch = char_img.size
    avail_h = frame - headroom_top - floor_pad
    scale = avail_h / ch
    nw = max(1, int(round(cw * scale)))
    nh = max(1, int(round(ch * scale)))
    method = Image.LANCZOS if scale < 1 else Image.NEAREST
    scaled = char_img.resize((nw, nh), method)
    canvas = Image.new('RGBA', (frame, frame), (0, 0, 0, 0))
    cx = (frame - nw) // 2
    cy = frame - nh - floor_pad
    canvas.paste(scaled, (cx, cy), scaled)
    return canvas


def trim_full_width_rows(rgba, fullness=0.85):
    """Zero out any row where opaque-pixel count >= fullness * width.

    Catches decorative full-width horizontal lines that flood-fill missed.
    """
    w, h = rgba.size
    px = rgba.load()
    out = rgba.copy()
    out_px = out.load()
    removed = 0
    for y in range(h):
        count = sum(1 for x in range(w) if px[x, y][3] > 0)
        if count >= w * fullness:
            for x in range(w):
                out_px[x, y] = (0, 0, 0, 0)
            removed += 1
    if removed:
        print(f"  trimmed {removed} full-width decorative rows")
    return out


def main():
    keyed = key_background(SRC)
    print(f"image size: {keyed.size}")
    print("removing orphan pixels (JPG dust)...")
    keyed = remove_orphan_components(keyed, min_size=400)
    full_bbox = keyed.getbbox()
    print(f"content bbox after orphan cleanup: {full_bbox}")
    if not full_bbox:
        raise SystemExit("no non-transparent content found")

    content = keyed.crop(full_bbox)
    print(f"content area: {content.size}")

    # Slice into 9 equal vertical strips
    strips = []
    for i in range(N):
        x0 = int(round(i * content.width / N))
        x1 = int(round((i + 1) * content.width / N))
        strip = content.crop((x0, 0, x1, content.height))
        bb = strip.getbbox()
        if not bb:
            print(f"  warning: frame {i} appears empty")
            strips.append(strip)
            continue
        strips.append(strip.crop(bb))
        print(f"  frame {i}: strip {x1-x0}x{content.height} -> tight {bb[2]-bb[0]}x{bb[3]-bb[1]}")

    # Source is clean — skip remove_side_blobs (it was a workaround for the prior
    # artifact-laden reference). Re-enable per-frame if needed.
    fitted = [fit_to_frame(s) for s in strips]

    sheet = Image.new('RGBA', (FRAME * N, FRAME), (0, 0, 0, 0))
    for i, f in enumerate(fitted):
        sheet.paste(f, (i * FRAME, 0), f)
    sheet.save(OUT_DIR / 'ShanksSheet.png')
    print(f"saved {OUT_DIR / 'ShanksSheet.png'}  ({sheet.size[0]}x{sheet.size[1]})")

    # Asleep frames: reuse the idle (frame 0) at slightly different positions
    sleep1 = fitted[0].copy()
    # sleep2: shift down 4px to suggest a breathing slump
    sleep2 = Image.new('RGBA', (FRAME, FRAME), (0, 0, 0, 0))
    sleep2.paste(fitted[0], (0, 4), fitted[0])
    sleep1.save(OUT_DIR / 'ShanksAsleep1.png')
    sleep2.save(OUT_DIR / 'ShanksAsleep2.png')
    print(f"saved asleep frames")

    # Icon: head crop from frame 0
    f0 = strips[0]
    head = f0.crop((0, 0, f0.width, int(f0.height * 0.55)))
    icon_canvas = Image.new('RGBA', (FRAME, FRAME), (0, 0, 0, 0))
    scale = min(FRAME / head.width, FRAME / head.height) * 0.92
    nw = max(1, int(round(head.width * scale)))
    nh = max(1, int(round(head.height * scale)))
    method = Image.LANCZOS if scale < 1 else Image.NEAREST
    head_scaled = head.resize((nw, nh), method)
    icon_canvas.paste(head_scaled, ((FRAME - nw) // 2, (FRAME - nh) // 2), head_scaled)
    icon_canvas.save(OUT_DIR / 'ShanksIcon.png')
    print(f"saved {OUT_DIR / 'ShanksIcon.png'}")


if __name__ == "__main__":
    main()
