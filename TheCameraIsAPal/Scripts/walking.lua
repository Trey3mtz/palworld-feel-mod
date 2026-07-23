-- =========================================================================
-- PalFeel subsystem: walking — Odyssey-style buildup and momentum
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
-- Air                : bUseSeparateBrakingFriction is GLOBAL, so it must be
--                      toggled off while falling or the ground stop value
--                      lands on the air as drag. See OnTick.
-- =========================================================================

local Easing = require("easingfunctions")

-- ---- standstill -> walk easing ----
local START_CAP   = 150     -- cap at the first instant of movement (uu/s)
local STOP_SPEED  = 50      -- below this 2D speed we count as standing
local EASE_UP_TIME,   EASE_UP_FN   = 0.50, Easing.EaseInSine
local EASE_DOWN_TIME, EASE_DOWN_FN = 0.80, Easing.EaseOutQuad

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

local DEBUG      = true
local DEBUG_AIR  = false   -- per-frame falling log
local DEBUG_KEEP = true    -- logs each retention burst once

local M = { name = "walking" }

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

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:walk] " .. fmt .. "\n", ...)) end
end

local function Retarget(from, to)
    capFrom, capTo, easeT = from, to, 0
    if to >= from then easeDur, easeFn = EASE_UP_TIME, EASE_UP_FN
    else easeDur, easeFn = EASE_DOWN_TIME, EASE_DOWN_FN end
end

local function CurrentCap()
    if easeFn == nil or easeDur <= 0 then return capTo end
    return easeFn(capFrom, capTo, easeT / easeDur)
end

local function Write(cmc, cap)
    if lastWrite == nil or math.abs(cap - lastWrite) > 0.5 then
        cmc.MaxWalkSpeed = cap
        lastWrite = cap
    end
end

-- Read a property that may not exist under this exact name.
-- NOTE: must not collapse a legitimate `false` to nil, or boolean-false
-- states become indistinguishable from unreadable fields.
local function ReadOpt(cmc, prop)
    local ok, v = pcall(function() return cmc[prop] end)
    if not ok then return nil end
    return v
end

local function WriteOpt(cmc, prop, value, label)
    if value == nil then return end
    local ok, err = pcall(function() cmc[prop] = value end)
    if ok then dbg("%s -> %s", label or prop, tostring(value))
    else dbg("WRITE FAILED for %s: %s", prop, tostring(err)) end
end

-- Grounded locomotion the turn may run through. Sprint may lapse to plain
-- Walking as speed collapses — that is expected, not an abort.
--   1 = Walking, 2 = NavWalking, 6 = MOVE_Custom (custom 2 = Sprint)
local function TurnStillValid(mode, custom)
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

-- Returns true while a turn owns velocity.
local function UpdateTurn(dt, cmc)
    if turnCool > 0 then turnCool = math.max(0, turnCool - dt) end

    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local v, a   = cmc.Velocity, cmc.Acceleration
    local spd    = math.sqrt(v.X * v.X + v.Y * v.Y)
    local imag   = math.sqrt(a.X * a.X + a.Y * a.Y)
    local analog = ReadOpt(cmc, "AnalogInputModifier") or 0
    local ix, iy = 0, 0
    if imag > 1e-3 then ix, iy = a.X / imag, a.Y / imag end

    -- ---------------- committed run ----------------
    -- Once started, only physical invalidation stops it. Input release and
    -- sprint-flag loss are NOT aborts.
    if phase ~= PHASE_NONE then
        if not TurnStillValid(mode, custom) then
            dbg("turn aborted: mode=%d/%d", mode, custom)
            phase, turnCool = PHASE_NONE, TURN_COOLDOWN
            return false
        end

        turnT = turnT + dt
        -- Steer the launch while input exists; otherwise the direction
        -- captured at trigger stands.
        if imag > 1e-3 then launchX, launchY = ix, iy end

        if phase == PHASE_SKID then
            if turnT < SKID_TIME then
                local s = SKID_FN(skidSpeed, skidSpeed * SKID_END_FRAC,
                                  turnT / SKID_TIME)
                cmc.Velocity.X = skidX * s
                cmc.Velocity.Y = skidY * s
            else
                phase, turnT = PHASE_LAUNCH, 0
                dbg("LAUNCH %.0f -> (%+.2f,%+.2f)",
                    launchSpeed, launchX, launchY)
            end
            return true
        end

        -- PHASE_LAUNCH: reassert for a few frames so PhysCustom's per-frame
        -- decay cannot bleed the exit speed.
        cmc.Velocity.X = launchX * launchSpeed
        cmc.Velocity.Y = launchY * launchSpeed
        if turnT >= LAUNCH_HOLD then
            phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        end
        return true
    end

    -- ---------------- idle: track peak, watch for trigger ----------------
    if not TurnStillValid(mode, custom) then peakSpeed = 0 return false end

    -- Momentum is gated on the tracked peak, not instantaneous speed: the
    -- reversal itself collapses speed, so an instantaneous gate races the
    -- dot gate and the trigger window closes before the dot goes negative.
    peakSpeed = math.max(spd, peakSpeed - PEAK_DECAY * dt)

    local dot = 0
    if imag > 1e-3 and spd > 1e-3 then dot = (ix * v.X + iy * v.Y) / spd end

    if turnCool == 0 and dot < TURN_DOT
       and peakSpeed > TURN_MIN_PEAK and spd > TURN_MIN_SPEED
       and analog > TURN_MIN_ANALOG then
        local sprintClass = peakSpeed > SPRINT_PEAK
        phase, turnT     = PHASE_SKID, 0
        skidX, skidY     = v.X / spd, v.Y / spd
        skidSpeed        = spd                     -- skid from actual speed
        launchX, launchY = ix, iy
        launchSpeed      = peakSpeed *             -- but launch from peak
            (sprintClass and LAUNCH_FRAC or LAUNCH_FRAC_WALK)
        dbg("TURN [%s] dot=%+.2f spd=%.0f peak=%.0f launch=%.0f",
            sprintClass and "sprint" or "walk", dot, spd, peakSpeed, launchSpeed)
        return true
    end

    return false
