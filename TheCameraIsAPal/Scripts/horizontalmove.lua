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
--         5 walk-cap ease · 6 animation (montage + probes) ·
--         7 sliding turn · 8 arc retention · 9 air/ground braking ·
--         10 landing · 11 buildup · 12 lifecycle
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

local SKID_TIME          = 0.25
local SKID_END_PEAK_FRAC = 0.45   -- end speed as a fraction of tracked PEAK
local SKID_END_FLOOR     = 150    -- uu/s absolute floor
local LAUNCH_HOLD        = 0.20   -- s reasserting launch, so the write takes

local PIVOT_TIME = 0.24                 -- s
local PIVOT_FN   = Easing.EaseOutCirc   -- (from, to, alpha), like SKID_FN

local SPRINT_PEAK      = 450    -- peak above this = sprint-class turn
local LAUNCH_FRAC      = 0.85   -- sprint-class
local LAUNCH_FRAC_WALK = 0.51   -- 51% of the sprint launch

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
local DEBUG_KEEP = false   -- logs each retention burst once
local DEBUG_ANIM = true    -- IsWalking/IsSprint flips
local DEBUG_CHANNELS = true -- lean-channel resting values, via the ABP hook

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "horizontalmove" }

local cachedPawn = nil
local originalRotationRateYaw = nil

-- ---- animation state ----
local animInstance = nil
local animInstanceAddress = nil
local prevAnimIsWalking, prevAnimIsSprint = nil, nil

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

local function GetSkidMontage(class)
    local montage = skidMontageCache[class]
    if montage and montage:IsValid() then return montage end
    montage = StaticFindObject(SKID_MONTAGES[class])
    if montage and not montage:IsValid() then montage = nil end
    skidMontageCache[class] = montage
    return montage
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

-- Read-only. Catches the speed at which the ABP flips IsWalking / IsSprint.
local function LogAnimState(frame)
    if not DEBUG_ANIM then return end
    if animInstance == nil or not animInstance:IsValid() then
        if not CacheAnimInstance() then return end
    end

    local animIsWalking = ReadOpt(animInstance, "IsWalking")
    local animIsSprint  = ReadOpt(animInstance, "IsSprint")
    local stateFlipped  = (animIsWalking ~= prevAnimIsWalking)
                       or (animIsSprint  ~= prevAnimIsSprint)

    if stateFlipped then
        dbg("anim flip: IsWalking=%s IsSprint=%s  ourSpd=%.0f abpSpeed=%s",
            tostring(animIsWalking), tostring(animIsSprint), frame.spd,
            tostring(ReadOpt(animInstance, "Speed")))
    end

    prevAnimIsWalking, prevAnimIsSprint = animIsWalking, animIsSprint
end

