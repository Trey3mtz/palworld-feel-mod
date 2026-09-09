-- =========================================================================
-- PalFeel subsystem: horizontalmove — ground locomotion feel.
--
-- Standstill -> walk : our eased MaxWalkSpeed cap (game never lowers it at
--                      idle, so buildup can't come from the game's value).
-- Walk -> sprint     : the game's own dedicated SprintMaxAcceleration,
--                      set low so the engine itself produces the buildup.
-- Sprint release     : speed glides back to the walk cap via the lowered
--                      braking statics (no stop-on-dime anywhere).
-- Turn arc           : GroundFriction IS the engine's rotate-toward rate
--                      (CalcVelocity lerps velocity toward AccelDir at
--                      alpha dt*Friction). tau = 1/Friction.
-- Turn retention     : that lerp is a CHORD between two equal-length
--                      vectors, so it shortens velocity every frame —
--                      ~28% lost through a 90 deg turn, ~68% through 135.
--                      Lowering friction barely helps (slower rotate, more
--                      frames, same total). So we restore the magnitude
--                      after the engine rotates it: arc shape untouched,
--                      speed preserved. Faster through the turn = wider
--                      radius, which is the arc feel we want.
-- Sliding turn       : sprint/walk momentum-preserving reversal, triggered
--                      on dot(inputDir, velDir) < TURN_DOT.
-- Skid animation     : a one-shot montage on DefaultSlot fired once at the
--                      turn trigger (the plant), classed walk/sprint by the
--                      same peak test as the launch. Placeholder clips
--                      until authored skids exist.
-- Lean               : one continuous signed value (degrees, + = right)
--                      from a heading-rate signal, filtered, applied
--                      ADDITIVELY every frame. Two backends: an additive
--                      montage scrubbed by position (amount = position),
--                      or a rotator channel on the ABP. No montage
--                      cross-fades: the amount IS the blend. Section 7.
-- Sprint cycle       : the authored sprint montage plays while sprinting
--                      and stops otherwise. Section 7.
-- Air                : bUseSeparateBrakingFriction is GLOBAL, so it must be
--                      toggled off while falling or the ground stop value
--                      lands on the air as drag. See OnTick.
--
-- Layout: 1 tuning · 2 state · 3 utilities · 4 frame sampling ·
--         5 walk-cap ease · 6 animation (montage + probes) ·
--         7 movement montages (lean + sprint) · 8 sliding turn ·
--         9 arc retention · 10 air/ground braking · 11 landing ·
--         12 buildup · 13 lifecycle
-- =========================================================================

local Easing = require("easingfunctions")
local UEHelpers = require("UEHelpers")

-- =========================================================================
-- 1. TUNING
-- =========================================================================

local ROTATION_RATE = 0.8 -- 1.0 vanilla

-- ---- standstill -> walk easing ----
local START_CAP   = 135     -- cap at the first instant of movement (uu/s)
local STOP_SPEED  = 50      -- below this 2D speed we count as standing
local EASE_UP_TIME,   EASE_UP_FN   = 0.20, Easing.EaseInSine
local EASE_DOWN_TIME, EASE_DOWN_FN = 0.55, Easing.EaseOutQuad

-- ---- sprint shaping (nil = leave vanilla) ----
local SPRINT_ACCEL     = 500    -- drives walk->sprint buildup
local SPRINT_MAX_SPEED = 610    -- vanilla = 500
local SPRINT_YAW       = 0.75   -- vanilla = 0.6999; lower = wider sprint arcs

-- ---- ground momentum statics ----      -- vanilla:
local MAX_ACCEL               = 2048     -- 2048 (high = speed hugs the cap)
local BRAKING_DECEL           = 1000     -- 2048 (lower = glide to a stop)
-- Friction duties are SPLIT: GroundFriction only governs how fast velocity
-- realigns to input in turns (the arc), while BrakingFriction governs the
-- stop/no-input glide independently.
local USE_SEPARATE_BRAKING    = true
local GROUND_FRICTION         = 6.35     -- 8.0 vanilla; arc rate, tau ~= 0.16s
local BRAKING_FRICTION        = 2.5      -- no-input glide (separate braking on)
local BRAKING_FRICTION_FACTOR = 1.2      -- 2.0; multiplies BrakingFriction

-- ---- turn speed retention ----
local KEEP_ON         = true
local KEEP_FRAC       = 1.00    -- 1.00 = lossless; 0.95 = slight scrub
local KEEP_MAX_DOT    = 0.995   -- above this the player is going straight
local KEEP_MIN_ANALOG = 0.35    -- must be actively holding input
local KEEP_MIN_SPEED  = 80      -- no point restoring a crawl
local KEEP_DECAY      = 200     -- uu/s^2 the remembered speed bleeds off
local KEEP_MIN_DOT    = -0.30   -- TURN_DOT is -0.35, so the skid still claims
                                -- everything sharper; the 90-110 deg band no
                                -- longer falls between the two systems.

-- ---- wall contact ----
local WALL_DECEL = 6000   -- uu/s^2; no braking path reaches this with input held
local WALL_HOLD  = 0.20   -- s the latch persists past the last impact frame

-- ---- air ----
local AIR_CONTROL              = 0.5    -- 0.05 UE default; 0.3-0.5 = responsive
local AIR_CONTROL_BOOST_MULT   = nil    -- leave vanilla until read
local FALLING_LATERAL_FRICTION = 0.0    -- true air drag; 0 = ballistic

-- ---- sliding turn (sprint + walk) ----
local TURN_DOT        = -0.35   -- input vs velocity; -0.35 ~= 110 deg
local TURN_MIN_PEAK   = 150     -- tracked pre-reversal speed: "had momentum"
local TURN_MIN_SPEED  = 100     -- instantaneous floor: "still actually moving"
local TURN_MIN_ANALOG = 0.35    -- reject the dead-zone crossing frame
local TURN_COOLDOWN   = 0.35    -- s before another turn may trigger
local PEAK_DECAY      = 300     -- uu/s^2 the tracked peak bleeds off
local SKID_FN         = Easing.EaseOutQuad

local SKID_TIME          = 0.32   -- s; the clip is half-turned at 0.32
local SKID_END_PEAK_FRAC = 0.45   -- end speed as a fraction of tracked PEAK
local SKID_END_FLOOR     = 150    -- uu/s absolute floor
local LAUNCH_HOLD        = 0.20   -- s reasserting launch, so the write takes

-- Facing during the turn. Two modes, chosen per turn by whether the skid
-- montage actually started:
--   montage playing : the clip turns the body 180 deg inside its own bones,
--                     so the capsule must NOT rotate underneath it or the
--                     two stack to 360. Instead the capsule yaw is snapped
--                     to the launch heading in one frame at PIVOT_SNAP_TIME,
--                     the moment the clip is fully round. The animated pose
--                     then faces exactly where the new capsule forward
--                     points, so the snap is invisible, and the montage
--                     blend-out hands off to locomotion facing the same way.
--                     The montage's blend-out must start at the same time:
--                     BlendOut = length - PIVOT_SNAP_TIME (0.633 - 0.55 =
--                     ~0.08 s) with Blend Out Trigger Time -1.
--   no montage      : the capsule is eased over PIVOT_TIME as before.
-- SKID_CLIP_ROOT_MOTION: the clip's heading lives on its root bone and the
-- sequence has Enable Root Motion on, so the engine strips the turn from the
-- rendered pose. The capsule then carries the whole turn, eased over
-- PIVOT_CLIP_TIME (clip length minus blend-out) with PIVOT_CLIP_FN. This is
-- the only stack-free arrangement: rotation in one place.
-- false: legacy clip with the turn baked into pelvis; the capsule snaps at
-- PIVOT_SNAP_POS (always shows a flip during blend-out).
local SKID_CLIP_ROOT_MOTION = false
local PIVOT_CLIP_TIME = 0.55
local PIVOT_CLIP_FN   = Easing.EaseInOutSine
local PIVOT_SNAP_POS  = 0.51            -- montage position (s) to snap at.
                                        -- Must sit one frame BEFORE blend-out
                                        -- starts (length - BlendOut), so the
                                        -- capsule is already round when the
                                        -- first blended frame renders.
local PIVOT_SNAP_TIME = 0.60            -- s from trigger; fallback only
local PIVOT_TIME = 0.24                 -- s, ease fallback (no montage)
local PIVOT_FN   = Easing.EaseOutCirc   -- (from, to, alpha), like SKID_FN

local SPRINT_PEAK      = 450    -- peak above this = sprint-class turn
local LAUNCH_FRAC      = 0.85   -- sprint-class
local LAUNCH_FRAC_WALK = 0.51   -- 51% of the sprint launch

-- ---- skid animation ----
-- Authored clip, shipped in TheJumpIsAPal_P.pak. Must be the AM_ montage,
-- never the AS_ sequence it wraps: Montage_Play only accepts a UAnimMontage
-- and silently no-ops on a sequence.
-- Targets DefaultSlot on SK_PalHuman_Skeleton; blend 0.10 in / 0.35 out
-- come from the montage asset itself.
local SKID_ANIM_ENABLED = true   -- false: sliding turn runs, no montage plays

