#!/usr/bin/env python3
"""
Minimal FBX 7.4 ASCII writer for skeleton-only animation.

Why hand-rolled: the only thing Unreal needs to import an AnimSequence is a
named bone hierarchy plus T/R curves on it. Writing that directly means the
file contains exactly the 65 LimbNodes of the target skeleton and nothing
else -- no exporter's extra "Armature" null node, no leaf bones, no mesh, no
material stubs, all of which are the usual causes of "bone X not found in
skeleton" on import.

COORDINATE HANDOFF. Unreal converts an incoming FBX scene to
(Z up, -Y front, right-handed) and then flips to its own left-handed space in
FFbxDataConverter:

    ConvertPos:      (x, y, z)      -> (x, -y,  z)
    ConvertRotToQuat:(x, y, z, w)   -> (x, -y,  z, -w)

so this writer declares exactly that axis system (making the scene conversion
a no-op) and pre-applies the inverse of the flip. Both flips are involutions,
so "pre-apply the inverse" is the same operation, and what lands in Unreal is
bit-for-bit the transform the rig was authored with.

Rotations are written as Euler XYZ, which FBX composes as Rz * Ry * Rx, and
the tracks are unwrapped for continuity so no channel jumps a full turn
between frames.
"""

import math
import time

import rig as R

KTIME_PER_SECOND = 46186158000          # FBXSDK_TIME_ONE_SECOND
TIME_MODE_30FPS = 6                     # FbxTime::eFrames30


# ---------------------------------------------------------------------------
# space conversion
# ---------------------------------------------------------------------------

def to_fbx_pos(p):
    return (p[0], -p[1], p[2])


def to_fbx_quat(q):
    return (q[0], -q[1], q[2], -q[3])


def euler_track(quats):
    """Quaternion track -> continuous Euler XYZ degrees.

    Each frame picks between the two Euler solutions for the same rotation and
    any 360-degree shift of them, whichever is closest to the previous frame.
    Without this a channel can jump +179 -> -179 and anything that resamples
    the curve (Blender, a DCC round trip) sweeps the long way round.
    """
    out = []
    prev = None
    for q in quats:
        rx, ry, rz = R.quat_to_euler_xyz(q)
        if prev is None:
            out.append((rx, ry, rz))
            prev = (rx, ry, rz)
            continue
        candidates = [(rx, ry, rz), (rx + 180.0, 180.0 - ry, rz + 180.0)]
        best, best_cost = None, None
        for cand in candidates:
            fixed = []
            for c, p in zip(cand, prev):
                while c - p > 180.0:
                    c -= 360.0
                while c - p < -180.0:
                    c += 360.0
                fixed.append(c)
            cost = sum(abs(f - p) for f, p in zip(fixed, prev))
            if best_cost is None or cost < best_cost:
                best, best_cost = tuple(fixed), cost
        out.append(best)
        prev = best
    return out


# ---------------------------------------------------------------------------
# writer
# ---------------------------------------------------------------------------

class _Ids(object):
    def __init__(self, start=1000000):
        self.next = start

    def __call__(self):
        self.next += 1
        return self.next


def _fmt(v):
    """FBX ASCII numbers: short, but never in exponent form."""
    if abs(v) < 1e-9:
        return "0"
    s = "%.6f" % v
    return s.rstrip("0").rstrip(".")


