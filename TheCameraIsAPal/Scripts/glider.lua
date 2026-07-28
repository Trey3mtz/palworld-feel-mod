-- =========================================================================
-- PalFeel subsystem: glider
-- Author: TheTr3y
-- =========================================================================

local DEBUG = true

-- =========================================================================
-- 1. TUNING
-- =========================================================================

-- Custom movement mode ID for gliding. Unknown until the first capture
-- run names it; while nil, deployment detection falls back to
-- bRequestGliding alone.
local GLIDE_CUSTOM_MODE = nil

-- Frames retained before a glider-open edge and logged after it.
-- At ~120 fps this is roughly 0.1 s before and 0.2 s after.
local CAPTURE_FRAMES_BEFORE = 12
local CAPTURE_FRAMES_AFTER  = 24

local MOVEMENT_MODE_FALLING = 3
local MOVEMENT_MODE_CUSTOM  = 6

-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "glider" }

-- ---- frame cache ----
-- Written only on frames where the glider is NOT deployed, so across the
-- open edge these hold the last pre-glide velocity.
local prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
local wasGliderDeployedLastFrame = false

-- ---- capture state ----
local frameRing          = {}
local frameRingNextSlot  = 1
local framesLeftToLog    = 0

-- ---- mode watch state ----
local prevMovementMode       = nil
local prevCustomMovementMode = nil

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

local function HorizontalSpeed(velocity)
    return math.sqrt(velocity.X * velocity.X + velocity.Y * velocity.Y)
end

-- =========================================================================
-- 4. STATE DETECTION
-- =========================================================================

-- True when the game considers the glider open. While GLIDE_CUSTOM_MODE is
-- unknown this trusts bRequestGliding, which is a request flag and may
-- therefore lead the real state — the capture below is what proves whether
-- the two agree.
local function IsGliderDeployed(cmc)
    local requestsGliding = (ReadOpt(cmc, "bRequestGliding") == true)

    if GLIDE_CUSTOM_MODE == nil then
        return requestsGliding
    end

    local movementMode          = cmc.MovementMode
    local customMovementMode    = ReadOpt(cmc, "CustomMovementMode") or 0
    local inGlideMovementMode   =
        (movementMode == MOVEMENT_MODE_CUSTOM and customMovementMode == GLIDE_CUSTOM_MODE)

    return inGlideMovementMode
end

-- =========================================================================
-- 5. CAPTURE
-- Ring-buffered burst logger around the glider-open edge. The ring is
-- cleared when a burst ends so stale frames never replay as a new burst.
-- =========================================================================

local function BuildFrameLine(dt, cmc, isGliderDeployed)
    local velocity           = cmc.Velocity
    local acceleration       = cmc.Acceleration
    local movementMode       = cmc.MovementMode
    local customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0
    local requestsGliding    = ReadOpt(cmc, "bRequestGliding")

    return string.format(
        "mode=%d/%d deployed=%-5s req=%-5s  vXY=%7.1f vZ=%+8.1f  accXY=%6.1f  gravScale=%.2f  dt=%.4f",
        movementMode, customMovementMode,
        tostring(isGliderDeployed), tostring(requestsGliding),
        HorizontalSpeed(velocity), velocity.Z,
        HorizontalSpeed(acceleration),
        ReadOpt(cmc, "GravityScale") or -1,
        dt)
end

local function PushFrameToRing(line)
    frameRing[frameRingNextSlot] = line
    frameRingNextSlot = (frameRingNextSlot % CAPTURE_FRAMES_BEFORE) + 1
end

local function ClearRing()
    for i = 1, CAPTURE_FRAMES_BEFORE do frameRing[i] = nil end
    frameRingNextSlot = 1
end

-- Print the retained pre-edge frames oldest-first, then arm the post-edge
-- log. Called on the frame the glider opens.
local function StartCaptureBurst()
    dbg("==== glider open ====")
    dbg("cached pre-glide velocity: vXY=%.1f vZ=%+.1f",
        math.sqrt(prevVelocityX * prevVelocityX + prevVelocityY * prevVelocityY),
        prevVelocityZ)

    for offset = 0, CAPTURE_FRAMES_BEFORE - 1 do
        local slot = ((frameRingNextSlot - 1 + offset) % CAPTURE_FRAMES_BEFORE) + 1
        if frameRing[slot] ~= nil then
            dbg("  -%2d  %s", CAPTURE_FRAMES_BEFORE - offset, frameRing[slot])
        end
    end

    ClearRing()
    framesLeftToLog = CAPTURE_FRAMES_AFTER
