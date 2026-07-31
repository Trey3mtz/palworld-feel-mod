# Skid turn — authored quick-turn clips

Two clips for the sliding turn in `TheCameraIsAPal/Scripts/horizontalmove.lua`,
built procedurally against the real `SK_PalHuman_Skeleton` rig.

| clip | frames @30fps | length | what it is |
|---|---|---|---|
| `AS_Player_Female_SkidTurn_Sprint` | 16 | 0.500s | sprint-class reversal, full amplitude |
| `AS_Player_Female_SkidTurn_Walk`   | 13 | 0.393s | walk-class reversal, 62% amplitude |

The Lua already picks between them with the same `peakSpeed > SPRINT_PEAK` test
that picks `LAUNCH_FRAC` vs `LAUNCH_FRAC_WALK`, and fires the montage once at
`BeginTurn` — the frame the plant happens.

## The motion

Modelled on Breath of the Wild's quick turn: the outside leg is thrown out in
front, the body stays behind it and skates for a beat — reading as *about to
slip* — then the leg bites and fires the character the other way. Seven beats:

```
 f0  entry   mid-stride, hips at 93cm, nothing committed yet
 f2  plant   right leg thrown forward heel-first, torso starts going back
 f5  skid    HERO POSE. hips at 77cm, torso pitched 32 deg back, plant contact
             39cm ahead of the hips, hips lagging 21 deg while the shoulders
             lead 7 and the head leads 34 -- the body wound like a spring
 f7  drift   the skate: plant contact slides a further 3cm out from under the
             body, hips sink another 1cm, almost nothing else changes
 f10 catch   it bites, hips come up over the plant, torso starts righting
 f12 push    plant leg drives, torso whips 15 deg forward, arms swap
 f15 exit    plain accelerating stride, near neutral so the blend-out lands
             on the locomotion cycle
```

(walk beats land on f0 / f2 / f4 / f5 / f8 / f9 / f12.)

Three things do the work, and all three are tuning constants in `poses.py`:

- **Separation** (`HIP_LAG`, `CHEST_LEAD`, `HEAD_LEAD`). The hips lag the turn
  while the chest and head lead it. The movement component is yawing the whole
  actor toward the new heading while this plays, so a pelvis that lags in mesh
  space is a pelvis that *stays put in world space* — which is what a planted
  foot does.
- **The plant** (`PLANT_REACH`, `PLANT_SPLAY`). Contact ~39cm ahead of the
  hips, leg long, heel first, toes up and turned out of the path, rolled onto
  the outside edge. Braking geometry, not running geometry.
- **Weight behind, then ahead** (`BACK_PITCH`, `PUSH_PITCH`). Torso 32 deg back
  through the skid, 15 deg forward on the drive. That reversal across three
  frames is the "caught it at the last second" beat.

Hip height is never authored. `clip.py` solves it every frame from the weighted
support foot, so the crouch is whatever the leg geometry demands and no pose can
float or sink. Retuning `PLANT_REACH` moves the hips automatically.

## Build

```
python3 build.py                 # both clips -> out/
python3 build.py --mirror        # plus right-turn mirrors (see below)
python3 build.py --clip sprint
```

No dependencies — standard library only. Outputs land in `out/`:

- `<name>.fbx` — skeleton-only animation, the import path into Unreal
- `<name>.glb` — same motion on a blocky proxy body, drag into any glTF viewer
  or Blender to look at it without opening the editor
- `preview.html` — self-contained scrubbable previewer, orbit + per-frame metrics
- `<name>_side.png`, `<name>_front.png` — contact sheets
- `report.txt` — per-frame hip height, torso pitch, separation, foot positions

`build.py` refuses to finish if the FBX fails its round-trip check: `verify.py`
re-reads the file, applies the exact conversion Unreal's importer applies, runs
forward kinematics and compares against the baked pose. Current worst-case error
is 0.0000 cm, so what lands in the editor is what the previews show.

## Getting it into the game

