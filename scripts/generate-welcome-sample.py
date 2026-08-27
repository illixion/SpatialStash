"""Generates the welcome screen's sample image: an original layered dusk
landscape.

Layered on purpose. Each ridge is a distinct depth plane with atmospheric
perspective, and the foreground pines sit hard in front, so a monocular depth
model separates them cleanly and the 2D->3D toggle reads as real parallax
rather than a soft warp. Original artwork, so nothing about shipping it in the
app bundle is encumbered.

Run from the repository root:  python3 scripts/generate-welcome-sample.py
Requires Pillow. Output: SpatialStash/SpatialStash/Resources/WelcomeSample.jpg,
which `WelcomeSample.swift` picks up by name."""
import random
from PIL import Image, ImageChops, ImageDraw, ImageFilter

W, H = 2400, 1600
HORIZON = int(H * 0.52)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vertical_gradient(size, top, bottom, gamma=1.0):
    w, h = size
    strip = Image.new("RGB", (1, h))
    px = strip.load()
    for y in range(h):
        px[0, y] = lerp(top, bottom, (y / max(1, h - 1)) ** gamma)
    return strip.resize((w, h), Image.BILINEAR)


def ridge(seed, base_y, amplitude, roughness, n=1024):
    """Midpoint-displacement skyline, resampled to image width."""
    rng = random.Random(seed)
    pts = [0.0] * (n + 1)
    pts[0] = base_y + rng.uniform(-amplitude, amplitude)
    pts[n] = base_y + rng.uniform(-amplitude, amplitude)
    step, amp = n, amplitude
    while step > 1:
        half = step // 2
        for x in range(half, n, step):
            pts[x] = (pts[x - half] + pts[x + half]) / 2 + rng.uniform(-amp, amp)
        step = half
        amp *= roughness
    out = []
    for x in range(W):
        u = x * n / (W - 1)
        i = min(int(u), n - 1)
        f = u - i
        out.append(pts[i] * (1 - f) + pts[i + 1] * f)
    return out


# --- Sky -------------------------------------------------------------------
canvas = Image.new("RGB", (W, H), (10, 12, 26))
canvas.paste(vertical_gradient((W, HORIZON), (22, 32, 74), (250, 178, 122), gamma=1.75), (0, 0))

SUN_X, SUN_Y, SUN_R = int(W * 0.63), int(HORIZON * 0.84), int(W * 0.028)
glow = Image.new("RGB", (W, H), (0, 0, 0))
gd = ImageDraw.Draw(glow)
for i in range(80, 0, -1):
    r = SUN_R * (1 + i * 0.44)
    t = 1 - i / 80.0
    gd.ellipse([SUN_X - r, SUN_Y - r, SUN_X + r, SUN_Y + r],
               fill=lerp((26, 14, 20), (255, 224, 186), t ** 2.2))
glow = glow.filter(ImageFilter.GaussianBlur(30))
# Mask the glow to the sky so it doesn't wash out the water.
sky_mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(sky_mask).rectangle([0, 0, W, HORIZON + 30], fill=255)
canvas = Image.composite(ImageChops.screen(canvas, glow), canvas, sky_mask.filter(ImageFilter.GaussianBlur(18)))

draw = ImageDraw.Draw(canvas)
draw.ellipse([SUN_X - SUN_R, SUN_Y - SUN_R, SUN_X + SUN_R, SUN_Y + SUN_R], fill=(255, 250, 240))

# --- Ridges: far (hazy) to near (dark) ------------------------------------
for seed, base_y, amp, rough, colour in [
    (11, HORIZON - 215, 132, 0.56, (135, 128, 158)),
    (23, HORIZON - 132, 108, 0.55, (100,  92, 130)),
    (37, HORIZON -  62,  76, 0.54, ( 66,  59,  96)),
    (51, HORIZON -  16,  44, 0.52, ( 39,  34,  64)),
]:
    heights = ridge(seed, base_y, amp, rough)
    draw.polygon([(x, heights[x]) for x in range(W)] + [(W, HORIZON + 4), (0, HORIZON + 4)],
                 fill=colour)

