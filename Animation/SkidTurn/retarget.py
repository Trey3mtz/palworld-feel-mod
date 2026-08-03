#!/usr/bin/env python3
"""
Retarget a baked clip onto a skeleton read from someone else's FBX.

    python3 retarget.py path/to/SK_Player_Female.fbx

The clips are authored against the game's SK_PalHuman_Skeleton reference pose.
A skeleton round-tripped through Blender is the same character but not the same
rig: measured on the file this was written for, it is rotated 90 degrees about
Z, stored in metres with the unit conversion parked on the Armature node as a
100x scale, has every bone's local axes re-derived by Blender, and rests in a
T-pose where the game skeleton rests in an A-pose. Local rotations authored
against one are meaningless on the other.

What survives all of that is the SHAPE: bone lengths here match the game rig to
under a millimetre, and every joint sits in the same place once the 90 degree
rotation is taken out. So the transfer is done in three steps:

  1. G, the space map, fitted from joint positions on the bones whose rest is
     identical in both rigs (pelvis, spine, legs). Fitting it on the arms would
     let the A/T-pose difference contaminate it -- 34cm at the hand.
  2. Per bone, the rotation its rest needs to reproduce the GAME rig's rest.
     This is what separates "Blender renamed my axes" from "this rig rests in a
     T-pose", and only the first should be corrected for.
  3. Per frame, place each bone at the world orientation the clip asks for,
     expressed through that correction, and let POSITION follow from the target
     rig's own bone offsets -- the same rotation-driven rule the shipped
     skeleton uses via Skeleton translation retargeting.

Transferring the pose as a deformation delta instead is the obvious approach
and is wrong when the rests differ: it preserves motion relative to each rig's
own rest, so a T-pose rig plays the arms 45 degrees high. Measured: 49cm at the
fingertips. The rotation-driven route above lands every joint within 1.6mm.

Output is written in the SKELETON FILE'S OWN conventions -- its axis header,
its units, its node tree, including the Armature node and its transform -- so
Unreal applies the same import conversion to the animation as it did to the
skeleton, and the two cannot disagree.
"""

import argparse
import math
import os

import fbx_ascii
import foreign_rig as FR
import poses
import rig as R

# Bones whose reference pose is identical in both rigs. The arms are excluded
# on purpose: the game skeleton rests in an A-pose and the exported mesh in a
# T-pose, a ~34cm difference at the hand that would otherwise be absorbed into
# the fitted scale.
STABLE = ["root", "pelvis", "spine_01", "spine_02", "spine_03",
          "thigh_l", "calf_l", "foot_l", "ball_l", "thigh_twist_01_l", "calf_twist_01_l",
          "thigh_r", "calf_r", "foot_r", "ball_r", "thigh_twist_01_r", "calf_twist_01_r"]

# UE's FFbxDataConverter flips Y between FBX space and its own. Applying it as
# a matrix conjugation moves a whole transform between the two, and it is its
# own inverse.
FLIP_Y = [[1.0, 0, 0, 0], [0, -1.0, 0, 0], [0, 0, 1.0, 0], [0, 0, 0, 1.0]]


def ue_from_fbx(m):
    return FR.mat_mul(FLIP_Y, FR.mat_mul(m, FLIP_Y))


fbx_from_ue = ue_from_fbx           # involution


def solve_map(game, foreign, bones=None):
    """Similarity taking game-rig space to the foreign rig's space (UE side)."""
    bones = [b for b in (bones or STABLE) if b in foreign.index and b in game.index]
    src = [game.ref_world_t[game.index[n]] for n in bones]
    dst = [FR.mat_translation(ue_from_fbx(foreign.world[foreign.index[n]])) for n in bones]
    return FR.solve_similarity(src, dst) + (bones,)


def procrustes_rotation(src, dst):
    """Rotation best taking the vectors in src onto those in dst (Kabsch)."""
    h = [[sum(s[i] * d[j] for s, d in zip(src, dst)) for j in range(3)] for i in range(3)]
    u, _sing, vt = FR._svd3(h)
    rot = [[sum(vt[k][i] * u[j][k] for k in range(3)) for j in range(3)] for i in range(3)]
    if FR._det3(rot) < 0:
        vt = [vt[0], vt[1], [-c for c in vt[2]]]
        rot = [[sum(vt[k][i] * u[j][k] for k in range(3)) for j in range(3)] for i in range(3)]
    m = FR.mat_identity()
    for i in range(3):
        for j in range(3):
            m[i][j] = rot[i][j]
    return FR.mat_to_quat(m)[0]


