-- =========================================================================
-- TheCameraIsAPal subsystem: sprintfx — roadie-run screen bob while sprinting
--
-- Gears-style bob, not noise: a phase-accumulated footstep pattern. The
-- vertical dips once per step (sharpened sine — wide peaks, quick reversals,
-- which is where the "jolt" comes from), the lateral alternates each step,
-- and cadence scales with actual speed. A small Perlin layer roughs it up so
-- it never reads as a metronome.
--
-- Channel split: the continuous bob is a per-frame curve, so it can only
-- ride Channel C (jitter). Each footfall additionally fires a one-shot
-- ROTATIONAL impulse on Channel B — that runs inside camera evaluation and
-- is never contested, and it supplies roll/pitch that a positional
-- SocketOffset simply cannot produce.
--
-- All tuning lives in config.sprintfx. Press F10 after editing.
-- =========================================================================

local Rig = require("rig")
local U   = require("camutil")
local Log = require("log")

local M = { name = "sprintfx" }

local dbg = Log.Make("sprintfx", "sprintfx")

-- ==== configuration ======================================================

local CFG = nil

-- ==== state ==============================================================

local amp      = 0.0     -- eased intensity 0..1
local ph       = 0.0     -- phase, counted in steps
local nt       = 0.0     -- noise time base
local lastStep = 0
local engaged  = false

-- Hoisted request payload; the tick path allocates nothing.
local jitter  = { x = 0, y = 0, z = 0 }
local request = { fovAdd = 0, jitter = jitter }

-- ==== subsystem interface ================================================

function M.RefreshConfig(c)
    if c == nil then return end
    CFG = c
    dbg("config refreshed: fov=%.1f bob=(%.0f/%.0f) cadence=%.1f-%.1fHz",
        CFG.fovAdd, CFG.bobLat, CFG.bobVert, CFG.stepLo, CFG.stepHi)
end

function M.OnCached(ctx)
    amp, ph, nt, lastStep, engaged = 0.0, 0.0, 0.0, 0, false
end

function M.Release()
    amp, engaged = 0.0, false
end

function M.OnTick(dt, ctx, sig)
    if CFG == nil then return end

    local target = 0.0
    if sig.sprinting then
        target = U.MapClamped(sig.speed2d, CFG.speedLo, CFG.speedHi, CFG.minInt, 1.0)
    end

    if (target > 0) ~= engaged then
        engaged = (target > 0)
        dbg("%s (speed2d=%.0f)", engaged and "engaged" or "disengaged", sig.speed2d)
        if engaged then lastStep = math.floor(ph) end
    end

    local rate = (target > amp) and CFG.rampIn or CFG.rampOut
    amp = U.ExpApproach(amp, target, rate, dt)
    if amp < 0.01 then return end

    -- Cadence tracks real speed, so the bob stays locked to the animation.
    local stepHz = U.MapClamped(sig.speed2d, CFG.speedLo, CFG.speedHi,
                                CFG.stepLo, CFG.stepHi)
    ph = ph + stepHz * dt
    nt = nt + dt

    local lat, vert = U.Bob(ph, CFG.bobSharp)
    jitter.x = 0
    jitter.y = lat  * CFG.bobLat  * amp
             + U.Noise1D(nt * CFG.roughHz + 37.3) * CFG.roughY * amp
    jitter.z = vert * CFG.bobVert * amp
             + U.Noise1D(nt * CFG.roughHz + 91.7) * CFG.roughZ * amp
    request.fovAdd = CFG.fovAdd * amp

    Rig.Add(request)

    -- One rotational jolt per footfall, on the uncontested channel.
    if CFG.footfallImpulse and engaged then
        local step = math.floor(ph)
        if step ~= lastStep then
            lastStep = step
            Rig.Impulse(CFG.impulseScale * amp)
        end
    end
end

function M.DumpState(out)
    out("-- sprintfx --")
    out("  engaged     : %s  amp=%.2f", tostring(engaged), amp)
    out("  phase       : %.2f steps", ph)
end

return M
