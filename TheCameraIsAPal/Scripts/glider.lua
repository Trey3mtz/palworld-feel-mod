-- =========================================================================
-- PalFeel subsystem: glider — momentum preservation and buoyant catch
-- Author: TheTr3y
--
-- Two behaviours, independent lifetimes, both owned by the deploy state:
--
--   Momentum. Opening the glider visibly discards horizontal momentum. The
--   deploy re-asserts the horizontal velocity carried into the open, for a
--   short hold window.
--
--   Buoyant catch. Vanilla caps fall speed the instant the glider opens.
--   Instead the fall speed is preserved, so the player sinks below the
--   glide line, and a restoring force proportional to that sink lifts them
--   back up -- a body pushed under water, released. Underdamped, so the
--   rise carries past the line before settling.
--
-- Neither applies to jetpack-type gliders. They fire the same
-- OnStartGliding edge but fly on an entirely separate solver.
--
-- Field model (UPalGliderComponent, native parent of BP_GliderComponent --
-- the BP child's own CurrentGliderObject is left alone, since the native
-- member is set on every path):
--   bIsGliding         : deploy state
--   CurrentGlider      : the equipped APalGliderObject
--   CurrentGliderPalID : FName of the equipped glider
--   OnStartGlidingDelegate / OnEndGlidingDelegate : native multicast edges
--
--   APalGliderObject.GliderMaxSpeed / GliderAirControl / GliderGravityScale
--       : per-item values, presumed stamped onto the identically named
--         UPalCharacterMovementComponent fields at deploy.
--   APalGliderObject.bIsJetpackType : gates everything in this file.
--
-- Frame ordering, and the risk it creates: the controller tick runs before
-- the pawn's component tick. CacheFrameState records the pre-glide velocity
-- and OnStartGliding then fires within the same frame, so the snapshot is
-- clean. But it also means every write here lands UPSTREAM of the glide
-- solver. If that solver clamps descent to a fixed rate, it clamps after
-- us and the buoyant catch does nothing at all. In that case the correct
-- fix is the inverse -- relax the field that defines the descent limit and
-- let the game's own physics produce the dip.
-- =========================================================================

local DEBUG = false
local EasingOptions = require("easingfunctions")

-- =========================================================================
-- 1. TUNING
-- =========================================================================

-- Glider objects are spawned actors. Their construction is the earliest
-- lifecycle event available, so it is where the deploy animation gets
-- configured. Native class, so Blueprint subclasses are caught too.
local GLIDER_OBJECT_NATIVE_CLASS = "/Script/Pal.PalGliderObject"

-- Blueprint event bound to OnStartGlidingDelegate. Lives on the component,
-- so the hook's Context is the BP_GliderComponent_C instance.
local PATH_ON_START_GLIDING =
    "/Game/Pal/Blueprint/Component/Glider/BP_GliderComponent.BP_GliderComponent_C:"
    .. "OnStartGliding"


-- ---- swoop boost (horizontal speed increase after dip) ----

-- Duration bounds (scaled by the magnitude of the dip)
local SWOOP_MIN_DURATION = 1         -- s
local SWOOP_MAX_DURATION = 2         -- s

-- Peak velocity multipliers (+10% to +25% extra horizontal speed)
local SWOOP_MIN_BOOST_PCT = 0.1
local SWOOP_MAX_BOOST_PCT = 0.25

-- The sink depth at which the boost magnitude hits 100%. 
-- Because buoyancy.sinkDepth is negative while sinking, this must also be negative.
local SWOOP_REFERENCE_DEPTH = -300     -- uu


-- ---- momentum preservation ----

-- Fraction of the carried horizontal velocity re-asserted during the hold.
-- 1.0 = full preservation.
local MOMENTUM_KEEP = 1.0
local AIR_CONTROL = 0.5 -- Vanilla is 1.0
local GLIDE_ROTATION_MULTIPLIER = 0.5

-- Below this, the open is a near-standstill deploy and there is no
-- momentum worth preserving.
local MOMENTUM_SPEED_FLOOR = 50    -- uu/s

