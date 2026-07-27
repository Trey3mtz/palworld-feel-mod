-- =========================================================================
-- Author: TheTr3y
-- Date: 2026-07-25
-- =========================================================================

local CommonState = require("commonstate")
local Easing = require("easingfunctions")

-- =========================================================================
-- 1. TUNING
-- =========================================================================

local DEBUG   = true


-- ---- slide ----
local VZ_TRIGGER  = -600
local VZ_CAP      = 1600
local TRANSFER    = 0.45
local DECEL       = 1400
local MIN_SLIDE_V = 60
local BLOCK_RATIO = 0.4


-- Speed profile along the leap direction: EaseOutQuint from START to
-- END. Drive time is derived from the curve's time-average speed
-- (START/6 + 5*END/6 for out-quint) so travel is exactly LEAP_DIST
-- regardless of tuning. Keep (driveTime + ATTACH_WINDOW) under ~0.50s or
-- the component's cooldown expires mid-leap and organic re-grabs
-- return. Current average = 900 -> driveTime = 0.278s, same as the
-- constant-speed build.
local LEAP_SPEED_START = 2100
local LEAP_SPEED_END   = 150
local LEAP_EASE        = Easing.EaseOutCirc
local LEAP_DIST     = 250    -- uu of travel before the attach check
local LEAP_ANGLES   = { UP = 0.0, DIAG = 45.0, SIDE = 90.0 }
local ATTACH_WINDOW = 0.10   -- s at leap end to confirm a wall
local HUG_IN        = 150    -- into-wall carry, common to all buckets

-- ---- init climb: wall detection ----
local INIT_CLIMB_CONE_DEG    = 35    -- max angle between input and into-wall
local INIT_CLIMB_MAX_GAP     = 20    -- uu from capsule SURFACE that counts as reachable
local INIT_CLIMB_INPUT_FLOOR = 0.75   -- min |Acceleration.XY| that counts as input
local INIT_CLIMB_CONE_COS    = math.cos(math.rad(INIT_CLIMB_CONE_DEG))

local WALKABLE_FLOOR_Z_FALLBACK = 0.6428   -- cos(50 deg); BP_PlayerBase default

-- ---- climb jump: forced-attach probe ----
local PROBE_DIST   = 40     -- swept distance into the wall facing
local PROBE_BLOCK  = 0.5    -- moved/commanded below this = wall present

-- ---- climb jump: attach verification ----
local ATTACH_MAX_TRIES = 3  -- attempts within the window; then free fall

-- ---- climb jump: hop away (DOWN) ----
local HOP_VZ    = 620
local HOP_OUT   = 300
local HOP_LOCK  = 0.20

local LOCK_ROTATION = true

-- ---- component flag reconciliation ----
local RECONCILE_TICKS = 3   -- consecutive desynced ticks before repair


-- ---- hug closed-loop (facing + distance hold) ----
local HUG_TARGET     = 55      -- uu gap to hold (matches observed ~55 rest)
local HUG_RAY_LEN    = 112     -- fwdRay(80) * 1.4; fan reach
local HUG_FAN_DEG    = 30      -- side ray splay
local HUG_YAW_RATE   = 340     -- deg/s slew cap (round-wall track / corner take)
local HUG_PARALLEL   = 0.90    -- facing.normal above this = gap trusted for dist
local HUG_IN_GAIN    = 6.0     -- 1/s; inward vel = gain * (gap - target)
local HUG_IN_MAX     = 400     -- uu/s inward correction cap
local HUG_WRAP_COS   = -0.70   -- new-normal vs facing dot below this = corner too
                               -- sharp (~135 deg) -> detach; >= wraps.
                               -- -0.50~120, -0.70~135, -0.87~150
local HUG_LOST_TICKS = 4       -- consecutive all-miss frames -> end leap
local LEAD_RAY_BONUS = 8    -- uu of score preference for the ray angled
                            -- toward travel; lets it win near-ties so
                            -- corners are seen before the forward ray
local ATTACH_MAX_GAP = 15   -- uu of clearance from the capsule surface at
                            -- which a wall counts as grabbable


-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "climb" }

-- Published for jump.lua's jump-cut guard during the HOP (which hands
-- gravity back to jump.lua and therefore isn't covered by the priority
-- gate). Hug leaps are protected by ClimbHasPriority itself.
M.InClimbJump = false
M.InInitClimbState = false

local comp, compName = nil, nil
local capsuleRadius = 42 -- this is a fallback for radius someone on discord told me this
local savedOrient, savedCtrlRot = nil, nil
local walkableFloorZ = WALKABLE_FLOOR_Z_FALLBACK

-- ---- fall / climb frame cache ----
local lastFallVz     = 0
local prevModeWasClimb  = false
local prevClimbVel   = { X = 0, Y = 0, Z = 0 }
local prevWallFwd    = { X = 1, Y = 0 }
local prevClimbZ     = nil

-- ---- slide state ----
local slidingDownWall        = false
local slideV         = 0
local savedClimbMax  = nil

-- ---- climb jump state ----
local climbJumpState = nil
local JUMP_DIRECTIONS = {
    { name = "SIDE", sign = -1, x = -1.0, y =  0.0 },
    { name = "DIAG", sign = -1, x = -0.5, y =  0.5 },
    { name = "UP",   sign =  0, x =  0.0, y =  1.0 },
    { name = "DIAG", sign =  1, x =  0.5, y =  0.5 },
    { name = "SIDE", sign =  1, x =  1.0, y =  0.0 },
    { name = "DOWN", sign =  0, x =  0.0, y = -1.0 },
}

-- ---- init climb state ----
-- Shadowed by M.InInitClimbState: the two are written together, in
-- StartClimbFrom* and EndInitClimb, and nowhere else.
local initClimbState = nil

-- ---- flag watch state ----
local prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
local stuckIsTicks = 0
local KSL = nil             -- KismetSystemLibrary default object, lazy

-- ---- component hook state ----
local hooksRegistered = false
local lastGroundCheck = nil



-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end