local SKID_MONTAGES = {
    sprint = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_QuickTurn.AM_Player_Female_QuickTurn",
    walk   = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_QuickTurn.AM_Player_Female_QuickTurn",
}

-- ---- movement montages ----
-- Same pak and skeleton as the skid; AM_ montages only (see SKID_MONTAGES).
local MOVE_ANIMS = {
    -- Lean
    sprintlean_left  = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_Sprint_LeanLeft.AM_Player_Female_Sprint_LeanLeft",
    sprintlean_right = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_Sprint_LeanRight.AM_Player_Female_Sprint_LeanRight",
    walklean_left    = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_Walk_LeanLeft.AM_Player_Female_Walk_LeanLeft",
    walklean_right   = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_Walk_LeanRight.AM_Player_Female_Walk_LeanRight",

    -- New Sprint anim
    sprint = "/Game/Mods/TheJumpIsAPal/Animations/AM_Player_Female_Sprint.AM_Player_Female_Sprint",
}

-- ---- sprint cycle ----
-- Looping full-body cycle on DefaultSlot while sprinting straight or
-- leaning. Author with a looping section; a clip that runs out restarts.
local SPRINT_CYCLE_ENABLED = true
local SPRINT_CYCLE_SPEED   = SPRINT_MAX_SPEED  -- authored speed; rate = spd/this
local SPRINT_CYCLE_RATE_MIN, SPRINT_CYCLE_RATE_MAX = 0.65, 1.35
local SPRINT_CYCLE_BLEND_OUT = 0.20  -- s, when sprint ends
local SPRINT_CYCLE_MIN_SPEED = 120

-- ---- lean: signal -> degrees ----
-- Signed heading rate in deg/s, + = turning right. Two sources blended:
--   predicted : the engine's own steer, friction * sin(input vs velocity).
--               Same frame, no lag -- the lean starts as the stick moves.
--   measured  : yaw delta of the velocity vector per second. Truth, one
--               frame late, carries the arc-retention rescale.
-- The rate maps linearly to degrees, saturating at LEAN_RATE_FULL, scaled
-- by speed so a crawl barely leans, then smoothed. The smoothed value is
-- the ONLY thing the backends see. There is no on/off: 0.3 of a lean is
-- 0.3 of the pose, every frame.
local LEAN_ENABLED        = true
local LEAN_PREDICT_WEIGHT = 0.6    -- 1.0 = input only, 0.0 = measured only
local LEAN_RATE_CLAMP     = 720    -- deg/s, spike guard on the raw sample
local LEAN_RATE_DEAD      = 12     -- deg/s, below this the target is 0
local LEAN_RATE_FULL      = 220    -- deg/s that reaches LEAN_MAX_DEG
local LEAN_MAX_DEG        = 1.0    -- full lean, in backend units (see below)
local LEAN_CURVE          = Easing.EaseOutSine  -- (0, max, t): shape of the
                                                -- rate -> amount map
local LEAN_SPEED_REF      = SPRINT_MAX_SPEED    -- speed at which scale = 1
local LEAN_SPEED_MIN_SCALE = 0.35  -- scale at standstill-ish speeds
local LEAN_MIN_ANALOG     = 0.35   -- predicted term needs a held stick
local LEAN_INVERT         = false  -- flip if it leans out of the turn
-- Smoothing is asymmetric: into a lean fast, out of it slower, and
-- rate-limited so a stick flick cannot snap the spine.
local LEAN_TAU_IN         = 0.09   -- s, |target| rising
local LEAN_TAU_OUT        = 0.16   -- s, |target| falling
local LEAN_MAX_RATE       = 6.0    -- units/s, hard slew limit
local LEAN_ZERO_SNAP      = 0.004  -- |amount| treated as straight (an
                                   -- exponential never reaches 0 alone)

-- ---- lean backend ----
-- "scrub"  : ADDITIVE montage scrubbed by position. Author the lean clips
--            as additive (Local Space, base = first frame) ramps from no
--            lean at t=0 to full lean at the end. The montage is played,
--            paused, and its position set to |amount| * length each frame,
--            so the amount is the pose. t=0 is identity, so the swap
--            between the left and right clip at zero is invisible and the
--            montage's own blend-in never shows. LEAN_MAX_DEG = 1.0 here
--            (a fraction of the ramp). SlotEvaluatePose accumulates an
--            additive montage on top of whatever DefaultSlot carries, so
--            the locomotion underneath keeps playing.
-- "spine"  : write a rotator channel the ABP already feeds into the spine.
--            LEAN_MAX_DEG is then real degrees. The channel must be
--            confirmed with the L-key probe in section 12 first.
-- "off"    : signal runs, nothing is applied (log only).
local LEAN_BACKEND        = "scrub"
local LEAN_SCRUB_GAIT     = true   -- use walklean_* under walk, sprintlean_*
                                   -- under sprint; false = sprint clips always
local LEAN_SCRUB_SWAP_AT  = 0.02   -- |amount| under which a side/gait swap
                                   -- is allowed (both clips ~identity there)
-- Montages in one GROUP are exclusive: Montage_Play stops every other
-- montage in the group. With the lean clips on DefaultSlot (DefaultGroup)
-- the scrub and the sprint cycle cannot both play, so while any lean is
-- applied the sprint cycle yields and vanilla sprint runs underneath.
-- Author the lean montages into a slot in ANOTHER group (see the slot
-- group dump at spawn) and set this true to let both play at once.
local LEAN_SCRUB_OWN_GROUP = false
local LEAN_SPINE_CHANNEL  = "AimRotatorForSpine"  -- or "Ride_SpineAddRotate"
local LEAN_SPINE_AXIS     = "Roll"                -- Roll / Pitch / Yaw
local LEAN_SPINE_WEIGHT   = nil                   -- "Ride_SpineWeight" when
                                                  -- the channel has a weight

-- ---- debug ----
local DEBUG      = true
local DEBUG_AIR  = false   -- per-frame falling log
local DEBUG_KEEP = false   -- logs each retention burst once
local DEBUG_CHANNELS = false -- one-shot lean-channel resting values at spawn
local DEBUG_TURN_TRACE = true -- per-tick trace while a turn owns velocity
local DEBUG_LEAN = false      -- per-tick lean signal + amount (60Hz spam)

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "horizontalmove" }

local cachedPawn = nil
local originalRotationRateYaw = nil

-- ---- animation state ----
local animInstance = nil
local animInstanceAddress = nil

-- ---- walk-cap state ----
local desired   = nil     -- game's intended walk top speed (captured)
local moving    = false
local capFrom, capTo = 0, 0
local easeT, easeDur, easeFn = 0, 0, nil
local lastWrite = nil

-- ---- air state ----
local lastSplit   = nil
local wasAirborne = false

-- ---- retention state ----
local keepSpeed   = 0
local keepActive  = false
local sprintCap   = nil

-- ---- turn state ----
local PHASE_NONE, PHASE_SKID, PHASE_LAUNCH = 0, 1, 2
local phase, turnT = PHASE_NONE, 0
local peakSpeed, turnCool = 0, 0
local skidX, skidY, skidSpeed, skidEndSpeed = 0, 0, 0, 0
local launchX, launchY, launchSpeed = 0, 0, 0
local pivotT, pivotStartYaw, pivotTargetYaw = 0, 0, 0
local pivotSnap, pivotDone = false, false   -- snap mode this turn; yaw applied
local activeSkidMontage = nil               -- montage started for this turn

-- ---- wall contact state ----
local prevSpd = nil
local wallT   = 0

-- ---- skid animation state ----
local skidMontageCache = {}    -- asset path -> montage handle

-- ---- movement montage / lean state ----
-- One table: the main chunk is near Lua's 200-local limit.
local mv = {
    montageCache   = {},    -- asset path -> montage handle (separate from the
                            -- skid cache: IsAnySkidPlaying walks that)
    clipLength     = {},    -- MOVE_ANIMS key -> clip length (s)
    apiChecked     = false,
    hasIsAnyMontagePlaying = false,
    -- sprint cycle
    sprintMontage  = nil,   -- playing handle, or nil
    sprintRate     = 0,
    -- lean
    rate           = 0,     -- raw blended heading rate, deg/s (this frame)
    amount         = 0,     -- smoothed signed amount the backend applies
    prevHeadingYaw = nil,   -- last velocity yaw, for the measured rate
    scrubKey       = nil,   -- MOVE_ANIMS key currently scrubbed, or nil
    scrubMontage   = nil,
    spineWritten   = false, -- a non-zero value is on the channel
}

-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:hmove] " .. fmt .. "\n", ...)) end
end

-- Safe full-name read for diagnostics; unresolved pointers must print as a
-- distinct token rather than erroring out of the surrounding log line.
local function FullNameOf(obj)
    if not (obj and obj:IsValid()) then return "<nil>" end
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or "<unreadable>"
end

