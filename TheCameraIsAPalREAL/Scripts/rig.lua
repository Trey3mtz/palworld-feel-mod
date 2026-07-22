-- =========================================================================
-- TheCameraIsAPal module: rig (v2) — the single writer for camera properties
--
-- v2 rationale: the game's native camera code writes TargetArmLength and
-- SocketOffset per frame during at least some states (confirmed 2026-07-22,
-- 40-48 writes/s during slide/glide). v1 smoothed ABSOLUTE values and reset
-- them on every external write, which erased its own progress each frame.
-- v2 smooths in OFFSET space (scale factor / additive deltas); external
-- writes update only the base, so accumulated effect survives contention.
-- Within a frame the last writer before camera evaluation wins; telemetry
-- below reports which side that is.
--
-- Per tick, main.lua calls:
--   Rig.Begin()            reset this frame's request accumulators
--   <subsystems run>       each may call Rig.Add{...} any number of times
--   Rig.Finish(dt, ctx)    smooth toward composed targets, write once
--
-- Request channels (all optional per Add call):
--   armScale : number   multiplies TargetArmLength base   (composed by product)
--   fovAdd   : number   degrees added to FieldOfView base (composed by sum)
--   sock     : {x,y,z}  uu offset added to SocketOffset base (sum, smoothed)
--   jitter   : {x,y,z}  uu raw additive offset, NOT smoothed (phase C noise)
--
-- Behavior:
--   * Idle suppression — while all channels are neutral the rig writes
--     NOTHING; bases track the game's values exactly. The game keeps full
--     ownership whenever we have nothing to say.
--   * While active, TELEMETRY prints 1 Hz per contested-capable channel:
--       arm[w=58 s=1 base=400 out=478]
--     w = frames our previous write survived to this tick ("wins")
--     s = frames the game overwrote us ("stomps"; base adopts its value)
--     Read it as: w~framerate,s~0 -> we own the channel, effect visible.
--                 s~framerate     -> game writes after us; property channel
--                                    is lost for that value; escalate to
--                                    steering the game's source parameters
--                                    (see xray dump) instead.
-- =========================================================================

local U = require("camutil")

-- smoothing (offset space)
local ARM_SMOOTH_TIME = 0.45     -- s; pace of armScale transitions
local FOV_SMOOTH_TIME = 0.30     -- s
local SOCK_RATE       = 6.0      -- 1/s exponential rate for framing offsets

-- external-write classification epsilons
local EPS_ARM  = 0.5             -- uu
local EPS_FOV  = 0.25            -- deg
local EPS_SOCK = 0.5             -- uu, max per-axis

-- neutrality thresholds (below these, the rig goes silent)
local NEUTRAL_SCALE = 0.002
local NEUTRAL_FOV   = 0.05
local NEUTRAL_SOCK  = 0.1

local DEBUG     = true
local TELEMETRY = true           -- 1 Hz channel report while active

local M = {}

-- bases (track the game)
local baseArm, baseFov = nil, nil
local baseSock         = { x = 0, y = 0, z = 0 }

-- smoothed effect state (offset space; survives external writes)
local sScale, vScale = 1.0, 0.0
local sFov,   vFov   = 0.0, 0.0
local sSock          = { x = 0, y = 0, z = 0 }

-- write tracking
local lastWroteArm, lastWroteFov = nil, nil
local lastWroteSock              = nil
local sockPath                   = nil   -- "field" | "struct"

-- telemetry
local stats = { t = 0,
                arm  = { w = 0, s = 0 },
                fov  = { w = 0, s = 0 },
                sock = { w = 0, s = 0 },
                hinted = {} }

local req = nil

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[TheCameraIsAPal:rig] " .. fmt .. "\n", ...)) end
end

-- ------------------------------ requests ---------------------------------

function M.Begin()
    req = {
        armScale = 1.0,
        fovAdd   = 0.0,
        sock     = { x = 0, y = 0, z = 0 },
        jitter   = { x = 0, y = 0, z = 0 },
    }
end

