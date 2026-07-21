-- =========================================================================
-- CineCam subsystem: probe — camera recon (run before building phase B)
--
-- Discovery is handled by main.lua; this subsystem answers the rest:
--   [B] Vanilla values for every property the camera rig will touch.
--   [C] Whether the game REASSERTS those values per frame or writes stick,
--       including which FVector write path works on this UE4SS build
--       (struct field write vs whole-struct table assignment).
--   [D] The camera manager's real class name and modifier stack contents.
--   [E] Live validation of every signal main.lua derives:
--       holster index, bRequestSprint, movement mode, look input.
--
-- Two-pass usage:
--   Pass 1: WRITE_TEST = false. Load in, walk, sprint, jump, holster and
--           draw the weapon. Read the log; confirm [B]/[D]/[E].
--   Pass 2: WRITE_TEST = true. Load in and STAND STILL, camera untouched,
--           for ~10 seconds. Read the [C] VERDICT lines.
-- =========================================================================

local WRITE_TEST      = false
local WRITE_AT        = 3.0     -- s after cache before test writes
local VERDICT_AT      = 9.0     -- s after cache to judge stickiness
local ARM_DELTA       = 150.0   -- TargetArmLength += this
local FOV_DELTA       = 10.0    -- FieldOfView += this
local SAMPLE_INTERVAL = 1.0

local M = { name = "probe" }

local t             = 0
local nextSample    = 0
local wroteTest     = false
local verdictDone   = false
local base          = {}
local written       = {}
local sockWritePath = "none"
local C             = nil       -- ctx captured at OnCached

local lastHolstered, lastSprint, lastMode, lastLooking = nil, nil, nil, nil

local function dbg(fmt, ...)
    print(string.format("[CineCam:probe] " .. fmt .. "\n", ...))
end

