#!/usr/bin/env python3
"""
Round-trip check on the generated FBX.

Re-reads the ASCII file, applies the exact conversion Unreal's FBX importer
applies (FFbxDataConverter: negate Y on positions, negate Y and W on
rotations), rebuilds each frame's pose with forward kinematics and compares it
against what the builder baked.

This is the only test available without Unreal in the loop, and it is the one
that matters: it proves the Euler order, the axis handoff and the curve
plumbing all invert cleanly. A failure here means the clip would import
mangled; a pass means the file says what the pose data says.
"""

import re

import rig as R


def parse(path):
    """-> (bone order, parents by name, per-bone translation/rotation tracks)"""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()

    models = {}                                  # id -> name
    for mid, name in re.findall(r'Model: (\d+), "Model::([^"]+)", "LimbNode"', text):
        models[int(mid)] = name

    # AnimationCurveNode id -> (model name, property)
    objects = text.split("Objects:  {", 1)[1].split("\nConnections:", 1)[0]
    conns = text.split("Connections:  {", 1)[1]

    curvenode_prop = {}
    for cid, mid, prop in re.findall(r'C: "OP",(\d+),(\d+), "(Lcl \w+)"', conns):
        curvenode_prop[int(cid)] = (models[int(mid)], prop)

    curve_to_node = {}
    for cid, nid, axis in re.findall(r'C: "OP",(\d+),(\d+), "d\|([XYZ])"', conns):
        curve_to_node[int(cid)] = (int(nid), axis)

    parent_of = {}
    for a, b in re.findall(r'C: "OO",(\d+),(\d+)', conns):
        a, b = int(a), int(b)
        if a in models:
            parent_of[models[a]] = models.get(b)

    # curve id -> values
    values = {}
    for block in re.finditer(
            r"AnimationCurve: (\d+), \"AnimCurve::\", \"\" \{(.*?)\n\t\}", objects, re.S):
        cid = int(block.group(1))
        body = block.group(2)
        vals = re.search(r"KeyValueFloat: \*\d+ \{\s*a: ([^\n]+)", body).group(1)
        values[cid] = [float(v) for v in vals.split(",")]

    tracks = {}
    for cid, (nid, axis) in curve_to_node.items():
        if nid not in curvenode_prop:
            continue
        bone, prop = curvenode_prop[nid]
        tracks.setdefault(bone, {}).setdefault(prop, {})[axis] = values[cid]

    order = [models[mid] for mid in sorted(models)]
    return order, parent_of, tracks


def euler_xyz_to_quat(rx, ry, rz):
    """Inverse of rig.quat_to_euler_xyz: R = Rz * Ry * Rx."""
    import math
    hx, hy, hz = math.radians(rx) / 2, math.radians(ry) / 2, math.radians(rz) / 2
    qx = (math.sin(hx), 0.0, 0.0, math.cos(hx))
    qy = (0.0, math.sin(hy), 0.0, math.cos(hy))
    qz = (0.0, 0.0, math.sin(hz), math.cos(hz))
    return R.qmul(qz, R.qmul(qy, qx))


def check(path, rig, frames, tol=0.05, extra_root=None):
    """frames: the baked (local_rots, local_trans) list. -> (ok, worst_cm)

    extra_root, when the file was written with one, is expected to sit above
    `root` and to be keyed to identity -- so it must not move any joint, which
    is exactly what comparing the FK result against the baked pose proves.
    """
    order, parent_of, tracks = parse(path)

    missing = [b["name"] for b in rig.bones if b["name"] not in tracks]
    if missing:
        raise AssertionError("FBX is missing tracks for: %s" % missing[:5])
    if extra_root:
        if extra_root not in tracks:
            raise AssertionError("FBX has no track for extra root %r" % extra_root)
        if parent_of.get(extra_root) is not None:
            raise AssertionError("extra root %r is not the top of the hierarchy" % extra_root)
    for bone in rig.bones:
        name, parent = bone["name"], bone["parent"]
        expect = rig.bones[parent]["name"] if parent >= 0 else extra_root
        if parent_of.get(name) != expect:
            raise AssertionError("FBX parent of %s is %r, rig says %r"
                                 % (name, parent_of.get(name), expect))

    worst = 0.0
    for f, (rots, trans) in enumerate(frames):
        local_r, local_t = [], []
        for b, bone in enumerate(rig.bones):
            t = tracks[bone["name"]]["Lcl Translation"]
            r = tracks[bone["name"]]["Lcl Rotation"]
            # what Unreal's FFbxDataConverter would hand the engine
            local_t.append((t["X"][f], -t["Y"][f], t["Z"][f]))
            q = euler_xyz_to_quat(r["X"][f], r["Y"][f], r["Z"][f])
            local_r.append((q[0], -q[1], q[2], -q[3]))
        got_q, got_t = rig.forward_kinematics(local_r, local_t)
        want_q, want_t = rig.forward_kinematics(rots, trans)
        for a, b in zip(got_t, want_t):
            worst = max(worst, R.vlen(R.vsub(a, b)))
    return worst <= tol, worst
