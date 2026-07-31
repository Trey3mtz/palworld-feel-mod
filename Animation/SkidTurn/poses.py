#!/usr/bin/env python3
"""
The skid-turn pose data. This file IS the animation; everything else is
plumbing.

Reference: Breath of the Wild's quick turn. Link throws the outside leg out in
front, weight behind it, and skates on it for a beat -- reading as "about to
lose it" -- before the leg bites and fires him the other way. Three things
carry that read, and all three are authored explicitly below:

  1. SEPARATION. The hips lag (still pointing along the OLD heading) while the
     chest and head lead into the new one. The body is a wound spring. Because
     the movement component yaws the whole actor toward the new heading while
     this plays, a lagging pelvis in mesh space is a pelvis that stays put in
     world space -- which is exactly what a planted foot does.
  2. THE PLANT. Right leg thrown forward, long, heel first, toes up and turned
     out of the path, rolled onto the outside edge. The contact is ~35cm ahead
     of the hips: that is the geometry of braking, not of running.
  3. WEIGHT BEHIND. Torso pitched BACK over the trailing leg through the skid,
     then whipped FORWARD as the plant leg extends and drives. That reversal
     of pitch across three frames is the "caught it at the last second" beat.

Hip height is never authored here. clip.py solves it every frame from the
weighted support foot (the wl/wr channels on the pelvis), so the crouch is
whatever the leg geometry demands and no pose can float or sink. The numbers
below were tuned against that solve; the hip track dips 93 -> 77 -> 92 cm
across the clip, and raising PLANT_REACH deepens it on its own.

Turn direction is canonical LEFT (plant = right foot). clip.mirror_clip()
produces the right-turn version from the same data.

Channel conventions live in rig.py:
    limb  swing + forward, splay + outboard, twist + right-hand about the bone
    arm   same, but splay 0 means hanging at the side (the rig rests in an
          A-pose, so raw limb() splay would be offset by 45 degrees)
    axial lean  + top forward, tilt + top toward the LEFT, turn + toward LEFT
    foot  pitch + toes up, yaw + toes toward the LEFT, roll + sole to the LEFT
"""

import rig as R
from clip import Clip, Key

# ---------------------------------------------------------------------------
# tuning -- the performance in ~15 numbers
# ---------------------------------------------------------------------------

HIP_LAG = 20.0        # deg the pelvis trails the new heading at peak skid
CHEST_LEAD = 34.0     # deg the ribcage leads it (separation = LAG + LEAD)
HEAD_LEAD = 34.0      # deg the head leads; the eyes commit to the turn first
BACK_PITCH = 24.0     # deg the torso pitches back at peak (weight behind foot)
PUSH_PITCH = 20.0     # deg it whips forward again on the drive
PLANT_REACH = 34.0    # deg of hip flexion on the planted leg at peak
PLANT_SPLAY = 6.0     # deg the plant leg is thrown outboard of the hips
TRAIL_FOLD = 74.0     # deg of knee fold on the trailing leg at peak
FINGER_CURL = 34.0    # loose fists; the hands are not doing anything precise

_RIG = R.Rig()        # imported at module scope to solve the finger-curl axis


def _hands(curl=FINGER_CURL):
    """Both hands in a loose run fist, carried so the arms can go anywhere."""
    out = {}
    for side in ("l", "r"):
        out.update(R.finger_curl(_RIG, side, curl))
    return out


# ---------------------------------------------------------------------------
# beat 1 -- ENTRY (t = 0.000)
# The clip blends in over ~0.1s, so frame 0 has to sit close to the locomotion
# cycle it interrupts or the plant reads as a pop. Deliberately mid-stride and
# near standing hip height: right foot just ahead, left trailing off the toe,
# opposite arm forward. Nothing here is committed to the turn yet.
# ---------------------------------------------------------------------------

