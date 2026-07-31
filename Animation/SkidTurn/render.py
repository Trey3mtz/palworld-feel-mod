#!/usr/bin/env python3
"""
Dependency-free PNG contact-sheet renderer for authored poses.

Exists so a pose can be judged before it ever reaches Unreal: it draws the
forward-kinematics result as an orthographic stick figure, one cell per frame,
with the ground plane and the two feet colour-coded (left = warm, right = cool)
so a plant/slide reads at a glance.
"""

import math
import struct
import zlib

# ---------------------------------------------------------------------------
# canvas
# ---------------------------------------------------------------------------


class Canvas(object):
    def __init__(self, w, h, bg=(18, 20, 26)):
        self.w, self.h = w, h
        self.buf = bytearray(bg * (w * h))

    def px(self, x, y, c, a=1.0):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            if a >= 1.0:
                self.buf[i:i + 3] = bytes(c)
            else:
                for k in range(3):
                    self.buf[i + k] = int(self.buf[i + k] * (1 - a) + c[k] * a)

    def line(self, p0, p1, c, width=2):
        x0, y0 = p0
        x1, y1 = p1
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        r = (width - 1) * 0.5
        for s in range(n + 1):
            t = s / float(n)
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            ir = int(math.ceil(r))
            for dy in range(-ir, ir + 1):
                for dx in range(-ir, ir + 1):
                    d = math.hypot(dx, dy)
                    if d <= r + 0.5:
                        self.px(int(x) + dx, int(y) + dy, c, min(1.0, r + 0.5 - d + 0.3))

    def disc(self, p, r, c):
        cx, cy = p
        ir = int(math.ceil(r))
        for dy in range(-ir, ir + 1):
            for dx in range(-ir, ir + 1):
                d = math.hypot(dx, dy)
                if d <= r + 0.5:
                    self.px(int(cx) + dx, int(cy) + dy, c, min(1.0, r + 0.5 - d))

    def rect(self, x0, y0, x1, y1, c):
        for y in range(int(y0), int(y1)):
            for x in range(int(x0), int(x1)):
                self.px(x, y, c)

    def save(self, path):
        raw = bytearray()
        stride = self.w * 3
        for y in range(self.h):
            raw.append(0)
            raw += self.buf[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            return (struct.pack(">I", len(data)) + tag + data +
                    struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
               + chunk(b"IEND", b""))
        with open(path, "wb") as fh:
            fh.write(png)


# ---------------------------------------------------------------------------
# 3x5 digit font, for frame indices
# ---------------------------------------------------------------------------

GLYPHS = {
    "0": ("111", "101", "101", "101", "111"), "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"), "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"), "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"), "7": ("111", "001", "010", "010", "010"),
    "8": ("111", "101", "111", "101", "111"), "9": ("111", "101", "111", "001", "111"),
    ".": ("000", "000", "000", "000", "010"), "-": ("000", "000", "111", "000", "000"),
    "s": ("111", "100", "111", "001", "111"), "f": ("111", "100", "110", "100", "100"),
    " ": ("000", "000", "000", "000", "000"),
}


def text(canvas, x, y, s, c=(150, 158, 175), scale=1):
    cx = x
    for ch in s:
        g = GLYPHS.get(ch)
        if g:
            for ry, row in enumerate(g):
                for rx, bit in enumerate(row):
                    if bit == "1":
                        canvas.rect(cx + rx * scale, y + ry * scale,
                                    cx + (rx + 1) * scale, y + (ry + 1) * scale, c)
        cx += 4 * scale


# ---------------------------------------------------------------------------
# projection
# ---------------------------------------------------------------------------

VIEWS = {
    # name: (screen_x_axis, screen_y_axis) in mesh space (+X left, +Y fwd, +Z up)
    "side":  ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0)),    # character faces screen-right
    "front": ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0)),    # looking the character in the face
    "top":   ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),    # bird's eye, forward = screen-up
}


def view_axes(name):
    if name in VIEWS:
        return VIEWS[name]
    if name.startswith("orbit"):                    # orbit<yaw_degrees>
        yaw = math.radians(float(name[5:] or 35.0))
        pitch = math.radians(12.0)
        sx = (math.cos(yaw), math.sin(yaw), 0.0)
        sy = (-math.sin(yaw) * math.sin(pitch), math.cos(yaw) * math.sin(pitch), math.cos(pitch))
        return sx, sy
    raise ValueError("unknown view %r" % name)


