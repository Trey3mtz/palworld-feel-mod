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
-- Air                : bUseSeparateBrakingFriction is GLOBAL, so it must be
--                      toggled off while falling or the ground stop value
--                      lands on the air as drag. See OnTick.
--
-- Layout: 1 tuning · 2 state · 3 utilities · 4 frame sampling ·
--         5 walk-cap ease · 6 skid animation · 7 sliding turn ·
--         8 arc retention · 9 air/ground braking · 10 landing ·
--         11 buildup · 12 lifecycle
-- =========================================================================

local Easing = require("easingfunctions")

-- =========================================================================
-- 1. TUNING
-- =========================================================================

-- ---- standstill -> walk easing ----
local START_CAP   = 150     -- cap at the first instant of movement (uu/s)
local STOP_SPEED  = 50      -- below this 2D speed we count as standing
local EASE_UP_TIME,   EASE_UP_FN   = 0.20, Easing.EaseInSine
local EASE_DOWN_TIME, EASE_DOWN_FN = 0.50, Easing.EaseOutQuad

-- ---- sprint shaping (nil = leave vanilla) ----
local SPRINT_ACCEL     = 500    -- drives walk->sprint buildup
local SPRINT_MAX_SPEED = 610    -- vanilla = 500
local SPRINT_YAW       = nil    -- vanilla = 0.6999; lower = wider sprint arcs

-- ---- ground momentum statics ----      -- vanilla:
local MAX_ACCEL               = 2048     -- 2048 (high = speed hugs the cap)
local BRAKING_DECEL           = 1000     -- 2048 (lower = glide to a stop)
-- Friction duties are SPLIT: GroundFriction only governs how fast velocity
-- realigns to input in turns (the arc), while BrakingFriction governs the
-- stop/no-input glide independently.
local USE_SEPARATE_BRAKING    = true
local GROUND_FRICTION         = 3.5      -- 8.0 vanilla; arc rate, tau ~= 0.29s
local BRAKING_FRICTION        = 2.5      -- no-input glide (separate braking on)
local BRAKING_FRICTION_FACTOR = 1.2      -- 2.0; multiplies BrakingFriction

-- ---- turn speed retention ----
local KEEP_ON         = true
local KEEP_FRAC       = 1.00    -- 1.00 = lossless; 0.95 = slight scrub
local KEEP_MAX_DOT    = 0.995   -- above this the player is going straight
local KEEP_MIN_ANALOG = 0.35    -- must be actively holding input
local KEEP_MIN_SPEED  = 80      -- no point restoring a crawl
local KEEP_DECAY      = 200     -- uu/s^2 the remembered speed bleeds off
local KEEP_MIN_DOT = 0.0   -- retention assists forward arcs only; the
                           -- -0.35..0 band is half-reversal territory
                           
-- ---- wall contact ----
local WALL_DECEL = 6000   -- uu/s^2; no braking path reaches this with input held inside the retention window
local WALL_HOLD  = 0.20   -- s the latch persists past the last impact frame

-- ---- air ----
local AIR_CONTROL              = 0.35   -- 0.05 UE default; 0.3-0.5 = responsive
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

local SKID_TIME     = 0.32
local SKID_END_FRAC = 0.15    -- fraction of TRIGGER speed (auto-scales)
local LAUNCH_HOLD   = 0.06    -- s reasserting launch, so the write takes

local SPRINT_PEAK      = 450    -- peak above this = sprint-class turn
local LAUNCH_FRAC      = 0.85   -- sprint-class
local LAUNCH_FRAC_WALK = 0.51   -- 60% of the sprint launch

-- ---- skid animation ----
-- PLACEHOLDER clips (resident dodge montages) until authored skids exist.
-- Both target DefaultSlot on SK_PalHuman_Skeleton; blend 0.10 in / 0.35 out
-- come from the montage assets themselves.
local SKID_MONTAGES = {
    sprint = "/Game/Pal/Animation/Character/Player/Female/Dodge/AM_Player_Female_FlipBwd.AM_Player_Female_FlipBwd",
    walk   = "/Game/Pal/Animation/Character/Player/Female/Dodge/AM_Player_Female_RollFwd.AM_Player_Female_RollFwd",
}