ENTRY = {
    "pelvis":      R.merge(R.axial(lean=8, turn=7), {"wl": 0.35, "wr": 0.65}),
    "spine_01":    R.axial(lean=5, turn=-4),
    "spine_02":    R.axial(lean=5, turn=-4),
    "spine_03":    R.axial(lean=4, turn=-3),
    "neck_01":     R.axial(lean=-4, turn=5),
    "head":        R.axial(lean=-3, turn=7),

    "thigh_r":     R.limb(swing=26, splay=3, side="r"),
    "calf_r":      R.limb(swing=-16, side="r"),
    "foot_r":      R.foot(pitch=10),
    "thigh_l":     R.limb(swing=-14, splay=4, side="l"),
    "calf_l":      R.limb(swing=-34, side="l"),
    "foot_l":      R.foot(pitch=-14),
    "ball_l":      R.foot(pitch=20),

    "clavicle_l":  R.limb(swing=5, side="l"),
    "upperarm_l":  R.arm(swing=32, splay=8, side="l"),
    "lowerarm_l":  R.limb(swing=78, side="l"),
    "clavicle_r":  R.limb(swing=-4, side="r"),
    "upperarm_r":  R.arm(swing=-28, splay=10, side="r"),
    "lowerarm_r":  R.limb(swing=70, side="r"),
}

# ---------------------------------------------------------------------------
# beat 2 -- PLANT (t = 0.067, two frames in)
# The right leg is thrown out ahead heel-first while the chest is still
# travelling forward. Fastest change in the clip, and the frame the gameplay
# skid actually starts on -- BeginTurn fires the montage here.
# ---------------------------------------------------------------------------

PLANT = {
    "pelvis":      R.merge(R.axial(lean=2, turn=-7, tilt=3), {"wl": 0.15, "wr": 0.85}),
    "spine_01":    R.axial(lean=-3, turn=6, tilt=2),
    "spine_02":    R.axial(lean=-4, turn=7, tilt=2),
    "spine_03":    R.axial(lean=-3, turn=6, tilt=2),
    "neck_01":     R.axial(lean=4, turn=8),
    "head":        R.axial(lean=5, turn=13, tilt=-3),

    # plant leg: reach, heel leading, toes already turning out of the path
    "thigh_r":     R.limb(swing=32, splay=4, twist=-6, side="r"),
    "calf_r":      R.limb(swing=-16, side="r"),
    "foot_r":      R.foot(pitch=22, yaw=-12, roll=-4),
    # trail leg starts folding as the weight comes off it
    "thigh_l":     R.limb(swing=-14, splay=6, side="l"),
    "calf_l":      R.limb(swing=-52, side="l"),
    "foot_l":      R.foot(pitch=-20),
    "ball_l":      R.foot(pitch=24),

    "clavicle_l":  R.limb(swing=8, side="l"),
    "upperarm_l":  R.arm(swing=42, splay=-6, side="l"),
    "lowerarm_l":  R.limb(swing=84, side="l"),
    "clavicle_r":  R.limb(swing=-8, splay=5, side="r"),
    "upperarm_r":  R.arm(swing=-34, splay=34, side="r"),
    "lowerarm_r":  R.limb(swing=46, side="r"),
}

# ---------------------------------------------------------------------------
# beat 3 -- SKID (t = 0.167)
# The hero pose. Hip lag, chest lead, back pitch and leg extension all peak
# together, and the ground solve drops the hips onto the long plant leg for
# the lowest frame in the clip. Hold-ish: the next beat only drifts out of it,
# which is what sells "skating" rather than "posing".
# ---------------------------------------------------------------------------