# ---------------------------------------------------------------------------
# skeleton drawing
# ---------------------------------------------------------------------------

SPINE_C = (226, 230, 240)
LEG_L_C = (255, 122, 60)         # left leg  -- warm, saturated
LEG_R_C = (58, 150, 255)         # right leg -- cool, saturated
ARM_L_C = (255, 206, 130)        # left arm  -- warm, pale
ARM_R_C = (150, 214, 255)        # right arm -- cool, pale
FADE_C = (78, 84, 98)
GROUND_C = (52, 58, 72)
ACCENT_C = (255, 214, 120)

LEG_BONES = ("thigh", "calf", "foot", "ball")
ARM_BONES = ("clavicle", "upperarm", "lowerarm", "hand")


def bone_colour(name):
    """Legs saturated, arms pale, spine white -- limbs cross constantly in
    these poses and are unreadable when both sides share one colour."""
    side = name[-2:]
    if side not in ("_l", "_r"):
        return SPINE_C
    if any(name.startswith(p) for p in LEG_BONES):
        return LEG_L_C if side == "_l" else LEG_R_C
    if any(name.startswith(p) for p in ARM_BONES):
        return ARM_L_C if side == "_l" else ARM_R_C
    return SPINE_C


DRAW_SKIP = ("index", "middle", "pinky", "ring", "thumb", "weapon", "eyes", "twist")


def draw_pose(canvas, rig, world_t, origin, scale, view="side", colour_scale=1.0,
              width=2, joints=True):
    sx, sy = view_axes(view)
    ox, oy = origin

    def proj(p):
        return (ox + (p[0] * sx[0] + p[1] * sx[1] + p[2] * sx[2]) * scale,
                oy - (p[0] * sy[0] + p[1] * sy[1] + p[2] * sy[2]) * scale)

    def dim(c):
        return tuple(int(v * colour_scale + FADE_C[i] * (1 - colour_scale))
                     for i, v in enumerate(c))

    for i, name in enumerate(rig.names):
        p = rig.parents[i]
        if p < 0 or any(k in name for k in DRAW_SKIP):
            continue
        canvas.line(proj(world_t[p]), proj(world_t[i]), dim(bone_colour(name)), width)

    if joints:
        for key, r in (("foot_l", 3.0), ("foot_r", 3.0), ("ball_l", 2.2), ("ball_r", 2.2),
                       ("hand_l", 2.4), ("hand_r", 2.4), ("head", 4.5), ("pelvis", 3.0)):
            canvas.disc(proj(world_t[rig.index[key]]), r, dim(bone_colour(key)))


def contact_sheet(rig, frames, path, view="side", cols=8, cell=(190, 250),
                  cm_per_px=None, ghost=True, labels=None, title=None):
    """frames: list of world-translation arrays (one per animation frame)."""
    cw, ch = cell
    rows = int(math.ceil(len(frames) / float(cols)))
    header = 12 if title else 0
    canvas = Canvas(cw * cols, ch * rows + header)
    scale = cm_per_px if cm_per_px else (ch - 40) / 200.0
    if title:
        text(canvas, 6, 3, title, (150, 158, 175))

    for n, wt in enumerate(frames):
        cx = (n % cols) * cw
        cy = (n // cols) * ch + header
        canvas.rect(cx, cy, cx + 1, cy + ch, (34, 38, 48))
        ground = cy + ch - 26
        for x in range(cx + 6, cx + cw - 6, 6):        # dashed ground plane
            canvas.rect(x, ground, x + 3, ground + 1, GROUND_C)
        origin = (cx + cw * 0.5, ground)
        if ghost and n > 0:
            draw_pose(canvas, rig, frames[n - 1], origin, scale, view, 0.28, 2, False)
        draw_pose(canvas, rig, wt, origin, scale, view, 1.0, 2)
        text(canvas, cx + 6, cy + 6, labels[n] if labels else str(n), (120, 128, 145))

    canvas.save(path)
    return path
