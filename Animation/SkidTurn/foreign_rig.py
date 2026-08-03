#!/usr/bin/env python3
"""
Load a skeleton out of somebody else's FBX and solve the map onto our rig.

The clips are authored against the game's SK_PalHuman_Skeleton reference pose.
A skeleton round-tripped through a DCC keeps the bone NAMES but not the bone
FRAMES: Blender re-derives every bone's local axes on export (bones end up
running along local X), works in metres, and parks the unit conversion and the
up-axis fix on the Armature node as scale and rotation. Local rotations
authored against one rig are meaningless on the other.

What survives the round trip is the SHAPE -- where each joint sits in space.
So this solves a similarity transform G between the two rigs from their joint
positions, then retargets by deformation rather than by local rotation:

    D(b,t) = M_game(b,t) * inverse(B_game(b))       deformation, game space
    M_them(b,t) = G * D(b,t) * inverse(G) * B_them(b)

D is what the skin actually sees, and conjugating it by G moves it into the
other rig's space. Bone frames, bone lengths and units all cancel, because
both bind poses appear as their own rig's B.
"""

import math

import fbx_binary as FB
import rig as R

# ---------------------------------------------------------------------------
# 4x4 affine helpers, row-major nested tuples, column-vector convention
# ---------------------------------------------------------------------------


