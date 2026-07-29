-- =========================================================================
-- TheCameraIsAPal subsystem: fallfx — heavy heave while falling
--
-- An earlier version was dominated by smooth lateral noise drift, which
-- reads as slow rotation/swimming: the camera slides while its aim stays
-- fixed. Gears-style falling is vertical-dominant and punchy, so a large
-- sharpened HEAVE on Z carries the effect, lateral turbulence is demoted to
-- garnish, and touchdown fires one hard rotational impulse scaled by how
-- fast you were falling.
--
-- Channel split, same reasoning as sprintfx: the continuous heave is a
-- per-frame curve and rides Channel C; the landing jolt is a one-shot and
-- rides Channel B, inside camera evaluation where nothing contests it.
--
-- Engages while MovementMode == Falling and downward speed > vzStart.
-- All tuning lives in config.fallfx. Press F10 after editing.
-- =========================================================================

local Rig = require("rig")
local U   = require("camutil")
local Log = require("log")

local M = { name = "fallfx" }

local dbg = Log.Make("fallfx", "fallfx")

-- ==== configuration ======================================================

local CFG = nil

-- ==== state ==============================================================

local amp     = 0.0     -- eased intensity 0..1
local tt      = 0.0     -- effect time base
local peak    = 0.0     -- highest intensity this fall, drives the land jolt
local engaged = false

-- Hoisted request payload; the tick path allocates nothing.
local jitter  = { x = 0, y = 0, z = 0 }
local request = { fovAdd = 0, jitter = jitter }

-- ==== subsystem interface ================================================

function M.RefreshConfig(c)
    if c == nil then return end
    CFG = c
    dbg("config refreshed: heave=%.0fuu@%.1fHz fov=%.1f land=%s",
        CFG.heaveZ, CFG.heaveHz, CFG.fovMax, tostring(CFG.landImpulse))
end

function M.OnCached(ctx)
    amp, tt, peak, engaged = 0.0, 0.0, 0.0, false
end

function M.Release()
    amp, peak, engaged = 0.0, 0.0, false
end

function M.OnTick(dt, ctx, sig)
    if CFG == nil then return end

    local down   = -sig.vz
    local target = 0.0
    if sig.falling and down > CFG.vzStart then
        target = U.MapClamped(down, CFG.vzStart, CFG.vzMax, CFG.minInt, 1.0)
    end

    if (target > 0) ~= engaged then
        engaged = (target > 0)
        dbg("%s (down=%.0f)", engaged and "engaged" or "disengaged", down)
        if not engaged then
            -- Fire ONLY on a real touchdown. The old test was "the effect
            -- stopped", which is not the same thing: the logs caught it
            -- firing at down=468, i.e. still falling fast, because the
            -- movement mode had changed (glide/swim/mount). That is a jolt
            -- from nothing, mid-air.
            local landed = sig.grounded
            if landed and CFG.landImpulse and peak >= CFG.landMinInt then
                Rig.Impulse(CFG.landScale * peak)
                dbg("landing impulse (peak=%.2f)", peak)
            elseif not landed then
                dbg("fall ended without touchdown (down=%.0f) — no impulse", down)
            end
            peak = 0.0
        end
    end
    if engaged and target > peak then peak = target end

    local rate = (target > amp) and CFG.rampIn or CFG.rampOut
    amp = U.ExpApproach(amp, target, rate, dt)
    if amp < 0.01 then return end

    tt = tt + dt
    local heave = U.Heave(tt, CFG.heaveHz, CFG.heaveSharp)
    local f = CFG.turbHz
    jitter.x = U.FBm(tt * f +  11.9, CFG.octaves) * CFG.turbX * amp
    jitter.y = U.FBm(tt * f + 157.1, CFG.octaves) * CFG.turbY * amp
    jitter.z = heave * CFG.heaveZ * amp
             + U.FBm(tt * f + 313.7, CFG.octaves) * CFG.turbZ * amp
    request.fovAdd = CFG.fovMax * amp

    Rig.Add(request)
end

function M.DumpState(out)
    out("-- fallfx --")
    out("  engaged     : %s  amp=%.2f  peak=%.2f", tostring(engaged), amp, peak)
end

return M