def align_rest(game, foreign, G):
    """World rotation each foreign bone needs to reproduce the GAME rig's rest.

    This is the piece that makes the whole thing work. B_them carries two
    unrelated things at once: the axis convention Blender invented, and the
    fact that this skeleton rests in a T-pose where the game's rests in an
    A-pose. Only the first should be corrected for; baking in the second plays
    the arms 45 degrees high and puts the fingertips 49cm out.

    Solved root-downwards. Each bone starts from its parent's correction with
    its own rest offset kept, which is exact wherever the two rests agree, and
    is then re-aimed at where the game rig actually puts its children. Bones
    with two or more children that are not collinear (the hand, the pelvis) get
    a full Procrustes fit on those children instead, which pins the roll down
    as well -- an aim-only fit leaves the roll free, and a wrongly rolled hand
    throws the fingers several centimetres out.

    Fitting a bone against its whole SUBTREE looks tempting and is wrong: for
    anything above the shoulder the subtree straddles the very joint where the
    two rests differ, so no single rotation fits and the compromise poisons
    everything below it.
    """
    g_rot = FR.mat_mul(G, mat_scale_inverse(G))
    want = {}
    for name in game.names:
        if name in foreign.index:
            want[name] = FR.mat_point(g_rot, game.ref_world_t[game.index[name]])

    them_pos = [FR.mat_translation(ue_from_fbx(m)) for m in foreign.world]
    them_rot = [FR.mat_to_quat(ue_from_fbx(m))[0] for m in foreign.world]

    kids = {}
    for i, p in enumerate(foreign.parents):
        if p >= 0:
            kids.setdefault(p, []).append(i)

    out = {}
    for fi in range(len(foreign.names)):            # parents precede children
        name = foreign.names[fi]
        parent = foreign.parents[fi]
        pname = foreign.names[parent] if parent >= 0 else None

        if pname in out and out[pname] is not None:
            inherited = R.qmul(out[pname], R.qmul(R.qconj(them_rot[parent]), them_rot[fi]))
        else:
            inherited = them_rot[fi]

        if name not in want:
            out[name] = inherited
            continue

        pairs = []
        for c in kids.get(fi, ()):
            cname = foreign.names[c]
            if cname not in want:
                continue
            v_local = R.qrot(R.qconj(them_rot[fi]), R.vsub(them_pos[c], them_pos[fi]))
            v_world = R.vsub(want[cname], want[name])
            if R.vlen(v_local) > 1e-4 and R.vlen(v_world) > 1e-4:
                pairs.append((v_local, v_world))

        # Two candidates, and the children decide. A Procrustes fit uses all of
        # them but goes degenerate when they are nearly in line; re-aiming the
        # inherited frame always hits the first child but leaves the roll where
        # the parent put it. Scoring both against the actual child positions
        # picks correctly per bone instead of trusting a threshold.
        if not pairs:
            out[name] = inherited
            continue
        aim_now = R.vnorm(R.qrot(inherited, pairs[0][0]))
        candidates = [R.qmul(_arc(aim_now, R.vnorm(pairs[0][1])), inherited)]
        if len(pairs) >= 2:
            candidates.append(procrustes_rotation([a for a, _ in pairs],
                                                  [b for _, b in pairs]))
        out[name] = min(candidates, key=lambda q: _fit_error(q, pairs))
    return out


def _fit_error(q, pairs):
    """Total distance between where a candidate rotation sends each child rest
    offset and where that child actually sits on the game rig."""
    return sum(R.vlen(R.vsub(R.qrot(q, a), b)) for a, b in pairs)


def _spread(pairs):
    """How non-collinear a bone's child directions are.

    Kabsch on two nearly parallel vectors is degenerate and does not merely
    leave the roll free -- it returns a rotation that misses the aim too. The
    calf, whose two children (the twist bone and the foot) are almost in line,
    came back 70cm out before this was gated.
    """
    a = R.vnorm(pairs[0][0])
    worst = 0.0
    for v, _ in pairs[1:]:
        b = R.vnorm(v)
        worst = max(worst, R.vlen(_cross(a, b)))
    return worst


