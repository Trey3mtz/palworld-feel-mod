#!/usr/bin/env python3
"""
GLB writer -- the same clip on a blocky proxy body, viewable anywhere.

The FBX is what Unreal eats, but nothing outside Unreal can show it. This
writes the identical baked transforms as a glTF 2.0 binary so the motion can
be checked in a browser viewer, Blender, or the OS model viewer before anyone
opens the editor. It is a preview artefact, not an import path.

No skinning: every bone node carries a child box scaled to that bone's length,
so plain node animation drives the whole body. Boxes are tinted by chain
(left warm / right cool / spine pale) to match the PNG contact sheets.

glTF is right-handed, Y up, metres; the rig is Unreal-style left-handed, Z up,
centimetres. Swapping Y and Z flips handedness, which is why the quaternion
also has to flip sign on W.
"""

import json
import math
import struct

import rig as R

CM_TO_M = 0.01
BONE_THICKNESS = 0.028      # metres


def to_gltf_pos(p):
    return (p[0] * CM_TO_M, p[2] * CM_TO_M, p[1] * CM_TO_M)


def to_gltf_quat(q):
    # (x, y, z, w) -> (x, z, y, -w): the Y/Z swap is a reflection, so the
    # rotation angle changes sign along with the axis permutation.
    return (q[0], q[2], q[1], -q[3])


def _unit_box():
    """A box spanning x in 0..1, y/z in -0.5..0.5 -- one bone's worth."""
    v = []
    for x in (0.0, 1.0):
        for y in (-0.5, 0.5):
            for z in (-0.5, 0.5):
                v.append((x, y, z))
    # indices into the order above: 0=(0,-,-) 1=(0,-,+) 2=(0,+,-) 3=(0,+,+)
    #                               4=(1,-,-) 5=(1,-,+) 6=(1,+,-) 7=(1,+,+)
    idx = [0, 1, 3, 0, 3, 2,   4, 6, 7, 4, 7, 5,
           0, 4, 5, 0, 5, 1,   2, 3, 7, 2, 7, 6,
           0, 2, 6, 0, 6, 4,   1, 5, 7, 1, 7, 3]
    return v, idx


def _chain_material(name):
    side = name[-2:]
    if any(name.startswith(p) for p in ("thigh", "calf", "foot", "ball")):
        return 1 if side == "_l" else 2
    if any(name.startswith(p) for p in ("clavicle", "upperarm", "lowerarm", "hand")):
        return 3 if side == "_l" else 4
    return 0


def _quat_from_x_to(direction):
    """Rotation taking +X onto `direction` (already normalised, glTF space)."""
    ax, ay, az = 1.0, 0.0, 0.0
    dx, dy, dz = direction
    dot = ax * dx + ay * dy + az * dz
    if dot > 0.999999:
        return (0.0, 0.0, 0.0, 1.0)
    if dot < -0.999999:
        return (0.0, 0.0, 1.0, 0.0)
    cx, cy, cz = ay * dz - az * dy, az * dx - ax * dz, ax * dy - ay * dx
    w = 1.0 + dot
    n = math.sqrt(cx * cx + cy * cy + cz * cz + w * w)
    return (cx / n, cy / n, cz / n, w / n)


class _Buffer(object):
    def __init__(self):
        self.data = bytearray()
        self.views = []
        self.accessors = []

    def _view(self, payload, target=None):
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data += payload
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(payload)}
        if target:
            view["target"] = target
        self.views.append(view)
        return len(self.views) - 1

    def add(self, values, kind, comp_type, fmt, target=None, minmax=False):
        flat = []
        for v in values:
            flat.extend(v if isinstance(v, (list, tuple)) else [v])
        payload = struct.pack("<%d%s" % (len(flat), fmt), *flat)
        view = self._view(payload, target)
        acc = {"bufferView": view, "componentType": comp_type,
               "count": len(values), "type": kind}
        if minmax:
            n = len(values[0]) if isinstance(values[0], (list, tuple)) else 1
            cols = [[v[i] for v in values] for i in range(n)] if n > 1 else [list(values)]
            acc["min"] = [min(c) for c in cols]
            acc["max"] = [max(c) for c in cols]
        self.accessors.append(acc)
        return len(self.accessors) - 1