end

local function TickCapture(dt, cmc, isGliderDeployed)
    if not DEBUG then return end

    local line = BuildFrameLine(dt, cmc, isGliderDeployed)

    if framesLeftToLog > 0 then
        dbg("  +%2d  %s", CAPTURE_FRAMES_AFTER - framesLeftToLog + 1, line)
        framesLeftToLog = framesLeftToLog - 1
        if framesLeftToLog == 0 then dbg("==== capture end ====") end
        return
    end

    local gliderJustOpened = (isGliderDeployed and not wasGliderDeployedLastFrame)
    if gliderJustOpened then
        StartCaptureBurst()
        dbg("  +%2d  %s", 1, line)
        framesLeftToLog = CAPTURE_FRAMES_AFTER - 1
        return
    end

    PushFrameToRing(line)
end

-- =========================================================================
-- 6. MODE WATCH
-- Independent of the capture: names every MovementMode / CustomMovementMode
-- pair the player passes through, which is how GLIDE_CUSTOM_MODE gets
-- filled in.
-- =========================================================================

local function LogMovementModeEdges(cmc)
    if not DEBUG then return end

    local movementMode       = cmc.MovementMode
    local customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0
    local modeChanged        =
        (movementMode ~= prevMovementMode or customMovementMode ~= prevCustomMovementMode)

    if modeChanged then
        dbg("movement mode %d (custom %d)", movementMode, customMovementMode)
        prevMovementMode       = movementMode
        prevCustomMovementMode = customMovementMode
    end
end

-- =========================================================================
-- 7. LIFECYCLE
-- =========================================================================

-- ActionMovementModeMap is keyed by EPalCharacterMovementCustomMode, so its
-- entries enumerate every custom mode the component knows about. If the
-- handler class names come through readable, this identifies the glide ID
-- without needing to fly at all.
local function DumpCustomMovementModes(cmc)
    local map = ReadOpt(cmc, "ActionMovementModeMap")
    if map == nil then
        dbg("ActionMovementModeMap unreadable")
        return
    end

    local ok = pcall(function()
        map:ForEach(function(key, value)
            local keyText   = tostring(key:get())
            local valueText = "<nil>"
            pcall(function() valueText = value:get():GetFullName() end)
            dbg("  custom mode %s -> %s", keyText, valueText)
        end)
    end)

    if not ok then dbg("ActionMovementModeMap iteration not supported") end
end

local GLIDER_FIELDS = {
    "GliderMaxSpeed",
    "GliderAirControl",
    "GliderGravityScale",
    "GravityScale",
    "AirControl",
    "JetpackGliderAnimInterpSpeed",
}

function M.OnPlayerCached(pawn, cmc)
    prevVelocityX, prevVelocityY, prevVelocityZ = 0, 0, 0
    wasGliderDeployedLastFrame = false
    framesLeftToLog = 0
    prevMovementMode, prevCustomMovementMode = nil, nil
    ClearRing()

    dbg("---- vanilla glider values ----")
    for _, field in ipairs(GLIDER_FIELDS) do
        dbg("  %-30s = %s", field, tostring(ReadOpt(cmc, field)))
    end

    dbg("---- custom movement modes ----")
    DumpCustomMovementModes(cmc)

    local gliderComponent = ReadOpt(pawn, "BP_GliderComponent")
    dbg("glider component: %s",
        gliderComponent and tostring(gliderComponent) or "NOT FOUND")
    dbg("-------------------------------")
end

-- Cache this frame's velocity for the next frame's comparison. Skipped
-- while the glider is deployed, so prevVelocity* stays pinned to the last
-- frame before the open — the momentum the open is suspected of
-- discarding.
local function CacheFrameState(cmc, isGliderDeployed)
    if not isGliderDeployed then
        local velocity = cmc.Velocity
        prevVelocityX = velocity.X
        prevVelocityY = velocity.Y
        prevVelocityZ = velocity.Z
    end
    wasGliderDeployedLastFrame = isGliderDeployed
end

function M.OnTick(dt, pawn, cmc)
    local gliderComponent = pawn.BP_GliderComponent
    if gliderComponent == nil then return end
  
    local isGliding = gliderComponent.bIsGliding
    local gliderObj = gliderComponent.CurrentGlider
    local gliderKey = gliderComponent.CurrentGliderPalID -- FName of our current glider
  
    if isGliding and not wasGliderDeployedLastFrame then
        -- init glider start
    end

    -- Cache values for next frame comparisons. Must stay last.
    CacheFrameState(cmc, isGliding)
end

return M
