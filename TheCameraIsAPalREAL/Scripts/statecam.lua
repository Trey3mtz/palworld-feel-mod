-- =========================================================================
-- TheCameraIsAPal subsystem: statecam — framing via state bank + output glide
--
-- Two findings shape this design:
--   (1) The game uses the Walk fields for grounded locomotion regardless of
--       holster state, so framing is holster-driven by us.
--   (2) The game reads the state bank ONLY on locomotion-state transitions.
--       Writing the fields while standing still changes nothing until the
--       next jump/aim/state switch. Therefore, after each holster
--       transition this subsystem also GLIDES the live output
--       (TargetArmLength / SocketOffset) to the target itself. Mid-state
--       the output channel is uncontested (contention was only ever
--       observed during state interpolation); if the game's interp does
--       take over mid-glide, the glide detects the external write and
--       yields immediately. The bank fields are always written as well, so
--       the game's own transitions land on the same values.
--
-- Holster truth: sig.holstered (== HelpfulHolster's IsHolstered() ground
-- truth; see main.lua header).
--
-- Also owns: Air/AirHipShoot anti jump-zoom mirrors, camera lag (live +
-- Default* mirrors, re-asserted at 1 Hz), optional speed blur.
-- =========================================================================

local U = require("camutil")

local CFG = {
    -- Framing while holstered (BOTW: centered, pulled back, slightly high)
    HOLSTERED = { arm = 500, offset = { x = 10, y = 0,  z = 50 } },
    -- Framing while a weapon/tool is out (vanilla-like shoulder, a bit back)
    DRAWN     = { arm = 360, offset = { x = 80, y = 60, z = 60 } },

    GLIDE_RATE    = 7.0,    -- 1/s exponential ease of the output glide
    GLIDE_TIMEOUT = 1.5,    -- s hard stop
    GLIDE_DONE    = 1.5,    -- uu closeness that ends the glide
    GLIDE_ABORT   = 3.0,    -- uu external-write delta that aborts the glide

    LAG = {
        enable   = true,
        speed    = 9,       -- lower = more float. 6 heavy, 12 subtle
        maxDist  = 150,
        rotation = false,   -- delays look input; off by default
        rotSpeed = 15,
    },

    SPEED_BLUR = true,
}

local M = { name = "statecam" }

local C             = nil
local vecPath       = nil
local lastHolstered = nil
local lagTimer      = 0
local glide         = { active = false, t = 0, lastWrote = nil }

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:statecam] " .. fmt .. "\n", ...))
end

local function CurrentSet(holstered)
    return holstered and CFG.HOLSTERED or CFG.DRAWN
end

local function WriteVec(owner, prop, x, y, z)
    if vecPath == "struct" then
        return pcall(function() owner[prop] = { X = x, Y = y, Z = z } end)
    end
    local ok = pcall(function()
        local v = owner[prop]
        v.X = x; v.Y = y; v.Z = z
    end)
    if ok and vecPath == nil then
        local good = false
        pcall(function()
            local v = owner[prop]
            good = math.abs(v.X - x) < 0.01 and math.abs(v.Y - y) < 0.01
        end)
        if good then vecPath = "field"; return true end
        local ok2 = pcall(function() owner[prop] = { X = x, Y = y, Z = z } end)
        if ok2 then vecPath = "struct" end
        return ok2
    end
    return ok
end

-- ---- state bank ----------------------------------------------------------

local function ApplyBank(holstered)
    if not (C and C.arm and C.arm:IsValid()) then return end
    local arm = C.arm
    local set = CurrentSet(holstered)
    local o = set.offset

    pcall(function() arm.WalkCameraArmLength = set.arm end)
    WriteVec(arm, "WalkCameraOffset", o.x, o.y, o.z)
    pcall(function() arm.HipShootCameraArmLength = set.arm end)
    WriteVec(arm, "HipShootCameraOffset", o.x, o.y, o.z)
    pcall(function() arm.AirCameraArmLength = set.arm end)
    WriteVec(arm, "AirCameraOffset", o.x, o.y, o.z)
    pcall(function() arm.AirHipShootCameraArmLength = set.arm end)
    WriteVec(arm, "AirHipShootCameraOffset", o.x, o.y, o.z)

    dbg("bank -> %s (arm=%d offset=(%d,%d,%d)) [walk/hipshoot/air]",
        holstered and "HOLSTERED" or "DRAWN", set.arm, o.x, o.y, o.z)