local function ReadOpt(obj, prop)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function IsLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- Unit XY direction, or nil when the vector is too short to have one.
local function NormalizeXY(x, y)
    local length = math.sqrt(x * x + y * y)
    if length < 1e-3 then return nil end
    return { X = x / length, Y = y / length }
end


-- Rotates the leap's facing toward the wall, capped per frame so a single
-- bad normal can't whip the player around.
local function SlewFacingToward(dt, targetX, targetY)
    local currentAngle = math.atan(climbJumpState.faceDir.Y, climbJumpState.faceDir.X)
    local targetAngle  = math.atan(targetY, targetX)

    local angleDelta = targetAngle - currentAngle
    while angleDelta >  math.pi do angleDelta = angleDelta - 2 * math.pi end
    while angleDelta < -math.pi do angleDelta = angleDelta + 2 * math.pi end

    local maxTurnThisFrame = math.rad(HUG_YAW_RATE) * dt
    if angleDelta >  maxTurnThisFrame then angleDelta =  maxTurnThisFrame end
    if angleDelta < -maxTurnThisFrame then angleDelta = -maxTurnThisFrame end

    local newAngle = currentAngle + angleDelta
    climbJumpState.faceDir = { X = math.cos(newAngle), Y = math.sin(newAngle) }
end

-- Sets the inward velocity that pulls toward HUG_TARGET. Only trusted when
-- near-parallel: off-angle, the ray hits obliquely and reads longer than
-- the true perpendicular gap, which would drive the correction backwards.
local function UpdateGapCorrection(gap, facingAlignment)
    local gapReadingIsTrustworthy = facingAlignment >= HUG_PARALLEL
    if not gapReadingIsTrustworthy then
        climbJumpState.inVel = 0
        return
    end

    local gapError = gap - HUG_TARGET
    local correction = gapError * HUG_IN_GAIN
    climbJumpState.inVel = math.max(-HUG_IN_MAX, math.min(HUG_IN_MAX, correction))
end

-- No ray found the wall this frame. Coast on the last known facing; give up
-- once it's been gone long enough to mean the wall genuinely ended.
local function HandleLostWall()
    climbJumpState.framesWithoutWall = climbJumpState.framesWithoutWall + 1
    climbJumpState.inVel = 0

    local wallIsGoneForGood = climbJumpState.framesWithoutWall >= HUG_LOST_TICKS
    if wallIsGoneForGood then
        EndClimbJumpState()
        return false
    end
    return true
end

-- Where the player is asking to go, in world space. Acceleration rather
-- than Velocity: pressed against a wall the velocity collapses to zero
-- while the input stays populated.
local function GetInputDirection(cmc)
    local acceleration = ReadOpt(cmc, "Acceleration")
    if acceleration == nil then return nil end

    local inputX, inputY = 0, 0
    local readOk = pcall(function() inputX, inputY = acceleration.X, acceleration.Y end)
    if not readOk then return nil end

    local inputMagnitude = math.sqrt(inputX * inputX + inputY * inputY)
    local noInputHeld = inputMagnitude < INIT_CLIMB_INPUT_FLOOR
    if noInputHeld then return nil end

    return { X = inputX / inputMagnitude, Y = inputY / inputMagnitude }
end

-- One level ray from the capsule centre, on the climbing component's own
-- trace channel. Returns { normalX, normalY, normalZ, gap } or nil, where
-- gap is measured from the capsule SURFACE rather than its centre.
local function TraceAlongDirection(pawn, direction, rayLength)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then return nil end
    end

    local origin = GetLoc(pawn)
    if origin == nil then return nil end

    local finish = {
        X = origin.X + direction.X * rayLength,
        Y = origin.Y + direction.Y * rayLength,
        Z = origin.Z,
    }

    local hitResult, didHit = {}, nil
    pcall(function()
        didHit = KSL:LineTraceSingle(pawn, origin, finish,
            ReadOpt(comp, "Const_RayChannel") or 0, false, {}, 0,
            hitResult, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0.0)
    end)
    if not didHit then return nil end

    local normalX, normalY, normalZ, distanceFromCentre
    pcall(function() normalX = hitResult.ImpactNormal.X end)
    pcall(function() normalY = hitResult.ImpactNormal.Y end)
    pcall(function() normalZ = hitResult.ImpactNormal.Z end)
    pcall(function() distanceFromCentre = hitResult.Distance end)

    local hitIsReadable = type(normalX) == "number"
        and type(normalY) == "number"
        and type(normalZ) == "number"
        and type(distanceFromCentre) == "number"
    if not hitIsReadable then return nil end

    return {
        normalX = normalX,
        normalY = normalY,
        normalZ = normalZ,
        gap     = distanceFromCentre - capsuleRadius,
    }
end

-- Is the player moving into a wall, rather than past one or up a slope?
-- Returns the wall as { faceDir, gap } so the starter has a direction to
-- launch along and face; nil when any condition fails.
local function WallInMovementPath(pawn, cmc)
    local inputDirection = GetInputDirection(cmc)
    if inputDirection == nil then return nil end

    -- Ray length is derived from the grab distance, so "the ray hit" and
    -- "the wall is close enough" are one statement instead of two knobs.
    local rayLength = capsuleRadius + INIT_CLIMB_MAX_GAP
    local hit = TraceAlongDirection(pawn, inputDirection, rayLength)
    if hit == nil then return nil end

    -- A hit closer than the capsule radius means the trace started inside
    -- geometry, where UE returns a normal facing back down the trace --
    -- which would read as a perfectly head-on wall every time.
    local traceStartedInsideGeometry = hit.gap < 0
    if traceStartedInsideGeometry then return nil end

    -- The game's own line between "walk up it" and "must climb it".
    local surfaceIsTooSteepToWalk = hit.normalZ < walkableFloorZ
    if not surfaceIsTooSteepToWalk then return nil end

    local intoWall = NormalizeXY(-hit.normalX, -hit.normalY)
    if intoWall == nil then return nil end

    local approachAlignment =
        inputDirection.X * intoWall.X + inputDirection.Y * intoWall.Y
    local isHeadOnApproach = approachAlignment >= INIT_CLIMB_CONE_COS
    if not isHeadOnApproach then return nil end

    return { faceDir = intoWall, gap = hit.gap }