SKID = {
    "pelvis":      R.merge(R.axial(lean=-10, turn=-HIP_LAG, tilt=7), {"wl": 0.05, "wr": 0.95}),
    "spine_01":    R.axial(lean=-BACK_PITCH * 0.34, turn=CHEST_LEAD * 0.30, tilt=5),
    "spine_02":    R.axial(lean=-BACK_PITCH * 0.38, turn=CHEST_LEAD * 0.36, tilt=5),
    "spine_03":    R.axial(lean=-BACK_PITCH * 0.28, turn=CHEST_LEAD * 0.34, tilt=4),
    # neck and head pitch forward against the back-leaning chest so the gaze
    # stays level, and carry most of the lead yaw: the eyes get there first.
    "neck_01":     R.axial(lean=10, turn=HEAD_LEAD * 0.35, tilt=-3),
    "head":        R.axial(lean=12, turn=HEAD_LEAD * 0.65, tilt=-5),

    # PLANT LEG -- long, barely bent, skating on the outside edge of the heel
    "thigh_r":     R.limb(swing=PLANT_REACH, splay=PLANT_SPLAY, twist=-10, side="r"),
    "calf_r":      R.limb(swing=-10, side="r"),
    "foot_r":      R.foot(pitch=12, yaw=-20, roll=-10),
    "ball_r":      R.foot(pitch=6),
    # TRAIL LEG -- folded under the hips, knee out, toe skimming the ground
    "thigh_l":     R.limb(swing=0, splay=6, twist=8, side="l"),
    "calf_l":      R.limb(swing=-TRAIL_FOLD, side="l"),
    "foot_l":      R.foot(pitch=-20, yaw=6),
    "ball_l":      R.foot(pitch=22),

    # ARMS -- right arm thrown wide and back as counterweight, left arm
    # crossing the chest in the direction of the turn.
    "clavicle_l":  R.limb(swing=12, side="l"),
    "upperarm_l":  R.arm(swing=38, splay=-18, twist=-10, side="l"),
    "lowerarm_l":  R.limb(swing=64, side="l"),
    "hand_l":      R.limb(swing=10, side="l"),
    "clavicle_r":  R.limb(swing=-12, splay=9, side="r"),
    "upperarm_r":  R.arm(swing=-36, splay=52, twist=14, side="r"),
    "lowerarm_r":  R.limb(swing=22, side="r"),
    "hand_r":      R.limb(splay=12, side="r"),
}

# ---------------------------------------------------------------------------
# beat 4 -- DRIFT (t = 0.233)
# The skate. Almost nothing changes except that the plant foot gets FURTHER
# ahead of the hips (+39 -> +43) while the body stays behind it -- an in-place
# montage cannot move the character, so a foot sliding out from under the
# centre of mass is what "still sliding" has to look like. Without this beat
# the clip recovers the instant it hits the extreme and the slide reads as a
# single pose rather than a state.
# ---------------------------------------------------------------------------

DRIFT = {
    "pelvis":      R.merge(R.axial(lean=-8, turn=-16, tilt=6), {"wl": 0.05, "wr": 0.95}),
    "spine_01":    R.axial(lean=-BACK_PITCH * 0.30, turn=CHEST_LEAD * 0.28, tilt=4),
    "spine_02":    R.axial(lean=-BACK_PITCH * 0.33, turn=CHEST_LEAD * 0.33, tilt=4),
    "spine_03":    R.axial(lean=-BACK_PITCH * 0.24, turn=CHEST_LEAD * 0.31, tilt=3),
    "neck_01":     R.axial(lean=9, turn=HEAD_LEAD * 0.33, tilt=-3),
    "head":        R.axial(lean=10, turn=HEAD_LEAD * 0.60, tilt=-4),

    # plant leg straightens further as it slides out ahead
    "thigh_r":     R.limb(swing=PLANT_REACH + 3, splay=PLANT_SPLAY, twist=-10, side="r"),
    "calf_r":      R.limb(swing=-6, side="r"),
    "foot_r":      R.foot(pitch=9, yaw=-24, roll=-12),
    "ball_r":      R.foot(pitch=6),
    # trail leg starts to unfold toward the new heading
    "thigh_l":     R.limb(swing=5, splay=6, twist=6, side="l"),
    "calf_l":      R.limb(swing=-TRAIL_FOLD - 6, side="l"),
    "foot_l":      R.foot(pitch=-18, yaw=6),
    "ball_l":      R.foot(pitch=20),

    "clavicle_l":  R.limb(swing=10, side="l"),
    "upperarm_l":  R.arm(swing=35, splay=-17, twist=-8, side="l"),
    "lowerarm_l":  R.limb(swing=68, side="l"),
    "clavicle_r":  R.limb(swing=-11, splay=8, side="r"),
    "upperarm_r":  R.arm(swing=-33, splay=48, twist=12, side="r"),
    "lowerarm_r":  R.limb(swing=26, side="r"),
}