def mat_identity():
    return [[1.0, 0, 0, 0], [0, 1.0, 0, 0], [0, 0, 1.0, 0], [0, 0, 0, 1.0]]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_from_trs(t, q, s):
    x, y, z, w = q
    rot = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
           [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
           [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    m = mat_identity()
    for i in range(3):
        for j in range(3):
            m[i][j] = rot[i][j] * s[j]
        m[i][3] = t[i]
    return m


def mat_point(m, p):
    return tuple(m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3))


def mat_translation(m):
    return (m[0][3], m[1][3], m[2][3])


def mat_inverse(m):
    """Inverse of an affine matrix whose linear part may carry uniform scale."""
    lin = [[m[i][j] for j in range(3)] for i in range(3)]
    det = (lin[0][0] * (lin[1][1] * lin[2][2] - lin[1][2] * lin[2][1])
           - lin[0][1] * (lin[1][0] * lin[2][2] - lin[1][2] * lin[2][0])
           + lin[0][2] * (lin[1][0] * lin[2][1] - lin[1][1] * lin[2][0]))
    if abs(det) < 1e-20:
        raise ValueError("singular matrix")
    inv = [[0.0] * 4 for _ in range(4)]
    for i in range(3):
        for j in range(3):
            a = lin[(j + 1) % 3][(i + 1) % 3] * lin[(j + 2) % 3][(i + 2) % 3]
            b = lin[(j + 1) % 3][(i + 2) % 3] * lin[(j + 2) % 3][(i + 1) % 3]
            inv[i][j] = (a - b) / det
    t = mat_translation(m)
    for i in range(3):
        inv[i][3] = -(inv[i][0] * t[0] + inv[i][1] * t[1] + inv[i][2] * t[2])
    inv[3] = [0.0, 0.0, 0.0, 1.0]
    return inv


def mat_to_quat(m):
    """Rotation part -> quaternion, tolerating uniform scale."""
    cols = [[m[i][j] for i in range(3)] for j in range(3)]
    lens = [math.sqrt(sum(c * c for c in col)) or 1.0 for col in cols]
    r = [[m[i][j] / lens[j] for j in range(3)] for i in range(3)]
    tr = r[0][0] + r[1][1] + r[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        q = ((r[2][1] - r[1][2]) / s, (r[0][2] - r[2][0]) / s, (r[1][0] - r[0][1]) / s, 0.25 * s)
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        s = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2
        q = (0.25 * s, (r[0][1] + r[1][0]) / s, (r[0][2] + r[2][0]) / s, (r[2][1] - r[1][2]) / s)
    elif r[1][1] > r[2][2]:
        s = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2
        q = ((r[0][1] + r[1][0]) / s, 0.25 * s, (r[1][2] + r[2][1]) / s, (r[0][2] - r[2][0]) / s)
    else:
        s = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2
        q = ((r[0][2] + r[2][0]) / s, (r[1][2] + r[2][1]) / s, 0.25 * s, (r[1][0] - r[0][1]) / s)
    return R.qnorm(q), lens


def mat_scale(m):
    return [math.sqrt(sum(m[i][j] ** 2 for i in range(3))) for j in range(3)]


def euler_to_quat(deg, order=0):
    """FBX Euler (degrees) -> quaternion. Order 0 (eEulerXYZ) is R = Rz*Ry*Rx."""
    hx, hy, hz = (math.radians(d) / 2 for d in deg)
    qx = (math.sin(hx), 0.0, 0.0, math.cos(hx))
    qy = (0.0, math.sin(hy), 0.0, math.cos(hy))
    qz = (0.0, 0.0, math.sin(hz), math.cos(hz))
    if order != 0:
        raise NotImplementedError("rotation order %d" % order)
    return R.qmul(qz, R.qmul(qy, qx))


# ---------------------------------------------------------------------------
# the foreign rig
# ---------------------------------------------------------------------------

class ForeignRig(object):
    """A skeleton read out of an arbitrary FBX, in that file's own space."""

    def __init__(self, path):
        self.raw = FB.read_skeleton(path)
        models, parent_of = self.raw["models"], self.raw["parent_of"]

        # depth-first so parents always precede children
        order, seen = [], set()

        def visit(uid):
            if uid in seen:
                return
            parent = parent_of.get(uid)
            if parent is not None and parent in models and parent not in seen:
                visit(parent)
            seen.add(uid)
            order.append(uid)

        for uid in models:
            visit(uid)

        self.uids = order
        self.index = {}
        self.names, self.parents, self.local = [], [], []
        for i, uid in enumerate(order):
            m = models[uid]
            self.index[m["name"]] = i
            self.names.append(m["name"])
            p = parent_of.get(uid)
            self.parents.append(order.index(p) if p in models else -1)
            self.local.append(mat_from_trs(m["lcl_t"], euler_to_quat(m["lcl_r"], m["rot_order"]),
                                           m["lcl_s"]))
        self.kind = [models[u]["kind"] for u in order]
        self.world = self._fk(self.local)

        # the file's own bind pose, when it has one -- authoritative for skinning
        self.bind = {}
        for uid, flat in self.raw["bind_pose"].items():
            if uid in self.index_by_uid:
                m = [[flat[c * 4 + r] for c in range(4)] for r in range(4)]  # column-major
                self.bind[self.index_by_uid[uid]] = m

    @property
    def index_by_uid(self):
        return {uid: i for i, uid in enumerate(self.uids)}

    def _fk(self, local):
        world = [None] * len(local)
        for i, p in enumerate(self.parents):
            world[i] = local[i] if p < 0 else mat_mul(world[p], local[i])
        return world

    def rest_world(self, name):
        i = self.index[name]
        return self.bind.get(i, self.world[i])


# ---------------------------------------------------------------------------
# solving the map between rigs
# ---------------------------------------------------------------------------

def solve_similarity(src_pts, dst_pts):
    """Least-squares similarity (uniform scale + rotation + translation).

    Kabsch with a scale term. Returns (matrix, rms_error_in_dst_units).
    """
    n = len(src_pts)
    cs = [sum(p[a] for p in src_pts) / n for a in range(3)]
    cd = [sum(p[a] for p in dst_pts) / n for a in range(3)]
    s = [[p[a] - cs[a] for a in range(3)] for p in src_pts]
    d = [[p[a] - cd[a] for a in range(3)] for p in dst_pts]

    h = [[sum(s[k][i] * d[k][j] for k in range(n)) for j in range(3)] for i in range(3)]
    u, sing, vt = _svd3(h)
    rot = [[sum(vt[k][i] * u[j][k] for k in range(3)) for j in range(3)] for i in range(3)]
    if _det3(rot) < 0:                       # reflection guard
        vt = [vt[0], vt[1], [-c for c in vt[2]]]
        rot = [[sum(vt[k][i] * u[j][k] for k in range(3)) for j in range(3)] for i in range(3)]

    var_s = sum(sum(c * c for c in row) for row in s)
    scale = sum(sing) / var_s if var_s > 1e-20 else 1.0

    m = mat_identity()
    for i in range(3):
        for j in range(3):
            m[i][j] = rot[i][j] * scale
        m[i][3] = cd[i] - sum(m[i][j] * cs[j] for j in range(3))

    err = 0.0
    for p, q in zip(src_pts, dst_pts):
        r = mat_point(m, p)
        err += sum((r[a] - q[a]) ** 2 for a in range(3))
    return m, math.sqrt(err / n)


def _det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def _svd3(a, iters=64):
    """Tiny Jacobi SVD for 3x3. Returns (U, singular values, V^T)."""
    ata = [[sum(a[k][i] * a[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    v = [[1.0 if i == j else 0.0 for j in range(3)] for i in range(3)]
    for _ in range(iters):
        off = sum(ata[i][j] ** 2 for i in range(3) for j in range(3) if i != j)
        if off < 1e-24:
            break
        for p in range(2):
            for q in range(p + 1, 3):
                if abs(ata[p][q]) < 1e-30:
                    continue
                theta = (ata[q][q] - ata[p][p]) / (2 * ata[p][q])
                t = (1 if theta >= 0 else -1) / (abs(theta) + math.sqrt(theta * theta + 1))
                c = 1 / math.sqrt(t * t + 1)
                s = t * c
                for k in range(3):
                    akp, akq = ata[k][p], ata[k][q]
                    ata[k][p], ata[k][q] = c * akp - s * akq, s * akp + c * akq
                for k in range(3):
                    apk, aqk = ata[p][k], ata[q][k]
                    ata[p][k], ata[q][k] = c * apk - s * aqk, s * apk + c * aqk
                for k in range(3):
                    vkp, vkq = v[k][p], v[k][q]
                    v[k][p], v[k][q] = c * vkp - s * vkq, s * vkp + c * vkq
    sing = [math.sqrt(max(0.0, ata[i][i])) for i in range(3)]
    u = [[0.0] * 3 for _ in range(3)]
    for j in range(3):
        col = [sum(a[i][k] * v[k][j] for k in range(3)) for i in range(3)]
        n = math.sqrt(sum(c * c for c in col)) or 1.0
        for i in range(3):
            u[i][j] = col[i] / n
    vt = [[v[j][i] for j in range(3)] for i in range(3)]
    return u, sing, vt
