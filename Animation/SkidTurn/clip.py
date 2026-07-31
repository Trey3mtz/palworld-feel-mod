#!/usr/bin/env python3
"""
Keyframes -> baked per-frame bone transforms.

Two things happen here that the pose data deliberately does not carry:

* Interpolation is per CHANNEL, not per quaternion. Channels are mesh-space
  angles, so lerping them keeps the authored silhouette between keys instead
  of letting a slerp cut its own path through the pose.
* Hip height is SOLVED, not authored. Every frame drops the pelvis until the
  lowest heel/toe contact sits on the floor, so the skid crouch is whatever
  the planted leg geometry demands and no pose can float or sink. A per-key
  `lift` bias is applied afterwards for the frames that should leave the
  ground.

Easing names mirror TheCameraIsAPal/Scripts/easingfunctions.lua so timing
vocabulary is shared with the runtime side of the mod.
"""

import math

import rig as R

# ---------------------------------------------------------------------------
# easing (t in 0..1)
# ---------------------------------------------------------------------------

EASING = {
    "EaseLinear": lambda t: t,
    "EaseInSine": lambda t: 1.0 - math.cos(t * math.pi * 0.5),
    "EaseOutSine": lambda t: math.sin(t * math.pi * 0.5),
    "EaseInOutSine": lambda t: -(math.cos(math.pi * t) - 1.0) * 0.5,
    "EaseInQuad": lambda t: t * t,
    "EaseOutQuad": lambda t: 1.0 - (1.0 - t) ** 2,
    "EaseInOutQuad": lambda t: 2 * t * t if t < 0.5 else 1 - ((-2 * t + 2) ** 2) / 2,
    "EaseInCubic": lambda t: t ** 3,
    "EaseOutCubic": lambda t: 1.0 - (1.0 - t) ** 3,
    "EaseInOutCubic": lambda t: 4 * t ** 3 if t < 0.5 else 1 - ((-2 * t + 2) ** 3) / 2,
    "EaseOutQuart": lambda t: 1.0 - (1.0 - t) ** 4,
    "EaseOutBack": lambda t: 1 + 2.70158 * (t - 1) ** 3 + 1.70158 * (t - 1) ** 2,
    "EaseInBack": lambda t: 2.70158 * t ** 3 - 1.70158 * t * t,
}

STATIC_KEYS = ("axis", "space")     # carried verbatim, never interpolated


class Key(object):
    def __init__(self, t, pose, ease="EaseInOutSine", label=""):
        self.t = float(t)
        self.pose = pose
        self.ease = ease            # shapes the segment ARRIVING at this key
        self.label = label


class Clip(object):
    def __init__(self, name, keys, fps=30.0, duration=None, amp=1.0,
                 ground_lock=True, notes=""):
        self.name = name
        self.keys = sorted(keys, key=lambda k: k.t)
        self.fps = fps
        self.duration = duration if duration is not None else self.keys[-1].t
        self.amp = amp              # global exaggeration scale (walk vs sprint)
        self.ground_lock = ground_lock
        self.notes = notes

    @property
    def frame_count(self):
        return int(round(self.duration * self.fps)) + 1

    # -- channel sampling ---------------------------------------------------

    def _channel_table(self):
        """(bone, channel) -> [(t, value, ease)], plus the static channels."""
        if getattr(self, "_table_cache", None):
            return self._table_cache
        table, static = {}, {}
        for key in self.keys:
            for bone, ch in key.pose.items():
                for cname, value in ch.items():
                    if cname in STATIC_KEYS:
                        static.setdefault(bone, {})[cname] = value
                        continue
                    table.setdefault((bone, cname), []).append((key.t, value, key.ease))
        self._table_cache = (table, static)
        return self._table_cache

    def sample(self, t):
        """Pose dict at time t, with amp applied to every angle/offset."""
        table, static = self._channel_table()
        pose = {}
        for (bone, cname), points in table.items():
            v = _interp(points, t, self.keys[0].t, self.keys[-1].t)
            if abs(v) > 1e-9:
                pose.setdefault(bone, {})[cname] = v * self.amp
        for bone, ch in static.items():
            if bone in pose:
                pose[bone].update(ch)
        return pose

    # -- baking -------------------------------------------------------------

    def bake(self, rig, verbose=False):
        """-> (local_rots[f][b], local_trans[f][b], world_q[f][b], world_t[f][b])

        Hip height is solved per frame from the WEIGHTED support foot. Keys
        declare wl/wr on the pelvis (how much of the body's weight each foot
        carries at that beat); the weights interpolate like any other channel,
        so weight transfer is a smooth hip curve instead of the step you get
        from snapping to whichever contact happens to be lowest. A final clamp
        guarantees nothing ends up under the floor.
        """
        pelvis = rig.index["pelvis"]
        rots, trans, offsets, floors = [], [], [], []

        for f in range(self.frame_count):
            pose = self.sample(f / self.fps)
            pch = pose.get("pelvis", {})
            lift = pch.pop("lift", 0.0)
            wl, wr = pch.pop("wl", 1.0), pch.pop("wr", 1.0)
            lr, lt = rig.evaluate(pose)
            rots.append(lr)
            trans.append(lt)
            if not self.ground_lock:
                offsets.append(0.0)
                floors.append(-1e9)
                continue
            wq, wt = rig.forward_kinematics(lr, lt)
            cl, cr = rig.lowest_per_foot(wq, wt)
            total = max(1e-6, wl + wr)
            offsets.append(-(wl * cl + wr * cr) / total + lift)
            floors.append(-min(cl, cr))       # below this something is buried

        # A pelvis is a mass: it cannot change height by 8cm in one frame and
        # back. One [.25 .5 .25] pass kills the single-frame bounces the raw
        # geometric solve produces when a leg passes under the body nearly
        # straight, then the floor clamp is re-applied so smoothing can never
        # push a foot through the ground.
        if self.ground_lock and len(offsets) >= 3:
            smoothed = list(offsets)
            for f in range(1, len(offsets) - 1):
                smoothed[f] = 0.25 * offsets[f - 1] + 0.5 * offsets[f] + 0.25 * offsets[f + 1]
            offsets = smoothed

        worst, clamped = 0.0, 0
        wqs, wts = [], []
        for f in range(self.frame_count):
            dz = offsets[f]
            if dz < floors[f]:
                if floors[f] - dz > 0.5:
                    clamped += 1
                dz = floors[f]
            dz = max(-40.0, min(40.0, dz))
            worst = max(worst, abs(dz))
            base = trans[f][pelvis]
            trans[f][pelvis] = (base[0], base[1], base[2] + dz)
            wq, wt = rig.forward_kinematics(rots[f], trans[f])
            wqs.append(wq)
            wts.append(wt)

        if verbose:
            steps = [abs(wts[f + 1][pelvis][2] - wts[f][pelvis][2])
                     for f in range(len(wts) - 1)]
            print("  %-34s %2d frames  %.4fs  amp %.2f  hip solve max %.1fcm, "
                  "biggest step %.1fcm, floor-driven on %d/%d frames"
                  % (self.name, self.frame_count, self.duration, self.amp, worst,
                     max(steps) if steps else 0.0, clamped, self.frame_count))
        return rots, trans, wqs, wts

    def frame_labels(self):
        """Frame index, plus the beat name on whichever frame each key lands
        nearest to -- key times are authored in seconds and rarely fall exactly
        on a frame boundary."""
        labels = [str(f) for f in range(self.frame_count)]
        for key in self.keys:
            if not key.label:
                continue
            f = int(round(key.t * self.fps))
            if 0 <= f < len(labels):
                labels[f] = "%d %s" % (f, key.label)
        return labels