# ---------------------------------------------------------------------------
# beat 5 -- CATCH (t = 0.333)
# It bites. The slide stops, the hips come up and swing through over the plant,
# the torso starts righting itself and the trail knee drives toward the new
# heading. The beat that says "didn't slip after all".
# ---------------------------------------------------------------------------

CATCH = {
    "pelvis":      R.merge(R.axial(lean=-2, turn=-5, tilt=4), {"wl": 0.2, "wr": 0.8}),
    "spine_01":    R.axial(lean=1, turn=6, tilt=3),
    "spine_02":    R.axial(lean=1, turn=7, tilt=3),
    "spine_03":    R.axial(lean=2, turn=6, tilt=2),
    "neck_01":     R.axial(lean=3, turn=7),
    "head":        R.axial(lean=4, turn=11, tilt=-3),

    "thigh_r":     R.limb(swing=22, splay=4, twist=-8, side="r"),
    "calf_r":      R.limb(swing=-22, side="r"),
    "foot_r":      R.foot(pitch=4, yaw=-14, roll=-3),
    "thigh_l":     R.limb(swing=10, splay=7, side="l"),
    "calf_l":      R.limb(swing=-70, side="l"),
    "foot_l":      R.foot(pitch=-10),
    "ball_l":      R.foot(pitch=18),

    "clavicle_l":  R.limb(swing=6, side="l"),
    "upperarm_l":  R.arm(swing=30, splay=-16, side="l"),
    "lowerarm_l":  R.limb(swing=78, side="l"),
    "clavicle_r":  R.limb(swing=-6, splay=5, side="r"),
    "upperarm_r":  R.arm(swing=-22, splay=36, side="r"),
    "lowerarm_r":  R.limb(swing=44, side="r"),
}

# ---------------------------------------------------------------------------
# beat 6 -- PUSH (t = 0.400)
# The plant leg extends and drives back down the old heading, the hips have
# flipped from lagging to leading, the torso whips forward and the arms swap.
# Lines up with the Lua launch phase, where the mod reasserts velocity along
# the new input direction.
# ---------------------------------------------------------------------------

PUSH = {
    "pelvis":      R.merge(R.axial(lean=PUSH_PITCH * 0.45, turn=13, tilt=-1), {"wl": 0.8, "wr": 0.2}),
    "spine_01":    R.axial(lean=PUSH_PITCH * 0.32, turn=-4),
    "spine_02":    R.axial(lean=PUSH_PITCH * 0.34, turn=-5),
    "spine_03":    R.axial(lean=PUSH_PITCH * 0.24, turn=-4),
    "neck_01":     R.axial(lean=-6, turn=4),
    "head":        R.axial(lean=-7, turn=5),

    # plant leg finishes the push: extended behind, driving off the toe
    "thigh_r":     R.limb(swing=-22, splay=4, side="r"),
    "calf_r":      R.limb(swing=-48, side="r"),
    "foot_r":      R.foot(pitch=-22, yaw=-6),
    "ball_r":      R.foot(pitch=32),
    # trail leg swings through into the first stride of the new direction
    "thigh_l":     R.limb(swing=28, splay=2, side="l"),
    "calf_l":      R.limb(swing=-38, side="l"),
    "foot_l":      R.foot(pitch=10),

    "clavicle_l":  R.limb(swing=-4, side="l"),
    "upperarm_l":  R.arm(swing=-26, splay=6, side="l"),
    "lowerarm_l":  R.limb(swing=60, side="l"),
    "clavicle_r":  R.limb(swing=8, side="r"),
    "upperarm_r":  R.arm(swing=34, splay=6, side="r"),
    "lowerarm_r":  R.limb(swing=76, side="r"),
}