-- How long the carried velocity keeps being asserted after the open. Long
-- enough to outlast a deploy montage, short enough that normal glide
-- physics owns the flight.
local MOMENTUM_HOLD_TIME = 0.25    -- s

-- ---- deploy animation ----

-- Playback multiplier for the glider unfurl. Written to the montage
-- assets, which are read when the montage starts -- so this must be
-- applied before a deploy, never during one.
local DEPLOY_ANIM_RATE = 1.3

-- ---- buoyant catch ----

-- Fall speed the deploy must exceed before buoyancy engages. Below it the
-- game's normal cap is left alone entirely.
local BUOYANCY_MIN_FALL_SPEED = 350    -- uu/s

-- The preserved fall speed is clamped here. Dip depth scales with how far
-- the initial descent sits from equilibrium, so this is the knob that
-- bounds maximum dip depth.
local BUOYANCY_MAX_FALL_SPEED = 4500   -- uu/s

-- Steady-state descent rate of a normal glide, as a negative Z velocity.
-- UNMEASURED: read cmc.Velocity.Z during a settled glide and plug in the
-- real number. The oscillator below swings about this line, so a wrong
-- value makes the character fight the game's descent rate indefinitely.
local GLIDE_DESCENT_RATE = -200        -- uu/s

-- How fast the catch resolves, in oscillations per second. The whole
-- dip-and-recover takes roughly one period, so 1.0 Hz is about a second.
-- This is the snappiness knob and it does NOT change the overshoot shape.
local BUOYANCY_FREQUENCY = 0.80         -- Hz

-- Overshoot shape, dimensionless and independent of frequency. 1.0 is
-- critically damped: the dip flattens out with no rise back. Lower values
-- carry the character back PAST the glide line before settling, which is
-- the visible catch. Below about 0.2 it starts to ring.
local BUOYANCY_DAMPING_RATIO = 0.32

-- Derived. Stated as frequency and ratio above because the raw pair is
-- coupled -- raising stiffness alone silently changes the overshoot, since
-- the ratio is damping / (2 * sqrt(stiffness)).
local BUOYANCY_ANGULAR_FREQUENCY = 2 * math.pi * BUOYANCY_FREQUENCY
local BUOYANCY_STIFFNESS = BUOYANCY_ANGULAR_FREQUENCY * BUOYANCY_ANGULAR_FREQUENCY
local BUOYANCY_DAMPING   = 2 * BUOYANCY_DAMPING_RATIO * BUOYANCY_ANGULAR_FREQUENCY

-- Settle thresholds. Once the character is this close to the glide line in
-- both position and rate, control goes back to the game.
local BUOYANCY_SETTLE_DEPTH = 10       -- uu
local BUOYANCY_SETTLE_SPEED = 60       -- uu/s

-- Hard ceiling on the settle, so a bad tune cannot own the whole flight.
local BUOYANCY_MAX_TIME = 2.25          -- s

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "glider" }

-- ---- frame cache ----
-- Written only on frames where the glider is NOT deployed, so at hook time
-- these hold the last pre-glide velocity.
local prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0

local originalRotationRateYaw = nil
local isRotationScaled = false

-- ---- deploy state ----
-- nil when no deploy is in progress. Built in StartDeployGlider, cleared in
-- EndDeployGlider, and nowhere else. Holds two sub-states that expire
-- independently.
local initDeployGlider = nil

-- ---- animation config ----
-- Set of montage asset names already given DEPLOY_ANIM_RATE. Keyed on the
-- asset rather than the glider object, because RateScale lives on the
-- shared UAnimMontage and every glider instance of a type resolves to the
-- same one. Cleared on player cache so a world reload that swaps the asset
-- object cannot leave a stale entry behind.
local configuredMontages = {}

-- ---- ownership guard ----
-- The event fires for any character carrying a glider component, so the
-- hook compares its Context against our own.
local myGliderComponentName = nil

-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:glider] " .. fmt .. "\n", ...)) end
end

