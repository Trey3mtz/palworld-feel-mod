-- =========================================================================
-- TheCameraIsAPal module: camimpulse — one-shot rotational camera shakes
--
-- Positional SocketOffset bob cannot roll or pitch the camera. The game's
-- shake pipeline can: the camera manager runs a live
-- CameraModifier_CameraShake (confirmed by probe), and the controller
-- carries the game's damage camera shake class. Impulse(ctx, scale) plays
-- that class at the given scale — applied during camera evaluation, so it
-- cannot be contested by anything we fight elsewhere.
--
-- The shake class property name on APalPlayerController is resolved
-- defensively from a candidate list. If none resolve, impulses disable
-- with a single log line (positional bob is unaffected); paste that line
-- back and the correct name can be added.
-- =========================================================================

local M = {}

local CANDIDATES = {
    "DamageCameraShake",
    "PlayerDamageCameraShake",
    "DamageCamShake",
    "CameraShake",
}

local resolved   = false
local shakeClass = nil
local failWarned = false

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:impulse] " .. fmt .. "\n", ...))
end

local function Resolve(ctx)
    resolved = true
    shakeClass = nil
    if not (ctx.pc and ctx.pc:IsValid()) then return end
    for _, name in ipairs(CANDIDATES) do
        local ok, v = pcall(function() return ctx.pc[name] end)
        if ok and v ~= nil then
            shakeClass = v
            dbg("shake class resolved via pc.%s", name)
            return
        end
    end
    dbg("no camera shake class found on the controller; rotational impulses disabled")
end

--- Play a one-shot rotational shake at `scale` (game units; ~0.1 subtle
--- footfall, ~1.0 hard landing). Returns true if the shake was started.
function M.Impulse(ctx, scale)
    if not resolved then Resolve(ctx) end
    if shakeClass == nil then return false end

    local mgr = nil
    pcall(function() mgr = ctx.pc.PlayerCameraManager end)
    if not (mgr and mgr:IsValid()) then return false end

    local ok = pcall(function()
        -- ECameraShakePlaySpace::CameraLocal = 0
        mgr:StartCameraShake(shakeClass, scale, 0, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok then
        if not failWarned then
            failWarned = true
            dbg("StartCameraShake failed; will re-resolve on next use")
        end
        resolved = false          -- stale class after level change: retry
        return false
    end
    return true
end

return M
