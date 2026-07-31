#!/usr/bin/env python3
"""
Extract the 65-bone animation rig out of FModel/CUE4Parse JSON dumps.

Inputs (JSON exports, not shipped in this repo):
  SK_PalHuman_Skeleton.json   the Skeleton asset -> reference skeleton + bone tree
  AS_Player_Female_*.json     any AnimSequence on that skeleton -> the track set

Why an AnimSequence is needed: SK_PalHuman_Skeleton carries 4079 bones (every
costume/NPC/hair variant merged into one master skeleton). A player AnimSequence
drives 65 of them, listed in CompressedTrackToSkeletonMapTable. That subset --
not the 4079 -- is the rig a player clip is expected to author.

Output: rig_palhuman.json
  bones[]                  name, parent (index into bones[]), ref local T/R/S
  meta.frame_rate          from the reference clip's TargetFrameRate
  meta.translation_retarget per-bone mode from the skeleton's BoneTree; only
                           root/pelvis are AnimationScaled (translation actually
                           read from the clip), the rest are Skeleton (translation
                           taken from the target mesh's ref pose, so authored
                           translation on them is ignored at runtime)
"""

import argparse
import json
import os
import sys


def load_export(path, type_name):
    with open(path, "r", encoding="utf-8") as fh:
        blob = json.load(fh)
    for entry in blob:
        if entry.get("Type") == type_name:
            return entry
    raise SystemExit("no %s object found in %s" % (type_name, path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skeleton_json")
    ap.add_argument("anim_json", help="reference AnimSequence for the track set")
    ap.add_argument("-o", "--out", default=os.path.join(os.path.dirname(__file__), "rig_palhuman.json"))
    args = ap.parse_args()

    skel = load_export(args.skeleton_json, "Skeleton")
    anim = load_export(args.anim_json, "AnimSequence")

    info = skel["ReferenceSkeleton"]["FinalRefBoneInfo"]
    pose = skel["ReferenceSkeleton"]["FinalRefBonePose"]
    tree = skel["Properties"]["BoneTree"]
    tracks = anim["CompressedTrackToSkeletonMapTable"]

    # skeleton bone index -> index within the extracted rig
    remap = {b: i for i, b in enumerate(tracks)}

    bones = []
    for skel_idx in tracks:
        src = pose[skel_idx]
        parent_skel = info[skel_idx]["ParentIndex"]
        if parent_skel >= 0 and parent_skel not in remap:
            raise SystemExit(
                "bone %s has parent %s outside the track set -- rig is not a closed hierarchy"
                % (info[skel_idx]["Name"], info[parent_skel]["Name"]))
        rot, trans, scale = src["Rotation"], src["Translation"], src["Scale3D"]
        bones.append({
            "name": info[skel_idx]["Name"],
            "parent": remap[parent_skel] if parent_skel >= 0 else -1,
            "skeleton_index": skel_idx,
            "t": [trans["X"], trans["Y"], trans["Z"]],
            "q": [rot["X"], rot["Y"], rot["Z"], rot["W"]],
            "s": [scale["X"], scale["Y"], scale["Z"]],
            "retarget": tree[skel_idx]["TranslationRetargetingMode"].split("::")[-1],
        })

    rate = anim["Properties"].get("TargetFrameRate", {})
    out = {
        "meta": {
            "skeleton": skel["Name"],
            "skeleton_guid": skel.get("Guid"),
            "reference_clip": anim["Name"],
            "retarget_source": anim["Properties"].get("RetargetSource"),
            "frame_rate": rate.get("Numerator", 30) / rate.get("Denominator", 1),
            "bone_count": len(bones),
            # Established by inspecting the reference pose: ball_l sits at +Y of
            # foot_l (toes point +Y) and hand_l sits at +X of the chest.
            "space": {"forward": "+Y", "left": "+X", "up": "+Z", "units": "cm"},
        },
        "bones": bones,
    }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
    sys.stderr.write("wrote %s (%d bones)\n" % (args.out, len(bones)))


if __name__ == "__main__":
    main()