local function ReadOpt(obj, prop)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function FullName(obj)
    if obj == nil then return nil end
    local ok, name = pcall(function() return obj:GetFullName() end)
    if not ok then return nil end
    return name
end

local function HorizontalSpeed(x, y)
    return math.sqrt(x * x + y * y)
end

local function SetHorizVel(cmc, x, y)
    pcall(function()
        cmc.Velocity.X = x
        cmc.Velocity.Y = y
    end)
end

local function SetVertVel(cmc, z)
    pcall(function() cmc.Velocity.Z = z end)
end

local function AddVertVel(cmc, dz)
    pcall(function() cmc.Velocity.Z = cmc.Velocity.Z + dz end)
end

local function IsOurGliderComponent(gliderComponent)
    local name = FullName(gliderComponent)
    return name ~= nil and name == myGliderComponentName
end

-- Jetpacks fire the same OnStartGliding edge but fly on a completely
-- separate solver -- JetpackGravityAcceleration, JetpackMaxSpeedAscend and
-- Descend, boost. Nothing in this file applies to them.
--
-- Permissive on a null glider: an unreadable CurrentGlider is treated as
-- not-a-jetpack and the deploy proceeds, since the drives never touch the
-- object. Invert if a null read should suppress the deploy instead.
local function IsJetpackGlider(gliderObj)
    return ReadOpt(gliderObj, "bIsJetpackType") == true
end

-- =========================================================================
-- 4. DEPLOY ANIMATION (configuration -- spawn-time only, never per frame)
-- =========================================================================

-- Both start montages get the same rate. GliderStartPlayerAnimation is the
-- character's unfurl and GliderStartAnimation is the canopy's own; retiming
-- one without the other desyncs the character from the glider mesh. The
-- loop montages are left alone -- only the deploy is being shortened.
--
-- Scope caveat: RateScale is a field on the shared UAnimMontage asset, so
-- this changes the deploy speed for every character on this client, not
-- just ours. Instance-scoped retiming would mean Montage_SetPlayRate on the
-- local anim instance at each deploy, which cannot be hoisted out of the
-- runtime path.
local function ApplyDeployAnimRate(gliderObj)
    local montageFields = { "GliderStartPlayerAnimation", "GliderStartAnimation" }

    for _, field in ipairs(montageFields) do
        local montage = ReadOpt(gliderObj, field)
        if montage == nil then
            dbg("anim rate: %s missing", field)
        else
            local montageName = FullName(montage)
            if montageName ~= nil and not configuredMontages[montageName] then
                configuredMontages[montageName] = true
                local wasWritten =
                    pcall(function() montage.RateScale = DEPLOY_ANIM_RATE end)
                dbg("anim rate: %s -> %.2f (%s)", field, DEPLOY_ANIM_RATE,
                    wasWritten and "ok" or "WRITE FAILED")
            end
        end
    end
end

local function ConfigureGliderObject(gliderObj, reason)
    if gliderObj == nil then return end
    if IsJetpackGlider(gliderObj) then return end

    --dbg("configuring glider (%s): %s", reason or "?", FullName(gliderObj))

    ApplyDeployAnimRate(gliderObj)
end

-- =========================================================================
-- 5. DEPLOY SEQUENCE
-- =========================================================================

local function EndDeployGlider(reason)
    if initDeployGlider == nil then return end
    initDeployGlider = nil
    dbg("deploy end: %s", reason or "?")
end