-- BoneListOnlySpines / BoneListFullBody are TMap<FName, UPalBoneInfo*>.
-- They are UE4SS TMap userdata, not Lua tables, so pairs() fails on them.
-- FName:get() also yields an FName OBJECT, not a string -- tostring() on
-- that prints the userdata pointer, which is why the first pass logged
-- addresses instead of bone names.
local function LogBoneList(targetAnimInstance, listPropertyName)
    local boneList = ReadOpt(targetAnimInstance, listPropertyName)
    if boneList == nil then
        dbg("%s unreachable", listPropertyName)
        return
    end

    local boneNames = {}
    local iterated = pcall(function()
        boneList:ForEach(function(boneNameKey, _boneInfo)
            local boneName = boneNameKey:get()
            local converted, boneNameString = pcall(function()
                return boneName:ToString()
            end)
            boneNames[#boneNames + 1] = converted and boneNameString or "<unreadable>"
        end)
    end)

    if not iterated then
        dbg("%s ForEach failed", listPropertyName)
        return
    end
    dbg("%s (%d): %s", listPropertyName, #boneNames, table.concat(boneNames, ", "))
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

    local overrideTranslation = "nil"
    if overrideTransform ~= nil then
        local gotTranslation, translation =
            pcall(function() return overrideTransform.Translation end)
        if gotTranslation and translation ~= nil then
            overrideTranslation = string.format("(%.1f,%.1f,%.1f)",
                translation.X or 0.0, translation.Y or 0.0, translation.Z or 0.0)
        end
        
    end

    dbg("channels: bOverride=%s alpha=%.2f rideWeight=%.2f rideRot=%s aimSpine=%s xformT=%s",
        tostring(overrideEnabled),
        overrideAlpha or 0.0,
        rideSpineWeight or 0.0,
        FormatRotator(rideSpineAddRotate),
        FormatRotator(aimRotatorForSpine),
        FormatTransform(overrideTransform))
end


-- /Game/ path: RefreshBlueprintHooks rebinds this on every pawn
-- construction. Registered as a POST hook; main.lua's Register() fills the
-- pre slot with NoOp, which UE4SS requires even for post-only hooks.
local ANIM_CHANNEL_LOG_INTERVAL = 0.5
local animChannelLogTimer = 0

local function TickAnimChannelLog(deltaTime)
    if not DEBUG_CHANNELS then return end
    if animInstance == nil or not animInstance:IsValid() then return end
    animChannelLogTimer = animChannelLogTimer + deltaTime
    if animChannelLogTimer < ANIM_CHANNEL_LOG_INTERVAL then return end
    animChannelLogTimer = 0
    LogAnimChannels(animInstance)
end

-- Either variant still playing suppresses a new play: both live in
-- DefaultGroup, so Montage_Play would cut the other mid-skid otherwise.
local function IsAnySkidPlaying(anim)
    for class in pairs(SKID_MONTAGES) do
        local montage = skidMontageCache[class]
        if montage and montage:IsValid() then
            local playing = false
            pcall(function() playing = anim:Montage_IsPlaying(montage) end)
            if playing then return true end
        end
    end
    return false
end

local function PlaySkidAnimation(class)
    local montage = GetSkidMontage(class)
    if montage == nil then return end
    local anim = ResolveAnimInstance()
    if anim == nil then return end
    if IsAnySkidPlaying(anim) then return end
    pcall(function() anim:Montage_Play(montage, 1.0, 0, 0.0, true) end)
end

-- =========================================================================
-- 7. SLIDING TURN
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
    if not (pawn and pawn:IsValid()) then return end

    local pivotAlpha = math.min(pivotT / PIVOT_TIME, 1.0)
    local rotation   = pawn:K2_GetActorRotation()
    rotation.Yaw     = PIVOT_FN(pivotStartYaw, pivotTargetYaw, pivotAlpha)
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
    PlaySkidAnimation(sprintClass and "sprint" or "walk")

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
local function TickLaunchPhase(cmc, pawn)
    cmc.Velocity.X = launchX * launchSpeed
    cmc.Velocity.Y = launchY * launchSpeed
    if turnT >= LAUNCH_HOLD then
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        UnlockMoveInput(pawn)
    end
end

-- Once started, only physical invalidation stops it. Input release and
-- sprint-flag loss are NOT aborts.
local function RunCommittedTurn(dt, cmc, f, pawn)
    if not IsTurnCapableMode(f.mode, f.custom) then
        dbg("turn aborted: mode=%d/%d", f.mode, f.custom)
        phase, turnCool = PHASE_NONE, TURN_COOLDOWN
        UnlockMoveInput(pawn)
        return false
    end

    turnT = turnT + dt
    -- Separate accumulator: turnT resets to 0 at the SKID -> LAUNCH handoff,
    -- which would restart the pivot mid-way through it.
    pivotT = pivotT + dt
    TickPivot(pawn)

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
    local landingSpeed = Speed2D(cmc)
    if landingSpeed > STOP_SPEED then
        moving = true
        Retarget(math.max(landingSpeed, START_CAP), desired or START_CAP)
        WriteCap(cmc, CurrentCap())
    end
    dbg("landed at %.0f", landingSpeed)
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
-- 12. LIFECYCLE
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
    lastSplit, wasAirborne = nil, false
    keepSpeed, keepActive = 0, false

    -- The old pawn's anim instance may still report valid, in which case
    -- LogAnimState would never re-resolve and animInstanceAddress would stay
    -- nil -- silently disarming the ABP hook for the rest of the session.
    
    animInstance, animInstanceAddress = nil, nil
    prevAnimIsWalking, prevAnimIsSprint = nil, nil
    animChannelLogTimer = 0
    

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
        local animClass = nil
        pcall(function() animClass = resolvedAnimInstance:GetClass() end)
        if animClass and animClass:IsValid() then
            local named, className = pcall(function() return animClass:GetFullName() end)
            dbg("anim class: %s", named and className or "class name read failed")
        end
        LogBoneList(resolvedAnimInstance, "BoneListOnlySpines")
        LogBoneList(resolvedAnimInstance, "BoneListFullBody")
        LogAnimChannels(resolvedAnimInstance)   -- one baseline read at spawn
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
    LogAnimState(frame)
    TickAnimChannelLog(dt)
    TickLeanProbe()

    -- Above every early return: an abort while airborne would otherwise
    -- strand the lock until the next grounded frame that reaches here.
    local lockOutlivedTurn = (phase == PHASE_NONE and moveInputLocked)
    if lockOutlivedTurn then UnlockMoveInput(pawn) end

    local walled  = UpdateWallContact(dt, frame)
    local turning = UpdateSlidingTurn(dt, cmc, frame, pawn)
    RetainTurnSpeed(dt, cmc, frame, walled)

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
    local debugEnableLeaning  = ReadOpt(animInstance, "DebugEnableLeaning")
    local forceDisableLeaning = ReadOpt(animInstance, "AnimNotifyForceDisableLeaning")
    dbg("debugEnableLeaning: %s", debugEnableLeaning)
    dbg("forceDisableLeaning: %s",forceDisableLeaning)
end

return M