end

-- Fires three traces in a fan around the current wall facing and returns
-- the best hit, or nil if the wall was lost this frame.
--
-- Returns a table: { normalX, normalY, gap, rayAngle }
--   gap      = distance from the capsule SURFACE to the wall (not center)
--   rayAngle = which ray won, in degrees; 0 = straight ahead, sign gives
--              which side. Non-zero means the wall is off to that side,
--              which is what identifies a corner.
local function SenseWall(pawn, wallFacing, leapSideSign)
    if not IsLive(KSL) then return nil end

    local origin = GetLoc(pawn)
    if origin == nil then return nil end

    local traceChannel = ReadOpt(comp, "Const_RayChannel") or 0
    local bestHit = nil
    local bestScore = math.huge

    local function CastRay(rayAngleDegrees)
        local angle = math.rad(rayAngleDegrees)
        local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
        local directionX = wallFacing.X * cosAngle - wallFacing.Y * sinAngle
        local directionY = wallFacing.X * sinAngle + wallFacing.Y * cosAngle

        local hitResult, didHit = {}, nil
        pcall(function()
            didHit = KSL:LineTraceSingle(pawn, origin,
                { X = origin.X + directionX * HUG_RAY_LEN,
                  Y = origin.Y + directionY * HUG_RAY_LEN,
                  Z = origin.Z },
                traceChannel, false, {}, 0, hitResult, true,
                {R=1,G=0,B=0,A=1}, {R=0,G=1,B=0,A=1}, 0.0)
        end)
        if not didHit then return end

        local normalX, normalY, distanceFromCenter = nil, nil, nil
        pcall(function() normalX = hitResult.ImpactNormal.X end)
        pcall(function() normalY = hitResult.ImpactNormal.Y end)
        pcall(function() distanceFromCenter = hitResult.Distance end)
        if type(normalX) ~= "number" or type(distanceFromCenter) ~= "number" then
            return
        end

        local gapFromCapsuleSurface = distanceFromCenter - capsuleRadius

        -- The ray angled toward the leap's travel side sees corners before
        -- the forward ray does, so it wins near-ties. The ray angled away
        -- gets no such preference.
        local isLeadingRay = (leapSideSign ~= 0)
            and (rayAngleDegrees * leapSideSign > 0)
        local score = gapFromCapsuleSurface - (isLeadingRay and LEAD_RAY_BONUS or 0)

        if score < bestScore then
            bestScore = score
            bestHit = {
                normalX  = normalX,
                normalY  = normalY,
                gap      = gapFromCapsuleSurface,
                rayAngle = rayAngleDegrees,
            }
        end
    end

    CastRay(0)
    if leapSideSign ~= 0 then
        CastRay(HUG_FAN_DEG * leapSideSign)
        CastRay(-HUG_FAN_DEG * leapSideSign)
    end

    return bestHit
end

-- pcall does NOT protect against native AVs: every dereference is
-- individually null-checked.
local function FindClimbingComponent(pawn)
    local ok, arr = pcall(function() return pawn.BlueprintCreatedComponents end)
    if not ok or arr == nil then return nil, nil end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local okC, c = pcall(function() return arr[i] end)
        if okC and c ~= nil and IsLive(c) then
            local okN, name = pcall(function() return c:GetFullName() end)
            if okN and type(name) == "string" and name:find("Climb") then
                return c, name
            end
        end
    end
    return nil, nil
end

-- =========================================================================
-- 4. GEOMETRY
-- =========================================================================

local function GetLoc(pawn)
    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc == nil then return nil end
    local out = nil
    pcall(function() out = { X = loc.X, Y = loc.Y, Z = loc.Z } end)
    return out
end

local function GetZ(pawn)
    local l = GetLoc(pawn)
    return l and l.Z or nil
end

local function WallFwd(pawn)
    local fwd = nil
    pcall(function() fwd = pawn:GetActorForwardVector() end)
    if fwd == nil then return nil end
    local x, y = 0, 0
    local ok = pcall(function() x, y = fwd.X, fwd.Y end)
    if not ok then return nil end
    local m = math.sqrt(x * x + y * y)
    if m < 1e-4 then return nil end
    return { X = x / m, Y = y / m }
end

-- (coordinate conversion) Decompose a world vector into (into-wall, along-wall, up) components.
-- World based params go in, wall-relative values come out
local function DecomposeIntoWallSpace(worldSpaceVector, faceDir)
    if worldSpaceVector == nil or faceDir == nil then return 0, 0, 0 end
    return  worldSpaceVector.X * faceDir.X + worldSpaceVector.Y * faceDir.Y,
           -worldSpaceVector.X * faceDir.Y + worldSpaceVector.Y * faceDir.X,
            worldSpaceVector.Z
end

local function SetHorizVel(cmc, x, y)
    pcall(function()
        cmc.Velocity.X = x
        cmc.Velocity.Y = y
    end)
end

local function FaceYaw(pawn, faceDir)
    if not LOCK_ROTATION or faceDir == nil then return end
    local yaw = math.deg(math.atan(faceDir.Y, faceDir.X))
    pcall(function()
        pawn:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false)
    end)
end



-- =========================================================================
--  INIT CLIMB SEQUENCE
-- =========================================================================

-- Square up to the wall and hand off to the game's own jump. Nothing has
-- left the ground when this returns -- Jump only raises bPressedJump, and
-- the character's movement tick is what acts on it.
local function StartClimbFromGround(pawn, cmc, wall)
    initClimbState = {
        deltaTime = 0,
        faceDir   = wall.faceDir,
        tries     = 0,
    }

    -- At most a 35 degree correction, bounded by the detection cone.
    -- ApplyInitClimbVelocity re-asserts this every frame of the launch.
    FaceYaw(pawn, wall.faceDir)

    local jumpRequested = pcall(function() pawn:Jump() end)
    if not jumpRequested then
        dbg("init climb: Jump() call failed -- aborting")
        initClimbState = nil
        return
    end

    M.InInitClimbState = true

    dbg("init climb from ground: gap=%.1f face=(%+.2f,%+.2f) jumpZ=%s",
        wall.gap, wall.faceDir.X, wall.faceDir.Y,
        tostring(ReadOpt(cmc, "JumpZVelocity")))
