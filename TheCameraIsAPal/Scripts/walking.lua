-- =========================================================================
-- PalFeel subsystem: walking — Odyssey-style buildup and momentum
--
-- Standstill -> walk : our eased MaxWalkSpeed cap (game never lowers it at
--                      idle, so buildup can't come from the game's value).
-- Walk -> sprint     : the game's own dedicated SprintMaxAcceleration,
--                      set low so the engine itself produces the buildup.
--                      Time to sprint ~= (sprintSpeed - current) / accel.
-- Sprint release     : speed glides back to the walk cap via the lowered
--                      braking statics (no stop-on-dime anywhere).
-- SprintYawRate      : sprint turn rate — lower = wide Odyssey arcs at
--                      full speed. Left vanilla (nil) until stock is known.
--
-- First run prints the vanilla sprint values; tune from those numbers.
-- =========================================================================

local Easing = require("easingfunctions")

-- ---- standstill -> walk easing ----
local START_CAP   = 150     -- cap at the first instant of movement (uu/s)
local STOP_SPEED  = 50      -- below this 2D speed we count as standing
local EASE_UP_TIME,   EASE_UP_FN   = 0.50, Easing.EaseInSine
local EASE_DOWN_TIME, EASE_DOWN_FN = 0.80, Easing.EaseOutQuad

-- ---- sprint shaping (nil = leave vanilla) ----
local SPRINT_ACCEL     = 500    -- vanilla unknown; ~0.4s walk->sprint if sprint ~550
local SPRINT_MAX_SPEED = 610    -- vanilla = 500
local SPRINT_YAW       = nil   -- vanilla = 0.6999 , lower = wider turning arcs while sprinting

-- ---- ground momentum statics ----      -- vanilla:
local MAX_ACCEL               = 2048     -- 2048 (high = speed hugs the cap)
local BRAKING_DECEL           = 600       -- 2048 (lower = glide to a stop)
-- Friction duties are SPLIT: GroundFriction now only governs how fast
-- velocity realigns to input in turns (higher = less speed shaved), while
-- BrakingFriction governs stop/no-input glide independently.
local USE_SEPARATE_BRAKING    = false
local GROUND_FRICTION         = 7.0       -- 8.0 vanilla; turn realignment only
local BRAKING_FRICTION        = 1.0       -- no-input glide (separate braking on)
local BRAKING_FRICTION_FACTOR = 1.2       -- 2.0; multiplies BrakingFriction

local DEBUG = true

local M = { name = "walking" }

local desired   = nil     -- game's intended walk top speed (captured)
local moving    = false
local capFrom, capTo = 0, 0
local easeT, easeDur, easeFn = 0, 0, nil
local lastWrite = nil

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
local function ReadOpt(cmc, prop)
    local ok, v = pcall(function() return cmc[prop] end)
    return ok and v or nil
end

local function WriteOpt(cmc, prop, value, label)
    if value == nil then return end
    local ok, err = pcall(function() cmc[prop] = value end)
    if ok then dbg("%s -> %s", label or prop, tostring(value))
    else dbg("WRITE FAILED for %s: %s", prop, tostring(err)) end
end

function M.OnPlayerCached(pawn, cmc)
    desired   = cmc.MaxWalkSpeed
    moving    = false
    lastWrite = nil
    capFrom, capTo, easeT, easeDur, easeFn = 0, START_CAP, 0, 0, nil

    -- Report the sprint fields before touching anything (fills the baseline).
    dbg("vanilla: walk=%.0f  SprintMaxSpeed=%s  SprintMaxAcceleration=%s  SprintYawRate=%s",
        desired,
        tostring(ReadOpt(cmc, "SprintMaxSpeed")),
        tostring(ReadOpt(cmc, "SprintMaxAcceleration")),
        tostring(ReadOpt(cmc, "SprintYawRate")))

    dbg("vanilla RotationRate: ", cmc.RotationRate)
    cmc.MaxAcceleration            = MAX_ACCEL
    cmc.BrakingDecelerationWalking = BRAKING_DECEL
    cmc.GroundFriction             = GROUND_FRICTION
    cmc.bUseSeparateBrakingFriction = USE_SEPARATE_BRAKING
    cmc.BrakingFriction            = BRAKING_FRICTION
    cmc.BrakingFrictionFactor      = BRAKING_FRICTION_FACTOR

    WriteOpt(cmc, "SprintMaxAcceleration", SPRINT_ACCEL)
    WriteOpt(cmc, "SprintMaxSpeed",        SPRINT_MAX_SPEED)
    WriteOpt(cmc, "SprintYawRate",         SPRINT_YAW)
end

function M.OnTick(dt, pawn, cmc)
    local mode = cmc.MovementMode
    local grounded = (mode == 1 or mode == 2)   -- Walking / NavWalking
    if not grounded then return end             -- keep momentum through jumps

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