-- ---- debug ----
local DEBUG      = true
local DEBUG_AIR  = false   -- per-frame falling log
local DEBUG_KEEP = true    -- logs each retention burst once

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "horizontalmove" }

local cachedPawn = nil

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
local skidX, skidY, skidSpeed = 0, 0, 0
local launchX, launchY, launchSpeed = 0, 0, 0

-- ---- wall contact state ----
local prevSpd = nil
local wallT   = 0

-- ---- skid animation state ----
local skidMontageCache = {}    -- class -> montage handle

-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:hmove] " .. fmt .. "\n", ...)) end
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
-- 6. SKID ANIMATION
-- One-shot montage at the turn trigger. Class ("walk"/"sprint") is decided
-- by the same peak test as the launch fraction.
-- =========================================================================

local function GetSkidMontage(class)
    local m = skidMontageCache[class]
    if m and m:IsValid() then return m end
    m = StaticFindObject(SKID_MONTAGES[class])
    if m and not m:IsValid() then m = nil end
    skidMontageCache[class] = m
    return m
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

-- Either variant still playing suppresses a new play: both live in
-- DefaultGroup, so Montage_Play would cut the other mid-skid otherwise.
local function IsAnySkidPlaying(anim)
    for class in pairs(SKID_MONTAGES) do
        local m = skidMontageCache[class]
        if m and m:IsValid() then
            local playing = false
            pcall(function() playing = anim:Montage_IsPlaying(m) end)
            if playing then return true end
        end
    end
    return false
end

local function PlaySkidAnimation(class)
    local m = GetSkidMontage(class)
    if m == nil then return end
    local anim = ResolveAnimInstance()
    if anim == nil then return end
    if IsAnySkidPlaying(anim) then return end
    pcall(function() anim:Montage_Play(m, 1.0, 0, 0.0, true) end)
end

-- =========================================================================
-- 7. SLIDING TURN
-- Three phases: NONE (watching for a reversal), SKID (velocity eased down
-- along the old heading), LAUNCH (exit speed reasserted along input).
-- =========================================================================

local function BeginTurn(f, dot)
    local sprintClass = peakSpeed > SPRINT_PEAK
    phase, turnT     = PHASE_SKID, 0
    skidX, skidY     = f.vx / f.spd, f.vy / f.spd
    skidSpeed        = f.spd                   -- skid from actual speed
    launchX, launchY = f.ix, f.iy
    launchSpeed      = peakSpeed *             -- but launch from peak
        (sprintClass and LAUNCH_FRAC or LAUNCH_FRAC_WALK)

    PlaySkidAnimation(sprintClass and "sprint" or "walk")

    dbg("TURN [%s] dot=%+.2f spd=%.0f peak=%.0f launch=%.0f",
        sprintClass and "sprint" or "walk", dot, f.spd, peakSpeed, launchSpeed)
end

local function TickSkidPhase(dt, cmc)
    if turnT < SKID_TIME then
        local s = SKID_FN(skidSpeed, skidSpeed * SKID_END_FRAC,
                          turnT / SKID_TIME)
        cmc.Velocity.X = skidX * s
        cmc.Velocity.Y = skidY * s
    else
        phase, turnT = PHASE_LAUNCH, 0
        dbg("LAUNCH %.0f -> (%+.2f,%+.2f)", launchSpeed, launchX, launchY)
    end
end

-- Reassert for a few frames so PhysCustom's per-frame decay cannot bleed
-- the exit speed.
local function TickLaunchPhase(cmc)
    cmc.Velocity.X = launchX * launchSpeed
    cmc.Velocity.Y = launchY * launchSpeed
    if turnT >= LAUNCH_HOLD then
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
    end
end

-- Once started, only physical invalidation stops it. Input release and
-- sprint-flag loss are NOT aborts.
local function RunCommittedTurn(dt, cmc, f)
    if not IsTurnCapableMode(f.mode, f.custom) then
        dbg("turn aborted: mode=%d/%d", f.mode, f.custom)
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        return false
    end

    turnT = turnT + dt
    -- Steer the launch while input exists; otherwise the direction
    -- captured at trigger stands.
    if f.imag > 1e-3 then launchX, launchY = f.ix, f.iy end

    if phase == PHASE_SKID then
        TickSkidPhase(dt, cmc)
    else
        TickLaunchPhase(cmc)
    end
    return true