end
  
local function DriveInitClimb(dt, pawn, cmc)
    initClimbState.deltaTime = initClimbState.deltaTime + dt

    local windowHasClosed = initClimbState.deltaTime > INIT_CLIMB_LOCK_TIME
    if windowHasClosed then
        EndInitClimb("window closed without a latch")
        return
    end

    ApplyInitClimbVelocity(pawn, cmc)

    local hasClearedTheGround = initClimbState.deltaTime >= INIT_CLIMB_ATTACH_AT
    if not hasClearedTheGround then return end

    local hasLatched = TryInitClimbAttach(pawn, cmc)
    if hasLatched then
        EndInitClimb("latched")
    end
end

-- =========================================================================
-- 5. WALL SLIDE
-- Fast fall into a wall skids down to a halt instead of latching dead.
-- Position writes (mode 6: the climb solver owns Velocity);
-- ClimbMaxSpeed = 0 doubles as the input lock.
-- =========================================================================

local function BeginWallSlide(cmc, entryVz)
    local v = math.min(math.abs(entryVz), VZ_CAP)
    slideV  = v * TRANSFER
    slidingDownWall = true
    savedClimbMax = ReadOpt(cmc, "ClimbMaxSpeed")
    if savedClimbMax ~= nil then
        local ok = pcall(function() cmc.ClimbMaxSpeed = 0 end)
        if not ok then
            dbg("WARN: ClimbMaxSpeed write failed -- input not locked")
            savedClimbMax = nil
        end
    else
        dbg("WARN: ClimbMaxSpeed unreadable -- input not locked")
    end
    dbg("slide start: entryVz=%.0f v0=%.0f (est dist %.0f uu) lock=%s",
        entryVz, slideV, (slideV * slideV) / (2 * DECEL),
        tostring(savedClimbMax ~= nil))
end

local function EndWallSlide(cmc, reason)
    if not slidingDownWall then return end
    slidingDownWall = false
    slideV  = 0
    if savedClimbMax ~= nil then
        pcall(function() cmc.ClimbMaxSpeed = savedClimbMax end)
        savedClimbMax = nil
    end
    dbg("slide end: %s", reason or "?")
end

local function TickWallSlide(dt, pawn, cmc)
    local deltaZ = slideV * dt
    local z0 = GetZ(pawn)
    local okMove = pcall(function()
        pawn:K2_AddActorWorldOffset({ X = 0, Y = 0, Z = -deltaZ }, true, {}, false)
    end)
    if not okMove then
        EndWallSlide(cmc, "K2_AddActorWorldOffset call failed")
        return
    end
    if z0 ~= nil then
        local z1 = GetZ(pawn)
        if z1 ~= nil and deltaZ > 0.5 then
            local moved = z0 - z1
            if moved < deltaZ * BLOCK_RATIO then
                EndWallSlide(cmc, string.format(
                    "blocked (commanded %.1f, moved %.1f)", deltaZ, moved))
                return
            end
        end
    end
    slideV = slideV - DECEL * dt
    if slideV <= MIN_SLIDE_V then
        EndWallSlide(cmc, "decayed to halt")
    end
end

-- Arm on a genuine fast-fall climb entry only: forced attaches land at
-- low vz and never arm mid climb jump (cj guard; FIX A supplies fresh
-- mode state so the guard holds on the post-attach frame).
local function UpdateWallSlide(dt, pawn, cmc, isClimbing)
    if isClimbing and not prevModeWasClimb and climbJumpState == nil then
        local entryVz = math.min(lastFallVz, cmc.Velocity.Z)
        if entryVz <= VZ_TRIGGER then
            BeginWallSlide(cmc, entryVz)
        end
    end

    if slidingDownWall and not isClimbing then
        EndWallSlide(cmc, "left climb mode")
    end

    if slidingDownWall and isClimbing then
        TickWallSlide(dt, pawn, cmc)
    end
end

-- =========================================================================
-- 6. CLIMB JUMP
-- Detach detection -> angle-bucket classification -> driven wall-plane
-- leap with a scheduled attach window, or DOWN hop away.
-- =========================================================================


-- Drives the leap: along-wall travel from the eased speed curve, the
-- inward correction that holds the gap, and the vertical component.
local function ApplyHugVelocity(pawn, cmc)
    local faceDir = climbJumpState.faceDir
    local alongWallX, alongWallY = -faceDir.Y, faceDir.X

    local leapProgress =
        math.min(climbJumpState.deltaTime / climbJumpState.driveTime, 1.0)
    local driveSpeed = LEAP_EASE(LEAP_SPEED_START, LEAP_SPEED_END, leapProgress)

    local inwardSpeed = climbJumpState.inVel or 0

    SetHorizVel(cmc,
        alongWallX * climbJumpState.dirSide * driveSpeed + faceDir.X * inwardSpeed,
        alongWallY * climbJumpState.dirSide * driveSpeed + faceDir.Y * inwardSpeed)
    pcall(function() cmc.Velocity.Z = climbJumpState.dirUp * driveSpeed end)

    FaceYaw(pawn, faceDir)
end

-- The leap's scheduled end: both sensors must confirm a wall before the
-- attach is forced. Gives up once the window closes.
local function TryAttachToWall(pawn, cmc, wallHit)
    local hasAttemptsLeft = climbJumpState.tries < ATTACH_MAX_TRIES
    local wallIsInReach   = (wallHit ~= nil) and (wallHit.gap <= ATTACH_MAX_GAP)

    if hasAttemptsLeft and wallIsInReach then
        local sweptIntoWall = ProbeWall(pawn, climbJumpState.faceDir)

        if sweptIntoWall == true then
            ForceClimbAttach(cmc)
            climbJumpState.tries = climbJumpState.tries + 1
        end
    end

    local attachWindowHasClosed = climbJumpState.deltaTime > climbJumpState.driveTime + ATTACH_WINDOW
    if attachWindowHasClosed then
        EndClimbJumpState()
    end