def _interp(points, t, t_first, t_last):
    if t <= points[0][0]:
        return points[0][1] if points[0][0] <= t_first + 1e-9 else _ramp_in(points, t, t_first)
    if t >= points[-1][0]:
        return points[-1][1] if points[-1][0] >= t_last - 1e-9 else _ramp_out(points, t, t_last)
    for i in range(len(points) - 1):
        t0, v0, _ = points[i]
        t1, v1, ease = points[i + 1]
        if t0 <= t <= t1:
            u = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
            return v0 + (v1 - v0) * EASING[ease](u)
    return points[-1][1]


def _ramp_in(points, t, t_first):
    """A channel that first appears mid-clip eases up from zero."""
    t0, v0, ease = t_first, 0.0, points[0][2]
    t1, v1 = points[0][0], points[0][1]
    u = 0.0 if t1 <= t0 else max(0.0, (t - t0) / (t1 - t0))
    return v0 + (v1 - v0) * EASING[ease](min(1.0, u))


def _ramp_out(points, t, t_last):
    """...and back down to zero if it stops being keyed before the end."""
    t0, v0 = points[-1][0], points[-1][1]
    u = 0.0 if t_last <= t0 else max(0.0, (t - t0) / (t_last - t0))
    return v0 + (0.0 - v0) * EASING["EaseInOutSine"](min(1.0, u))


# ---------------------------------------------------------------------------
# mirroring
# ---------------------------------------------------------------------------

def mirror_pose(pose):
    """Reflect a pose through the character's sagittal plane (swap l/r).

    Mesh X is the left axis, so reflecting means negating every rotation
    component that is not about X, and swapping the _l/_r bone names.
    """
    def flip_name(n):
        if n.endswith("_l"):
            return n[:-2] + "_r"
        if n.endswith("_r"):
            return n[:-2] + "_l"
        return n

    out = {}
    for bone, ch in pose.items():
        m = {}
        for k, v in ch.items():
            if k in ("ry", "rz", "twist", "angle", "tx"):
                # M R(a,t) M = R(Ma, -t) for M = reflect across x: rotations
                # about mesh X survive, everything else changes sign.
                m[k] = -v
            elif k == "axis":
                m[k] = (-v[0], v[1], v[2])
            else:
                m[k] = v
        out[flip_name(bone)] = m
    return out


def mirror_clip(clip, name=None):
    keys = [Key(k.t, mirror_pose(k.pose), k.ease, k.label) for k in clip.keys]
    return Clip(name or (clip.name + "_Mirror"), keys, clip.fps, clip.duration,
                clip.amp, clip.ground_lock, clip.notes)