# --- Water -----------------------------------------------------------------
canvas.paste(vertical_gradient((W, H - HORIZON), (52, 46, 82), (13, 15, 32), gamma=0.75), (0, HORIZON))
draw = ImageDraw.Draw(canvas)

rng = random.Random(99)
# Drawn on its own layer and blurred before compositing: crisp two-pixel
# streaks at even spacing read as a rendering artifact rather than as water.
refl = Image.new("RGB", (W, H), (0, 0, 0))
rd = ImageDraw.Draw(refl)
y = HORIZON + 2
while y < H:
    depth = (y - HORIZON) / (H - HORIZON)
    spread = int(W * (0.010 + depth * 0.115))
    for _ in range(rng.randint(1, 3)):
        cx = SUN_X + int(rng.uniform(-1, 1) * spread * 0.55)
        hw = max(3, int(spread * rng.uniform(0.12, 0.85)))
        fade = max(0.0, 1.0 - depth * 1.25) * rng.uniform(0.35, 1.0)
        rd.line([(cx - hw, y), (cx + hw, y)],
                fill=lerp((0, 0, 0), (255, 208, 158), fade * 0.9),
                width=rng.choice([2, 3, 4]))
    y += rng.randint(3, 9)
refl = refl.filter(ImageFilter.GaussianBlur(3.2))
canvas = ImageChops.screen(canvas, refl)
draw = ImageDraw.Draw(canvas)

for _ in range(260):
    ry = rng.randint(HORIZON + 4, H - 1)
    depth = (ry - HORIZON) / (H - HORIZON)
    rx = rng.randint(0, W)
    rw = int(W * rng.uniform(0.01, 0.05) * (0.4 + depth))
    draw.line([(rx, ry), (rx + rw, ry)], fill=lerp((13, 15, 32), (150, 160, 200), 0.10 + depth * 0.14), width=1)

canvas = canvas.filter(ImageFilter.SMOOTH)
draw = ImageDraw.Draw(canvas)

# --- Foreground: the strong near-depth cue --------------------------------
NEAR = (7, 8, 18)


def pine(x, base_y, height, width):
    tiers = 7
    for i in range(tiers):
        t = i / (tiers - 1)
        cy = base_y - height * (0.16 + 0.84 * t)
        hw = width * (1.0 - t) * 0.5 + width * 0.06
        draw.polygon([(x, cy - height * 0.15), (x - hw, cy + height * 0.10), (x + hw, cy + height * 0.10)],
                     fill=NEAR)
    draw.rectangle([x - width * 0.035, base_y - height * 0.2, x + width * 0.035, base_y], fill=NEAR)


bank = ridge(77, int(H * 0.965), 26, 0.5)
draw.polygon([(x, bank[x] - (1 - x / W) ** 2 * H * 0.10) for x in range(W)] + [(W, H), (0, H)], fill=NEAR)

pine(int(W * 0.085), int(H * 0.90), int(H * 0.62), int(W * 0.115))
pine(int(W * 0.185), int(H * 0.945), int(H * 0.44), int(W * 0.085))
pine(int(W * 0.945), int(H * 0.96), int(H * 0.34), int(W * 0.070))

# --- Finish: vignette + grain ---------------------------------------------
vig = Image.new("L", (W, H), 255)
vd = ImageDraw.Draw(vig)
steps = 48
for i in range(steps):
    t = i / steps
    ix, iy = int(-W * 0.22 + t * W * 0.30), int(-H * 0.22 + t * H * 0.30)
    vd.ellipse([ix, iy, W - ix, H - iy], outline=int(255 - 62 * (1 - t) ** 1.6), width=int(H * 0.03))
vig = vig.filter(ImageFilter.GaussianBlur(80))
canvas = Image.composite(canvas, Image.new("RGB", (W, H), (5, 6, 14)), vig)

grain = Image.effect_noise((W, H), 9).convert("L")
canvas = Image.blend(canvas, Image.merge("RGB", (grain, grain, grain)), 0.02)

out = "SpatialStash/SpatialStash/Resources/WelcomeSample.jpg"
canvas.save(out, "JPEG", quality=93, optimize=True, progressive=True)
print("wrote", out, canvas.size)