end

local function WatchForReversal(dt, f)
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
        BeginTurn(f, dot)
        return true
    end

    return false
end

-- Returns true while a turn owns velocity.
local function UpdateSlidingTurn(dt, cmc, f, walled)
    if turnCool > 0 then
        turnCool = math.max(0, turnCool - dt)
    end

    if phase ~= PHASE_NONE then
        return RunCommittedTurn(dt, cmc, f)
    end
    return WatchForReversal(dt, f, walled)
end

-- =========================================================================
-- 8. ARC RETENTION
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

    keepSpeed = math.max(f.spd, keepSpeed - KEEP_DECAY * dt)

    if f.imag < 1e-3 or f.analog < KEEP_MIN_ANALOG or f.spd < KEEP_MIN_SPEED then
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

    local ceil   = SpeedCeiling(cmc, f.mode, f.custom)
    local target = math.min(keepSpeed * KEEP_FRAC, ceil)
    if target > f.spd + 0.5 then
        local k = target / f.spd
        cmc.Velocity.X = f.vx * k
        cmc.Velocity.Y = f.vy * k
        if DEBUG_KEEP and not keepActive then
            dbg("keep: dot=%+.2f %.0f -> %.0f (ceil %.0f)", dot, f.spd, target, ceil)
        end
        keepActive = true
    else
        keepActive = false
    end
end

-- =========================================================================
-- 9. AIR / GROUND BRAKING SELECT
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
-- 10. LANDING
-- Seed the ease from the speed actually carried in, so the cap glides
-- down instead of the over-max clamp braking on touchdown.
-- =========================================================================

local function HandleLanding(cmc)
    if not wasAirborne then return end
    wasAirborne = false
    local s0 = Speed2D(cmc)
    if s0 > STOP_SPEED then
        moving = true
        Retarget(math.max(s0, START_CAP), desired or START_CAP)
        WriteCap(cmc, CurrentCap())
    end
    dbg("landed at %.0f", s0)
end

-- =========================================================================
-- 11. BUILDUP
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

-- =========================================================================
-- 12. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    cachedPawn = pawn
    desired    = cmc.MaxWalkSpeed
    moving     = false
    lastWrite  = nil
    prevSpd, wallT = nil, 0
    capFrom, capTo, easeT, easeDur, easeFn = 0, START_CAP, 0, 0, nil
    -- Turn, air and retention state must reset too, or a respawn mid-skid
    -- shoves the new pawn along the dead pawn's stored direction.
    phase, turnT, turnCool, peakSpeed = PHASE_NONE, 0, 0, 0
    lastSplit, wasAirborne = nil, false
    keepSpeed, keepActive = 0, false

    -- Report the sprint fields before touching anything (fills the baseline).
    dbg("vanilla: walk=%.0f  SprintMaxSpeed=%s  SprintMaxAcceleration=%s  SprintYawRate=%s",
        desired,
        tostring(ReadOpt(cmc, "SprintMaxSpeed")),
        tostring(ReadOpt(cmc, "SprintMaxAcceleration")),
        tostring(ReadOpt(cmc, "SprintYawRate")))

    -- One-shot recon: does the mesh chase velocity (arc reads visually) or
    -- the controller (velocity arcs, body does not)?
    local rr = cmc.RotationRate
    dbg("rot: RotationRate=(P%.0f Y%.0f R%.0f) OrientToMovement=%s ControllerDesired=%s MinAnalogWalk=%s",
        rr.Pitch, rr.Yaw, rr.Roll,
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
    local f = ReadFrame(cmc)

    local walled  = UpdateWallContact(dt, f)
    local turning = UpdateSlidingTurn(dt, cmc, f, walled)
    RetainTurnSpeed(dt, cmc, f, walled)

    DebugAirFrame(cmc, f.mode)
    SelectBrakingFriction(cmc, f.mode)

    if not f.grounded then
        -- Falling only. Sprint is mode 6 and must NOT arm the landing path.
        if f.mode == 3 then wasAirborne = true end
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
