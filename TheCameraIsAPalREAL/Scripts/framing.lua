-- =========================================================================
-- TheCameraIsAPal subsystem: framing — holster-driven camera framing
--
-- Replaces statecam.lua + holsterframe.lua, which between them wrote the
-- same two properties from two places (holsterframe was orphaned and never
-- even reached main.lua's Subsystems list).
--
-- THE ONE RULE THIS FILE OBEYS: it does not touch TargetArmLength or
-- SocketOffset. statecam did, in TickGlide, in the same tick the rig wrote
-- them — the rig then read statecam's write as an external stomp, adopted
-- it as its base, and re-applied its own scale on top. That is a two-writer
-- feedback loop entirely of our own making, and it jittered before the game
-- was involved at all. Framing now states a target and lets the rig write.
--
-- Three findings shape the design:
--   (1) The game uses the Walk fields for grounded locomotion regardless of
--       holster state, so framing has to be holster-driven by us.
--   (2) The bank does not take effect instantly, so each transition sends
--       BOTH: the destination to Channel A (the bank, for the game's own
--       interpolation) and an eased glide to Channel C (for the immediate
--       move). The glide is duration-based rather than an exponential
--       chase, which is what lets it use a real easing curve from
--       easingfunctions.lua.
--   (3) THE GAME NEVER STOPS OWNING THE OUTPUTS. The xray dump settled this:
--         CameraInterpTime                 = 0.5
--         LengthInterpCurve/OffsetInterpCurve -> CV_CameraInterpCurve
--         OriginalTargetArmLength          = 330   (a stored restore target)
--         SafetyNetArmLengthInterpSpeed    = 12
--         SafetyNetSocketOffsetInterpSpeed = 10
--         SafetyNetFoVInterpSpeed          = 12
--       There is a "safety net" whose job is to drag TargetArmLength,
--       SocketOffset and FOV back where the game wants them. Holding
--       Channel C against it produces a ~1 Hz limit cycle -- yield, settle,
--       resume, get dragged back -- which the player feels as the camera
--       snapping back about once a second. So once the glide finishes this
--       file RELEASES Channel C and holds the shot through the bank alone.
--       config.framing.holdOnChannelC = true restores the old behaviour for
--       A/B testing.
--
-- Holster truth: sig.holstered (see holsterlink.lua).
-- =========================================================================

local Rig  = require("rig")
local Ease = require("easingfunctions")
local Log  = require("log")

local M = { name = "framing" }

local dbg = Log.Make("framing", "framing")

-- ==== configuration ======================================================

local CFG = nil

-- ==== state ==============================================================

local C             = nil
local lastHolstered = nil
local lagTimer      = 0
local released      = false

-- Eased glide between framing sets.
local glide = {
    t = 1.0,                       -- normalized progress, 1 = settled
    fromArm = 0, fromX = 0, fromY = 0, fromZ = 0,
}

-- Reusable request payloads. Hoisted so the tick path allocates nothing.
local fOffset = { x = 0, y = 0, z = 0 }
local bOffset = { x = 0, y = 0, z = 0 }
local bank    = { arm = 0, offset = bOffset }
local request = { arm = 0, offset = fOffset, bank = bank, applyNow = true }

-- ==== helpers ============================================================

local function ValidArm() return C and C.arm and C.arm:IsValid() end

local function TargetSet(holstered)
    return holstered and CFG.holstered or CFG.drawn
end

local function EaseFn()
    local name = CFG.glide and CFG.glide.easing
    local fn = name and Ease[name]
    if fn then return fn end
    if name then
        dbg("unknown easing '%s'; using EaseOutCubic", tostring(name))
    end
    return Ease.EaseOutCubic
end

-- ==== glide ==============================================================

--- Begin an eased move from wherever the camera currently is to the new set.
--- Reading the live values once here is the only read this file performs.
local function StartGlide()
    glide.t = 0.0
    glide.fromArm, glide.fromX, glide.fromY, glide.fromZ = nil, 0, 0, 0

    if ValidArm() then
        pcall(function() glide.fromArm = C.arm.TargetArmLength end)
        pcall(function()
            local s = C.arm.SocketOffset
            glide.fromX, glide.fromY, glide.fromZ = s.X, s.Y, s.Z
        end)
    end

    if glide.fromArm == nil then
        -- Nothing to glide from; land on the target immediately.
        glide.t = 1.0
    end
end

-- ==== camera lag =========================================================
-- Live values plus the Default* mirrors, because the game restores from the
-- mirrors on some state changes. Re-asserted on a timer for the same reason.

local function ApplyLag()
    if not ValidArm() then return end
    local arm, L = C.arm, CFG.lag
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
    if C and C.cam and C.cam:IsValid() then
        pcall(function() C.cam.bIsEnableSpeedBlur = CFG.speedBlur end)
    end
end

-- ==== subsystem interface ================================================

function M.RefreshConfig(c)
    if c == nil then return end
    CFG = c
    Rig.SetBankConfig(CFG)
    -- Re-apply latched, non-per-frame state and re-glide to the new framing.
    ApplyLag()
    ApplyExtras()
    if lastHolstered ~= nil then StartGlide() end
    dbg("config refreshed: holstered.arm=%.0f drawn.arm=%.0f lag=%s/%0.f",
        CFG.holstered.arm, CFG.drawn.arm, tostring(CFG.lag.enable), CFG.lag.speed)
end

function M.OnCached(ctx)
    C = ctx
    lastHolstered, lagTimer, released = nil, 0, false
    glide.t = 1.0
    Rig.SetBankConfig(CFG)
    ApplyLag()
    ApplyExtras()
    dbg("cached. lag: enable=%s speed=%.0f maxDist=%.0f rotation=%s | speedBlur=%s",
        tostring(CFG.lag.enable), CFG.lag.speed, CFG.lag.maxDist,
        tostring(CFG.lag.rotation), tostring(CFG.speedBlur))
end

--- Called when the subsystem is switched off (F11 or config.enabled).
--- Stops requesting framing; the rig restores the vanilla bank.
function M.Release()
    released      = true
    lastHolstered = nil
    glide.t       = 1.0
end

function M.OnTick(dt, ctx, sig)
    if released then released = false end   -- re-enabled: resume cleanly
    if CFG == nil then return end

    -- Transition: bank the destination and start the eased glide.
    if sig.holstered ~= lastHolstered then
        lastHolstered = sig.holstered
        StartGlide()
        dbg("-> %s", sig.holstered and "HOLSTERED" or "DRAWN")
    end

    local set = TargetSet(sig.holstered)
    local o   = set.offset

    -- Channel A destination: always the settled target, never the glide value.
    bank.arm  = set.arm
    bOffset.x, bOffset.y, bOffset.z = o.x, o.y, o.z

    -- Channel C value: the eased position along the glide.
    --
    -- Once the glide settles we STOP asking for Channel C (unless
    -- holdOnChannelC is set). Holding it is what caused the once-a-second
    -- snap: the game's SafetyNet*InterpSpeed machinery drags those outputs
    -- back toward OriginalTargetArmLength every frame, the rig correctly
    -- yields, the value goes quiet, the rig resumes, and round it goes. The
    -- bank we wrote through Channel A already aims the game's own
    -- interpolation at these values, so letting go costs nothing and the
    -- shot holds itself.
    if glide.t < 1.0 then
        local dur = (CFG.glide and CFG.glide.duration) or 0.45
        glide.t = (dur > 0) and math.min(1.0, glide.t + dt / dur) or 1.0
        local e = EaseFn()
        request.arm = e(glide.fromArm, set.arm, glide.t)
        fOffset.x   = e(glide.fromX, o.x, glide.t)
        fOffset.y   = e(glide.fromY, o.y, glide.t)
        fOffset.z   = e(glide.fromZ, o.z, glide.t)
        request.applyNow = true
        if glide.t >= 1.0 then
            dbg("glide settled (arm=%.0f) — releasing channel C to the game",
                set.arm)
        end
    else
        request.arm = set.arm
        fOffset.x, fOffset.y, fOffset.z = o.x, o.y, o.z
        request.applyNow = CFG.holdOnChannelC and true or false
    end

    Rig.Framing(request)

    -- Optional lag re-assert, OFF by default (reassertHz = 0). The game runs
    -- SafetyNetCameraLagSpeedInterpSpeed = 12, so it pulls CameraLagSpeed
    -- back within a few frames of any write. Re-asserting on a timer just
    -- builds a sawtooth on the lag speed at exactly the re-assert rate,
    -- which the player feels as a periodic lurch.
    if CFG.lag.reassertHz and CFG.lag.reassertHz > 0 then
        lagTimer = lagTimer + dt
        if lagTimer >= 1.0 / CFG.lag.reassertHz then
            lagTimer = 0
            ApplyLag()
        end
    end
end

function M.DumpState(out)
    out("-- framing --")
    out("  holstered   : %s", tostring(lastHolstered))
    out("  glide       : t=%.2f (%s)", glide.t,
        glide.t >= 1.0 and "settled" or "in progress")
    out("  channel C   : %s", request.applyNow and "held (holdOnChannelC)"
        or "released to the game")
    out("  target      : arm=%.0f offset=(%.0f, %.0f, %.0f)",
        request.arm, fOffset.x, fOffset.y, fOffset.z)
    out("  bank fields : %s", CFG and table.concat(CFG.bank, ", ") or "?")
end

return M
