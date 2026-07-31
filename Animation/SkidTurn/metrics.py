#!/usr/bin/env python3
"""
Numeric read-out of a baked clip, for tuning poses without a viewport.

Stick figures show shape; these show whether the shape is physically sane --
hip height, how far ahead of the hips the plant foot actually is, whether a
foot is under the floor, and how much the shoulders lead the hips.
"""

import math

import rig as R


def torso_pitch(rig, wt):
    """Degrees the pelvis->neck line is pitched forward (+) or back (-)."""
    v = R.vsub(wt[rig.index["neck_01"]], wt[rig.index["pelvis"]])
    return math.degrees(math.atan2(v[1], max(1e-6, v[2])))


def _yaw_of(rig, wt, left_bone, right_bone):
    """Yaw of a left/right pair. + = turned toward the character's LEFT.

    The right->left vector lies along +X at rest; turning left carries the
    right side forward, so the vector picks up -Y.
    """
    v = R.vsub(wt[rig.index[left_bone]], wt[rig.index[right_bone]])
    return math.degrees(math.atan2(-v[1], v[0]))


def shoulder_yaw(rig, wt):
    return _yaw_of(rig, wt, "clavicle_l", "clavicle_r")


def hip_yaw(rig, wt):
    return _yaw_of(rig, wt, "thigh_l", "thigh_r")


def foot_contacts(rig, wq, wt):
    """{'l': (heel_z, toe_z), 'r': (...)} in the contact_locals order."""
    pts = rig.contact_points(wq, wt)
    return {"l": (pts[0][2], pts[1][2]), "r": (pts[2][2], pts[3][2])}


def report(rig, clip, wqs, wts, stream=None):
    out = stream.write if stream else print
    lines = ["  frame  hipZ   torso  shldr   hips  sep |  plantR fwd/lat/z |   trailL fwd/lat/z | lowest"]
    pelvis = rig.index["pelvis"]
    for f, (wq, wt) in enumerate(zip(wqs, wts)):
        p = wt[pelvis]
        sh, hp = shoulder_yaw(rig, wt), hip_yaw(rig, wt)
        c = foot_contacts(rig, wq, wt)
        fr = wt[rig.index["foot_r"]]
        fl = wt[rig.index["foot_l"]]
        lines.append(
            "  %4d %6.1f %+7.1f %+6.1f %+6.1f %+5.1f | %+6.1f %+6.1f %5.1f | %+6.1f %+6.1f %5.1f | %5.1f"
            % (f, p[2], torso_pitch(rig, wt), sh, hp, sh - hp,
               fr[1] - p[1], fr[0] - p[0], min(c["r"]),
               fl[1] - p[1], fl[0] - p[0], min(c["l"]),
               min(min(c["r"]), min(c["l"]))))
    text = "\n".join(lines)
    out(text + "\n")
    return text