end

-- Returns bucket, sideSign. Angle is measured from the wall-up axis in
-- the wall plane. Neutral maps to UP (BotW: no direction held = straight
-- up). Velocity-based for now; see the input diagnostic in
-- DetectClimbJump.
local function ClassifyJumpDirection(acceleration)
    local inputX, inputY = acceleration.X, acceleration.Y
    local inputMagnitude = math.sqrt(inputX * inputX + inputY * inputY)

    local noInputHeld = inputMagnitude < 1e-3
    if noInputHeld then
        return "UP", 0
    end

    inputX = inputX / inputMagnitude
    inputY = inputY / inputMagnitude

    local closestDirection = nil
    local closestDot = -math.huge

    for _, direction in ipairs(JUMP_DIRECTIONS) do
        local length = math.sqrt(direction.x * direction.x + direction.y * direction.y)
        local dot = inputX * (direction.x / length) + inputY * (direction.y / length)
        if dot > closestDot then
            closestDot = dot
            closestDirection = direction
        end
    end

    return closestDirection.name, closestDirection.sign
end

-- Swept probe into the wall facing. Returns:
--   true,  moved  -- capsule blocked; left flush against the blocker
--   false, moved  -- open air; offset fully reverted
--   nil           -- probe could not run; treated as no wall
-- False-positives on rim perches and off-channel blockers; gates
-- attaches only in agreement with the trace below.
local function ProbeWall(pawn, f)
    local l0 = GetLoc(pawn)
    if l0 == nil then return nil end
    local ok = pcall(function()
        pawn:K2_AddActorWorldOffset(
            { X = f.X * PROBE_DIST, Y = f.Y * PROBE_DIST, Z = 0 },
            true, {}, false)
    end)
    if not ok then return nil end
    local l1 = GetLoc(pawn)
    if l1 == nil then return nil end
    local moved = (l1.X - l0.X) * f.X + (l1.Y - l0.Y) * f.Y

    if moved < PROBE_DIST * PROBE_BLOCK then
        return true, moved
    end
    pcall(function()
        pawn:K2_AddActorWorldOffset(
            { X = l0.X - l1.X, Y = l0.Y - l1.Y, Z = 0 }, false, {}, false)
    end)
    return false, moved
end

-- The component's own wall test replicated: LineTraceSingle on its
-- Const_RayChannel at its forward length. Logs on verdict change only.
-- False-negatives at corners the fat capsule overlaps; gates attaches
-- only in agreement with the sweep above.
local function TraceWallTest(pawn, f, climbJumpState)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then return nil end
    end
    local l = GetLoc(pawn)
    if l == nil then return nil end

    local rayLen  = ReadOpt(comp, "Const_ForwardRayLength") or 80.0
    local channel = ReadOpt(comp, "Const_RayChannel") or 0
    local complex = ReadOpt(comp, "TraceComplex") or false
    local finish  = { X = l.X + f.X * rayLen, Y = l.Y + f.Y * rayLen, Z = l.Z }

    local hit, out = nil, {}
    local ok = pcall(function()
        hit = KSL:LineTraceSingle(pawn, l, finish, channel, complex, {},
            2, out, true,
            { R = 1.0, G = 0.0, B = 0.0, A = 1.0 },
            { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }, 2.0)
    end)
    if not ok then
        dbg("  trace: LineTraceSingle call failed")
        return nil
    end

    if climbJumpState.lastTrace == nil or climbJumpState.lastTrace ~= hit then
        climbJumpState.lastTrace = hit
        local nz, dist = "?", "?"
        pcall(function() nz   = string.format("%+.2f", out.ImpactNormal.Z) end)
        pcall(function() dist = string.format("%.1f", out.Distance) end)
        dbg("  trace: hit=%s dist=%s normalZ=%s", tostring(hit), dist, nz)
    end
    return hit
end

-- Turns a wall reading into a facing update and a gap correction.
-- Returns false when the leap should end (corner too sharp, or the wall
-- has been out of sight too long); true to keep going.
local function TrackWallSurface(dt, wallHit)
    if wallHit == nil then
        return HandleLostWall()
    end

    climbJumpState.framesWithoutWall = 0

    local towardWallX = -wallHit.normalX
    local towardWallY = -wallHit.normalY
    local length = math.sqrt(towardWallX * towardWallX + towardWallY * towardWallY)

    local normalIsUsable = length > 1e-3
    if not normalIsUsable then return true end

    towardWallX = towardWallX / length
    towardWallY = towardWallY / length

    local facingAlignment =
        climbJumpState.faceDir.X * towardWallX +
        climbJumpState.faceDir.Y * towardWallY

    local cornerIsTooSharpToWrap = facingAlignment < HUG_WRAP_COS
    if cornerIsTooSharpToWrap then
        EndClimbJumpState()
        return false
    end

    SlewFacingToward(dt, towardWallX, towardWallY)
    UpdateGapCorrection(wallHit.gap, facingAlignment)
    return true
end

-- One-shot out-struct characterization: a floor's normal is +1.00 by
-- definition, distinguishing a populated normal from a zero-init struct
-- (vertical walls cannot). Runs once per pawn.
local function CharacterizeTraceStruct(pawn)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then return end
    end
    local l = GetLoc(pawn)
    if l == nil then return end
    local out, hit = {}, nil
    local ok = pcall(function()
        hit = KSL:LineTraceSingle(pawn, l,
            { X = l.X, Y = l.Y, Z = l.Z - 200 },
            ReadOpt(comp, "Const_RayChannel") or 0, false, {},
            0, out, true,
            { R = 1.0, G = 0.0, B = 0.0, A = 1.0 },
            { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }, 0.0)
    end)
    if not ok then dbg("floor trace: call failed") return end
    local nz, dist = "?", "?"
    pcall(function() nz   = string.format("%+.2f", out.ImpactNormal.Z) end)
    pcall(function() dist = string.format("%.1f", out.Distance) end)
    dbg("floor trace: hit=%s dist=%s normalZ=%s  (+1.00 = normals live, "
        .. "+0.00 = struct dead)", tostring(hit), dist, nz)
