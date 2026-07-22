-- =========================================================================
-- TheCameraIsAPal subsystem: sprintfx — roadie-run screen bob while sprinting
--
-- Gears-style bob, not noise: a phase-accumulated footstep pattern.
--   vertical dips once per step (sharpened sine: wide peaks, quick
--   reversals = the "jolt"), lateral alternates each step, cadence scales
--   with speed. A small Perlin layer roughs it up so it never reads as a
--   metronome. Optionally fires a small ROTATIONAL impulse through the
--   game's shake pipeline on each footfall (camimpulse), which positional
--   offsets cannot provide.
--
-- Contributes via the rig: fovAdd + jitter. Engage/disengage is logged.
-- =========================================================================

local Rig     = require("rig")
local U       = require("camutil")
local Impulse = require("camimpulse")

local CFG = {
    FOV_ADD   = 7.0,     -- deg at full intensity

    BOB_VERT  = 12.0,    -- uu vertical dip amplitude
    BOB_LAT   = 7.0,     -- uu lateral sway amplitude
    BOB_SHARP = 0.62,    -- < 1 = punchier vertical
    STEP_LO   = 2.3,     -- Hz footfall cadence at SPEED_LO
    STEP_HI   = 3.0,     -- Hz cadence at SPEED_HI

    ROUGH_Y   = 2.5,     -- uu Perlin garnish amplitudes
    ROUGH_Z   = 2.0,
    ROUGH_HZ  = 3.7,

    SPEED_LO  = 420,     -- uu/s
    SPEED_HI  = 600,
    MIN_INT   = 0.4,
    RAMP_IN   = 3.0,     -- 1/s
    RAMP_OUT  = 5.0,

    FOOTFALL_IMPULSE = true,
    IMPULSE_SCALE    = 0.12,   -- per-footfall rotational jolt (x intensity)
}

local M = { name = "sprintfx" }

local amp      = 0.0
local ph       = 0.0     -- phase in steps
local nt       = 0.0     -- noise time
local lastStep = 0
local engaged  = false

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:sprintfx] " .. fmt .. "\n", ...))
end

function M.OnCached(ctx)
    amp, ph, nt, lastStep, engaged = 0.0, 0.0, 0.0, 0, false
end

function M.OnTick(dt, ctx, sig)
    local target = 0.0
    if sig.sprinting then
        target = U.MapClamped(sig.speed2d, CFG.SPEED_LO, CFG.SPEED_HI,
                              CFG.MIN_INT, 1.0)
    end

    if (target > 0) ~= engaged then
        engaged = (target > 0)
        dbg("%s (speed2d=%.0f)", engaged and "engaged" or "disengaged", sig.speed2d)
        if engaged then lastStep = math.floor(ph) end
    end

    local rate = (target > amp) and CFG.RAMP_IN or CFG.RAMP_OUT
    amp = U.ExpApproach(amp, target, rate, dt)
    if amp < 0.01 then return end

    -- cadence scales with actual speed
    local stepHz = U.MapClamped(sig.speed2d, CFG.SPEED_LO, CFG.SPEED_HI,
                                CFG.STEP_LO, CFG.STEP_HI)
    ph = ph + stepHz * dt
    nt = nt + dt

    local lat, vert = U.Bob(ph, CFG.BOB_SHARP)
    local jy = lat  * CFG.BOB_LAT  * amp
             + U.Noise1D(nt * CFG.ROUGH_HZ + 37.3) * CFG.ROUGH_Y * amp
    local jz = vert * CFG.BOB_VERT * amp
             + U.Noise1D(nt * CFG.ROUGH_HZ + 91.7) * CFG.ROUGH_Z * amp

    Rig.Add{
        fovAdd = CFG.FOV_ADD * amp,
        jitter = { x = 0, y = jy, z = jz },
    }

    -- one rotational jolt per footfall
    if CFG.FOOTFALL_IMPULSE and engaged then
        local step = math.floor(ph)
        if step ~= lastStep then
            lastStep = step
            Impulse.Impulse(ctx, CFG.IMPULSE_SCALE * amp)
        end
    end
end

return M