-- Called from the OnStartGliding hook. Snapshots what the player carried
-- into the open -- horizontal momentum and fall speed -- and the drives
-- below spend both on their own schedules.
local function StartDeployGlider()
    local carriedSpeed = HorizontalSpeed(prevVelocityX, prevVelocityY)

    -- Velocity.Z is negative while falling; both limits below are stated as
    -- positive rates of descent, so flip the sign once here.
    local fallSpeed = math.max(0, -prevVelocityZ)

    local hasMomentumToKeep   = carriedSpeed >= MOMENTUM_SPEED_FLOOR
    local fallIsWorthCatching = fallSpeed >= BUOYANCY_MIN_FALL_SPEED

    if not hasMomentumToKeep and not fallIsWorthCatching then
        dbg("deploy ignored: carried=%.1f fall=%.1f, nothing to do",
            carriedSpeed, fallSpeed)
        return
    end

    local preservedFallSpeed = math.min(fallSpeed, BUOYANCY_MAX_FALL_SPEED)

    initDeployGlider = {
        momentum = {
            active       = hasMomentumToKeep,
            elapsed      = 0,
            carriedX     = prevVelocityX * MOMENTUM_KEEP,
            carriedY     = prevVelocityY * MOMENTUM_KEEP,
            carriedSpeed = carriedSpeed * MOMENTUM_KEEP,
        },
        buoyancy = {
            active    = fallIsWorthCatching,
            elapsed   = 0,
            sinkDepth = 0,
            preservedFallSpeed   = preservedFallSpeed,
            hasRestoredFallSpeed = false,
            prevDescentError     = 0, -- NEW: Track for peak detection
        },
        swoop = {                     -- NEW: Swoop drive sub-state
            active = false,
            triggered = false,
            maxSinkDepth = 0,
            elapsed = 0,
            duration = 0,
            peakBoostPct = 0,
            currentBoostX = 0,
            currentBoostY = 0,
            baseMaxSpeed = nil
        }
    }

    dbg("deploy start: carried=%.1f fall=%.1f preserved=%.1f "
        .. "(momentum=%s buoyancy=%s)",
        carriedSpeed, fallSpeed, preservedFallSpeed,
        tostring(hasMomentumToKeep), tostring(fallIsWorthCatching))
end

-- Re-asserts the carried horizontal velocity. Only ever raises speed back
-- toward what was carried in -- a player already going faster is left
-- alone.
local function DriveMomentumHold(dt, cmc)
    local momentum = initDeployGlider.momentum
    if not momentum.active then return end

    local currentSpeed = HorizontalSpeed(cmc.Velocity.X, cmc.Velocity.Y)
    local hasLostSpeed = currentSpeed < momentum.carriedSpeed
    if hasLostSpeed then
        SetHorizVel(cmc, momentum.carriedX, momentum.carriedY)
    end

    momentum.elapsed = momentum.elapsed + dt
    if momentum.elapsed >= MOMENTUM_HOLD_TIME then
        momentum.active = false
        dbg("momentum hold expired")
    end
end

local function DriveSwoopBoost(dt, cmc)
    local swoop = initDeployGlider.swoop
    if not swoop.active then return end

    -- Strip the boost applied in the previous frame to isolate the base horizontal velocity
    SetHorizVel(cmc, cmc.Velocity.X - swoop.currentBoostX, cmc.Velocity.Y - swoop.currentBoostY)

    swoop.elapsed = swoop.elapsed + dt
    if swoop.elapsed >= swoop.duration then
        swoop.active = false
        swoop.currentBoostX = 0
        swoop.currentBoostY = 0

        if swoop.baseMaxSpeed then
            pcall(function() cmc.GliderMaxSpeed = swoop.baseMaxSpeed end)
        end

        dbg("swoop finished")
        return
    end

    local halfDuration = swoop.duration / 2
    local envelope = 0

    -- Ease up to the peak for the first half, ease down for the second half
    if swoop.elapsed < halfDuration then
        local t = swoop.elapsed / halfDuration
        envelope = EasingOptions.EaseInOutQuad(0, 1, t)
    else
        local t = (swoop.elapsed - halfDuration) / halfDuration
        envelope = EasingOptions.EaseInOutQuad(1, 0, t)
    end

    local currentMultiplier = swoop.peakBoostPct * envelope

    if swoop.baseMaxSpeed then
        pcall(function() cmc.GliderMaxSpeed = swoop.baseMaxSpeed * (1 + currentMultiplier) end)
    end

    -- Calculate and store the new added velocity based on the base velocity
    swoop.currentBoostX = cmc.Velocity.X * currentMultiplier
    swoop.currentBoostY = cmc.Velocity.Y * currentMultiplier

    -- Re-apply the boost on top of the base velocity
    SetHorizVel(cmc, cmc.Velocity.X + swoop.currentBoostX, cmc.Velocity.Y + swoop.currentBoostY)