end

-- Write the component into the ORGANIC post-attach signature
-- (is=true can=true ending=false). Mode-only left it unaware (no
-- cooldown, 24ms re-grabs); writes without ending=false left is=true
-- stuck after hops. The reconciler remains the safety net.
local function ForceClimbAttach(cmc)
    if not IsLive(comp) then
        dbg("WARN: climb component stale -- attach skipped")
        return false, false, false
    end
    local okCan = pcall(function() comp.CanClimbing = true end)
    local okMode = pcall(function() cmc:SetMovementMode(6, 5) end)
    if not okMode then
        okMode = pcall(function()
            cmc.MovementMode = 6
            cmc.CustomMovementMode = 5
        end)
    end
    local okIs = pcall(function()
        comp.IsClimbing = true
        comp.IsEnding   = false
    end)
    return okMode, okCan, okIs
end

local function BeginWallHugLeap(pawn, cmc, bucket, sideSign)
    local ang  = math.rad(LEAP_ANGLES[bucket])
    local mean = LEAP_SPEED_START / 6 + 5 * LEAP_SPEED_END / 6
    climbJumpState = { mode = "hug", kind = bucket, deltaTime = 0, faceDir = prevWallFwd,
           dirUp   = math.cos(ang),
           dirSide = math.sin(ang) * sideSign,
           driveTime  = LEAP_DIST / mean,
           l0 = GetLoc(pawn),
           probes = 0, tries = 0, logged = false,
            yawLost = 0}
    M.InClimbJump = true
    dbg("climb jump [%s%s] -> eased leap (%d->%d dist=%d driveTime=%.0fms)",
        bucket, sideSign ~= 0 and (sideSign > 0 and "/R" or "/L") or "",
        LEAP_SPEED_START, LEAP_SPEED_END, LEAP_DIST, climbJumpState.driveTime * 1000)
end

local function BeginHopAway(pawn, cmc, bucket)
    climbJumpState = { mode = "hop", kind = bucket, deltaTime = 0, f = prevWallFwd,
           l0 = GetLoc(pawn) }
    M.InClimbJump = true
    -- The hop is a normal-ish jump: release climb priority so jump.lua's
    -- gravity bands resume next tick. Without this, a gated jump.lua and
    -- a hop that doesn't manage gravity leaves NOBODY owning
    -- GravityScale -- and a preceding hug left it at 0.
    CommonState.ClimbHasPriority = false

    pcall(function() cmc.Velocity.Z = HOP_VZ end)
    SetHorizVel(cmc, -prevWallFwd.X * HOP_OUT, -prevWallFwd.Y * HOP_OUT)
    dbg("climb jump [%s] -> hop away (out=%d vz=%d lock=%.2fs)",
        bucket, HOP_OUT, HOP_VZ, HOP_LOCK)
end

local function EndClimbJumpState()
    if climbJumpState == nil then return end
    climbJumpState = nil
    M.InClimbJump = false
    CommonState.ClimbHasPriority = false
end

local function DidClimbJumpStart(cmc, mode)
    local notGrounded = mode == 3
    local ascendingFast = cmc.Velocity.Z > 600
    return climbJumpState == nil and prevModeWasClimb and notGrounded and ascendingFast
end

-- classify the jump and launch.
local function StartClimbJump(pawn, cmc)
    local bucket, sign = ClassifyJumpDirection(cmc.Acceleration)
    EndWallSlide(cmc, "climb jump")
    if bucket == "DOWN" then
        BeginHopAway(pawn, cmc, bucket)
    else
        BeginWallHugLeap(pawn, cmc, bucket, sign)
    end
end

-- Per-frame driver for a wall-hug climb jump. Ends when the leap attaches,
-- lands, loses the wall, or runs out its window.
local function TickHugWall(dt, pawn, cmc, mode, isClimbing)
    if isClimbing then
        EndClimbJumpState()
        return
    end

    local hasLeftFalling = mode ~= 3
    if hasLeftFalling then
        EndClimbJumpState()
        return
    end

    local isWithinLeapWindow = climbJumpState.deltaTime < climbJumpState.driveTime + ATTACH_WINDOW
    local hasReachedAttachWindow = climbJumpState.deltaTime >= climbJumpState.driveTime 
  
    local wallHit = SenseWall(pawn, climbJumpState.faceDir, climbJumpState.dirSide)
  
    if isWithinLeapWindow then
        pcall(function() cmc.GravityScale = 0.0 end)
        local leapShouldContinue = TrackWallSurface(dt, wallHit)
        if not leapShouldContinue then return end
        ApplyHugVelocity(pawn, cmc)
    end

    -- If time spent in jumpstate is greater than the time we should be in it, ignoring the time it takes to do the attach animation
    if hasReachedAttachWindow then
        TryAttachToWall(pawn, cmc, wallHit)
    end
end

-- Per-frame driver for the hop-off. Pushes away from the wall for a fixed
-- window, then hands control back. No wall sensing — this is a dismount.
local function TickHopOffWall(dt, pawn, cmc, mode)
    -- Landing inside the lock window must release control rather than keep
    -- shoving the pawn along the ground.
    local hasLeftFalling = mode ~= 3
    if hasLeftFalling then
        EndClimbJumpState()
        return
    end

    local isWithinPushWindow = climbJumpState.deltaTime < HOP_LOCK
    if not isWithinPushWindow then
        EndClimbJumpState()
        return
    end

    local faceDir = climbJumpState.faceDir
    SetHorizVel(cmc, -faceDir.X * HOP_OUT, -faceDir.Y * HOP_OUT)
    FaceYaw(pawn, faceDir)
end