function M.Add(r)
    if req == nil then return end
    if r.armScale then req.armScale = req.armScale * r.armScale end
    if r.fovAdd   then req.fovAdd   = req.fovAdd + r.fovAdd end
    if r.sock then
        req.sock.x = req.sock.x + (r.sock.x or 0)
        req.sock.y = req.sock.y + (r.sock.y or 0)
        req.sock.z = req.sock.z + (r.sock.z or 0)
    end
    if r.jitter then
        req.jitter.x = req.jitter.x + (r.jitter.x or 0)
        req.jitter.y = req.jitter.y + (r.jitter.y or 0)
        req.jitter.z = req.jitter.z + (r.jitter.z or 0)
    end
end

-- ------------------------------ lifecycle --------------------------------

function M.OnCached(ctx)
    baseArm, baseFov = nil, nil
    baseSock = { x = 0, y = 0, z = 0 }
    sScale, vScale, sFov, vFov = 1.0, 0.0, 0.0, 0.0
    sSock = { x = 0, y = 0, z = 0 }
    lastWroteArm, lastWroteFov, lastWroteSock = nil, nil, nil
    sockPath = nil
    stats = { t = 0, arm = { w = 0, s = 0 }, fov = { w = 0, s = 0 },
              sock = { w = 0, s = 0 }, hinted = {} }

    if ctx.arm and ctx.arm:IsValid() then
        pcall(function() baseArm = ctx.arm.TargetArmLength end)
        pcall(function()
            local so = ctx.arm.SocketOffset
            baseSock = { x = so.X, y = so.Y, z = so.Z }
        end)
    end
    if ctx.cam and ctx.cam:IsValid() then
        pcall(function() baseFov = ctx.cam.FieldOfView end)
    end
    dbg("bases: arm=%s fov=%s sock=(%.1f, %.1f, %.1f)",
        tostring(baseArm), tostring(baseFov),
        baseSock.x, baseSock.y, baseSock.z)
end

-- ------------------------------ writing ----------------------------------

local function WriteSock(armC, x, y, z)
    if sockPath == "field" then
        return pcall(function()
            local so = armC.SocketOffset
            so.X = x; so.Y = y; so.Z = z
        end)
    end
    if sockPath == "struct" then
        return pcall(function() armC.SocketOffset = { X = x, Y = y, Z = z } end)
    end
    local ok = pcall(function()
        local so = armC.SocketOffset
        so.X = x; so.Y = y; so.Z = z
    end)
    if ok then
        local verified = false
        pcall(function()
            local so = armC.SocketOffset
            verified = math.abs(so.X - x) < 0.01
                   and math.abs(so.Y - y) < 0.01
                   and math.abs(so.Z - z) < 0.01
        end)
        if verified then
            sockPath = "field"
            dbg("SocketOffset write path: field")
            return true
        end
    end
    local ok2 = pcall(function() armC.SocketOffset = { X = x, Y = y, Z = z } end)
    if ok2 then
        sockPath = "struct"
        dbg("SocketOffset write path: struct")
    else
        dbg("WARNING: no SocketOffset write path works")
    end
    return ok2
end

-- ------------------------------ finish -----------------------------------

