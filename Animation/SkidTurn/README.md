# Skid turn — authored quick-turn clips

Two clips for the sliding turn in `TheCameraIsAPal/Scripts/horizontalmove.lua`,
built procedurally against the real `SK_PalHuman_Skeleton` rig.

| clip | frames @30fps | length | what it is |
|---|---|---|---|
| `AS_Player_Female_SkidTurn_Sprint` | 15 | 0.467s | sprint-class reversal, full amplitude |
| `AS_Player_Female_SkidTurn_Walk`   | 15 | 0.467s | walk-class reversal, 62% amplitude |

The Lua picks between them with the same `peakSpeed > SPRINT_PEAK` test that
picks `LAUNCH_FRAC` vs `LAUNCH_FRAC_WALK`, and fires the montage once at
`BeginTurn` — the frame the plant happens.

**The two clips are the same length on purpose.** `SKID_TIME` and
`LAUNCH_HOLD` are not class-dependent: a walk-class reversal owns velocity for
exactly as long as a sprint-class one (0.25s + 0.20s), so a shorter walk clip
would blend out while the mod was still driving the turn. What a walking
reversal actually has is less momentum to fight — that is amplitude, not time.

### Cut to the gameplay phases

The beats sit on `horizontalmove.lua`'s phase boundaries, not on a rhythm of
their own:

| clip time | frame | beat | what the Lua is doing |
|---|---|---|---|
| 0.000 | f0  | entry | `BeginTurn`: input locked, pivot starts |
| 0.067 | f2  | plant | velocity easing down along the OLD heading |
| 0.133 | f4  | skid  | mid-`SKID`, mid-pivot |
| 0.200 | f6  | drift | late `SKID` |
| 0.267 | f8  | catch | just past the `SKID` → `LAUNCH` handoff at 0.25s |
| 0.367 | f11 | push  | mid `LAUNCH_HOLD`, velocity driven along the new input |
| 0.467 | f14 | exit  | just past release at 0.45s |

## The motion

Modelled on Breath of the Wild's quick turn: the outside leg is thrown out in
front, the body stays behind it and skates for a beat — reading as *about to
slip* — then the leg bites and fires the character the other way. Seven beats:

```
 f0  entry   mid-stride, hips at 93cm, nothing committed yet
 f2  plant   right leg thrown forward heel-first, torso starts going back
 f4  skid    HERO POSE. hips at 77cm, torso pitched 32 deg back, plant contact
             38cm ahead of the hips, hips lagging 21 deg while the shoulders
             lead 7 and the head leads 34 -- the body wound like a spring
 f6  drift   the skate: plant contact slides on out to 42cm while the body
             stays behind it and almost nothing else changes
 f8  catch   it bites, hips come up over the plant, torso starts righting
 f11 push    plant leg drives, torso whips 15 deg forward, arms swap
 f14 exit    plain accelerating stride, near neutral so the blend-out lands
             on the locomotion cycle
```

Hip track across the clip: 93 → 77 → 92cm, biggest single-frame move 7cm on
the catch (the explosive leg extension) and 9cm down on the plant (impact).
Both clips share these frame numbers.

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
add `BP_AnimNotify_FootStep` in the editor at frames 2 and 11 — those are the
two ground impacts, and they are the same frames in both clips. The vanilla
`AS_Player_Female_Sprint` uses the same notify class.

## The pivot decides whether any of this reads

`TickPivot` drives the actor's yaw explicitly with `PIVOT_FN` over
`PIVOT_TIME` while move input is locked. That curve is an **animation**
decision as much as a feel one, because it sets how much of the turn the body
has already made while each pose is on screen:

| frame | clip time | `EaseOutCirc` @0.24s (current) | `EaseInOutSine` @0.30s |
|---|---|---|---|
| f0  | 0.000 | 0%   | 0%   |
| f2  (plant) | 0.067 | **69%** | 12% |
| f4  (skid)  | 0.133 | **90%** | 41% |
| f6  (drift) | 0.200 | 99%  | 75% |
| f8  (catch) | 0.267 | 100% | 97% |

With the current curve the character has turned two thirds of the way round by
the plant frame and is essentially facing the new heading by the hero frame —
while `TickSkidPhase` is still holding velocity along the **old** one. The body
is sliding backwards relative to its own facing, so a leg thrown out front
points where the character is *going*, not where they are *sliding*: it reads
as a lunge into the new direction, not as a brake. The "weight behind the
plant" pitch then reads as leaning away from the direction of travel, which is
the opposite of the pose's intent.

**The clips are staged for the mid-rotation window** — hips still lagging,
chest and head already leading, body caught between the two headings. To get
that, the pivot has to happen *across* the skid rather than in front of it:

```lua
local PIVOT_TIME = 0.30
local PIVOT_FN   = Easing.EaseInOutSine
```

That is the one gameplay value the animation assumes. Everything else about
the clips is independent of it. If you would rather keep the snappy pivot,
the clips still play cleanly — they just read as a hard plant-and-drive rather
than a slide, and `HIP_LAG` in `poses.py` should go to ~0 since there is no
rotation left for the hips to lag behind by the time the pose is up.

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
