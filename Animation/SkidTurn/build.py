#!/usr/bin/env python3
"""
Build the skid-turn clips.

    python3 build.py                 # sprint + walk -> out/
    python3 build.py --mirror        # ...plus the right-turn mirrors
    python3 build.py --clip sprint   # one clip
    python3 build.py --no-preview    # FBX only, skip the PNG sheets

Outputs per clip:
    out/<name>.fbx        skeleton-only animation, import onto SK_PalHuman_Skeleton
    out/<name>.glb        same motion on a blocky proxy mesh, for eyeballing
    out/<name>_side.png   contact sheets
    out/<name>_front.png
    out/<name>.json       joint positions per frame, for preview.html
    out/preview.html      self-contained scrubbable previewer for all clips
    out/report.txt        per-frame metrics for every clip
"""

import argparse
import json
import os

import clip as C
import fbx_ascii
import glb
import metrics
import poses
import preview
import render
import rig as R
import verify

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def build_clip(rig, c, args, report, previews):
    print("building %s" % c.name)
    rots, trans, wqs, wts = c.bake(rig, verbose=True)
    frames = list(zip(rots, trans))

    report.append("=" * 78)
    report.append("%s  --  %s" % (c.name, c.notes))
    report.append("%d frames @ %gfps = %.4fs, amplitude %.2f"
                  % (c.frame_count, c.fps, c.duration, c.amp))
    report.append("=" * 78)
    metrics.report(rig, c, wqs, wts, stream=_Sink(report))
    report.append("")

    fbx_path = os.path.join(OUT, c.name + ".fbx")
    fbx_ascii.write(fbx_path, rig, c.name, frames, c.fps)
    ok, worst = verify.check(fbx_path, rig, frames)
    print("  fbx      %s   round-trip %s (worst joint error %.4f cm)"
          % (os.path.basename(fbx_path), "OK" if ok else "FAILED", worst))
    if not ok:
        raise SystemExit("FBX round-trip check failed for %s" % c.name)

    glb_path = os.path.join(OUT, c.name + ".glb")
    glb.write(glb_path, rig, c.name, frames, c.fps)
    print("  glb      %s" % os.path.basename(glb_path))

    data = _preview_data(rig, c, wts)
    previews.append(data)
    with open(os.path.join(OUT, c.name + ".json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))

    if args.preview:
        labels = c.frame_labels()
        cols = min(8, c.frame_count)
        for view in ("side", "front"):
            render.contact_sheet(rig, wts, os.path.join(OUT, "%s_%s.png" % (c.name, view)),
                                 view=view, cols=cols, cell=(210, 270),
                                 labels=labels, title="%s  %s" % (c.name, view))
        print("  preview  %s_side.png  %s_front.png" % (c.name, c.name))


def _preview_data(rig, c, wts):
    """Compact joint-position dump the HTML previewer animates."""
    drawn = [i for i, n in enumerate(rig.names)
             if not any(k in n for k in render.DRAW_SKIP)]
    remap = {b: i for i, b in enumerate(drawn)}
    return {
        "name": c.name,
        "fps": c.fps,
        "duration": round(c.duration, 4),
        "bones": [rig.names[i] for i in drawn],
        "parents": [remap.get(rig.parents[i], -1) for i in drawn],
        "labels": c.frame_labels(),
        "frames": [[[round(wt[i][a], 2) for a in range(3)] for i in drawn] for wt in wts],
    }


class _Sink(object):
    def __init__(self, lines):
        self.lines = lines

    def write(self, text):
        self.lines.append(text.rstrip("\n"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", choices=sorted(poses.CLIPS) + ["all"], default="all")
    ap.add_argument("--mirror", action="store_true",
                    help="also emit right-turn mirrors of each clip")
    ap.add_argument("--no-preview", dest="preview", action="store_false",
                    help="skip PNG contact sheets")
    args = ap.parse_args()

    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    rig = R.Rig()
    print("rig %s: %d bones, ref clip %s\n"
          % (rig.meta["skeleton"], len(rig.bones), rig.meta["reference_clip"]))

    names = sorted(poses.CLIPS) if args.clip == "all" else [args.clip]
    report, previews = [], []
    for name in names:
        c = poses.CLIPS[name]()
        build_clip(rig, c, args, report, previews)
        if args.mirror:
            build_clip(rig, C.mirror_clip(c, c.name + "_R"), args, report, previews)

    with open(os.path.join(OUT, "report.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    if args.preview:
        preview.write(os.path.join(OUT, "preview.html"), rig, previews)
        print("\npreview  out/preview.html")
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()