end

-- Damped oscillator about the glide line. The first frame undoes the
-- game's fall-speed cap; from then on the sink integrates and lift pushes
-- back against it.
local function DriveBuoyantCatch(dt, cmc)
    local buoyancy = initDeployGlider.buoyancy
    if not buoyancy.active then return end

    -- One frame late by construction -- the hook fires after our tick, so
    -- the game gets a single capped frame before this lands. At normal
    -- frame rates that is a few milliseconds and is not visible.
    if not buoyancy.hasRestoredFallSpeed then
        SetVertVel(cmc, -buoyancy.preservedFallSpeed)
        buoyancy.hasRestoredFallSpeed = true
    end

    -- Negative while sinking faster than a settled glide would.
    local descentError = cmc.Velocity.Z - GLIDE_DESCENT_RATE
    buoyancy.sinkDepth = buoyancy.sinkDepth + descentError * dt

    -- Peak Detection Logic
    local swoop = initDeployGlider.swoop
    if not swoop.triggered then
        -- Track the lowest point (most negative sink depth)
        swoop.maxSinkDepth = math.min(swoop.maxSinkDepth, buoyancy.sinkDepth)

        -- If descent error was negative (falling faster than glide) and crosses to positive (rising), we hit the bottom
        if buoyancy.prevDescentError <= 0 and descentError > 0 then
            swoop.triggered = true
            swoop.active = true
            swoop.baseMaxSpeed = ReadOpt(cmc, "GliderMaxSpeed")

            -- Normalize the depth against our reference. Both are negative, so division gives a positive ratio.
            local dipRatio = math.max(0, math.min(1, swoop.maxSinkDepth / SWOOP_REFERENCE_DEPTH))
            
            swoop.duration = SWOOP_MIN_DURATION + (SWOOP_MAX_DURATION - SWOOP_MIN_DURATION) * dipRatio
            swoop.peakBoostPct = SWOOP_MIN_BOOST_PCT + (SWOOP_MAX_BOOST_PCT - SWOOP_MIN_BOOST_PCT) * dipRatio
            
            dbg("swoop triggered: ratio=%.2f dur=%.2f peakPct=%.2f", dipRatio, swoop.duration, swoop.peakBoostPct)
        end
    end
    buoyancy.prevDescentError = descentError

    local restoringForce = -BUOYANCY_STIFFNESS * buoyancy.sinkDepth
    local dampingForce   = -BUOYANCY_DAMPING * descentError
    AddVertVel(cmc, (restoringForce + dampingForce) * dt)

    buoyancy.elapsed = buoyancy.elapsed + dt

    local isNearGlideLine = math.abs(buoyancy.sinkDepth) < BUOYANCY_SETTLE_DEPTH
    local isNearGlideRate = math.abs(descentError) < BUOYANCY_SETTLE_SPEED
    local hasSettled      = isNearGlideLine and isNearGlideRate
    local hasRunTooLong   = buoyancy.elapsed >= BUOYANCY_MAX_TIME

    if hasSettled or hasRunTooLong then
        buoyancy.active = false
        dbg("buoyancy done after %.2fs: %s",
            buoyancy.elapsed, hasSettled and "settled" or "time limit")
    end
end

-- Runs from the frame after the open until both drives finish or the
-- glider closes.
local function TickDeployGlider(dt, cmc, gliderComponent, gliderObj)
    local isGliding = (ReadOpt(gliderComponent, "bIsGliding") == true)
    if not isGliding then
        EndDeployGlider("glider closed")
        return
    end

    DriveMomentumHold(dt, cmc)
    DriveBuoyantCatch(dt, cmc)
    DriveSwoopBoost(dt, cmc) 

    if DEBUG then
        dbg("  drive vXY=%7.1f vZ=%+8.1f sink=%+8.1f",
            HorizontalSpeed(cmc.Velocity.X, cmc.Velocity.Y),
            cmc.Velocity.Z, initDeployGlider.buoyancy.sinkDepth)
    end

    local allDrivesFinished =
        (not initDeployGlider.momentum.active) and
        (not initDeployGlider.buoyancy.active) and
        (not initDeployGlider.swoop.active)
        
    if allDrivesFinished then
        EndDeployGlider("drives complete")
    end