def write(path, rig, clip_name, frames, fps=30.0):
    buf = _Buffer()
    verts, idx = _unit_box()
    acc_pos = buf.add(verts, "VEC3", 5126, "f", target=34962, minmax=True)
    acc_idx = buf.add(idx, "SCALAR", 5123, "H", target=34963)

    palette = [(0.88, 0.90, 0.94), (1.00, 0.48, 0.24), (0.23, 0.59, 1.00),
               (1.00, 0.81, 0.51), (0.59, 0.84, 1.00)]
    materials = [{"pbrMetallicRoughness": {"baseColorFactor": list(c) + [1.0],
                                           "metallicFactor": 0.0,
                                           "roughnessFactor": 0.75},
                  "name": n}
                 for c, n in zip(palette, ("spine", "leg_l", "leg_r", "arm_l", "arm_r"))]
    meshes = [{"primitives": [{"attributes": {"POSITION": acc_pos},
                               "indices": acc_idx, "material": m}]}
              for m in range(len(materials))]

    # ---- nodes: one per bone, plus a box child for every bone with length --
    nodes = []
    bone_node = {}
    for b, bone in enumerate(rig.bones):
        bone_node[b] = len(nodes)
        nodes.append({"name": bone["name"], "children": []})

    for b, bone in enumerate(rig.bones):
        parent = bone["parent"]
        if parent >= 0:
            nodes[bone_node[parent]]["children"].append(bone_node[b])
        # the box for the PARENT bone spans the parent's origin to this one
        offset = to_gltf_pos(rig.local_t[b])
        length = math.sqrt(sum(c * c for c in offset))
        if parent >= 0 and length > 0.005:
            direction = tuple(c / length for c in offset)
            nodes.append({
                "name": bone["name"] + "_box",
                "mesh": _chain_material(bone["name"]),
                "rotation": list(_quat_from_x_to(direction)),
                "scale": [length, BONE_THICKNESS, BONE_THICKNESS],
            })
            nodes[bone_node[parent]]["children"].append(len(nodes) - 1)

    for n in nodes:
        if not n.get("children"):
            n.pop("children", None)

    # ---- animation --------------------------------------------------------
    times = [round(f / fps, 6) for f in range(len(frames))]
    acc_time = buf.add(times, "SCALAR", 5126, "f", minmax=True)

    channels, samplers = [], []
    for b, bone in enumerate(rig.bones):
        trans = [to_gltf_pos(f[1][b]) for f in frames]
        rots = [to_gltf_quat(f[0][b]) for f in frames]
        for kind, values, ctype in (("translation", trans, "VEC3"),
                                    ("rotation", rots, "VEC4")):
            acc = buf.add(values, ctype, 5126, "f")
            samplers.append({"input": acc_time, "output": acc, "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1,
                             "target": {"node": bone_node[b], "path": kind}})

    gltf = {
        "asset": {"version": "2.0", "generator": "TheCameraIsAPal SkidTurn builder"},
        "scene": 0,
        "scenes": [{"nodes": [bone_node[0]]}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "animations": [{"name": clip_name, "channels": channels, "samplers": samplers}],
        "accessors": buf.accessors,
        "bufferViews": buf.views,
        "buffers": [{"byteLength": len(buf.data)}],
    }

    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
    bin_bytes = bytes(buf.data)
    bin_bytes += b"\x00" * ((4 - len(bin_bytes) % 4) % 4)

    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(json_bytes), 0x4E4F534A))
        fh.write(json_bytes)
        fh.write(struct.pack("<II", len(bin_bytes), 0x004E4942))
        fh.write(bin_bytes)
    return path