def frame_change(game, foreign, G):
    """Per-bone F, taking a game-rig bone frame to the same bone's frame there."""
    g_rot = FR.mat_mul(G, mat_scale_inverse(G))
    star = align_rest(game, foreign, G)

    out = {}
    for name in game.names:
        if name not in foreign.index:
            continue
        fi, gi = foreign.index[name], game.index[name]
        q_star = star[name]
        b_game = FR.mat_from_trs(game.ref_world_t[gi], game.ref_world_q[gi], (1, 1, 1))
        aligned = FR.mat_from_trs((0.0, 0.0, 0.0), q_star, (1, 1, 1))
        out[name] = FR.mat_mul(FR.mat_inverse(FR.mat_mul(g_rot, b_game)), aligned)
    return out, sum(1 for n in out if n in star)


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _arc(a, b):
    """Shortest rotation taking unit vector a onto unit vector b."""
    c = _cross(a, b)
    w = 1.0 + sum(x * y for x, y in zip(a, b))
    if w < 1e-9:
        axis = (1.0, 0.0, 0.0) if abs(a[0]) < 0.9 else (0.0, 1.0, 0.0)
        return R.axis_angle(R.vnorm(_cross(a, axis)), 180.0)
    return R.qnorm((c[0], c[1], c[2], w))


# Only these take their translation from the clip; every other bone keeps its
# own rig's bone offset, so limb LENGTHS come from the target skeleton. This is
# the same split the shipped skeleton uses (root/pelvis AnimationScaled, the
# rest Skeleton) and it is what makes the pose survive a different bind pose.
TRANSLATED = ("root", "pelvis")


def retarget_clip(game, foreign, wqs, wts, G):
    """-> frames[f][node] = (translation, euler_degrees, scale), in FBX space.

    Rotation-driven: each bone is placed at the world ORIENTATION the clip
    asks for, expressed in that bone's own frame, and its POSITION follows
    from the target rig's own bone offsets. Transferring position directly
    would carry the A-pose/T-pose difference into the result -- measured at
    49cm of drift at the fingertips on this skeleton.
    """
    n_nodes = len(foreign.names)
    frames_of, _ = frame_change(game, foreign, G)
    g_rot = FR.mat_mul(G, mat_scale_inverse(G))          # rotation part of G

    out = []
    for f in range(len(wqs)):
        world = [None] * n_nodes
        frame = [None] * n_nodes
        for node in range(n_nodes):                       # parents precede children
            name = foreign.names[node]
            parent = foreign.parents[node]
            parent_world = world[parent] if parent >= 0 else None

            if name in frames_of:
                gi = game.index[name]
                m_game = FR.mat_from_trs(wts[f][gi], wqs[f][gi], (1, 1, 1))
                target_ue = FR.mat_mul(FR.mat_mul(g_rot, m_game), frames_of[name])
                q_world, _ = FR.mat_to_quat(fbx_from_ue(target_ue))
                if name in TRANSLATED:
                    # land the joint exactly where the clip puts it
                    want = FR.mat_translation(fbx_from_ue(
                        FR.mat_mul(G, FR.mat_from_trs(wts[f][gi], wqs[f][gi], (1, 1, 1)))))
                    local_t = (FR.mat_point(FR.mat_inverse(parent_world), want)
                               if parent_world else want)
                else:
                    local_t = FR.mat_translation(foreign.local[node])
                local_s = FR.mat_scale(foreign.local[node])
                q_local = (R.qmul(R.qconj(FR.mat_to_quat(parent_world)[0]), q_world)
                           if parent_world else q_world)
                local = FR.mat_from_trs(local_t, q_local, local_s)
            else:
                # sockets, the Armature, anything we do not animate: keep the
                # rest offset so nothing detaches from its parent
                local = foreign.local[node]
                q_local, local_s = FR.mat_to_quat(local)
                local_t = FR.mat_translation(local)

            world[node] = FR.mat_mul(parent_world, local) if parent_world else local
            frame[node] = (local_t, R.quat_to_euler_xyz(q_local), tuple(local_s))
        out.append(frame)
    return out