-- Hub function for anything with ticking the jump
local function TickClimbJump(dt, pawn, cmc, mode, isClimbing)
    if climbJumpState == nil then return end

    climbJumpState.deltaTime = climbJumpState.deltaTime + dt

    if climbJumpState.mode == "hug" then
        TickHugWall(dt, pawn, cmc, mode, isClimbing)
    else
        TickHopOffWall(dt, pawn, cmc, mode)
    end
end

-- =========================================================================
-- 7. CLIMB PRIORITY + COMPONENT HOOKS
-- ClimbHasPriority is the translated truth: the game's climb state is
-- raw data (drops to Falling mid-leap); this flag means "climbing, as
-- the mod understands it".
-- =========================================================================

-- Level-set while in climb mode; held while a hug leap is in flight;
-- otherwise a short watchdog releases it. The watchdog is the safety net
-- for exit paths not explicitly enumerated (e.g. stamina-out detach) --
-- a latched priority would otherwise permanently disable jump.lua.
local function UpdateClimbPriority(pawn, cmc, isClimbing)
    local shouldTakePriority = false

    if isClimbing then
        shouldTakePriority = true
    elseif climbJumpState ~= nil and climbJumpState.mode == "hug" then
        shouldTakePriority = true
    elseif CommonState.ClimbHasPriority then
        dbg("climb priority released (watchdog)")
    end

    if shouldTakePriority and not CommonState.ClimbHasPriority then
        -- Taking priority: seize rotation authority. Save the vanilla
        -- flags so release restores exactly what the game had.
        savedOrient = ReadOpt(cmc, "bOrientRotationToMovement")
        savedCtrlRot = ReadOpt(cmc, "bUseControllerDesiredRotation")
        pcall(function() cmc.bOrientRotationToMovement = false end)
        pcall(function() cmc.bUseControllerDesiredRotation = false end)
        CommonState.ClimbHasPriority = true

    elseif not shouldTakePriority then
        -- Not wanting priority: restore the game's rotation authority
        -- whether or not WE still hold the flag. EndClimbJump clears
        -- ClimbHasPriority directly on free-fall exits, so keying restore
        -- on "has" would skip it there and leak the disabled flags into
        -- every later state -- dead rotation / unstable jumps. Nil-ing
        -- after restore makes this idempotent and prevents re-saving the
        -- already-false leaked value on a later leap's take branch.
        if savedOrient ~= nil then
            pcall(function() cmc.bOrientRotationToMovement = savedOrient end)
            savedOrient = nil
        end
        if savedCtrlRot ~= nil then
            pcall(function() cmc.bUseControllerDesiredRotation = savedCtrlRot end)
            savedCtrlRot = nil
        end
        CommonState.ClimbHasPriority = false
    end
end

local function IsOurComponent(Context)
    local obj = nil
    pcall(function() obj = Context:get() end)
    if obj == nil or compName == nil then return false end
    local name = nil
    pcall(function() name = obj:GetFullName() end)
    return name == compName
end

local function NoOp() end

