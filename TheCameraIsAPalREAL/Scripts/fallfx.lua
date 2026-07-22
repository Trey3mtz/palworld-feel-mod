-- =========================================================================
-- TheCameraIsAPal subsystem: fallfx — heavy heave while falling
--
-- v3 rationale: the previous fall shake was dominated by smooth lateral
-- noise drift, which reads as slow rotation/swimming (camera slides while
-- its aim stays fixed). Gears-style falling is vertical-dominant and
-- punchy: a large sharpened HEAVE on Z carries the effect, lateral
-- turbulence is demoted to garnish, and touchdown fires one hard
-- ROTATIONAL impulse through the game's shake pipeline, scaled by how
-- fast you were falling.
--
-- Engages while MovementMode == Falling and downward speed > VZ_START.
-- =========================================================================

local Rig     = require("rig")
local U       = require("camutil")
local Impulse = require("camimpulse")

local CFG = {
    VZ_START  = 200,     -- uu/s downward before any effect
    VZ_MAX    = 1400,    -- uu/s downward at full intensity
    FOV_MAX   = 12.0,    -- deg at full intensity

    HEAVE_Z   = 34.0,    -- uu dominant vertical heave at full intensity
    HEAVE_HZ  = 2.2,     -- Hz
    HEAVE_SHARP = 0.7,

    TURB_X    = 8.0,     -- uu fBm turbulence (garnish, vertical-biased)
    TURB_Y    = 10.0,
    TURB_Z    = 12.0,
    TURB_HZ   = 4.5,
    OCTAVES   = 3,

    MIN_INT   = 0.15,
    RAMP_IN   = 6.0,     -- 1/s
    RAMP_OUT  = 10.0,    -- fast decay on landing

    LAND_IMPULSE = true,
    LAND_MIN_INT = 0.20,   -- minimum peak intensity to fire the landing jolt
    LAND_SCALE   = 1.0,    -- shake scale = LAND_SCALE * peak intensity
}

local M = { name = "fallfx" }

local amp     = 0.0
local tt      = 0.0
local peak    = 0.0
local engaged = false

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:fallfx] " .. fmt .. "\n", ...))
end

function M.OnCached(ctx)
    amp, tt, peak, engaged = 0.0, 0.0, 0.0, false
end

function M.OnTick(dt, ctx, sig)
    local down = -sig.vz
    local target = 0.0
    if sig.falling and down > CFG.VZ_START then
        target = U.MapClamped(down, CFG.VZ_START, CFG.VZ_MAX, CFG.MIN_INT, 1.0)
    end

    if (target > 0) ~= engaged then
        engaged = (target > 0)
        dbg("%s (down=%.0f)", engaged and "engaged" or "disengaged", down)
        if not engaged then
            -- touchdown / effect end: one hard rotational jolt, scaled
            if CFG.LAND_IMPULSE and peak >= CFG.LAND_MIN_INT then
                Impulse.Impulse(ctx, CFG.LAND_SCALE * peak)
                dbg("landing impulse (peak=%.2f)", peak)
            end
            peak = 0.0
        end
    end
    if engaged then peak = math.max(peak, target) end

    local rate = (target > amp) and CFG.RAMP_IN or CFG.RAMP_OUT
    amp = U.ExpApproach(amp, target, rate, dt)
    if amp < 0.01 then return end

    tt = tt + dt
    local heave = U.Heave(tt, CFG.HEAVE_HZ, CFG.HEAVE_SHARP)
    local f = CFG.TURB_HZ
    local jx = U.FBm(tt * f +  11.9, CFG.OCTAVES) * CFG.TURB_X * amp
    local jy = U.FBm(tt * f + 157.1, CFG.OCTAVES) * CFG.TURB_Y * amp
    local jz = heave * CFG.HEAVE_Z * amp
             + U.FBm(tt * f + 313.7, CFG.OCTAVES) * CFG.TURB_Z * amp

    Rig.Add{
        fovAdd = CFG.FOV_MAX * amp,
        jitter = { x = jx, y = jy, z = jz },
    }
end

return M