end

-- ---- output glide --------------------------------------------------------

local function StartGlide()
    glide.active, glide.t, glide.lastWrote = true, 0, nil
end

local function TickGlide(dt, holstered)
    if not glide.active then return end
    if not (C and C.arm and C.arm:IsValid()) then glide.active = false; return end
    local arm = C.arm
    glide.t = glide.t + dt

    local nowA, nx, ny, nz
    local okR = pcall(function()
        nowA = arm.TargetArmLength
        local s = arm.SocketOffset
        nx, ny, nz = s.X, s.Y, s.Z
    end)
    if not okR then glide.active = false; return end

    -- Abort if something else (the game's state interp) moved the output.
    if glide.lastWrote then
        local d = math.max(math.abs(nowA - glide.lastWrote.a),
                           math.abs(nx - glide.lastWrote.x),
                           math.abs(ny - glide.lastWrote.y),
                           math.abs(nz - glide.lastWrote.z))
        if d > CFG.GLIDE_ABORT then
            glide.active = false
            dbg("glide yielded (game interp took over)")
            return
        end
    end

    local set = CurrentSet(holstered)
    local o = set.offset
    local a2 = U.ExpApproach(nowA, set.arm, CFG.GLIDE_RATE, dt)
    local x2 = U.ExpApproach(nx, o.x, CFG.GLIDE_RATE, dt)
    local y2 = U.ExpApproach(ny, o.y, CFG.GLIDE_RATE, dt)
    local z2 = U.ExpApproach(nz, o.z, CFG.GLIDE_RATE, dt)

    pcall(function() arm.TargetArmLength = a2 end)
    WriteVec(arm, "SocketOffset", x2, y2, z2)
    glide.lastWrote = { a = a2, x = x2, y = y2, z = z2 }

    local close = math.max(math.abs(a2 - set.arm), math.abs(x2 - o.x),
                           math.abs(y2 - o.y),     math.abs(z2 - o.z))
    if close < CFG.GLIDE_DONE or glide.t > CFG.GLIDE_TIMEOUT then
        glide.active = false
        dbg("glide complete (arm=%.0f)", a2)
    end
end

-- ---- lag + extras --------------------------------------------------------

local function ApplyLag()
    if not (C and C.arm and C.arm:IsValid()) then return end
    local arm = C.arm
    local L = CFG.LAG
    pcall(function() arm.bEnableCameraLag            = L.enable end)
    pcall(function() arm.CameraLagSpeed              = L.speed end)
    pcall(function() arm.CameraLagMaxDistance        = L.maxDist end)
    pcall(function() arm.bDefaultEnableCameraLag     = L.enable end)
    pcall(function() arm.DefaultCameraLagSpeed       = L.speed end)
    pcall(function() arm.DefaultCameraLagMaxDistance = L.maxDist end)
    pcall(function() arm.bEnableCameraRotationLag    = L.rotation end)
    pcall(function() arm.CameraRotationLagSpeed      = L.rotSpeed end)
end

local function ApplyExtras()
    if not (C and C.cam and C.cam:IsValid()) then return end
    pcall(function() C.cam.bIsEnableSpeedBlur = CFG.SPEED_BLUR end)
end

-- ---- subsystem interface -------------------------------------------------

function M.OnCached(ctx)
    C = ctx
    vecPath, lastHolstered, lagTimer = nil, nil, 0
    glide = { active = false, t = 0, lastWrote = nil }
    ApplyLag()
    ApplyExtras()
    dbg("lag: enable=%s speed=%.0f maxDist=%.0f rotation=%s | speedBlur=%s",
        tostring(CFG.LAG.enable), CFG.LAG.speed, CFG.LAG.maxDist,
        tostring(CFG.LAG.rotation), tostring(CFG.SPEED_BLUR))
end

function M.OnTick(dt, ctx, sig)
    if sig.holstered ~= lastHolstered then
        lastHolstered = sig.holstered
        ApplyBank(sig.holstered)
        StartGlide()                -- transitions apply mid-state, immediately
    end

    TickGlide(dt, sig.holstered)

    lagTimer = lagTimer + dt
    if lagTimer >= 1.0 then
        lagTimer = 0
        ApplyLag()
    end
end

return M
