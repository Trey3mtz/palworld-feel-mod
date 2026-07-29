-- =========================================================================
-- TheCameraIsAPal subsystem: probe — passive camera / signal recon (DEV)
--
-- Pass 1 (2026-07-21) confirmed:
--   arm = PalShooterSpringArmComponent  (pawn.CameraBoom)
--   cam = PalCharacterCameraComponent   (pawn.FollowCamera)
--   vanilla: arm 400, SocketOffset (0,0,0), FOV 70, lag disabled
--   camera manager: BP_PalPlayerCameraManager_C with the standard modifier
--   stack (CameraAnimationCameraModifier, CameraModifier_CameraShake)
--
-- PASSIVE ONLY. The old WRITE_TEST timeline is gone: it was permanently
-- dormant, its own header said never to enable it, and the rig's contention
-- tracking supersedes it entirely. Nothing in this file writes.
--
-- Off by default (config.enabled.probe). Turn it on when you need the [E]
-- transition log or a fresh vanilla dump, then turn it back off — the
-- transition lines are chatty enough to matter on the hot path.
-- =========================================================================

local Log = require("log")

local M = { name = "probe" }

local dbg = Log.Make("probe", "signals")

-- ==== configuration ======================================================

local CFG = nil

-- ==== state ==============================================================

local C = nil
local lastHolstered, lastSprint, lastMode, lastLooking = nil, nil, nil, nil

-- ==== read helpers =======================================================

local function ReadOpt(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function VecStr(v)
    if v == nil then return "<nil>" end
    local ok, s = pcall(function()
        return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    end)
    return ok and s or "<unreadable>"
end

local function ForEachUObjArray(arr, fn)
    local ok = pcall(function()
        arr:ForEach(function(_, el)
            local okE, obj = pcall(function() return el:get() end)
            if okE and obj then fn(obj) end
        end)
    end)
    if ok then return end
    pcall(function()
        for i = 1, #arr do
            local obj = arr[i]
            if obj then fn(obj) end
        end
    end)
end

-- ==== dumps ==============================================================

local ARM_PROPS = {
    "TargetArmLength", "SocketOffset", "TargetOffset",
    "bEnableCameraLag", "CameraLagSpeed", "CameraLagMaxDistance",
    "bEnableCameraRotationLag", "CameraRotationLagSpeed",
    "bUsePawnControlRotation", "bDoCollisionTest", "ProbeSize",
}
local CAM_PROPS = { "FieldOfView", "bConstrainAspectRatio", "PostProcessBlendWeight" }

local function DumpVanilla(out)
    out("---- vanilla camera values ----")
    if C.arm then
        for _, p in ipairs(ARM_PROPS) do
            local v = ReadOpt(C.arm, p)
            if type(v) == "userdata" then v = VecStr(v) end
            out("  arm.%-26s = %s", p, tostring(v))
        end
    else
        out("  no spring arm ref -- check main.lua discovery output")
    end
    if C.cam then
        for _, p in ipairs(CAM_PROPS) do
            out("  cam.%-26s = %s", p, tostring(ReadOpt(C.cam, p)))
        end
    else
        out("  no camera component ref -- check main.lua discovery output")
    end
end

local function DumpCameraManager(out)
    out("---- camera manager ----")
    local mgr = ReadOpt(C.pc, "PlayerCameraManager")
    if not mgr then out("  PlayerCameraManager not readable"); return end
    out("  class      : %s", mgr:GetFullName())
    out("  DefaultFOV : %s", tostring(ReadOpt(mgr, "DefaultFOV")))
    out("  Pitch range: %s .. %s",
        tostring(ReadOpt(mgr, "ViewPitchMin")), tostring(ReadOpt(mgr, "ViewPitchMax")))
    local mods = ReadOpt(mgr, "ModifierList")
    if mods then
        local n = 0
        ForEachUObjArray(mods, function(m)
            n = n + 1
            local okN, full = pcall(function() return m:GetFullName() end)
            out("  modifier[%d]: %s", n, okN and full or "<unnamed>")
        end)
        if n == 0 then out("  ModifierList: empty") end
    else
        out("  ModifierList: not readable")
    end
end

-- ==== subsystem interface ================================================

function M.RefreshConfig(c)
    if c == nil then return end
    CFG = c
end

function M.OnCached(ctx)
    C = ctx
    lastHolstered, lastSprint, lastMode, lastLooking = nil, nil, nil, nil
    if CFG and CFG.dumpOnCache then
        DumpVanilla(dbg)
        DumpCameraManager(dbg)
    end
end

function M.OnTick(dt, ctx, sig)
    if CFG == nil or not CFG.logSignals then return end
    -- The gate above plus log.channels.signals means this costs two table
    -- lookups when muted, and never reaches string.format.
    if sig.holstered ~= lastHolstered then
        lastHolstered = sig.holstered
        dbg("[E] holstered -> %s", tostring(sig.holstered))
    end
    if sig.sprinting ~= lastSprint then
        lastSprint = sig.sprinting
        dbg("[E] sprinting -> %s (speed2d %.0f)", tostring(sig.sprinting), sig.speed2d)
    end
    if sig.mode ~= lastMode then
        lastMode = sig.mode
        dbg("[E] MovementMode -> %d (Vz %.0f)", sig.mode, sig.vz)
    end
    if sig.userLooking ~= lastLooking then
        lastLooking = sig.userLooking
        dbg("[E] userLooking -> %s (mag %.3f)", tostring(sig.userLooking), sig.camInput)
    end
end

function M.DumpState(out)
    out("-- probe (live camera values) --")
    if C then
        DumpVanilla(out)
        DumpCameraManager(out)
    else
        out("  not cached yet")
    end
end

return M
