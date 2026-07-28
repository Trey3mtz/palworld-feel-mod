-- =========================================================================
-- PalFeel subsystem: glider — momentum preservation on deploy
-- Author: TheTr3y
--
-- Symptom: opening the glider visibly discards horizontal momentum for a
-- moment. The deploy state re-asserts the horizontal velocity the player
-- carried into the open, for a short hold window.
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
--
-- Frame ordering: the controller tick runs before the pawn's component
-- tick, so within one frame CacheFrameState records the pre-glide velocity,
-- then StartGliding fires and the hook snapshots it. The first
-- TickDeployGlider call is therefore one frame after the open, which is
-- why the state holds across a window instead of writing once.
--
-- If the hold does not survive, the deploy is clamping speed to
-- GliderMaxSpeed downstream of us and the fix moves to that field.
-- =========================================================================

local DEBUG = true

-- =========================================================================
-- 1. TUNING
-- =========================================================================

-- Full path of the Blueprint-bound event for OnStartGlidingDelegate.
-- UNCONFIRMED: grep the asset dump for "OnStartGlidingDelegate" and paste
-- the real path. A wrong path never errors -- main.lua just logs the hook
-- as pending forever.
local PATH_ON_START_GLIDING = "/Game/Pal/Blueprint/Component/Glider/BP_GliderComponent.BP_GliderComponent_C:OnStartGliding"

-- Fraction of the carried horizontal velocity re-asserted during the hold.
-- 1.0 = full preservation.
local MOMENTUM_KEEP = 1.0

-- Below this, the open is a near-standstill deploy and there is no
-- momentum worth preserving.
local MOMENTUM_SPEED_FLOOR = 50    -- uu/s

-- How long after the open the carried velocity keeps being asserted. Long
-- enough to outlast a deploy montage, short enough that normal glide
-- physics owns the flight.
local DEPLOY_HOLD_TIME = 0.15      -- s

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "glider" }

-- ---- frame cache ----
-- Written only on frames where the glider is NOT deployed, so at hook time
-- these hold the last pre-glide velocity.
local prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0

-- ---- deploy state ----
-- nil when no deploy is in progress. Built in StartDeployGlider, cleared in
-- EndDeployGlider, and nowhere else.
local initDeployGlider = nil

-- ---- ownership guard ----
-- The delegate can fire for any character carrying a glider component. Both
-- names are cached because the bind site decides whether the hook's Context
-- is the pawn or the component.
local myPawnName, myGliderComponentName = nil, nil

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

-- True when the object the delegate fired for is ours, whichever of the two
-- the bind site hands us.
local function IsOurGliderEvent(contextObject)
    local name = FullName(contextObject)
    if name == nil then return false end
    return name == myPawnName or name == myGliderComponentName
end

-- =========================================================================
-- 4. DEPLOY SEQUENCE
-- =========================================================================

local function EndDeployGlider(reason)
    if initDeployGlider == nil then return end
    initDeployGlider = nil
    dbg("deploy end: %s", reason or "?")
end

-- Called from the OnStartGliding hook. Snapshots the momentum the player
-- carried into the open; the drive below is what spends it.
local function StartDeployGlider()
    local carriedSpeed = HorizontalSpeed(prevVelocityX, prevVelocityY)
    if carriedSpeed < MOMENTUM_SPEED_FLOOR then
        dbg("deploy ignored: carried=%.1f below floor", carriedSpeed)
        return
    end

    initDeployGlider = {
        elapsed      = 0,
        carriedX     = prevVelocityX * MOMENTUM_KEEP,
        carriedY     = prevVelocityY * MOMENTUM_KEEP,
        carriedSpeed = carriedSpeed * MOMENTUM_KEEP,
    }

    dbg("deploy start: carried=%.1f", carriedSpeed)
end

-- Runs from the frame after the open until the hold expires or the glider
-- closes. Only ever raises speed back toward what was carried in -- a
-- player who is already going faster is left alone.
local function TickDeployGlider(dt, pawn, cmc, isGliding)
    local gliderComponent = pawn.BP_GliderComponent

    if not isGliding then
        EndDeployGlider("glider closed")
        return
    end
    
    initDeployGlider.elapsed = initDeployGlider.elapsed + dt

    local currentSpeed = HorizontalSpeed(cmc.Velocity.X, cmc.Velocity.Y)
    local hasLostSpeed = currentSpeed < initDeployGlider.carriedSpeed
    if hasLostSpeed then
        dbg("[glider.lua] I LOST speed upon deploy...")
        SetHorizVel(cmc, initDeployGlider.carriedX, initDeployGlider.carriedY)
    end

    if DEBUG and initDeployGlider.elapsed <= dt * 1.5 then
        dbg("first drive frame: current=%.1f carried=%.1f | "
            .. "cmc.GliderMaxSpeed=%s item.GliderMaxSpeed=%s",
            currentSpeed, initDeployGlider.carriedSpeed,
            tostring(ReadOpt(cmc, "GliderMaxSpeed")),
            tostring(ReadOpt(ReadOpt(gliderComponent, "CurrentGlider"), "GliderMaxSpeed")))
    end

    local holdHasExpired = initDeployGlider.elapsed >= DEPLOY_HOLD_TIME
    if holdHasExpired then
        EndDeployGlider("hold expired")
    end
end

-- =========================================================================
-- 5. HOOKS
-- Declared below the deploy functions on purpose: the callback closes over
-- StartDeployGlider, which does not exist as a local any earlier in the
-- file and would silently resolve as a global nil.
-- =========================================================================

M.Hooks = {
    { name = "OnStartGlidingDelegate (BP bound)",
        path = PATH_ON_START_GLIDING,
        callback = function(Context)
            local ok, obj = pcall(function() return Context:get() end)
            if not ok or not obj then return end
            if not IsOurGliderEvent(obj) then return end
            StartDeployGlider()
        end },
}

-- =========================================================================
-- 6. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
    initDeployGlider = nil

    local gliderComponent = ReadOpt(pawn, "BP_GliderComponent")
    myPawnName            = FullName(pawn)
    myGliderComponentName = FullName(gliderComponent)

    dbg("glider component: %s", myGliderComponentName or "NOT FOUND")
end

-- Cache this frame's velocity for the next frame's comparison. Skipped
-- while the glider is deployed, so prevVelocity* stays pinned to the last
-- frame before the open — the momentum the open discards.
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

    if initDeployGlider ~= nil then
        TickDeployGlider(dt, pawn, cmc, isGliding)
    end

    -- Cache values for next frame comparisons. Must stay last.
    CacheFrameState(cmc, isGliding)
end

return M