def write(path, rig, clip_name, frames, fps=30.0, extra_root=None):
    """frames: list of (local_rots, local_trans), one entry per frame.

    extra_root: name of an identity bone to insert ABOVE `root`.

    Unreal refuses an animation whose hierarchy does not start at the target
    skeleton's root bone ("Mesh contains X bone as root but animation doesn't
    contain the root track"). A skeleton round-tripped through Blender picks
    up an extra bone named after the Armature object, so its root is that name
    rather than `root`. Naming it here makes the clip importable onto such a
    skeleton; the bone is keyed to identity on every frame, and any skeleton
    that does not have it simply drops the track.
    """
    ids = _Ids()
    n_frames = len(frames)
    n_bones = len(rig.bones)
    bone_names = [b["name"] for b in rig.bones]
    bone_parents = [b["parent"] for b in rig.bones]
    if extra_root:
        # prepended, so index 0 is the synthetic bone and every real bone
        # shifts by one -- `root` is re-parented onto it
        bone_names = [extra_root] + bone_names
        bone_parents = [-1] + [(p + 1 if p >= 0 else 0) for p in bone_parents]
    tick = int(round(KTIME_PER_SECOND / fps))
    stop = tick * (n_frames - 1)

    # ---- per-bone tracks, already in FBX space ----------------------------
    tracks = []
    for b in range(n_bones):
        quats = [to_fbx_quat(f[0][b]) for f in frames]
        eul = euler_track(quats)
        pos = [to_fbx_pos(f[1][b]) for f in frames]
        tracks.append((pos, eul))
    if extra_root:
        identity = [(0.0, 0.0, 0.0)] * n_frames
        tracks.insert(0, (identity, identity))
    n_nodes = len(bone_names)

    lines = []
    w = lines.append

    now = time.gmtime()
    w("; FBX 7.4.0 project file")
    w("; Generated by Animation/SkidTurn/fbx_ascii.py -- skeleton-only animation")
    w("; ----------------------------------------------------")
    w("")
    w("FBXHeaderExtension:  {")
    w("\tFBXHeaderVersion: 1003")
    w("\tFBXVersion: 7400")
    w("\tCreationTimeStamp:  {")
    w("\t\tVersion: 1000")
    w("\t\tYear: %d" % now.tm_year)
    w("\t\tMonth: %d" % now.tm_mon)
    w("\t\tDay: %d" % now.tm_mday)
    w("\t\tHour: %d" % now.tm_hour)
    w("\t\tMinute: %d" % now.tm_min)
    w("\t\tSecond: %d" % now.tm_sec)
    w("\t\tMillisecond: 0")
    w("\t}")
    w('\tCreator: "TheCameraIsAPal SkidTurn builder"')
    w("}")
    w("GlobalSettings:  {")
    w("\tVersion: 1000")
    w("\tProperties70:  {")
    # Z up, -Y front, X right: the axis system Unreal converts TO, so its
    # own conversion pass has nothing to do.
    w('\t\tP: "UpAxis", "int", "Integer", "",2')
    w('\t\tP: "UpAxisSign", "int", "Integer", "",1')
    w('\t\tP: "FrontAxis", "int", "Integer", "",1')
    w('\t\tP: "FrontAxisSign", "int", "Integer", "",-1')
    w('\t\tP: "CoordAxis", "int", "Integer", "",0')
    w('\t\tP: "CoordAxisSign", "int", "Integer", "",1')
    w('\t\tP: "OriginalUpAxis", "int", "Integer", "",2')
    w('\t\tP: "OriginalUpAxisSign", "int", "Integer", "",1')
    w('\t\tP: "UnitScaleFactor", "double", "Number", "",1')
    w('\t\tP: "OriginalUnitScaleFactor", "double", "Number", "",1')
    w('\t\tP: "TimeSpanStart", "KTime", "Time", "",0')
    w('\t\tP: "TimeSpanStop", "KTime", "Time", "",%d' % stop)
    w('\t\tP: "TimeMode", "enum", "", "",%d' % TIME_MODE_30FPS)
    w('\t\tP: "CustomFrameRate", "double", "Number", "",%s' % _fmt(fps))
    w("\t}")
    w("}")
    w("")

    # ---- definitions ------------------------------------------------------
    n_curvenodes = n_nodes * 2                  # translation + rotation
    n_curves = n_nodes * 6                      # x/y/z of each
    total = 1 + n_nodes * 2 + 2 + n_curvenodes + n_curves
    w("; Object definitions")
    w(";------------------------------------------------------------------")
    w("")
    w("Definitions:  {")
    w("\tVersion: 100")
    w("\tCount: %d" % total)
    for otype, count in (("GlobalSettings", 1), ("NodeAttribute", n_nodes),
                         ("Model", n_nodes), ("AnimationStack", 1),
                         ("AnimationLayer", 1), ("AnimationCurveNode", n_curvenodes),
                         ("AnimationCurve", n_curves)):
        w('\tObjectType: "%s" {' % otype)
        w("\t\tCount: %d" % count)
        w("\t}")
    w("}")
    w("")

    # ---- objects ----------------------------------------------------------
    w("; Object properties")
    w(";------------------------------------------------------------------")
    w("")
    w("Objects:  {")

    attr_id, model_id = [], []
    for b, name in enumerate(bone_names):
        aid, mid = ids(), ids()
        attr_id.append(aid)
        model_id.append(mid)
        w('\tNodeAttribute: %d, "NodeAttribute::%s", "LimbNode" {' % (aid, name))
        w("\t\tProperties70:  {")
        w('\t\t\tP: "Size", "double", "Number", "",1')
        w("\t\t}")
        w('\t\tTypeFlags: "Skeleton"')
        w("\t}")

        t0 = tracks[b][0][0]
        r0 = tracks[b][1][0]
        w('\tModel: %d, "Model::%s", "LimbNode" {' % (mid, name))
        w("\t\tVersion: 232")
        w("\t\tProperties70:  {")
        w('\t\t\tP: "RotationActive", "bool", "", "",1')
        w('\t\t\tP: "RotationOrder", "enum", "", "",0')
        w('\t\t\tP: "InheritType", "enum", "", "",1')
        w('\t\t\tP: "ScalingMax", "Vector3D", "Vector", "",0,0,0')
        w('\t\t\tP: "DefaultAttributeIndex", "int", "Integer", "",0')
        w('\t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",%s,%s,%s'
          % (_fmt(t0[0]), _fmt(t0[1]), _fmt(t0[2])))
        w('\t\t\tP: "Lcl Rotation", "Lcl Rotation", "", "A",%s,%s,%s'
          % (_fmt(r0[0]), _fmt(r0[1]), _fmt(r0[2])))
        w('\t\t\tP: "Lcl Scaling", "Lcl Scaling", "", "A",1,1,1')
        w("\t\t}")
        w("\t\tShading: T")
        w('\t\tCulling: "CullingOff"')
        w("\t}")

    stack_id, layer_id = ids(), ids()
    w('\tAnimationStack: %d, "AnimStack::%s", "" {' % (stack_id, clip_name))
    w("\t\tProperties70:  {")
    w('\t\t\tP: "LocalStart", "KTime", "Time", "",0')
    w('\t\t\tP: "LocalStop", "KTime", "Time", "",%d' % stop)
    w('\t\t\tP: "ReferenceStart", "KTime", "Time", "",0')
    w('\t\t\tP: "ReferenceStop", "KTime", "Time", "",%d' % stop)
    w("\t\t}")
    w("\t}")
    w('\tAnimationLayer: %d, "AnimLayer::BaseLayer", "" {' % layer_id)
    w("\t}")

    key_times = ",".join(str(tick * f) for f in range(n_frames))
    curve_nodes = []                            # (id, model_id, property)
    curves = []                                 # (id, curve_node_id, channel)

    for b in range(n_nodes):
        pos, eul = tracks[b]
        for prop, label, values, defaults in (
                ("Lcl Translation", "T", pos, pos[0]),
                ("Lcl Rotation", "R", eul, eul[0])):
            cn_id = ids()
            curve_nodes.append((cn_id, model_id[b], prop))
            w('\tAnimationCurveNode: %d, "AnimCurveNode::%s", "" {' % (cn_id, label))
            w("\t\tProperties70:  {")
            for axis, dv in zip("XYZ", defaults):
                w('\t\t\tP: "d|%s", "Number", "", "A",%s' % (axis, _fmt(dv)))
            w("\t\t}")
            w("\t}")
            for i, axis in enumerate("XYZ"):
                c_id = ids()
                curves.append((c_id, cn_id, axis))
                w('\tAnimationCurve: %d, "AnimCurve::", "" {' % c_id)
                w("\t\tDefault: %s" % _fmt(values[0][i]))
                w("\t\tKeyVer: 4009")
                w("\t\tKeyTime: *%d {" % n_frames)
                w("\t\t\ta: %s" % key_times)
                w("\t\t}")
                w("\t\tKeyValueFloat: *%d {" % n_frames)
                w("\t\t\ta: %s" % ",".join(_fmt(v[i]) for v in values))
                w("\t\t}")
                # 4 = eInterpolationLinear. Every frame is keyed and Unreal
                # resamples at the same rate, so tangents never come into play.
                w("\t\tKeyAttrFlags: *1 {")
                w("\t\t\ta: 4")
                w("\t\t}")
                w("\t\tKeyAttrDataFloat: *4 {")
                w("\t\t\ta: 0,0,0,0")
                w("\t\t}")
                w("\t\tKeyAttrRefCount: *1 {")
                w("\t\t\ta: %d" % n_frames)
                w("\t\t}")
                w("\t}")
    w("}")
    w("")

    # ---- connections ------------------------------------------------------
    w("; Object connections")
    w(";------------------------------------------------------------------")
    w("")
    w("Connections:  {")
    for b, name in enumerate(bone_names):
        parent = bone_parents[b]
        pid = model_id[parent] if parent >= 0 else 0
        w('\t;Model::%s, %s' % (name, "Model::" + bone_names[parent] if parent >= 0
                                else "Model::RootNode"))
        w('\tC: "OO",%d,%d' % (model_id[b], pid))
        w('\t;NodeAttribute::%s, Model::%s' % (name, name))
        w('\tC: "OO",%d,%d' % (attr_id[b], model_id[b]))
    w('\t;AnimLayer::BaseLayer, AnimStack::%s' % clip_name)
    w('\tC: "OO",%d,%d' % (layer_id, stack_id))
    for cn_id, mid, prop in curve_nodes:
        w('\tC: "OO",%d,%d' % (cn_id, layer_id))
        w('\tC: "OP",%d,%d, "%s"' % (cn_id, mid, prop))
    for c_id, cn_id, axis in curves:
        w('\tC: "OP",%d,%d, "d|%s"' % (c_id, cn_id, axis))
    w("}")
    w("")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path