end

-- =========================================================================
-- 6. HOOKS AND REGISTRATION
-- Declared below the deploy functions on purpose: the callback closes over
-- StartDeployGlider, which does not exist as a local any earlier in the
-- file and would silently resolve as a global nil.
-- =========================================================================

M.Hooks = {
    { name = "OnStartGliding",
        path = PATH_ON_START_GLIDING,
        callback = function(Context)
            local ok, gliderComponent = pcall(function() return Context:get() end)
            if not ok or not gliderComponent then return end
            if not IsOurGliderComponent(gliderComponent) then return end

            local gliderObj = ReadOpt(gliderComponent, "CurrentGlider")
            if IsJetpackGlider(gliderObj) then
                dbg("deploy ignored: jetpack type")
                return
            end

            StartDeployGlider()
        end },
}

-- One notification per constructed glider object: class load (CDO), and
-- every subsequent construction. Native class, so like the native hooks it
-- installs once at mod load and never rebinds. The CDO pass alone is
-- usually enough, since the montage pointers on the CDO and on instances
-- reference the same asset.
M.Notifications = {
    { name  = "glider object constructed",
        class = GLIDER_OBJECT_NATIVE_CLASS,
        callback = function(constructedGlider)
            ConfigureGliderObject(constructedGlider, "spawned")
        end },
}

-- =========================================================================
-- 7. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
    initDeployGlider  = nil
    configuredMontages = {}
    local gliderComponent = ReadOpt(pawn, "BP_GliderComponent")
    myGliderComponentName = FullName(gliderComponent)
    cmc.GliderAirControl = AIR_CONTROL

    
    -- Cache original rotation rate
    local rotRate = ReadOpt(cmc, "RotationRate")
    originalRotationRateYaw = rotRate and rotRate.Yaw or nil
    isRotationScaled = false

    -- Covers hot-reload mid-session, where the equipped glider already
    -- exists and no construction notification is coming.
    ConfigureGliderObject(ReadOpt(gliderComponent, "CurrentGlider"), "already equipped")
end

-- Cache this frame's velocity for the next frame's comparison. Skipped
-- while the glider is deployed, so prevVelocity* stays pinned to the last
-- frame before the open — the momentum the open discards, and the fall
-- speed the catch is built from.
local function CacheFrameState(cmc, isGliding)
    if not isGliding then
        local velocity = cmc.Velocity
        prevVelocityX = velocity.X
        prevVelocityY = velocity.Y
        prevVelocityZ = velocity.Z
    end
end

function M.OnTick(dt, pawn, cmc)
    local gliderComponent = pawn.BP_GliderComponent
    if gliderComponent == nil then return end

    local isGliding = gliderComponent.bIsGliding
    local gliderObj = ReadOpt(gliderComponent, "CurrentGlider")

    if initDeployGlider ~= nil then
        TickDeployGlider(dt, cmc, gliderComponent, gliderObj)
    end
-- Handle turning rate scaling
    if isGliding and not isRotationScaled then
        if originalRotationRateYaw then
            pcall(function() cmc.RotationRate.Yaw = originalRotationRateYaw * GLIDE_ROTATION_MULTIPLIER end)
        end
        isRotationScaled = true
    elseif not isGliding and isRotationScaled then
        if originalRotationRateYaw then
            pcall(function() cmc.RotationRate.Yaw = originalRotationRateYaw end)
        end
        isRotationScaled = false
    end
    -- Cache values for next frame comparisons. Must stay last.
    CacheFrameState(cmc, isGliding)
end

return M