def mat_scale_inverse(m):
    """Matrix that divides out m's uniform scale, leaving rotation+translation."""
    s = FR.mat_scale(m)[0]
    inv = FR.mat_identity()
    for i in range(3):
        inv[i][i] = 1.0 / s
    return inv


def check(foreign, frames, game, wts, G, clip_name):
    """Re-run FK on the written locals and confirm EVERY joint lands where the
    clip puts it on the game rig, mapped through G. Checking only the bones G
    was fitted on would have hidden 49cm of drift in the hands."""
    worst = 0.0
    for f, frame in enumerate(frames):
        world = [None] * len(foreign.names)
        for i in range(len(foreign.names)):
            t, e, s = frame[i]
            local = FR.mat_from_trs(t, FR.euler_to_quat(e), s)
            p = foreign.parents[i]
            world[i] = local if p < 0 else FR.mat_mul(world[p], local)
        for name in game.names:
            if name not in foreign.index:
                continue
            got = FR.mat_translation(ue_from_fbx(world[foreign.index[name]]))
            want = FR.mat_point(G, wts[f][game.index[name]])
            worst = max(worst, math.dist(got, want))
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skeleton_fbx", help="the FBX the skeleton was imported from")
    ap.add_argument("--clip", choices=sorted(poses.CLIPS) + ["all"], default="all")
    ap.add_argument("-o", "--out", default=None)
    args = ap.parse_args()

    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "out", "retargeted")
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    game = R.Rig()
    foreign = FR.ForeignRig(args.skeleton_fbx)
    G, err, used = solve_map(game, foreign)
    q, lens = FR.mat_to_quat(G)
    ang = 2 * math.degrees(math.acos(max(-1.0, min(1.0, abs(q[3])))))
    print("skeleton: %s" % os.path.basename(args.skeleton_fbx))
    print("  %d nodes, %d of our 65 bones present"
          % (len(foreign.names), sum(1 for n in game.names if n in foreign.index)))
    print("  space map fitted on %d pose-identical bones:" % len(used))
    print("     scale %.6f, rotation %.3f deg, residual %.6f cm" % (lens[0], ang, err))

    missing = [n for n in game.names if n not in foreign.index]
    if missing:
        print("  NOT in that skeleton (left unanimated): %s" % ", ".join(missing))

    settings = {}
    for key in ("UpAxis", "UpAxisSign", "FrontAxis", "FrontAxisSign",
                "CoordAxis", "CoordAxisSign", "UnitScaleFactor"):
        if key in foreign.raw["settings"]:
            settings[key] = foreign.raw["settings"][key]

    names = sorted(poses.CLIPS) if args.clip == "all" else [args.clip]
    for name in names:
        c = poses.CLIPS[name]()
        rots, trans, wqs, wts = c.bake(game)
        frames = retarget_clip(game, foreign, wqs, wts, G)
        worst = check(foreign, frames, game, wts, G, c.name)
        # Emit the skeleton nodes only. The source file also carries the mesh
        # node; an animation-only FBX has no business shipping geometry, and a
        # Mesh node attribute in a skeleton hierarchy is malformed anyway.
        keep = [i for i, k in enumerate(foreign.kind) if k != "Mesh"]
        remap = {old_i: new_i for new_i, old_i in enumerate(keep)}
        names = [foreign.names[i] for i in keep]
        parents = [remap.get(foreign.parents[i], -1) for i in keep]
        kinds = [foreign.kind[i] for i in keep]
        kept_frames = [[fr[i] for i in keep] for fr in frames]

        path = os.path.join(out_dir, c.name + ".fbx")
        fbx_ascii.write_generic(path, c.name, names, parents,
                                kept_frames, c.fps, settings, kinds)
        print("  %-34s %2d frames  round-trip %s (worst %.4f cm)"
              % (c.name, c.frame_count, "OK" if worst < 0.5 else "FAILED", worst))
        if worst >= 0.5:
            raise SystemExit("retarget verification failed")
    print("\nwrote %s" % out_dir)


if __name__ == "__main__":
    main()
