-- =========================================================================
-- PalFeel subsystem: glider — momentum preservation on deploy
-- Author: TheTr3y
--
-- Symptom: opening the glider visibly discards horizontal momentum for a
-- moment. On the frame the glider opens we write back the horizontal
-- velocity the player carried into it.
--
-- Field model (UPalGliderComponent, the native parent of
-- BP_GliderComponent -- the BP child's own CurrentGliderObject is left
-- alone, since the native member is set on every path):
--   bIsGliding         : deploy state
--   CurrentGlider      : the equipped APalGliderObject
--   CurrentGliderPalID : FName of the equipped glider
--   OnStartGlidingDelegate / OnEndGlidingDelegate : native multicast
--       edges. If anything in BP binds to them, a BndEvt hook would
--       replace the per-tick edge check below with a real event.
--
--   APalGliderObject.GliderMaxSpeed / GliderAirControl / GliderGravityScale
--       : per-item values, presumed stamped onto the identically named
--         UPalCharacterMovementComponent fields at deploy.
--
-- Ordering caveat: this ticks from BP_PalPlayerController:ReceiveTick,
-- which runs before the pawn's movement update. A velocity write here is
-- therefore upstream of PhysCustom. If the deploy clamps speed to
-- GliderMaxSpeed, the restore is overwritten in the same frame and the
-- real fix is raising GliderMaxSpeed instead. The open-edge log prints
-- both numbers so the two cases are distinguishable on sight.
-- =========================================================================

local DEBUG = true

-- =========================================================================
-- 1. TUNING
-- =========================================================================

-- Fraction of the pre-glide horizontal velocity handed back on the open
-- frame. 1.0 = full preservation.
local MOMENTUM_KEEP = 1.0

-- Below this, the open is a near-standstill deploy and there is no
-- momentum worth preserving.
local MOMENTUM_SPEED_FLOOR = 50   -- uu/s

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "glider" }

-- ---- frame cache ----
-- Written only on frames where the glider is NOT deployed, so across the
-- open edge these hold the last pre-glide velocity.
local prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
local wasGliderDeployedLastFrame = false

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

local function HorizontalSpeed(x, y)
    return math.sqrt(x * x + y * y)
end

local function SetHorizVel(cmc, x, y)
    pcall(function()
        cmc.Velocity.X = x
        cmc.Velocity.Y = y
    end)
end

-- =========================================================================
-- 4. DEPLOY
-- =========================================================================

-- Runs on the single frame the glider opens. prevVelocity* still holds the
-- last airborne frame before the deploy, because CacheFrameState skips its
-- write while gliding.
local function OnGliderOpened(pawn, cmc, gliderComponent)
    local carriedSpeed = HorizontalSpeed(prevVelocityX, prevVelocityY)
    if carriedSpeed < MOMENTUM_SPEED_FLOOR then return end

    local restoredX = prevVelocityX * MOMENTUM_KEEP
    local restoredY = prevVelocityY * MOMENTUM_KEEP

    local speedAtOpen = HorizontalSpeed(cmc.Velocity.X, cmc.Velocity.Y)
    SetHorizVel(cmc, restoredX, restoredY)

    if DEBUG then
        local gliderObject   = ReadOpt(gliderComponent, "CurrentGlider")
        local itemMaxSpeed   = ReadOpt(gliderObject, "GliderMaxSpeed")
        local activeMaxSpeed = ReadOpt(cmc, "GliderMaxSpeed")

        dbg("open: carried=%.1f atOpen=%.1f restored=%.1f | "
            .. "cmc.GliderMaxSpeed=%s item.GliderMaxSpeed=%s",
            carriedSpeed, speedAtOpen,
            HorizontalSpeed(restoredX, restoredY),
            tostring(activeMaxSpeed), tostring(itemMaxSpeed))
    end
end

-- =========================================================================
-- 5. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
    wasGliderDeployedLastFrame = false

    local gliderComponent = ReadOpt(pawn, "BP_GliderComponent")
    dbg("glider component: %s",
        gliderComponent and tostring(gliderComponent) or "NOT FOUND")
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
    wasGliderDeployedLastFrame = isGliding
end

function M.OnTick(dt, pawn, cmc)
    local gliderComponent = pawn.BP_GliderComponent
    if gliderComponent == nil then return end

    local isGliding = gliderComponent.bIsGliding

    local gliderJustOpened = (isGliding and not wasGliderDeployedLastFrame)
    if gliderJustOpened then
        OnGliderOpened(pawn, cmc, gliderComponent)
    end

    -- Cache values for next frame comparisons. Must stay last.
    CacheFrameState(cmc, isGliding)
end

return M