function M.Finish(dt, ctx)
    if req == nil then return end
    local armC, camC = ctx.arm, ctx.cam
    if not (armC and armC:IsValid() and camC and camC:IsValid()) then
        req = nil
        return
    end

    -- ---- sample current values ----
    local okA, nowArm = pcall(function() return armC.TargetArmLength end)
    local okF, nowFov = pcall(function() return camC.FieldOfView end)
    local nowSock = nil
    pcall(function()
        local so = armC.SocketOffset
        nowSock = { x = so.X, y = so.Y, z = so.Z }
    end)
    if not (okA and okF and nowSock) then req = nil; return end

    -- ---- classify last frame; update bases ----
    if lastWroteArm then
        if math.abs(nowArm - lastWroteArm) <= EPS_ARM then
            stats.arm.w = stats.arm.w + 1
        else
            stats.arm.s = stats.arm.s + 1
            baseArm = nowArm            -- game wrote after us; its value is base
        end
    else
        baseArm = nowArm                 -- idle: base follows the game
    end
    if lastWroteFov then
        if math.abs(nowFov - lastWroteFov) <= EPS_FOV then
            stats.fov.w = stats.fov.w + 1
        else
            stats.fov.s = stats.fov.s + 1
            baseFov = nowFov
        end
    else
        baseFov = nowFov
    end
    if lastWroteSock then
        local d = math.max(math.abs(nowSock.x - lastWroteSock.x),
                           math.abs(nowSock.y - lastWroteSock.y),
                           math.abs(nowSock.z - lastWroteSock.z))
        if d <= EPS_SOCK then
            stats.sock.w = stats.sock.w + 1
        else
            stats.sock.s = stats.sock.s + 1
            baseSock = { x = nowSock.x, y = nowSock.y, z = nowSock.z }
        end
    else
        baseSock = { x = nowSock.x, y = nowSock.y, z = nowSock.z }
    end
    if baseArm == nil or baseFov == nil then req = nil; return end

    -- ---- smooth effect state in offset space ----
    sScale, vScale = U.SmoothDamp(sScale, req.armScale, vScale, ARM_SMOOTH_TIME, dt)
    sFov,   vFov   = U.SmoothDamp(sFov,   req.fovAdd,   vFov,   FOV_SMOOTH_TIME, dt)
    sSock.x = U.ExpApproach(sSock.x, req.sock.x, SOCK_RATE, dt)
    sSock.y = U.ExpApproach(sSock.y, req.sock.y, SOCK_RATE, dt)
    sSock.z = U.ExpApproach(sSock.z, req.sock.z, SOCK_RATE, dt)

    -- ---- neutrality: go silent when there is nothing to apply ----
    local jitterActive = req.jitter.x ~= 0 or req.jitter.y ~= 0 or req.jitter.z ~= 0
    local active = jitterActive
        or math.abs(sScale - 1.0) > NEUTRAL_SCALE
        or math.abs(sFov)         > NEUTRAL_FOV
        or math.abs(sSock.x)      > NEUTRAL_SOCK
        or math.abs(sSock.y)      > NEUTRAL_SOCK
        or math.abs(sSock.z)      > NEUTRAL_SOCK
        or req.armScale ~= 1.0
        or req.fovAdd   ~= 0.0
        or req.sock.x ~= 0 or req.sock.y ~= 0 or req.sock.z ~= 0

    if not active then
        lastWroteArm, lastWroteFov, lastWroteSock = nil, nil, nil
        req = nil
        return
    end

    -- ---- write once ----
    local outArm = baseArm * sScale
    local outFov = baseFov + sFov
    local ox = baseSock.x + sSock.x + req.jitter.x
    local oy = baseSock.y + sSock.y + req.jitter.y
    local oz = baseSock.z + sSock.z + req.jitter.z

    if pcall(function() armC.TargetArmLength = outArm end) then
        lastWroteArm = outArm
    end
    if pcall(function() camC.FieldOfView = outFov end) then
        lastWroteFov = outFov
    end
    if WriteSock(armC, ox, oy, oz) then
        lastWroteSock = { x = ox, y = oy, z = oz }
    end

    -- ---- telemetry ----
    if TELEMETRY then
        stats.t = stats.t + dt
        if stats.t >= 1.0 then
            dbg("telemetry arm[w=%d s=%d base=%.0f out=%.0f] fov[w=%d s=%d out=%.1f] sock[w=%d s=%d]",
                stats.arm.w, stats.arm.s, baseArm, outArm,
                stats.fov.w, stats.fov.s, outFov,
                stats.sock.w, stats.sock.s)
            for _, ch in ipairs({ { "arm", stats.arm }, { "fov", stats.fov },
                                  { "sock", stats.sock } }) do
                if ch[2].s > ch[2].w and not stats.hinted[ch[1]] then
                    stats.hinted[ch[1]] = true
                    dbg("HINT: game writes after us on '%s' -- property channel is losing; steer the game's source parameters instead (see xray dump)", ch[1])
                end
            end
            stats.t = 0
            stats.arm.w, stats.arm.s   = 0, 0
            stats.fov.w, stats.fov.s   = 0, 0
            stats.sock.w, stats.sock.s = 0, 0
        end
    end

    req = nil
end

return M