end

-- Cancel the chord shortfall of the engine's rotate-toward. Direction is
-- left exactly as CalcVelocity produced it, so the arc is unchanged; only
-- the magnitude is put back. Runs on grounded locomotion with input held,
-- outside the sliding turn (which deliberately sheds speed).
local function RetainTurnSpeed(dt, cmc)
    if not KEEP_ON or phase ~= PHASE_NONE then
        keepSpeed, keepActive = 0, false
        return
    end

    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    if not TurnStillValid(mode, custom) then
        keepSpeed, keepActive = 0, false
        return
    end

    local v      = cmc.Velocity
    local a      = cmc.Acceleration
    local spd    = math.sqrt(v.X * v.X + v.Y * v.Y)
    local imag   = math.sqrt(a.X * a.X + a.Y * a.Y)
    local analog = ReadOpt(cmc, "AnalogInputModifier") or 0

    -- Remember recent speed, bleeding slowly so a genuine slowdown (wall,
    -- slope, encumbrance) is not held forever.
    keepSpeed = math.max(spd, keepSpeed - KEEP_DECAY * dt)

    if imag < 1e-3 or analog < KEEP_MIN_ANALOG or spd < KEEP_MIN_SPEED then
        keepActive = false
        return
    end

    local ix, iy = a.X / imag, a.Y / imag
    local dot = (ix * v.X + iy * v.Y) / spd

    -- Straight line: leave the engine alone. Hard reversal: that belongs to
    -- the sliding turn, not here.
    if dot > KEEP_MAX_DOT or dot < TURN_DOT then
        keepActive = false
        return
    end

    local ceil   = SpeedCeiling(cmc, mode, custom)
    local target = math.min(keepSpeed * KEEP_FRAC, ceil)
    if target > spd + 0.5 then
        local k = target / spd
        cmc.Velocity.X = v.X * k
        cmc.Velocity.Y = v.Y * k
        if DEBUG_KEEP and not keepActive then
            dbg("keep: dot=%+.2f %.0f -> %.0f (ceil %.0f)", dot, spd, target, ceil)
        end
        keepActive = true
    else
        keepActive = false
    end
end

function M.OnPlayerCached(pawn, cmc)
    desired   = cmc.MaxWalkSpeed
    moving    = false
    lastWrite = nil
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

function M.OnTick(dt, pawn, cmc)
    local turning = UpdateTurn(dt, cmc)
    RetainTurnSpeed(dt, cmc)

    local mode     = cmc.MovementMode
    local grounded = (mode == 1 or mode == 2)   -- Walking / NavWalking

    if DEBUG_AIR and mode == 3 then
        local v = cmc.Velocity
        dbg("air spd=%.0f cap=%.0f vz=%.0f brakeFall=%s",
            math.sqrt(v.X * v.X + v.Y * v.Y), cmc.MaxWalkSpeed, v.Z,
            tostring(ReadOpt(cmc, "BrakingDecelerationFalling")))
    end

    -- bUseSeparateBrakingFriction is GLOBAL: while true, CalcVelocity uses
    -- BrakingFriction in EVERY mode, so the ground stop value lands on
    -- falling as air drag. Off while falling => air uses
    -- FallingLateralFriction (0) and BrakingDecelerationFalling (0), i.e.
    -- no horizontal decay. This also removes the over-max clamp's bite,
    -- since GetMaxSpeed() reports MaxWalkSpeed while falling and a
    -- sprint-speed takeoff would otherwise be braked down to walk speed.
    local wantSplit = (mode ~= 3)
    if lastSplit ~= wantSplit then
        cmc.bUseSeparateBrakingFriction = wantSplit
        lastSplit = wantSplit
    end

    if not grounded then
        -- Falling only. Sprint is mode 6 and must NOT arm the landing path.
        if mode == 3 then wasAirborne = true end
        return                                  -- keep momentum through jumps
    end

    -- Landed: seed the ease from the speed actually carried in, so the cap
    -- glides down instead of the over-max clamp braking on touchdown.
    if wasAirborne then
        wasAirborne = false
        local v0 = cmc.Velocity
        local s0 = math.sqrt(v0.X * v0.X + v0.Y * v0.Y)
        if s0 > STOP_SPEED then
            moving = true
            Retarget(math.max(s0, START_CAP), desired or START_CAP)
            Write(cmc, CurrentCap())
        end
        dbg("landed at %.0f", s0)
    end

    -- A live turn owns velocity. Hold the cap open so the ease cannot clamp
    -- the launch; leaving `moving` false makes the ease re-seed from the
    -- real speed on the frame the turn releases.
    if turning then
        moving = false
        Write(cmc, math.max(desired or START_CAP, launchSpeed))
        return
    end

    -- Capture game-side rewrites of the walk cap (buffs, encumbrance).
    -- Sprint does NOT route through MaxWalkSpeed (dedicated fields).
    local cur = cmc.MaxWalkSpeed
    if (lastWrite == nil or math.abs(cur - lastWrite) > 0.5)
       and (desired == nil or math.abs(cur - desired) > 0.5) then
        desired = cur
        dbg("Game set walk top speed: %.0f", desired)
        if moving then Retarget(CurrentCap(), desired) end
    end

    local v = cmc.Velocity
    local speed2d = math.sqrt(v.X * v.X + v.Y * v.Y)

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

    Write(cmc, moving and CurrentCap() or START_CAP)
end

return M