-- Read a property that may not exist under this exact name.
-- NOTE: must not collapse a legitimate `false` to nil, or boolean-false
-- states become indistinguishable from unreadable fields.
local function ReadOpt(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function WriteOpt(cmc, prop, value, label)
    if value == nil then return end
    local ok, err = pcall(function() cmc[prop] = value end)
    if ok then dbg("%s -> %s", label or prop, tostring(value))
    else dbg("WRITE FAILED for %s: %s", prop, tostring(err)) end
end

local function Speed2D(cmc)
    local v = cmc.Velocity
    return math.sqrt(v.X * v.X + v.Y * v.Y)
end

local moveInputLocked = false

local function LockMoveInput(pawn)
    if moveInputLocked then return end
    if not (pawn and pawn:IsValid()) then return end
    local controller = pawn:GetController()
    if not (controller and controller:IsValid()) then return end
    -- SetIgnoreMoveInput is a COUNTER: true increments, false decrements with
    -- a clamp at zero, so calls must be paired symmetrically.
    -- ResetIgnoreMoveInput assigns the CDO default instead of decrementing,
    -- which would release holds the game or another mod is also holding.
    controller:SetIgnoreMoveInput(true)
    moveInputLocked = true
end

local function UnlockMoveInput(pawn)
    if not moveInputLocked then return end
    -- Flag cleared before the write: if the controller read fails, the state
    -- machine must not stay latched believing a lock is still outstanding.
    moveInputLocked = false
    if not (pawn and pawn:IsValid()) then return end
    local controller = pawn:GetController()
    if not (controller and controller:IsValid()) then return end
    controller:SetIgnoreMoveInput(false)
end
local function FormatTransform(transform)
    if transform == nil then return "nil" end
    local translation = transform.Translation
    local scale3D     = transform.Scale3D
    if translation == nil or scale3D == nil then return "unreadable" end
    return string.format("T(%.1f,%.1f,%.1f) S(%.2f,%.2f,%.2f)",
        translation.X or 0.0, translation.Y or 0.0, translation.Z or 0.0,
        scale3D.X or 0.0, scale3D.Y or 0.0, scale3D.Z or 0.0)
end
-- =========================================================================
-- 4. FRAME SAMPLING
-- One read per tick of everything the turn and retention sections share.
-- The buildup section re-reads speed itself: retention may rescale
-- velocity mid-tick and the ease must seed from the post-retention value.
-- =========================================================================

local function ReadFrame(cmc)
    local f = {}
    f.mode     = cmc.MovementMode
    f.custom   = ReadOpt(cmc, "CustomMovementMode") or 0
    f.grounded = (f.mode == 1 or f.mode == 2)     -- Walking / NavWalking

    local v, a = cmc.Velocity, cmc.Acceleration
    f.vx, f.vy = v.X, v.Y
    f.spd      = math.sqrt(v.X * v.X + v.Y * v.Y)
    f.imag     = math.sqrt(a.X * a.X + a.Y * a.Y)
    f.analog   = ReadOpt(cmc, "AnalogInputModifier") or 0
    f.ix, f.iy = 0, 0
    if f.imag > 1e-3 then
        f.ix, f.iy = a.X / f.imag, a.Y / f.imag
    end
    return f
end

-- Grounded locomotion the turn may run through. Sprint may lapse to plain
-- Walking as speed collapses — that is expected, not an abort.
--   1 = Walking, 2 = NavWalking, 6 = MOVE_Custom (custom 2 = Sprint)
local function IsTurnCapableMode(mode, custom)
    if mode == 1 or mode == 2 then return true end
    if mode == 6 and (custom == 2 or custom == 0) then return true end
    return false
end

-- Ceiling for this frame's speed. Sprint does not route through
-- MaxWalkSpeed, so it needs its own field.
local function SpeedCeiling(cmc, mode, custom)
    if mode == 6 and custom == 2 then
        return sprintCap or SPRINT_MAX_SPEED
    end
    return cmc.MaxWalkSpeed
end

-- =========================================================================
-- 5. WALK-CAP EASE
-- The eased MaxWalkSpeed cap that shapes standstill -> walk buildup.
-- =========================================================================

local function Retarget(from, to)
    capFrom, capTo, easeT = from, to, 0
    if to >= from then easeDur, easeFn = EASE_UP_TIME, EASE_UP_FN
    else easeDur, easeFn = EASE_DOWN_TIME, EASE_DOWN_FN end
end

local function CurrentCap()
    if easeFn == nil or easeDur <= 0 then return capTo end
    return easeFn(capFrom, capTo, easeT / easeDur)
end

local function WriteCap(cmc, cap)
    if lastWrite == nil or math.abs(cap - lastWrite) > 0.5 then
        cmc.MaxWalkSpeed = cap
        lastWrite = cap
    end
end

-- =========================================================================
-- 6. ANIMATION: montage playback + read-only probes
-- The skid montage, the IsWalking/IsSprint flip log, the bone-list dump,
-- and the lean-channel resting-value probe all live here. The probe is
-- driven by a post-hook on the ABP's own update rather than from OnTick:
-- BlueprintUpdateAnimation runs on the game thread immediately before the
-- anim graph evaluates, which is also the slot any future lean WRITE must
-- use so the graph reads the value the same frame it is set.
-- =========================================================================

-- Sole loader for the skid clips, keyed by asset path so classes sharing
-- a clip share one lookup.
--
-- The clip is made resident by the BPModLoader ModActor, which holds a hard
-- reference to it; BPModLoader spawns that actor on every map load, so the
-- package is loaded and rooted for the life of the world and
-- StaticFindObject hits. UE4SS LoadAsset is NOT a substitute: it resolves
-- through the Asset Registry, which only knows the base game's
-- AssetRegistry.bin, so for a mod pak asset it returns nil without loading.
-- It stays as a fallback for assets that are in the registry.
local function LoadMontageInto(cache, path)
    if path == nil then return nil end
    local montage = cache[path]
    if montage and montage:IsValid() then return montage end
    montage = StaticFindObject(path)
    if not (montage and montage:IsValid()) then
        montage = nil
        local ok, err = pcall(function() montage = LoadAsset(path) end)
        if not ok then
            dbg("LoadAsset threw for %s: %s", path, tostring(err))
        elseif montage and not montage:IsValid() then
            montage = nil
        end
    end
    cache[path] = montage
    return montage
end

local function LoadSkidMontage(path)
    return LoadMontageInto(skidMontageCache, path)
end

local function GetSkidMontage(class)
    return LoadSkidMontage(SKID_MONTAGES[class])
end

local function ResolveAnimInstance()
    if not (cachedPawn and cachedPawn:IsValid()) then return nil end
    local mesh = cachedPawn.Mesh
    if not (mesh and mesh:IsValid()) then return nil end
    local anim = nil
    pcall(function() anim = mesh:GetAnimInstance() end)
    if anim and anim:IsValid() then return anim end
    return nil
end

-- Caches the anim instance AND its address. The address is what the ABP
-- hook filters on, so it has to be refreshed alongside the instance or the
-- hook silently stops firing after a respawn.
local function CacheAnimInstance()
    animInstance = ResolveAnimInstance()
    if animInstance == nil then
        animInstanceAddress = nil
        return false
    end

    local gotAddress, resolvedAddress =
        pcall(function() return animInstance:GetAddress() end)
    animInstanceAddress = gotAddress and resolvedAddress or nil

    local named, fullName = pcall(function() return animInstance:GetFullName() end)
    dbg("anim instance: %s", named and fullName or "name read failed")
    return true
end

local function FormatRotator(rotator)
    if rotator == nil then return "nil" end
    return string.format("[P %.2f Y %.2f R %.2f]",
        rotator.Pitch or 0.0, rotator.Yaw or 0.0, rotator.Roll or 0.0)
end

-- Resting-value probe for the candidate lean channels. Anything non-zero
-- here while standing or running means the game is already driving that
-- channel and we would be contending for it.
-- Property names are case-sensitive through UE4SS reflection: a lowercase
-- first letter resolves to nil and logs a convincing-looking 0.00.
local function LogAnimChannels(targetAnimInstance)
    local overrideEnabled    = ReadOpt(targetAnimInstance, "bOverrideTransform")
    local overrideAlpha      = ReadOpt(targetAnimInstance, "OverrideTransformAlpha")
    local rideSpineWeight    = ReadOpt(targetAnimInstance, "Ride_SpineWeight")
    local rideSpineAddRotate = ReadOpt(targetAnimInstance, "Ride_SpineAddRotate")
    local aimRotatorForSpine = ReadOpt(targetAnimInstance, "AimRotatorForSpine")
    local overrideTransform  = ReadOpt(targetAnimInstance, "BP_OverrideTransform")

    dbg("channels: bOverride=%s alpha=%.2f rideWeight=%.2f rideRot=%s aimSpine=%s xformT=%s",
        tostring(overrideEnabled),
        overrideAlpha or 0.0,
        rideSpineWeight or 0.0,
        FormatRotator(rideSpineAddRotate),
        FormatRotator(aimRotatorForSpine),
        FormatTransform(overrideTransform))
end



-- Either variant still playing suppresses a new play: both live in
-- DefaultGroup, so Montage_Play would cut the other mid-skid otherwise.
local function IsAnySkidPlaying(anim)
    for _, montage in pairs(skidMontageCache) do
        if montage and montage:IsValid() then
            local playing = false
            pcall(function() playing = anim:Montage_IsPlaying(montage) end)
            if playing then return true end
        end
    end
    return false
end

-- One-shot skeleton comparison. A montage whose Skeleton differs from the
-- mesh's live skeleton is rejected by Montage_Play with no engine warning,
-- so the two full names are printed side by side to make it visible.
local function LogSkidSkeletons(pawn)
    local mesh = pawn and pawn:IsValid() and pawn.Mesh or nil
    local meshSkeleton = nil
    if mesh and mesh:IsValid() then
        local skeletalMesh = ReadOpt(mesh, "SkeletalMesh")
                          or ReadOpt(mesh, "SkinnedAsset")
        if skeletalMesh and skeletalMesh:IsValid() then
            meshSkeleton = ReadOpt(skeletalMesh, "Skeleton")
        end
    end
    dbg("mesh skeleton: %s", FullNameOf(meshSkeleton))

    -- Montage slot groups the skeleton declares. A slot outside
    -- DefaultGroup is what the lean scrub needs to coexist with the sprint
    -- cycle (LEAN_SCRUB_OWN_GROUP). Best effort: TArray/FName access
    -- differs across UE4SS builds, so any failure is one log line.
    if meshSkeleton and meshSkeleton:IsValid() then
        local ok, err = pcall(function()
            local groups = meshSkeleton.SlotGroups
            groups:ForEach(function(_, groupElem)
                local group = groupElem:get()
                local names = {}
                group.SlotNames:ForEach(function(_, nameElem)
                    names[#names + 1] = nameElem:get():ToString()
                end)
                dbg("slot group %s: %s", group.GroupName:ToString(),
                    table.concat(names, ", "))
            end)
        end)
        if not ok then dbg("slot groups: unreadable (%s)", tostring(err)) end
    end

    for class in pairs(SKID_MONTAGES) do
        local montage = GetSkidMontage(class)
        dbg("montage %s: obj=%s skeleton=%s", class,
            FullNameOf(montage),
            FullNameOf(montage and ReadOpt(montage, "Skeleton") or nil))
    end
    do
        for key, path in pairs(MOVE_ANIMS) do
            local montage = LoadMontageInto(mv.montageCache, path)
            dbg("move montage %s: obj=%s skeleton=%s", key,
                FullNameOf(montage),
                FullNameOf(montage and ReadOpt(montage, "Skeleton") or nil))
        end
    end
end

-- Returns true when the montage actually started, so the turn can choose
-- its facing mode: snap when the clip carries the rotation, ease otherwise.
local function PlaySkidAnimation(class)
    if not SKID_ANIM_ENABLED then return false end
    local montage = GetSkidMontage(class)
    if montage == nil then
        dbg("skid play %s: montage not resolved (%s)", class, SKID_MONTAGES[class])
        return false
    end
    local anim = ResolveAnimInstance()
    if anim == nil then
        dbg("skid play %s: no anim instance", class)
        return false
    end
    if IsAnySkidPlaying(anim) then return false end
    -- Montage_Play returns the montage length, or 0.0 when the montage is
    -- rejected (incompatible skeleton, missing slot). Both are silent, so
    -- the return value is the only signal separating them from a good play.
    local played = 0.0
    local ok = pcall(function()
        played = anim:Montage_Play(montage, 1.0, 0, 0.0, true) or 0.0
    end)
    if not ok then
        dbg("skid play %s: Montage_Play threw", class)
        return false
    elseif played <= 0.0 then
        dbg("skid play %s: Montage_Play REJECTED (returned 0) -- "
            .. "skeleton mismatch or missing slot", class)
        return false
    end
    dbg("skid play %s: playing, length=%.3f", class, played)
    activeSkidMontage = montage
    return true
end

-- =========================================================================
-- 7. MOVEMENT MONTAGES: continuous lean + sprint cycle
-- Data flow per tick:
--   frame -> heading rate (deg/s) -> target amount -> smoothed amount
--         -> backend write (montage position | ABP rotator)
-- The amount is continuous and signed. Nothing here has an on state or an
-- off state; a small amount is a small lean. The skid owns DefaultSlot
-- while it plays: the lean and the sprint cycle both yield to it.
-- =========================================================================

local function GetMoveMontage(key)
    return LoadMontageInto(mv.montageCache, MOVE_ANIMS[key])
end

-- Reflection probe, run once on the first live instance. Degrades to
-- "assume free" rather than throwing every tick if a build hides it.
local function CheckMoveApi(anim)
    if mv.apiChecked then return end
    mv.apiChecked = true
    mv.hasIsAnyMontagePlaying =
        pcall(function() return anim:IsAnyMontagePlaying() end)
    dbg("move anim api: IsAnyMontagePlaying=%s", tostring(mv.hasIsAnyMontagePlaying))
end

local function IsMontagePlaying(anim, montage)
    if not (montage and montage:IsValid()) then return false end
    local playing = false
    pcall(function() playing = anim:Montage_IsPlaying(montage) end)
    return playing
end

-- A montage neither the skid nor this layer started (attack, emote,
-- glider unfurl). Playing over it cuts the game's clip and starts a
-- flicker war; yield instead.
local function IsForeignMontagePlaying(anim)
    if not mv.hasIsAnyMontagePlaying then return false end
    local any = false
    pcall(function() any = anim:IsAnyMontagePlaying() end)
    if not any then return false end
    if IsMontagePlaying(anim, mv.sprintMontage) then return false end
    if IsMontagePlaying(anim, mv.scrubMontage) then return false end
    if IsAnySkidPlaying(anim) then return false end
    return true
end

local function ClipLength(key, montage)
    local len = mv.clipLength[key]
    if len and len > 0 then return len end
    len = ReadOpt(montage, "SequenceLength") or 0
    if len > 0 then mv.clipLength[key] = len end
    return len
end

-- ---- 7a. signal ----

-- Sign convention is UE yaw: X forward, Y right, positive = clockwise from
-- above = turning right. cross(vel, input) > 0 puts the stick right of
-- travel and atan(vy, vx) rising is the same right turn, so the two
-- sources agree without a flip.
local function ReadHeadingRate(dt, f)
    local measured = 0
    if f.spd > 1e-3 then
        local yaw = math.deg(math.atan(f.vy, f.vx))
        if mv.prevHeadingYaw ~= nil and dt > 1e-4 then
            local delta = ((yaw - mv.prevHeadingYaw + 180) % 360) - 180
            measured = delta / dt
        end
        mv.prevHeadingYaw = yaw
    else
        mv.prevHeadingYaw = nil
    end

    local predicted = 0
    if f.imag > 1e-3 and f.spd > 1e-3 and f.analog >= LEAN_MIN_ANALOG then
        -- CalcVelocity rotates velocity toward AccelDir at alpha dt*Friction:
        -- an angular rate of Friction * sin(angle) rad/s.
        local sinAngle = (f.vx * f.iy - f.vy * f.ix) / f.spd
        predicted = math.deg(GROUND_FRICTION * sinAngle)
    end

    local raw = LEAN_PREDICT_WEIGHT * predicted
              + (1 - LEAN_PREDICT_WEIGHT) * measured
    raw = math.max(-LEAN_RATE_CLAMP, math.min(LEAN_RATE_CLAMP, raw))
    if LEAN_INVERT then raw = -raw end
    return raw
end

-- rate -> signed target amount. Dead band, saturating curve, speed scale.
local function LeanTarget(rate, f)
    local mag = math.abs(rate)
    if mag <= LEAN_RATE_DEAD then return 0 end
    local t = (mag - LEAN_RATE_DEAD) / math.max(1, LEAN_RATE_FULL - LEAN_RATE_DEAD)
    local amount = LEAN_CURVE(0, LEAN_MAX_DEG, t)
    local speedT = math.min(1, f.spd / math.max(1, LEAN_SPEED_REF))
    amount = amount * (LEAN_SPEED_MIN_SCALE + (1 - LEAN_SPEED_MIN_SCALE) * speedT)
    return (rate < 0) and -amount or amount
end

-- Asymmetric exponential smoothing plus a slew limit. tau IN when |target|
-- grows, OUT when it shrinks (including through zero on a flip).
local function SmoothLean(dt, target)
    local tau = (math.abs(target) >= math.abs(mv.amount)) and LEAN_TAU_IN or LEAN_TAU_OUT
    local alpha = (tau > 0) and (1 - math.exp(-dt / tau)) or 1
    local step  = (target - mv.amount) * alpha
    local slew  = LEAN_MAX_RATE * dt
    if step >  slew then step =  slew end
    if step < -slew then step = -slew end
    mv.amount = mv.amount + step
    if math.abs(mv.amount) < LEAN_ZERO_SNAP and math.abs(target) < LEAN_ZERO_SNAP then
        mv.amount = 0
    end
end

-- Gate: where a lean is meaningful at all. Elsewhere the target is 0 and
-- the smoothing carries the pose back on its own.
local function LeanAllowed(f)
    if not LEAN_ENABLED or LEAN_BACKEND == "off" then return false end
    if phase ~= PHASE_NONE then return false end
    return IsTurnCapableMode(f.mode, f.custom)
end

-- ---- 7b. backend: additive montage scrub ----

local function StopLeanScrub(anim, blendOut)
    if mv.scrubMontage and mv.scrubMontage:IsValid() and anim then
        pcall(function() anim:Montage_Stop(blendOut or 0.0, mv.scrubMontage) end)
    end
    mv.scrubKey, mv.scrubMontage = nil, nil
end

-- Play + pause once, then drive position. Returns true when the montage is
-- resident and paused at the requested position.
local function StartLeanScrub(anim, key)
    local montage = GetMoveMontage(key)
    if montage == nil then
        dbg("lean scrub %s: montage not resolved (%s)", key, MOVE_ANIMS[key])
        return false
    end
    local played = 0.0
    local ok = pcall(function()
        played = anim:Montage_Play(montage, 1.0, 0, 0.0, false) or 0.0
    end)
    if not ok or played <= 0.0 then
        dbg("lean scrub %s: Montage_Play %s", key,
            ok and "REJECTED (returned 0)" or "threw")
        return false
    end
    mv.clipLength[key] = mv.clipLength[key] or played
    -- Paused: the clip must not advance on its own; position is ours.
    pcall(function() anim:Montage_Pause(montage) end)
    mv.scrubKey, mv.scrubMontage = key, montage
    dbg("lean scrub -> %s (len %.2f)", key, played)
    return true
end

local function ApplyLeanScrub(anim, f)
    local sprinting = (f.mode == 6 and f.custom == 2)
    local mag = math.abs(mv.amount)

    if mag <= 0 then
        -- Fully straight: release the slot entirely so the sprint cycle or
        -- vanilla locomotion is all that plays. Position 0 is identity, so
        -- a zero-length blend-out shows nothing.
        if mv.scrubKey ~= nil then StopLeanScrub(anim, 0.0) end
        return
    end

    local gait = (LEAN_SCRUB_GAIT and not sprinting) and "walklean" or "sprintlean"
    local key  = gait .. ((mv.amount < 0) and "_left" or "_right")

    if key ~= mv.scrubKey then
        -- A side mismatch swaps now: the amount just crossed zero (the
        -- slew limit bounds how far past it) and scrubbing the wrong-side
        -- clip is worse than the sub-frame pop. A same-side GAIT change
        -- waits for near-identity, since a walk clip and a sprint clip
        -- differ visibly at the same position.
        local wrongSide = mv.scrubKey ~= nil
            and (mv.scrubKey:sub(-5) == "_left") ~= (mv.amount < 0)
        if mv.scrubKey ~= nil and not wrongSide and mag > LEAN_SCRUB_SWAP_AT then
            key = mv.scrubKey
        else
            StopLeanScrub(anim, 0.0)
            if not StartLeanScrub(anim, key) then return end
        end
    elseif not IsMontagePlaying(anim, mv.scrubMontage) then
        -- Cut by something else (skid, game montage). Re-enter.
        mv.scrubKey, mv.scrubMontage = nil, nil
        if not StartLeanScrub(anim, key) then return end
    end

    local len = ClipLength(key, mv.scrubMontage)
    if len <= 0 then return end
    -- Never touch the final frame: a montage at exactly its length is
    -- "finished" and the engine blends it out on its own.
    local pos = math.min(mag / LEAN_MAX_DEG, 1.0) * len
    pos = math.min(pos, len - 0.001)
    pcall(function() anim:Montage_SetPosition(mv.scrubMontage, pos) end)
end

-- ---- 7c. backend: ABP rotator channel ----

local function ApplyLeanSpine(anim)
    if mv.amount == 0 and not mv.spineWritten then return end
    local ok = pcall(function()
        anim[LEAN_SPINE_CHANNEL][LEAN_SPINE_AXIS] = mv.amount
        if LEAN_SPINE_WEIGHT then
            anim[LEAN_SPINE_WEIGHT] = (mv.amount ~= 0) and 1.0 or 0.0
        end
    end)
    mv.spineWritten = ok and (mv.amount ~= 0)
end

-- ---- 7d. sprint cycle ----

local function StopSprintCycle(anim, blendOut)
    if mv.sprintMontage and mv.sprintMontage:IsValid() and anim then
        pcall(function() anim:Montage_Stop(blendOut, mv.sprintMontage) end)
        dbg("sprint cycle -> none (blend %.2f)", blendOut)
    end
    mv.sprintMontage, mv.sprintRate = nil, 0
end

local function UpdateSprintCycle(anim, f)
    if not SPRINT_CYCLE_ENABLED then return end
    local want = phase == PHASE_NONE
             and f.mode == 6 and f.custom == 2
             and f.spd >= SPRINT_CYCLE_MIN_SPEED
             and f.imag > 1e-3

    if not want then
        if mv.sprintMontage ~= nil then StopSprintCycle(anim, SPRINT_CYCLE_BLEND_OUT) end
        return
    end
    -- Slot arbitration. The scrub's own Montage_Play is what blends the
    -- cycle out (over the lean clip's BlendIn); here we only decline to
    -- start it again until the lean has fully returned to zero.
    local scrubOwnsSlot = LEAN_BACKEND == "scrub" and not LEAN_SCRUB_OWN_GROUP
                      and (mv.amount ~= 0 or mv.scrubKey ~= nil)
    if scrubOwnsSlot or IsAnySkidPlaying(anim) or IsForeignMontagePlaying(anim) then
        if mv.sprintMontage ~= nil and not IsMontagePlaying(anim, mv.sprintMontage) then
            mv.sprintMontage, mv.sprintRate = nil, 0
        end
        return
    end

    local rate = math.max(SPRINT_CYCLE_RATE_MIN,
                 math.min(SPRINT_CYCLE_RATE_MAX, f.spd / math.max(1, SPRINT_CYCLE_SPEED)))

    if mv.sprintMontage ~= nil and IsMontagePlaying(anim, mv.sprintMontage) then
        if math.abs(rate - mv.sprintRate) >= 0.02 then
            if pcall(function() anim:Montage_SetPlayRate(mv.sprintMontage, rate) end) then
                mv.sprintRate = rate
            end
        end
        return
    end

    local montage = GetMoveMontage("sprint")
    if montage == nil then return end
    local played = 0.0
    local ok = pcall(function()
        played = anim:Montage_Play(montage, rate, 0, 0.0, false) or 0.0
    end)
    if not ok or played <= 0.0 then
        dbg("sprint cycle: Montage_Play %s", ok and "REJECTED (returned 0)" or "threw")
        mv.sprintMontage, mv.sprintRate = nil, 0
        return
    end
    -- The cycle's Montage_Play blends out every other DefaultGroup montage,
    -- the lean scrub included. Forget it so the scrub re-enters cleanly.
    mv.scrubKey, mv.scrubMontage = nil, nil
    mv.sprintMontage, mv.sprintRate = montage, rate
    dbg("sprint cycle -> playing (rate %.2f, len %.2f)", rate, played)
end

-- ---- 7e. tick ----

local function UpdateMoveAnim(dt, f)
    mv.rate = ReadHeadingRate(dt, f)
    SmoothLean(dt, LeanAllowed(f) and LeanTarget(mv.rate, f) or 0)

    local anim = ResolveAnimInstance()
    if anim == nil then
        mv.sprintMontage, mv.scrubKey, mv.scrubMontage = nil, nil, nil
        return
    end
    CheckMoveApi(anim)

    if DEBUG_LEAN then
        dbg("lean rate=%+.0f amount=%+.3f scrub=%s sprintcycle=%s",
            mv.rate, mv.amount, tostring(mv.scrubKey),
            tostring(mv.sprintMontage ~= nil))
    end

    -- Order matters: the sprint cycle's Montage_Play would cut a scrub
    -- started in the same tick, so it goes first and the scrub lands on
    -- top of it.
    UpdateSprintCycle(anim, f)

    if LEAN_BACKEND == "scrub" then
        if phase ~= PHASE_NONE or IsAnySkidPlaying(anim) or IsForeignMontagePlaying(anim) then
            -- Slot is owned elsewhere. Our montage was already cut by that
            -- play; drop the bookkeeping, the amount keeps decaying to 0.
            mv.scrubKey, mv.scrubMontage = nil, nil
        else
            ApplyLeanScrub(anim, f)
        end
    elseif LEAN_BACKEND == "spine" then
        ApplyLeanSpine(anim)
    end
end

-- =========================================================================
-- 8. SLIDING TURN
-- Three phases: NONE (watching for a reversal), SKID (velocity eased down
-- along the old heading), LAUNCH (exit speed reasserted along input).
-- =========================================================================

-- Facing is frozen while move input is locked: Acceleration is zero, so
-- ComputeOrientToMovementRotation returns the current rotation and
-- PhysicsRotation does nothing. The pivot must be driven explicitly.
-- Gated on the lock so that if locking failed, the engine's own orientation
-- keeps running instead of fighting this write.
local function TickPivot(pawn)
    if not moveInputLocked then return end
    if pivotDone then return end
    if not (pawn and pawn:IsValid()) then return end

    local rotation = pawn:K2_GetActorRotation()
    if pivotSnap and SKID_CLIP_ROOT_MOTION then
        local pivotAlpha = math.min(pivotT / PIVOT_CLIP_TIME, 1.0)
        rotation.Yaw = PIVOT_CLIP_FN(pivotStartYaw, pivotTargetYaw, pivotAlpha)
        pivotDone    = pivotAlpha >= 1.0
    elseif pivotSnap then
        -- The clip is turning the body; leave the capsule alone until the
        -- clip is nearly round, then set the yaw in one frame. Lua ticks
        -- after this frame's animation was evaluated, so the snap must land
        -- BEFORE blend-out begins: once the montage reports stopped the
        -- first hand-off frame has already rendered against the old yaw
        -- (one frame facing the wrong way). Read the clip position and
        -- snap at PIVOT_SNAP_POS; the stopped flag and PIVOT_SNAP_TIME are
        -- fallbacks only.
        local why = nil
        local anim = ResolveAnimInstance()
        if anim and activeSkidMontage and activeSkidMontage:IsValid() then
            pcall(function()
                if not anim:Montage_IsPlaying(activeSkidMontage) then
                    why = "montage stopped"
                elseif anim:Montage_GetPosition(activeSkidMontage) >= PIVOT_SNAP_POS then
                    why = "PIVOT_SNAP_POS"
                end
            end)
        end
        if why == nil and pivotT >= PIVOT_SNAP_TIME then why = "PIVOT_SNAP_TIME" end
        if why == nil then return end
        dbg("pivot snap at t=%.3f (%s)", pivotT, why)
        rotation.Yaw = pivotTargetYaw
        pivotDone    = true
    else
        local pivotAlpha = math.min(pivotT / PIVOT_TIME, 1.0)
        rotation.Yaw = PIVOT_FN(pivotStartYaw, pivotTargetYaw, pivotAlpha)
        pivotDone    = pivotAlpha >= 1.0
    end
    pawn:K2_SetActorRotation(rotation, false)
end

local function BeginTurn(f, dot, pawn)
    local sprintClass = peakSpeed > SPRINT_PEAK
    phase, turnT     = PHASE_SKID, 0
    skidX, skidY     = f.vx / f.spd, f.vy / f.spd
    skidSpeed        = f.spd                   -- skid from actual speed

    -- Resolved once at phase entry, not per frame: this is state
    -- configuration. The end speed is referenced to the tracked PEAK, not to
    -- instantaneous speed: the dot gate cannot fire until the reversal has
    -- already collapsed velocity, so f.spd at trigger is post-collapse and
    -- scrubbing a fraction of it would penalise the same loss twice.
    local peakReferencedFloor = peakSpeed * SKID_END_PEAK_FRAC
    local flooredEndSpeed     = math.max(peakReferencedFloor, SKID_END_FLOOR)
    -- A floor above the entry speed would make the skid accelerate.
    skidEndSpeed              = math.min(skidSpeed, flooredEndSpeed)

    launchX, launchY = f.ix, f.iy
    launchSpeed      = peakSpeed *             -- but launch from peak
        (sprintClass and LAUNCH_FRAC or LAUNCH_FRAC_WALK)

    LockMoveInput(pawn)
    pivotSnap = PlaySkidAnimation(sprintClass and "sprint" or "walk")
    pivotDone = false

    local currentRotation = pawn:K2_GetActorRotation()
    pivotT                = 0
    pivotStartYaw         = currentRotation.Yaw
    local launchYawDeg    = math.deg(math.atan(launchY, launchX))
    -- Shortest signed path, so a pivot across the +/-180 seam does not sweep
    -- the long way around.
    local shortestYawDelta = ((launchYawDeg - pivotStartYaw + 180) % 360) - 180
    pivotTargetYaw         = pivotStartYaw + shortestYawDelta

    dbg("TURN [%s] dot=%+.2f spd=%.0f peak=%.0f launch=%.0f end=%.0f  Fwd=%s Rt=%s",
        sprintClass and "sprint" or "walk", dot, f.spd, peakSpeed, launchSpeed,
        skidEndSpeed,
        tostring(ReadOpt(animInstance, "Forward")),
        tostring(ReadOpt(animInstance, "Right")))
end

local function TickSkidPhase(cmc)
    if turnT < SKID_TIME then
        local skidCurrentSpeed = SKID_FN(skidSpeed, skidEndSpeed, turnT / SKID_TIME)
        cmc.Velocity.X = skidX * skidCurrentSpeed
        cmc.Velocity.Y = skidY * skidCurrentSpeed
    else
        phase, turnT = PHASE_LAUNCH, 0
        dbg("LAUNCH %.0f -> (%+.2f,%+.2f)", launchSpeed, launchX, launchY)
    end
end

-- Reassert for a few frames so PhysCustom's per-frame decay cannot bleed
-- the exit speed.
-- Input stays locked until the facing is final as well: unlocking while
-- the capsule still faces the old heading would let orient-to-movement
-- start its own rotation and fight the snap.
local function TickLaunchPhase(cmc, pawn)
    cmc.Velocity.X = launchX * launchSpeed
    cmc.Velocity.Y = launchY * launchSpeed
    if turnT >= LAUNCH_HOLD and pivotDone then
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        UnlockMoveInput(pawn)
    end
end

-- Per-tick trace while a turn is active: capsule yaw against velocity
-- heading, montage state, and the ABP's locomotion flags. Exists to catch
-- the game rotating the capsule or dropping the montage on its own.
local function TraceTurn(f, pawn)
    if not DEBUG_TURN_TRACE then return end
    local yaw = -1
    if pawn and pawn:IsValid() then
        local ok, rot = pcall(function() return pawn:K2_GetActorRotation() end)
        if ok and rot then yaw = rot.Yaw end
    end
    local velYaw = (f.spd > 1e-3) and math.deg(math.atan(f.vy, f.vx)) or 0
    local playing, pos = "?", -1
    local anim = ResolveAnimInstance()
    if anim then
        for _, montage in pairs(skidMontageCache) do
            if montage and montage:IsValid() then
                pcall(function()
                    playing = tostring(anim:Montage_IsPlaying(montage))
                    pos     = anim:Montage_GetPosition(montage)
                end)
            end
        end
    end
    dbg("trace t=%.3f ph=%d yaw=%.0f vel=%.0f spd=%.0f montage=%s@%.2f walk=%s sprint=%s lock=%s",
        pivotT, phase, yaw, velYaw, f.spd, playing, pos,
        tostring(anim and ReadOpt(anim, "IsWalking")),
        tostring(anim and ReadOpt(anim, "IsSprint")),
        tostring(moveInputLocked))
end

-- Once started, only physical invalidation stops it. Input release and
-- sprint-flag loss are NOT aborts.
local function RunCommittedTurn(dt, cmc, f, pawn)
    if not IsTurnCapableMode(f.mode, f.custom) then
        dbg("turn aborted: mode=%d/%d", f.mode, f.custom)
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        pivotDone = true
        UnlockMoveInput(pawn)
        return false
    end

    turnT = turnT + dt
    -- Separate accumulator: turnT resets to 0 at the SKID -> LAUNCH handoff,
    -- which would restart the pivot mid-way through it.
    pivotT = pivotT + dt
    TickPivot(pawn)
    TraceTurn(f, pawn)

    -- Launch direction is captured at the trigger and deliberately NOT
    -- re-steered: letting live input rewrite it allowed the player to cancel
    -- a turnaround mid-skid. Moot while input is locked, kept as a guard.

    if phase == PHASE_SKID then
        TickSkidPhase(cmc)
    else
        TickLaunchPhase(cmc, pawn)
    end
    return true
end

local function WatchForReversal(dt, f, pawn)
    if not IsTurnCapableMode(f.mode, f.custom) then
        peakSpeed = 0
        return false
    end

    -- Momentum is gated on the tracked peak, not instantaneous speed: the
    -- reversal itself collapses speed, so an instantaneous gate races the
    -- dot gate and the trigger window closes before the dot goes negative.
    peakSpeed = math.max(f.spd, peakSpeed - PEAK_DECAY * dt)

    local dot = 0
    if f.imag > 1e-3 and f.spd > 1e-3 then
        dot = (f.ix * f.vx + f.iy * f.vy) / f.spd
    end

    if turnCool == 0 and dot < TURN_DOT
       and peakSpeed > TURN_MIN_PEAK and f.spd > TURN_MIN_SPEED
       and f.analog > TURN_MIN_ANALOG then
        BeginTurn(f, dot, pawn)
        return true
    end

    return false
end

-- Returns true while a turn owns velocity.
local function UpdateSlidingTurn(dt, cmc, f, pawn)
    if turnCool > 0 then
        turnCool = math.max(0, turnCool - dt)
    end

    if phase ~= PHASE_NONE then
        return RunCommittedTurn(dt, cmc, f, pawn)
    end
    return WatchForReversal(dt, f, pawn)
end

-- =========================================================================
-- 9. ARC RETENTION
-- Cancel the chord shortfall of the engine's rotate-toward. Direction is
-- left exactly as CalcVelocity produced it, so the arc is unchanged; only
-- the magnitude is put back. Runs on grounded locomotion with input held,
-- outside the sliding turn (which deliberately sheds speed).
-- =========================================================================

local function RetainTurnSpeed(dt, cmc, f, walled)
    if not KEEP_ON or phase ~= PHASE_NONE then
        keepSpeed, keepActive = 0, false
        return
    end

    if not IsTurnCapableMode(f.mode, f.custom) then
        keepSpeed, keepActive = 0, false
        return
    end

    -- Wall contact: accept the loss; restoring it is the glide bug.
    if walled then
        keepSpeed, keepActive = f.spd, false
        return
    end

    -- Decay is a release behaviour, not a turn behaviour. While the stick is
    -- held, keepSpeed is a setpoint rather than a memory -- bleeding it at
    -- 200 uu/s^2 through a realign is what made every corner cost speed,
    -- and cost proportionally more against the lower walk cap.
    local inputHeld = (f.imag > 1e-3 and f.analog >= KEEP_MIN_ANALOG)
    if inputHeld then
        keepSpeed = math.max(f.spd, keepSpeed)
    else
        keepSpeed = math.max(f.spd, keepSpeed - KEEP_DECAY * dt)
    end

    if not inputHeld or f.spd < KEEP_MIN_SPEED then
        keepActive = false
        return
    end

    local dot = (f.ix * f.vx + f.iy * f.vy) / f.spd

    -- Straight line: leave the engine alone. Hard reversal: that belongs to
    -- the sliding turn, not here.
    if dot > KEEP_MAX_DOT or dot < KEEP_MIN_DOT then
        keepActive = false
        return
    end

    local speedCeiling = SpeedCeiling(cmc, f.mode, f.custom)
    -- CalcVelocity scales its own max by AnalogInputModifier, so the
    -- commanded ceiling is scaled identically -- otherwise retention would
    -- restore speed the stick is not asking for.
    local commandedCeiling = speedCeiling * f.analog
    local target           = math.min(keepSpeed * KEEP_FRAC, commandedCeiling)

    if target > f.spd + 0.5 then
        local speedScale = target / f.spd
        cmc.Velocity.X = f.vx * speedScale
        cmc.Velocity.Y = f.vy * speedScale
        if DEBUG_KEEP and not keepActive then
            dbg("keep: dot=%+.2f %.0f -> %.0f (ceiling %.0f)",
                dot, f.spd, target, commandedCeiling)
        end
        keepActive = true
    else
        keepActive = false
    end
end

-- =========================================================================
-- 10. AIR / GROUND BRAKING SELECT
-- bUseSeparateBrakingFriction is GLOBAL: while true, CalcVelocity uses
-- BrakingFriction in EVERY mode, so the ground stop value lands on falling
-- as air drag. Off while falling => air uses FallingLateralFriction (0)
-- and BrakingDecelerationFalling (0), i.e. no horizontal decay. This also
-- removes the over-max clamp's bite, since GetMaxSpeed() reports
-- MaxWalkSpeed while falling and a sprint-speed takeoff would otherwise
-- be braked down to walk speed.
-- =========================================================================

local function SelectBrakingFriction(cmc, mode)
    local wantSplit = (mode ~= 3)
    if lastSplit ~= wantSplit then
        cmc.bUseSeparateBrakingFriction = wantSplit
        lastSplit = wantSplit
    end
end

local function DebugAirFrame(cmc, mode)
    if DEBUG_AIR and mode == 3 then
        local v = cmc.Velocity
        dbg("air spd=%.0f cap=%.0f vz=%.0f brakeFall=%s",
            math.sqrt(v.X * v.X + v.Y * v.Y), cmc.MaxWalkSpeed, v.Z,
            tostring(ReadOpt(cmc, "BrakingDecelerationFalling")))
    end
end

-- =========================================================================
-- 11. LANDING
-- Seed the ease from the speed actually carried in, so the cap glides
-- down instead of the over-max clamp braking on touchdown.
-- =========================================================================

local function HandleLanding(cmc)
    if not wasAirborne then return end
    wasAirborne = false
    local landingSpeed = Speed2D(cmc)
    if landingSpeed > STOP_SPEED then
        moving = true
        Retarget(math.max(landingSpeed, START_CAP), desired or START_CAP)
        WriteCap(cmc, CurrentCap())
    end
    dbg("landed at %.0f", landingSpeed)
end

-- =========================================================================
-- 12. BUILDUP
-- =========================================================================

-- A live turn owns velocity. Hold the cap open so the ease cannot clamp
-- the launch; leaving `moving` false makes the ease re-seed from the real
-- speed on the frame the turn releases.
local function HoldCapOpenForLaunch(cmc)
    moving = false
    WriteCap(cmc, math.max(desired or START_CAP, launchSpeed))
end

-- Capture game-side rewrites of the walk cap (buffs, encumbrance).
-- Sprint does NOT route through MaxWalkSpeed (dedicated fields).
local function CaptureGameWalkCap(cmc)
    local cur = cmc.MaxWalkSpeed
    if (lastWrite == nil or math.abs(cur - lastWrite) > 0.5)
       and (desired == nil or math.abs(cur - desired) > 0.5) then
        desired = cur
        dbg("Game set walk top speed: %.0f", desired)
        if moving then Retarget(CurrentCap(), desired) end
    end
end

-- Fresh speed read here on purpose: retention may have rescaled velocity
-- after the frame sample, and the ease must see the real value.
local function AdvanceBuildupEase(dt, cmc)
    local speed2d = Speed2D(cmc)

    if moving then
        if speed2d < STOP_SPEED then
            moving = false
        else
            easeT = math.min(easeT + dt, easeDur)
        end
    else
        if speed2d > STOP_SPEED then
            moving = true
            Retarget(math.max(START_CAP, speed2d), desired or START_CAP)
        end
    end

    WriteCap(cmc, moving and CurrentCap() or START_CAP)
end


local LEAN_PROBE_DEGREES = 70.0    -- unmistakable, not subtle
local leanProbeChannel = 0         -- 0 = off, 1..3 = channel under test

-- Re-asserted every tick: if the ABP overwrites the variable each update,
-- a one-shot write would appear to do nothing and we would wrongly rule the
-- channel out. Writing every frame distinguishes "inert" from "contested".
local function TickLeanProbe()
    if leanProbeChannel == 0 then return end
    if animInstance == nil or not animInstance:IsValid() then return end

    pcall(function()
        if leanProbeChannel == 1 then
            animInstance.Ride_SpineAddRotate.Roll = LEAN_PROBE_DEGREES
            animInstance.Ride_SpineWeight         = 1.0
elseif leanProbeChannel == 2 then
            -- Scale FIRST. A zeroed FTransform has Scale3D (0,0,0), and
            -- enabling the override with that collapses every affected bone
            -- to a point -- the mesh disappears.
            animInstance.BP_OverrideTransform.Scale3D.X     = 1.0
            animInstance.BP_OverrideTransform.Scale3D.Y     = 1.0
            animInstance.BP_OverrideTransform.Scale3D.Z     = 1.0
            animInstance.BP_OverrideTransform.Translation.Z = 50.0
            animInstance.OverrideTransformAlpha             = 1.0
            animInstance.bOverrideTransform                 = true
        elseif leanProbeChannel == 3 then
            animInstance.AimRotatorForSpine.Yaw = LEAN_PROBE_DEGREES
        end
    end)
end

local function ClearLeanProbe()
    if animInstance == nil or not animInstance:IsValid() then return end
    pcall(function()
        -- Flag first: zeroing the transform while the override is still
        -- active would apply the zeroed value for a frame.
        animInstance.bOverrideTransform      = false
        animInstance.OverrideTransformAlpha  = 0.0
        animInstance.Ride_SpineWeight        = 0.0
        animInstance.Ride_SpineAddRotate.Roll = 0.0
        animInstance.AimRotatorForSpine.Yaw  = 0.0
        animInstance.BP_OverrideTransform.Translation.Z = 0.0
        -- Left at unit, deliberately, not zero.
        animInstance.BP_OverrideTransform.Scale3D.X = 1.0
        animInstance.BP_OverrideTransform.Scale3D.Y = 1.0
        animInstance.BP_OverrideTransform.Scale3D.Z = 1.0
    end)
end

RegisterKeyBind(Key.L, function()
    ClearLeanProbe()
    leanProbeChannel = 3
    dbg("lean probe channel -> %d", 3)
end)

-- =========================================================================
-- 13. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    moveInputLocked = false
    
    -- Captured once per session. Re-reading on a later cache would read the
    -- already-scaled value and scale it a second time (540 * 0.8 * 0.8).
    if originalRotationRateYaw == nil then
        local rotationRate = ReadOpt(cmc, "RotationRate")
        originalRotationRateYaw = rotationRate and rotationRate.Yaw or nil
    end
    if originalRotationRateYaw ~= nil then
        cmc.RotationRate.Yaw = originalRotationRateYaw * ROTATION_RATE
    end

    cachedPawn = pawn
    desired    = cmc.MaxWalkSpeed
    moving     = false
    lastWrite  = nil
    prevSpd, wallT = nil, 0
    capFrom, capTo, easeT, easeDur, easeFn = 0, START_CAP, 0, 0, nil

    -- Turn, air and retention state must reset too, or a respawn mid-skid
    -- shoves the new pawn along the dead pawn's stored direction.
    phase, turnT, turnCool, peakSpeed = PHASE_NONE, 0, 0, 0
    pivotT, pivotStartYaw, pivotTargetYaw = 0, 0, 0
    pivotSnap, pivotDone = false, false
    activeSkidMontage    = nil
    lastSplit, wasAirborne = nil, false
    keepSpeed, keepActive = 0, false

    -- Lean + sprint cycle: the old pawn's montages are gone with the old
    -- mesh, and a filtered amount carried across a respawn would land a
    -- phantom lean on the new one.
    mv.sprintMontage, mv.sprintRate = nil, 0
    mv.rate, mv.amount, mv.prevHeadingYaw = 0, 0, nil
    mv.scrubKey, mv.scrubMontage, mv.spineWritten = nil, nil, false
    mv.montageCache, mv.clipLength = {}, {}
    mv.apiChecked = false

    -- The old pawn's anim instance may still report valid, in which case
    -- the lazy re-cache on the next tick would never fire and
    -- animInstanceAddress would stay stale for the rest of the session.
    animInstance, animInstanceAddress = nil, nil

    if not pawn or not pawn:IsValid() then return end

    local footIKComponent = pawn.FootIKComponent
    if footIKComponent and footIKComponent:IsValid() then
        dbg("[move] Foot IK valid")
        if not footIKComponent.bIsEnableFootIK then
            dbg("[move] Foot IK is DISABLED, enabling...")
            footIKComponent.bIsEnableFootIK = true
        end
    end

    -- Local name differs from the module-level `animInstance` on purpose:
    -- shadowing it here would make the assignment look global and hide the
    -- fact that the module cache is populated lazily on the first tick.
    local resolvedAnimInstance = ResolveAnimInstance()
    if resolvedAnimInstance and resolvedAnimInstance:IsValid() then
        if DEBUG_CHANNELS then LogAnimChannels(resolvedAnimInstance) end
        resolvedAnimInstance.DebugEnableLeaning            = true
        resolvedAnimInstance.AnimNotifyForceDisableLeaning = false
    end

    -- Report the sprint fields before touching anything (fills the baseline).
    dbg("vanilla: walk=%.0f  SprintMaxSpeed=%s  SprintMaxAcceleration=%s  SprintYawRate=%s",
        desired,
        tostring(ReadOpt(cmc, "SprintMaxSpeed")),
        tostring(ReadOpt(cmc, "SprintMaxAcceleration")),
        tostring(ReadOpt(cmc, "SprintYawRate")))

    local rotationRate = cmc.RotationRate
    dbg("rot: RotationRate=(P%.0f Y%.0f R%.0f) OrientToMovement=%s ControllerDesired=%s MinAnalogWalk=%s",
        rotationRate.Pitch, rotationRate.Yaw, rotationRate.Roll,
        tostring(ReadOpt(cmc, "bOrientRotationToMovement")),
        tostring(ReadOpt(cmc, "bUseControllerDesiredRotation")),
        tostring(ReadOpt(cmc, "MinAnalogWalkSpeed")))

    cmc.MaxAcceleration             = MAX_ACCEL
    cmc.BrakingDecelerationWalking  = BRAKING_DECEL
    cmc.GroundFriction              = GROUND_FRICTION
    cmc.bUseSeparateBrakingFriction = USE_SEPARATE_BRAKING
    cmc.BrakingFriction             = BRAKING_FRICTION
    cmc.BrakingFrictionFactor       = BRAKING_FRICTION_FACTOR
    lastSplit                       = USE_SEPARATE_BRAKING

    WriteOpt(cmc, "SprintMaxAcceleration", SPRINT_ACCEL)
    WriteOpt(cmc, "SprintMaxSpeed",        SPRINT_MAX_SPEED)
    WriteOpt(cmc, "SprintYawRate",         SPRINT_YAW)

    -- Cache the sprint ceiling for the retention clamp.
    sprintCap = ReadOpt(cmc, "SprintMaxSpeed") or SPRINT_MAX_SPEED

    cmc.AirControl = AIR_CONTROL
    WriteOpt(cmc, "AirControlBoostMultiplier", AIR_CONTROL_BOOST_MULT)
    WriteOpt(cmc, "FallingLateralFriction",    FALLING_LATERAL_FRICTION)

    dbg("air: AirControl=%s BoostMult=%s BoostThresh=%s FallingLateralFriction=%s",
        tostring(ReadOpt(cmc, "AirControl")),
        tostring(ReadOpt(cmc, "AirControlBoostMultiplier")),
        tostring(ReadOpt(cmc, "AirControlBoostVelocityThreshold")),
        tostring(ReadOpt(cmc, "FallingLateralFriction")))

    -- Preload skid clips, once per distinct asset. This runs on every
    -- spawn and world reload by design: a reload GCs the montage, and this
    -- is the first game-thread point where a sync load is acceptable. When
    -- the clip is still resident it costs one StaticFindObject per path.
    local seen = {}
    for _, path in pairs(SKID_MONTAGES) do
        if not SKID_ANIM_ENABLED then break end
        if not seen[path] then
            seen[path] = true
            if LoadSkidMontage(path) == nil then
                dbg("skid montage failed to load: %s", path)
            end
        end
    end

    do
        for key, path in pairs(MOVE_ANIMS) do
            if LoadMontageInto(mv.montageCache, path) == nil then
                dbg("move montage %s failed to load: %s", key, path)
            end
        end
    end

    LogSkidSkeletons(pawn)
end

-- A deceleration no braking path can produce while input is held means the
-- environment took the speed (wall or prop impact). While latched, both
-- momentum memories resync to the real speed instead of restoring it:
-- a collision is a legitimate loss of momentum.
-- Gated to dot > TURN_DOT because a hard reversal's own friction shave
-- approaches the threshold; reversals belong to the turn system.
local function UpdateWallContact(dt, f)
    local hit = false
    if f.grounded and phase == PHASE_NONE and prevSpd ~= nil
       and f.analog >= KEEP_MIN_ANALOG and dt > 1e-4 then
        local dot = 1
        if f.imag > 1e-3 and f.spd > 1e-3 then
            dot = (f.ix * f.vx + f.iy * f.vy) / f.spd
        end
        if dot > TURN_DOT and (prevSpd - f.spd) / dt > WALL_DECEL then
            hit = true
        end
    end
    prevSpd = f.grounded and f.spd or nil

    if hit then
        if wallT <= 0 then dbg("wall contact: memories resynced") end
        wallT = WALL_HOLD
    elseif wallT > 0 then
        wallT = math.max(0, wallT - dt)
    end
    return wallT > 0
end

function M.OnTick(dt, pawn, cmc)
    local frame = ReadFrame(cmc)
    -- Lazy: the pawn's components are not initialised at construction, so
    -- the instance is resolved on the first tick that can see it.
    if animInstance == nil or not animInstance:IsValid() then
        CacheAnimInstance()
    end
    TickLeanProbe()

    -- Above every early return: an abort while airborne would otherwise
    -- strand the lock until the next grounded frame that reaches here.
    local lockOutlivedTurn = (phase == PHASE_NONE and moveInputLocked)
    if lockOutlivedTurn then UnlockMoveInput(pawn) end

    local walled  = UpdateWallContact(dt, frame)
    local turning = UpdateSlidingTurn(dt, cmc, frame, pawn)
    RetainTurnSpeed(dt, cmc, frame, walled)
    -- After the turn and retention: the measured heading rate must see the
    -- velocity the engine will actually integrate this frame. Runs on air
    -- frames too, so the lean decays and the sprint cycle stops the frame
    -- the ground is lost.
    UpdateMoveAnim(dt, frame)

    DebugAirFrame(cmc, frame.mode)
    SelectBrakingFriction(cmc, frame.mode)

    if not frame.grounded then
        -- Falling only. Sprint is mode 6 and must NOT arm the landing path.
        if frame.mode == 3 then wasAirborne = true end
        return                                  -- keep momentum through jumps
    end

    HandleLanding(cmc)

    if turning then
        HoldCapOpenForLaunch(cmc)
        return
    end

    CaptureGameWalkCap(cmc)
    AdvanceBuildupEase(dt, cmc)
end

return M