local function ReadOpt(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if not ok or v == nil then return nil end
    return v
end

local function Num(obj, prop)
    local v = ReadOpt(obj, prop)
    return (type(v) == "number") and v or nil
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

-- ------------------------- [B] vanilla dump ------------------------------

local ARM_PROPS = {
    "TargetArmLength", "SocketOffset", "TargetOffset",
    "bEnableCameraLag", "CameraLagSpeed", "CameraLagMaxDistance",
    "bEnableCameraRotationLag", "CameraRotationLagSpeed",
    "bUsePawnControlRotation", "bDoCollisionTest", "ProbeSize",
}
local CAM_PROPS = { "FieldOfView", "bConstrainAspectRatio", "PostProcessBlendWeight" }

local function DumpVanilla()
    dbg("---- [B] vanilla camera values ----")
    if C.arm then
        for _, p in ipairs(ARM_PROPS) do
            local v = ReadOpt(C.arm, p)
            if type(v) == "userdata" then v = VecStr(v) end
            dbg("  arm.%-26s = %s", p, tostring(v))
        end
        base.arm = Num(C.arm, "TargetArmLength")
        pcall(function() base.sockY = C.arm.SocketOffset.Y end)
    else
        dbg("  no spring arm ref — check main.lua discovery output")
    end
    if C.cam then
        for _, p in ipairs(CAM_PROPS) do
            dbg("  cam.%-26s = %s", p, tostring(ReadOpt(C.cam, p)))
        end
        base.fov = Num(C.cam, "FieldOfView")
    else
        dbg("  no camera component ref — check main.lua discovery output")
    end
end

-- ------------------------- [D] camera manager ----------------------------

local function DumpCameraManager()
    dbg("---- [D] camera manager ----")
    local mgr = ReadOpt(C.pc, "PlayerCameraManager")
    if not mgr then dbg("  PlayerCameraManager not readable"); return end
    dbg("  class      : %s", mgr:GetFullName())
    dbg("  DefaultFOV : %s", tostring(ReadOpt(mgr, "DefaultFOV")))
    dbg("  Pitch range: %s .. %s",
        tostring(ReadOpt(mgr, "ViewPitchMin")), tostring(ReadOpt(mgr, "ViewPitchMax")))
    local mods = ReadOpt(mgr, "ModifierList")
    if mods then
        local n = 0
        ForEachUObjArray(mods, function(m)
            n = n + 1
            local okN, full = pcall(function() return m:GetFullName() end)
            dbg("  modifier[%d]: %s", n, okN and full or "<unnamed>")
        end)
        if n == 0 then dbg("  ModifierList: empty") end
    else
        dbg("  ModifierList: not readable")
    end
end

-- ------------------------- [C] write test --------------------------------

local function ApplyWriteTest()
    dbg("---- [C] applying test writes (stand still!) ----")
    if C.arm and base.arm then
        written.arm = base.arm + ARM_DELTA
        local ok = pcall(function() C.arm.TargetArmLength = written.arm end)
        dbg("  write arm.TargetArmLength %.1f -> %.1f : %s",
            base.arm, written.arm, ok and "OK" or "FAILED")
    end
    if C.arm and base.sockY ~= nil then
        written.sockY = 0.0
        -- Path 1: field write through the struct proxy.
        local ok1 = pcall(function() C.arm.SocketOffset.Y = 0.0 end)
        local applied1 = false
        pcall(function() applied1 = math.abs(C.arm.SocketOffset.Y) < 0.01 end)
        if ok1 and applied1 then
            sockWritePath = "field"
        else
            -- Path 2: whole-struct table assignment.
            local x, z = 0, 0
            pcall(function()
                local so = C.arm.SocketOffset
                x, z = so.X, so.Z
            end)
            local ok2 = pcall(function()
                C.arm.SocketOffset = { X = x, Y = 0.0, Z = z }
            end)
            local applied2 = false
            pcall(function() applied2 = math.abs(C.arm.SocketOffset.Y) < 0.01 end)
            sockWritePath = (ok2 and applied2) and "struct" or "NONE WORKED"
        end
        dbg("  write arm.SocketOffset.Y %.1f -> 0 : path = %s",
            base.sockY, sockWritePath)
    end
    if C.cam and base.fov then
        written.fov = base.fov + FOV_DELTA
        local ok = pcall(function() C.cam.FieldOfView = written.fov end)
        if not ok then
            ok = pcall(function() C.cam:SetFieldOfView(written.fov) end)
            dbg("  FieldOfView property write failed; SetFieldOfView(): %s",
                ok and "OK" or "FAILED")
        end
        dbg("  write cam.FieldOfView %.1f -> %.1f : %s",
            base.fov, written.fov, ok and "OK" or "FAILED")
    end
end

local function Verdict()
    dbg("---- [C] VERDICT (%.0fs after writes) ----", VERDICT_AT - WRITE_AT)
    local function judge(label, target, currentFn)
        if target == nil then dbg("  %-22s: not tested", label); return end
        local cur = nil
        pcall(function() cur = currentFn() end)
        if cur == nil then dbg("  %-22s: unreadable now", label); return end
        local held = math.abs(cur - target) < 0.5
        dbg("  %-22s: %s  (now %.1f, wrote %.1f)",
            label, held and "HELD — writes stick" or "REASSERTED by game",
            cur, target)
    end
    judge("arm.TargetArmLength", written.arm,
          function() return C.arm.TargetArmLength end)
    judge("arm.SocketOffset.Y",  written.sockY,
          function() return C.arm.SocketOffset.Y end)
    judge("cam.FieldOfView",     written.fov,
          function() return C.cam.FieldOfView end)
    dbg("  FVector write path    : %s", sockWritePath)
end

-- ------------------------- subsystem interface ---------------------------

function M.OnCached(ctx)
    C = ctx
    t, nextSample, wroteTest, verdictDone = 0, 0, false, false
    base, written, sockWritePath = {}, {}, "none"
    lastHolstered, lastSprint, lastMode, lastLooking = nil, nil, nil, nil

    DumpVanilla()
    DumpCameraManager()
    dbg("probe armed. WRITE_TEST = %s", tostring(WRITE_TEST))
end

function M.OnTick(dt, ctx, sig)
    t = t + dt

    -- [E] signal transition logging
    if sig.holstered ~= lastHolstered then
        dbg("[E] holstered -> %s", tostring(sig.holstered))
        lastHolstered = sig.holstered
    end
    if sig.sprinting ~= lastSprint then
        dbg("[E] sprinting -> %s (speed2d %.0f)", tostring(sig.sprinting), sig.speed2d)
        lastSprint = sig.sprinting
    end
    if sig.mode ~= lastMode then
        dbg("[E] MovementMode -> %d (Vz %.0f)", sig.mode, sig.vz)
        lastMode = sig.mode
    end
    if sig.userLooking ~= lastLooking then
        dbg("[E] userLooking -> %s (mag %.3f)", tostring(sig.userLooking), sig.camInput)
        lastLooking = sig.userLooking
    end

    -- [C] write-test timeline
    if WRITE_TEST and not wroteTest and t >= WRITE_AT then
        wroteTest = true
        ApplyWriteTest()
    end
    if WRITE_TEST and wroteTest and not verdictDone and t >= VERDICT_AT then
        verdictDone = true
        Verdict()
    end
    if WRITE_TEST and wroteTest and not verdictDone and t >= nextSample then
        nextSample = t + SAMPLE_INTERVAL
        local a = C.arm and Num(C.arm, "TargetArmLength") or nil
        local f = C.cam and Num(C.cam, "FieldOfView") or nil
        dbg("[C] sample t=%.1f  arm=%s  fov=%s", t,
            a and string.format("%.1f", a) or "?",
            f and string.format("%.1f", f) or "?")
    end
end

return M