# ---------------------------------------------------------------------------
# beat 7 -- EXIT (t = 0.500)
# A plain accelerating stride, deliberately close to neutral so the 0.35s
# blend-out lands on the locomotion cycle without a second pop.
# ---------------------------------------------------------------------------

EXIT = {
    "pelvis":      R.merge(R.axial(lean=7, turn=5), {"wl": 0.9, "wr": 0.1}),
    "spine_01":    R.axial(lean=4, turn=-3),
    "spine_02":    R.axial(lean=4, turn=-4),
    "spine_03":    R.axial(lean=3, turn=-3),
    "neck_01":     R.axial(lean=-3, turn=2),
    "head":        R.axial(lean=-3, turn=3),

    "thigh_l":     R.limb(swing=24, side="l"),
    "calf_l":      R.limb(swing=-24, side="l"),
    "foot_l":      R.foot(pitch=8),
    "thigh_r":     R.limb(swing=-10, side="r"),
    "calf_r":      R.limb(swing=-62, side="r"),
    "foot_r":      R.foot(pitch=-8),
    "ball_r":      R.foot(pitch=20),

    "clavicle_l":  R.limb(swing=-2, side="l"),
    "upperarm_l":  R.arm(swing=-18, splay=6, side="l"),
    "lowerarm_l":  R.limb(swing=66, side="l"),
    "clavicle_r":  R.limb(swing=4, side="r"),
    "upperarm_r":  R.arm(swing=24, splay=6, side="r"),
    "lowerarm_r":  R.limb(swing=74, side="r"),
}


# ---------------------------------------------------------------------------
# clips
# ---------------------------------------------------------------------------

def _keys(scale=1.0):
    """Beat times, optionally compressed for the shorter walk clip.

    Easing carries as much of the read as the poses do:
      ENTRY -> PLANT   OutQuad,   the leg is thrown and arrives early
      PLANT -> SKID    OutCubic,  slam into the extreme, then settle
      SKID  -> DRIFT   Linear,    constant-rate skate: no ease, it is a slide
      DRIFT -> CATCH   Linear,    the leg extends at a constant rate; easing
                       here bunches the whole 14cm hip rise into one frame
      CATCH -> PUSH    InCubic,   coil then release -- the snap of the clip
      PUSH  -> EXIT    OutQuad,   unwinding into locomotion
    """
    beats = [
        (0.000, ENTRY, "EaseLinear", "entry"),
        (0.067, PLANT, "EaseOutQuad", "plant"),
        (0.167, SKID, "EaseOutCubic", "skid"),
        (0.233, DRIFT, "EaseLinear", "drift"),
        (0.333, CATCH, "EaseLinear", "catch"),
        (0.400, PUSH, "EaseInCubic", "push"),
        (0.500, EXIT, "EaseOutQuad", "exit"),
    ]
    hands = _hands()
    out = []
    for t, pose, ease, label in beats:
        merged = dict(pose)
        merged.update(hands)
        out.append(Key(round(t * scale, 4), merged, ease, label))
    return out


def sprint_clip():
    """Full-amplitude version, for reversals out of a sprint."""
    return Clip("AS_Player_Female_SkidTurn_Sprint", _keys(1.0), fps=30.0,
                duration=0.5,
                notes="sprint-class reversal; covers SKID_TIME 0.32 + LAUNCH_HOLD 0.06")


def walk_clip():
    """Same performance at 62% amplitude and 79% duration.

    A walking reversal has less momentum to fight, so the plant is shorter and
    the body never gets as far behind its feet -- but it is the same move, and
    sharing the data means retuning the sprint clip retunes both.
    """
    return Clip("AS_Player_Female_SkidTurn_Walk", _keys(0.786), fps=30.0,
                duration=0.3933, amp=0.62,
                notes="walk-class reversal; softer plant, quicker recovery")


CLIPS = {"sprint": sprint_clip, "walk": walk_clip}