1. **Import.** In a UE 5.1 project with the Palworld skeleton available, import
   `AS_Player_Female_SkidTurn_Sprint.fbx` with:
   - Skeleton: `SK_PalHuman_Skeleton`
   - Import Content Type: **Animation** (no mesh in the file — that is deliberate)
   - Import Uniform Scale 1.0, **Convert Scene** on, Force Front X Axis **off**
   - Import Animations on, Animation Length **Exported Time**, Sample Rate 30
   - **Do not** enable root motion. The Lua owns velocity; the clip keeps the
     `root` bone at identity on every frame so the two never fight.
2. Repeat for the walk clip.
3. **Retarget source.** Leave it at the default (the skeleton's own reference
   pose). The clips are authored against `SK_PalHuman_Skeleton`'s reference
   pose, and every bone except `root`/`pelvis` is
   `EBoneTranslationRetargetingMode::Skeleton`, so bone lengths come from
   whatever mesh plays it and only the rotations are ours.
4. **Cook and pak** to
   `/Game/Pal/Animation/Character/Player/Female/Turn/`, matching the paths in
   `SKID_MONTAGES` in `horizontalmove.lua`. Any other path works too — just
   change the two strings.
5. Run. `DEBUG` in `horizontalmove.lua` logs `skid play failed for <class>` if
   the asset cannot be found, which is the fast way to catch a path typo.

No montage asset is needed. The Lua plays an `AnimSequence` through
`PlaySlotAnimationAsDynamicMontage` on `SKID_SLOT` with `SKID_BLEND_IN` /
`SKID_BLEND_OUT` / `SKID_PLAY_RATE` from its tuning block, so blend timing is
tunable in Lua instead of baked into an asset. If you would rather author real
`AM_` montages, point `SKID_MONTAGES` at them — the play path detects an
`AnimMontage` and calls `Montage_Play` directly.

### Notifies

FBX carries no notifies. If you want footstep audio on the plant and the drive,
add `BP_AnimNotify_FootStep` in the editor at frames 2 and 12 of the sprint clip
(2 and 9 for walk) — those are the two ground impacts. The vanilla
`AS_Player_Female_Sprint` uses the same notify class.

## Turn direction

The canonical clip turns to the character's **left** and plants the **right**
foot. For a ~180 degree reversal that reads fine either way — the pose is mostly
a brake in the sagittal plane, and the in-clip yaw is deliberately small because
the movement component supplies the real rotation.

If you want handed clips, `build.py --mirror` emits `..._R` versions reflected
through the sagittal plane (bone names swapped, non-X rotation components
negated). Wiring them up means keying `SKID_MONTAGES` on turn side as well as
speed class, and picking the side at `BeginTurn` from the sign of
`ix*vy - iy*vx` (positive = input is to the left of current velocity).

## Files

```
extract_rig.py    FModel JSON dumps -> rig_palhuman.json (run once, already done)
rig_palhuman.json the 65-bone player rig: names, parents, reference pose
rig.py            quaternion math, FK, mesh-space pose evaluation, contacts
clip.py           keyframes -> baked frames: channel interpolation, hip solve, mirroring
poses.py          THE ANIMATION. Beat poses and tuning constants
metrics.py        per-frame numeric read-out used for tuning
render.py         dependency-free PNG contact sheets
preview.py        self-contained HTML previewer
fbx_ascii.py      FBX 7.4 ASCII writer, Unreal axis convention
glb.py            glTF 2.0 binary writer with a proxy body
verify.py         FBX round-trip check
build.py          CLI
```

### Why the rig is only 65 bones

`SK_PalHuman_Skeleton` carries 4079 bones — every costume, hair and NPC variant
merged into one master skeleton. `AS_Player_Female_Sprint` drives 65 of them,
listed in its `CompressedTrackToSkeletonMapTable`. That subset is what a player
clip is expected to author, so it is exactly what the rig and the FBX contain.

### Why poses are authored in mesh space

This rig has no consistent bone-axis convention: `thigh_l`'s local +X points up
the leg while `thigh_r`'s points down, the spine runs +X up, the toes run +X
forward. Authoring local Euler per bone would mean memorising 65 frames of
reference. Instead every channel is a rotation in mesh space
(**+X left, +Y forward, +Z up**), applied on top of where the reference pose put
that bone, with children inheriting their parent's animated orientation first —
so "swing the thigh 34 forward" means 34 degrees about the character's
left-right axis, whatever the bone's local axes happen to be.
