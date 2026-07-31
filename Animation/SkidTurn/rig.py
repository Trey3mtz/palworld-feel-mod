#!/usr/bin/env python3
"""
Rig math for the SkidTurn authoring pipeline.

Everything here works in MESH SPACE, which for SK_PalHuman is:
    +X = character's LEFT      +Y = character's FORWARD      +Z = UP
(established from the reference pose: toes sit at +Y of the ankle, the left
hand sits at +X of the chest). Units are centimetres, matching UE.

Why poses are authored as mesh-space deltas instead of local rotations:
this rig has no consistent bone-axis convention -- thigh_l's local +X points
UP the leg while thigh_r's points DOWN, the spine runs +X up, the toes run +X
forward. Authoring local Euler per bone would mean memorising 65 different
frames of reference. Instead a pose states, per bone, a rotation applied in
mesh space on top of where the reference pose already put that bone:

    world_new(bone) = D(bone) * ( world_new(parent) * local_ref(bone) )
    local_new(bone) = inverse(world_new(parent)) * world_new(bone)

so "swing the thigh 50 forward" is literally 50 degrees about the character's
left-right axis, whatever the bone's local axes happen to be, and a child
inherits its parent's animated orientation before its own delta is applied.
"""

import json
import math
import os

# ---------------------------------------------------------------------------
# quaternions / vectors  (q = (x, y, z, w), rotating column vectors)
# ---------------------------------------------------------------------------

IDENT = (0.0, 0.0, 0.0, 1.0)


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qnorm(q):
    n = math.sqrt(sum(c * c for c in q))
    if n < 1e-12:
        return IDENT
    return tuple(c / n for c in q)


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty),
            vy + w * ty + (z * tx - x * tz),
            vz + w * tz + (x * ty - y * tx))


def axis_angle(axis, degrees):
    if abs(degrees) < 1e-9:
        return IDENT
    n = math.sqrt(sum(c * c for c in axis))
    if n < 1e-12:
        return IDENT
    a = math.radians(degrees) * 0.5
    s = math.sin(a) / n
    return (axis[0] * s, axis[1] * s, axis[2] * s, math.cos(a))