-- Class-level BP function hooks: register once per session (the class
-- object persists across respawns; re-registering would double-fire).
-- Instance-filtered in the callbacks. pcall-guarded registration logs
-- whether each function name actually exists on the class.
local function RegisterComponentHooks()
    if hooksRegistered or comp == nil then return end

    local clsPath = nil
    -- GetClass():GetFullName() on a live component: same pattern that
    -- safely identified ABP_Player_C. (The known-crash case was
    -- GetClass() on the holster's placeholder UObject, not this.)
    pcall(function() clsPath = comp:GetClass():GetFullName() end)
    if type(clsPath) ~= "string" then
        dbg("hook reg: component class path unreadable -- skipped")
        return
    end
    clsPath = clsPath:match("(%S+)$")   -- strip "BlueprintGeneratedClass "

    -- Vault-to-top: advisory clear (UpdateClimbPriority re-asserts while
    -- still in 6/5 during the vault curve, which is fine -- jump.lua has
    -- no business during a scripted vault). Registered pre-hook.
    local okTop, errTop = pcall(function()
        RegisterHook(clsPath .. ":ClimbUpAtTopEvent", function(Context)
            if not IsOurComponent(Context) then return end
            CommonState.ClimbHasPriority = false
            dbg("ClimbUpAtTopEvent fired -- priority released")
        end)
    end)
    dbg("hook ClimbUpAtTopEvent: %s",
        okTop and "registered" or ("FAILED: " .. tostring(errTop)))

    -- Ground contact: the return value only exists post-execution, so
    -- NoOp pre-slot + post callback (established pattern). Return value
    -- expected as the final vararg; logged raw on change for first-run
    -- characterization.
    local okGnd, errGnd = pcall(function()
        RegisterHook(clsPath .. ":GroundCheck", NoOp, function(Context, ...)
            if not IsOurComponent(Context) then return end
            local args = { ... }
            local ret = nil
            if #args > 0 then
                pcall(function() ret = args[#args]:get() end)
            end
            if ret ~= lastGroundCheck then
                lastGroundCheck = ret
                dbg("GroundCheck -> %s", tostring(ret))
            end
            if ret == true and CommonState.ClimbHasPriority then
                CommonState.ClimbHasPriority = false
                dbg("GroundCheck true -- priority released")
            end
        end)
    end)
    dbg("hook GroundCheck: %s",
        okGnd and "registered" or ("FAILED: " .. tostring(errGnd)))

    hooksRegistered = true
end

-- =========================================================================
-- 8. CAPTURE
-- Ring-buffered burst logger around climb-relevant edges. Ring clears on
-- burst end so stale frames never replay as new bursts.
-- =========================================================================

local function BuildLine(dt, pawn, cmc)
    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local v      = cmc.Velocity
    local is     = ReadOpt(comp, "IsClimbing")
    local can    = ReadOpt(comp, "CanClimbing")
    local vIn, vSide, vUp = DecomposeIntoWallSpace(v, prevWallFwd)
    return string.format(
        "mode=%d/%d is=%s can=%s  vIn=%+7.1f vSide=%+7.1f vUp=%+7.1f  dt=%.4f",
        mode, custom, tostring(is), tostring(can), vIn, vSide, vUp, dt)
end



-- =========================================================================
-- 9. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    comp, compName = FindClimbingComponent(pawn)
    lastFallVz     = 0
    prevModeWasClimb  = false
    prevClimbVel   = { X = 0, Y = 0, Z = 0 }
    prevWallFwd    = { X = 1, Y = 0 }
    prevClimbZ     = nil
    slidingDownWall        = false
    slideV         = 0
    savedClimbMax  = nil
    climbJumpState             = nil
    M.InClimbJump  = false
    CommonState.ClimbHasPriority = false   -- belt; main.lua's Reset is braces
    prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
    stuckIsTicks   = 0
    lastGroundCheck = nil
    KSL            = nil
    ring, ringN, capLeft = {}, 0, 0
    walkableFloorZ = ReadOpt(cmc, "WalkableFloorZ") or WALKABLE_FLOOR_Z_FALLBACK
    initClimbState     = nil
    M.InInitClimbState = false
  
    pcall(function()
      capsuleRadius = pawn.CapsuleComponent.CapsuleRadius
    end)
  
    if comp == nil then
        dbg("climbing component NOT FOUND")
    else
        dbg("component: %s  ClimbMaxSpeed=%s  fwdRay=%s",
            compName, tostring(ReadOpt(cmc, "ClimbMaxSpeed")),
            tostring(ReadOpt(comp, "Const_ForwardRayLength")))
        CharacterizeTraceStruct(pawn)
        RegisterComponentHooks()
    end
end

-- FIX B: remember fall speed only while falling; grounded clears it so a
-- stale hard-fall value cannot arm a slide on a later gentle entry.
local function CacheFallSpeed(mode, cmc)
    if mode == 3 then
        lastFallVz = cmc.Velocity.Z
    else
        lastFallVz = 0
    end
end


local function LogComponentFlagEdges(mode, custom)
    if not DEBUG then return end
    local palgame_isClimbing     = ReadOpt(comp, "IsClimbing")
    local palgame_canClimb    = ReadOpt(comp, "CanClimbing")
    local palgame_isEndingClimb = ReadOpt(comp, "IsEnding")
    if palgame_isClimbing ~= prevFlagIs or palgame_canClimb ~= prevFlagCan or palgame_isEndingClimb ~= prevFlagEnding then
        dbg("flags: isClimbing=%s canClimb=%s endingClimb=%s (mode %d/%d)",
            tostring(palgame_isClimbing), tostring(palgame_canClimb), tostring(palgame_isEndingClimb), mode, custom)
        prevFlagIs, prevFlagCan, prevFlagEnding = palgame_isClimbing, palgame_canClimb, palgame_isEndingClimb
    end
end

-- Repair the residual desync class: IsClimbing latched true while not
-- climbing. Waits N consecutive ticks so the game's own detach
-- transition frames are never fought. CanClimbing is deliberately left
-- alone -- its cooldown is the component's business.
local function ReconcileStuckClimbFlag(isClimbing)
    if isClimbing then
        stuckIsTicks = 0
        return
    end
    if ReadOpt(comp, "IsClimbing") ~= true then
        stuckIsTicks = 0
        return
    end
    stuckIsTicks = stuckIsTicks + 1
    if stuckIsTicks >= RECONCILE_TICKS then
        local ok = pcall(function() comp.IsClimbing = false end)
        dbg("reconciled stuck IsClimbing -> false (write ok=%s)", tostring(ok))
        stuckIsTicks = 0
    end
end

-- Cache the climb frame for next tick's detach classification.
local function CacheClimbFrame(pawn, cmc, inClimb)
    if inClimb then
        local v = cmc.Velocity
        prevClimbVel = { X = v.X, Y = v.Y, Z = v.Z }
        local faceDir = WallFwd(pawn)
        if faceDir ~= nil then prevWallFwd = faceDir end
        prevClimbZ = GetZ(pawn)
    end
    prevModeWasClimb = inClimb
end


-- Hub for starting a climb. All functions here are theoretical and don't yet exist.
local function TickInitClimbStart(dt, pawn, cmc, isWalking)
    
    if not M.InInitClimbState then
        -- First, are we moving into a wall we're allowed to climb?
        local wallAhead = WallInMovementPath(pawn, cmc)
        local isMovingIntoWall = (wallAhead ~= nil)

        -- Second, check with the game's native climb checks that we are good to climb
        local componentAllowsClimb = ReadOpt(comp, "CanClimbing") == true

        if isMovingIntoWall and componentAllowsClimb then
            -- Second, which state are we entering from?
            if isWalking then
                StartClimbFromGround(pawn, cmc, wallAhead)
            end
            -- later: StartClimbFromAir(pawn, cmc, wallAhead)
        end
    end

    if M.InInitClimbState then
        DriveInitClimb(dt, pawn, cmc)
    end
end


function M.OnTick(dt, pawn, cmc)
    local movementMode    = cmc.MovementMode
    local customMovementMode  = ReadOpt(cmc, "CustomMovementMode") or 0
    local isClimbing = (movementMode == 6 and customMovementMode == 5)
    local isWalking = (movementMode == 1 or movementMode == 2 or (movementMode == 6 and customMovementMode == 2))

    if not isClimbing and not M.InClimbJump then
        TickInitClimbStart(dt, pawn, cmc, isWalking)
    end
  
    CacheFallSpeed(movementMode, cmc)
    LogComponentFlagEdges(movementMode, customMovementMode)

    if DidClimbJumpStart(cmc, movementMode) then
        StartClimbJump(pawn, cmc)
    end
    TickClimbJump(dt, pawn, cmc, movementMode, isClimbing)

    movementMode    = cmc.MovementMode
    customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0

    isClimbing = (movementMode == 6 and customMovementMode == 5)

    UpdateClimbPriority(pawn, cmc, isClimbing)
    --ReconcileStuckClimbFlag(isClimbing)
    UpdateWallSlide(dt, pawn, cmc, isClimbing)
    CacheClimbFrame(pawn, cmc, isClimbing)
end

return M
