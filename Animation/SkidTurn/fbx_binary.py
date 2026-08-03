#!/usr/bin/env python3
"""
Minimal binary FBX reader -- enough to recover a skeleton's rest pose.

Written to answer one question the ASCII writer cannot: what does the
skeleton the clip is actually being played on look like? A rig round-tripped
through a DCC keeps the bone NAMES but rarely the bone AXES, and can pick up a
unit scale and an up-axis rotation on the way through. Reading the real file
beats guessing at export settings.

Format (Kaydara FBX Binary):
  23-byte magic, 2 pad bytes, uint32 version, then a tree of records:
    EndOffset, NumProperties, PropertyListLen  (uint32 each, uint64 from 7500)
    NameLen (uint8), Name, properties, optional nested records,
    terminated by a null record of the same header width.
  Property types: Y i16, C bool, I i32, F f32, D f64, L i64,
                  f/d/l/i/b arrays (optionally zlib deflated), S string, R raw.
"""

import struct
import zlib


class Node(object):
    __slots__ = ("name", "props", "children")

    def __init__(self, name, props, children):
        self.name = name
        self.props = props
        self.children = children

    def find(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None

    def find_all(self, name):
        return [c for c in self.children if c.name == name]

    def __repr__(self):
        return "<%s props=%d kids=%d>" % (self.name, len(self.props), len(self.children))


def _read_prop(buf, pos):
    kind = buf[pos:pos + 1].decode("ascii")
    pos += 1
    if kind == "Y":
        return struct.unpack_from("<h", buf, pos)[0], pos + 2
    if kind == "C":
        return bool(buf[pos]), pos + 1
    if kind == "I":
        return struct.unpack_from("<i", buf, pos)[0], pos + 4
    if kind == "F":
        return struct.unpack_from("<f", buf, pos)[0], pos + 4
    if kind == "D":
        return struct.unpack_from("<d", buf, pos)[0], pos + 8
    if kind == "L":
        return struct.unpack_from("<q", buf, pos)[0], pos + 8
    if kind in "fdlib":
        count, encoding, comp_len = struct.unpack_from("<III", buf, pos)
        pos += 12
        payload = buf[pos:pos + comp_len]
        pos += comp_len
        if encoding == 1:
            payload = zlib.decompress(payload)
        fmt = {"f": "f", "d": "d", "l": "q", "i": "i", "b": "b"}[kind]
        return list(struct.unpack("<%d%s" % (count, fmt), payload)), pos
    if kind in "SR":
        length = struct.unpack_from("<I", buf, pos)[0]
        pos += 4
        data = buf[pos:pos + length]
        pos += length
        if kind == "S":
            return data.decode("utf-8", "replace"), pos
        return data, pos
    raise ValueError("unknown FBX property type %r at %d" % (kind, pos))


def parse(path):
    with open(path, "rb") as fh:
        buf = fh.read()
    if not buf.startswith(b"Kaydara FBX Binary"):
        raise ValueError("not a binary FBX: %s" % path)
    version = struct.unpack_from("<I", buf, 23)[0]
    wide = version >= 7500
    hdr = struct.Struct("<QQQ") if wide else struct.Struct("<III")
    null_len = 25 if wide else 13

    def read_records(pos, limit):
        out = []
        while pos < limit:
            if pos + hdr.size > limit:
                break
            end_offset, num_props, prop_len = hdr.unpack_from(buf, pos)
            if end_offset == 0:                      # null record: list terminator
                pos += null_len
                break
            name_len = buf[pos + hdr.size]
            p = pos + hdr.size + 1
            name = buf[p:p + name_len].decode("utf-8", "replace")
            p += name_len
            props = []
            for _ in range(num_props):
                value, p = _read_prop(buf, p)
                props.append(value)
            children = []
            if p < end_offset:                        # nested list present
                children = read_records(p, end_offset)
            out.append(Node(name, props, children))
            pos = end_offset
        return out

    return version, Node("root", [], read_records(27, len(buf)))


# ---------------------------------------------------------------------------
# skeleton extraction
# ---------------------------------------------------------------------------

def properties70(node):
    """P records -> {name: [values]}"""
    out = {}
    p70 = node.find("Properties70")
    if p70 is None:
        return out
    for p in p70.find_all("P"):
        if p.props:
            out[p.props[0]] = p.props[4:]
    return out


def read_skeleton(path):
    """-> (meta, models, connections)

    models: uid -> {name, kind, lcl_t, lcl_r, lcl_s, pre_rot, post_rot,
                    rot_off, rot_piv, scl_off, scl_piv, rot_order, inherit}
    """
    version, root = parse(path)

    settings = {}
    gs = root.find("GlobalSettings")
    if gs is not None:
        for k, v in properties70(gs).items():
            settings[k] = v[0] if len(v) == 1 else v

    models = {}
    objects = root.find("Objects")
    if objects is not None:
        for m in objects.find_all("Model"):
            uid = m.props[0]
            raw_name = m.props[1]
            name = raw_name.split("\x00")[0] if "\x00" in raw_name else raw_name
            props = properties70(m)

            def vec(key, default):
                v = props.get(key)
                return tuple(float(x) for x in v[:3]) if v and len(v) >= 3 else default

            models[uid] = {
                "name": name,
                "kind": m.props[2] if len(m.props) > 2 else "",
                "lcl_t": vec("Lcl Translation", (0.0, 0.0, 0.0)),
                "lcl_r": vec("Lcl Rotation", (0.0, 0.0, 0.0)),
                "lcl_s": vec("Lcl Scaling", (1.0, 1.0, 1.0)),
                "pre_rot": vec("PreRotation", (0.0, 0.0, 0.0)),
                "post_rot": vec("PostRotation", (0.0, 0.0, 0.0)),
                "rot_off": vec("RotationOffset", (0.0, 0.0, 0.0)),
                "rot_piv": vec("RotationPivot", (0.0, 0.0, 0.0)),
                "scl_off": vec("ScalingOffset", (0.0, 0.0, 0.0)),
                "scl_piv": vec("ScalingPivot", (0.0, 0.0, 0.0)),
                "rot_order": int(props.get("RotationOrder", [0])[0]) if props.get("RotationOrder") else 0,
                "inherit": int(props.get("InheritType", [0])[0]) if props.get("InheritType") else 1,
            }

    # A Model appears as the CHILD end of several OO records -- its parent
    # bone, but also its node attribute, its deformers, its materials. Only
    # the record whose other end is another Model is the hierarchy, and it
    # must not be overwritten by the others.
    parent_of = {}
    conns = root.find("Connections")
    if conns is not None:
        for c in conns.find_all("C"):
            if c.props and c.props[0] == "OO" and len(c.props) >= 3:
                child, parent = c.props[1], c.props[2]
                if child in models and parent in models:
                    parent_of[child] = parent
        for uid in models:
            parent_of.setdefault(uid, None)

    # bind pose: the authoritative rest transform for anything skinned
    bind = {}
    if objects is not None:
        for pose in objects.find_all("Pose"):
            for pn in pose.find_all("PoseNode"):
                node_uid = pn.find("Node")
                mat = pn.find("Matrix")
                if node_uid is not None and mat is not None and mat.props:
                    bind[node_uid.props[0]] = list(mat.props[0])

    # cluster link matrices: the same thing, from the skin side
    links = {}
    if objects is not None and conns is not None:
        deformer_of = {}
        for d in objects.find_all("Deformer"):
            if len(d.props) > 2 and d.props[2] == "Cluster":
                tl = d.find("TransformLink")
                if tl is not None and tl.props:
                    deformer_of[d.props[0]] = list(tl.props[0])
        for c in conns.find_all("C"):
            if c.props and c.props[0] == "OO" and len(c.props) >= 3:
                if c.props[1] in models and c.props[2] in deformer_of:
                    links[c.props[1]] = deformer_of[c.props[2]]

    return {
        "version": version,
        "settings": settings,
        "models": models,
        "parent_of": parent_of,
        "bind_pose": bind,
        "cluster_links": links,
    }