def vadd(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vsub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vlen(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def vnorm(a):
    n = vlen(a)
    return (0.0, 0.0, 0.0) if n < 1e-12 else (a[0] / n, a[1] / n, a[2] / n)


def quat_to_euler_xyz(q):
    """Euler (degrees) such that R = Rz(z) * Ry(y) * Rx(x) -- FBX eEulerXYZ."""
    x, y, z, w = qnorm(q)
    m00 = 1 - 2 * (y * y + z * z)
    m10 = 2 * (x * y + z * w)
    m20 = 2 * (x * z - y * w)
    m21 = 2 * (y * z + x * w)
    m22 = 1 - 2 * (x * x + y * y)
    m20 = max(-1.0, min(1.0, m20))
    ry = math.asin(-m20)
    if abs(m20) < 0.9999999:
        rx = math.atan2(m21, m22)
        rz = math.atan2(m10, m00)
    else:                                   # gimbal lock: fold roll into yaw
        m01 = 2 * (x * y - z * w)
        m11 = 1 - 2 * (x * x + z * z)
        rx = math.atan2(-m01, m11)
        rz = 0.0
    return (math.degrees(rx), math.degrees(ry), math.degrees(rz))


# ---------------------------------------------------------------------------
# mesh-space axes
# ---------------------------------------------------------------------------

AXIS_LEFT = (1.0, 0.0, 0.0)
AXIS_FWD = (0.0, 1.0, 0.0)
AXIS_UP = (0.0, 0.0, 1.0)


class Rig(object):
    """The 65-bone player rig plus its reference-pose forward kinematics."""

    def __init__(self, path=None):
        path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "rig_palhuman.json")
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        self.meta = data["meta"]
        self.bones = data["bones"]
        self.names = [b["name"] for b in self.bones]
        self.index = {n: i for i, n in enumerate(self.names)}
        self.parents = [b["parent"] for b in self.bones]
        self.local_t = [tuple(b["t"]) for b in self.bones]
        self.local_q = [qnorm(tuple(b["q"])) for b in self.bones]
        self.children = [[] for _ in self.bones]
        for i, p in enumerate(self.parents):
            if p >= 0:
                self.children[p].append(i)
        self.ref_world_q, self.ref_world_t = self.forward_kinematics(self.local_q)
        self.aim = self._compute_aims()

    # -- forward kinematics -------------------------------------------------

    def forward_kinematics(self, local_rots, local_trans=None):
        """local_rots[i] replaces the reference local rotation of bone i."""
        wq = [IDENT] * len(self.bones)
        wt = [(0.0, 0.0, 0.0)] * len(self.bones)
        for i in range(len(self.bones)):           # bones are parent-ordered
            lq = local_rots[i]
            lt = self.local_t[i] if local_trans is None else local_trans[i]
            p = self.parents[i]
            if p < 0:
                wq[i], wt[i] = lq, lt
            else:
                wq[i] = qnorm(qmul(wq[p], lq))
                wt[i] = vadd(wt[p], qrot(wq[p], lt))
        return wq, wt

    def _compute_aims(self):
        """Mesh-space direction each bone points in the reference pose.

        Used as the axis for `twist` channels, so a twist is always "spin the
        limb about its own length" no matter how the bone's local axes run.
        """
        aims = []
        for i in range(len(self.bones)):
            kids = self.children[i]
            if kids:
                target = self.ref_world_t[kids[0]]
                if len(kids) > 1:                  # average the fan (hand, pelvis)
                    acc = (0.0, 0.0, 0.0)
                    for k in kids:
                        acc = vadd(acc, vnorm(vsub(self.ref_world_t[k], self.ref_world_t[i])))
                    aims.append(vnorm(acc))
                    continue
                aims.append(vnorm(vsub(target, self.ref_world_t[i])))
            else:
                p = self.parents[i]
                aims.append(vnorm(vsub(self.ref_world_t[i], self.ref_world_t[p]))
                            if p >= 0 else AXIS_UP)
        return aims

    # -- pose evaluation ----------------------------------------------------

    def delta_quat(self, bone_idx, ch):
        """Channel dict -> mesh-space rotation, composed Rz * Rx * Ry * twist.

        Order is deliberate. ry (splay/tilt/roll) is innermost so it settles a
        limb into its plane FIRST -- these arms sit in a 45 degree A-pose at
        rest, so nearly every arm channel starts by dropping them -- and rx
        (the swing) then happens about the mesh left-right axis, keeping the
        full authored angle instead of bleeding part of it into the splay.
        rz (yaw) is outermost because a yaw should steer the finished limb.
        """
        q = IDENT
        if ch.get("angle"):
            q = axis_angle(ch.get("axis", AXIS_UP), ch["angle"])
        tw = ch.get("twist", 0.0)
        if tw:
            q = qmul(axis_angle(self.aim[bone_idx], tw), q)
        for key, axis in (("ry", AXIS_FWD), ("rx", AXIS_LEFT), ("rz", AXIS_UP)):
            a = ch.get(key, 0.0)
            if a:
                q = qmul(axis_angle(axis, a), q)
        return qnorm(q)

    def evaluate(self, pose):
        """pose: {bone_name: channel dict} -> (local_rots, local_trans).

        Translation channels (tx/ty/tz, centimetres, mesh space) are only
        meaningful on root and pelvis: every other bone in this skeleton is
        EBoneTranslationRetargetingMode::Skeleton, i.e. UE takes its
        translation from the target mesh's reference pose and ignores what
        the clip stores.
        """
        n = len(self.bones)
        local_rots = [None] * n
        local_trans = list(self.local_t)
        wq = [IDENT] * n
        wt = [(0.0, 0.0, 0.0)] * n

        for i in range(n):
            ch = pose.get(self.names[i]) or {}
            p = self.parents[i]
            parent_q = wq[p] if p >= 0 else IDENT
            parent_t = wt[p] if p >= 0 else (0.0, 0.0, 0.0)

            if ch.get("tx") or ch.get("ty") or ch.get("tz"):
                base = self.local_t[i]
                local_trans[i] = (base[0] + ch.get("tx", 0.0),
                                  base[1] + ch.get("ty", 0.0),
                                  base[2] + ch.get("tz", 0.0))

            inherited = qmul(parent_q, self.local_q[i])
            if not ch:
                world_q = qnorm(inherited)
            elif ch.get("space") == "carried":
                # Delta stated in mesh axes but riding the parent chain: the
                # pose reads the same after the parent moves. Fingers need
                # this -- a "curl" must stay a curl once the arm swings.
                ref = self.ref_world_q[i]
                d_local = qmul(qconj(ref), qmul(self.delta_quat(i, ch), ref))
                world_q = qnorm(qmul(inherited, d_local))
            else:
                world_q = qnorm(qmul(self.delta_quat(i, ch), inherited))
            local_rots[i] = qnorm(qmul(qconj(parent_q), world_q))

            wq[i] = world_q
            wt[i] = vadd(parent_t, qrot(parent_q, local_trans[i]))

        return local_rots, local_trans

    def world_from_pose(self, pose):
        lr, lt = self.evaluate(pose)
        return self.forward_kinematics(lr, lt)

    # -- ground contact -----------------------------------------------------

    HEEL_BEHIND = 6.0        # cm the heel contact sits behind the ankle

    def contact_locals(self):
        """Heel/toe contact points, in bone-local space.

        Solved from the reference pose by requiring each to land exactly on
        z = 0 there, which is what makes "lowest contact point" a usable
        floor test for any pose the rig can reach.
        """
        if getattr(self, "_contacts", None):
            return self._contacts
        out = []
        for side in ("l", "r"):
            fi, bi = self.index["foot_" + side], self.index["ball_" + side]
            ankle, ball = self.ref_world_t[fi], self.ref_world_t[bi]
            heel_w = (0.0, -self.HEEL_BEHIND, -ankle[2])
            toe_w = (0.0, 0.0, -ball[2])
            out.append((fi, qrot(qconj(self.ref_world_q[fi]), heel_w)))
            out.append((bi, qrot(qconj(self.ref_world_q[bi]), toe_w)))
        self._contacts = out
        return out

    def contact_points(self, wq, wt):
        return [vadd(wt[i], qrot(wq[i], off)) for i, off in self.contact_locals()]

    def lowest_contact(self, wq, wt):
        return min(p[2] for p in self.contact_points(wq, wt))

    def lowest_per_foot(self, wq, wt):
        """(left, right) lowest contact height -- the hip solve needs them
        separately so a swinging leg cannot dictate the support height."""
        p = self.contact_points(wq, wt)
        return min(p[0][2], p[1][2]), min(p[2][2], p[3][2])


# ---------------------------------------------------------------------------
# authoring helpers -- readable channel dicts
# ---------------------------------------------------------------------------

def limb(swing=0.0, splay=0.0, twist=0.0, side=None):
    """For bones that hang DOWN/OUT (legs, arms, fingers).

    swing +  tip travels FORWARD (+Y)          -- hip flexion, shoulder raise
    splay +  tip travels OUTBOARD, away from the midline (side-aware)
    twist +  right-hand spin about the bone's own length
    """
    ch = {}
    if swing:
        ch["rx"] = swing
    if splay:
        # a downward bone rotated about +Y moves toward -X (the right), so the
        # left side needs the negative to travel outboard.
        ch["ry"] = -splay if side == "l" else splay
    if twist:
        ch["twist"] = twist
    return ch


def axial(lean=0.0, tilt=0.0, turn=0.0):
    """For bones that point UP (pelvis, spine, neck, head).

    lean +   top tips FORWARD          tilt +  top tips to the character's LEFT
    turn +   faces further LEFT
    """
    ch = {}
    if lean:
        ch["rx"] = -lean
    if tilt:
        ch["ry"] = tilt
    if turn:
        ch["rz"] = -turn
    return ch


ARM_REST_SPLAY = -45.0    # this rig's reference pose is a 45 degree A-pose


def arm(swing=0.0, splay=0.0, twist=0.0, side=None):
    """Upper arm, with splay measured from HANGING STRAIGHT DOWN.

    splay 0 puts the arm at the side, +90 raises it to a T-pose, negative
    crosses it in front of the body. Without this offset every arm channel in
    every pose would have to carry the same -45 correction.
    """
    return limb(swing=swing, splay=splay + ARM_REST_SPLAY, twist=twist, side=side)


def foot(pitch=0.0, yaw=0.0, roll=0.0):
    """For the ankle/toe, whose bone already points FORWARD (+Y).

    pitch +  toes lift (dorsiflexion, the heel-first skid plant)
    yaw   +  toes swing toward the character's LEFT
    roll  +  the sole tips toward the character's LEFT
    """
    ch = {}
    if pitch:
        ch["rx"] = pitch
    if yaw:
        ch["rz"] = -yaw
    if roll:
        ch["ry"] = roll
    return ch


def finger_curl(rig, side, degrees):
    """Curl every finger of one hand toward the palm.

    The bend axis is the knuckle line (index -> pinky) measured off the
    reference pose, and the channels are `carried`, so the curl survives the
    arm being thrown anywhere by the pose.
    """
    knuckle = vnorm(vsub(rig.ref_world_t[rig.index["pinky_01_" + side]],
                         rig.ref_world_t[rig.index["index_01_" + side]]))
    sign = 1.0 if side == "l" else -1.0
    out = {}
    for digit, weight in (("index", 1.0), ("middle", 1.05), ("ring", 1.0), ("pinky", 0.95)):
        for seg, seg_w in (("01", 0.9), ("02", 1.1), ("03", 0.9)):
            out["%s_%s_%s" % (digit, seg, side)] = {
                "axis": knuckle, "angle": degrees * weight * seg_w * sign,
                "space": "carried"}
    for seg, seg_w in (("01", 0.5), ("02", 0.7), ("03", 0.7)):
        out["thumb_%s_%s" % (seg, side)] = {
            "axis": knuckle, "angle": degrees * seg_w * 0.55 * sign, "space": "carried"}
    return out


def merge(*channel_dicts):
    """Combine channel dicts; numeric channels add, the rest overwrite."""
    out = {}
    for d in channel_dicts:
        for k, v in d.items():
            if isinstance(v, (int, float)) and isinstance(out.get(k), (int, float)):
                out[k] = out[k] + v
            else:
                out[k] = v
    return out
