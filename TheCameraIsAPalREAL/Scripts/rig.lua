-- =========================================================================
-- TheCameraIsAPal: rig — the ONLY module that writes camera properties
--
-- v3. v2 lost because it competed for the game's OUTPUT properties every
-- frame. The game recomputes TargetArmLength / SocketOffset / FieldOfView
-- from its own parameters, so whoever writes last before camera evaluation
-- wins — and that ordering is not stable frame to frame. The value then
-- alternates between ours and theirs. That alternation IS the jitter.
--
-- v3 splits writes across three channels by what the game does with them:
--
--   A  SOURCE PARAMS   the per-state bank on PalShooterSpringArmComponent
--                      (WalkCameraArmLength, WalkCameraOffset, AirCamera*,
--                      HipShootCamera*, ...). We write the INPUT the game
--                      interpolates FROM, so the game stays the only writer
--                      of the outputs and there is nothing to alternate
--                      with. Uncontested — but LATCHED: the game re-reads
--                      the bank only on a locomotion-state transition.
--
--   B  SHAKE PIPELINE  PlayerCameraManager:StartCameraShake. Applied inside
--                      ApplyCameraModifiers during camera evaluation, so it
--                      is structurally last. Uncontested — but it can only
--                      carry one-shot impulses with the game's own shake
--                      class, not an arbitrary per-frame curve.
--
--   C  OUTPUT WRITE    TargetArmLength / SocketOffset / FieldOfView.
--                      Immediate and can carry any curve, but contested
--                      during state interp / slide / glide.
--
-- THE CONTENTION POLICY IS THE FIX. v2 detected the game's write and then
-- kept writing anyway — adopting the game's value as its new base and
-- re-applying its own offset on top of it. That is precisely how you build a
-- per-frame oscillator, and measurement confirmed it: under a contested
-- SocketOffset, v2 overwrote the game on 60 of 60 frames, with the composed
-- value swinging +6.5uu to -7.0uu across eight frames.
--
-- v3 hands the channel back instead. On detecting the game's write it stops
-- writing, then WATCHES the property: while the value keeps moving on its
-- own the game is still interpolating, so we stay out; once it has held
-- still for cfg.contention.quietFrames the game is done and we take over
-- again. A fixed frame countdown cannot make that distinction — it has to
-- guess, and every wrong guess is a write the game instantly reverts, which
-- is a visible pop (measured at ~40uu before this was added).
--
-- Handover in both directions is blended through `authority` (0..1), so
-- neither standing down nor coming back is a snap. Channel A has already
-- pointed the game's own interpolation at our values, so what it produces
-- while we are silent is close to what we wanted anyway.
--
-- Per tick main.lua calls:
--   Rig.Begin()            reset accumulators (allocates nothing)
--   <subsystems run>       Rig.Framing / Rig.Add / Rig.Impulse
--   Rig.Finish(dt, ctx)    compose, route, write at most once per channel
--
-- Subsystem API:
--   Rig.Framing{ arm=<uu>, offset={x,y,z}, bank={arm=,offset=} }
--       Absolute, already-shaped framing target. The caller owns its own
--       easing (see framing.lua); the rig does NOT smooth this again.
--       `bank` is the DESTINATION value for Channel A, written only when it
--       changes. Last caller in a frame wins — framing is exclusive.
--   Rig.Add{ armScale=, fovAdd=, sock={x,y,z}, jitter={x,y,z} }
--       Additive modifiers composed across all callers. armScale by
--       product, the rest by sum. sock is smoothed, jitter is not.
--   Rig.Impulse(scale)
--       One-shot rotational shake through Channel B.
-- =========================================================================

local U   = require("camutil")
local Log = require("log")

local M = {}

local dbg  = Log.Make("rig", "rig")
local warn = Log.MakeAlways("rig")

-- ==== configuration (hot-swappable) ======================================

local CFG = nil

-- ==== state & caches =====================================================

local C = nil          -- ctx from main.lua

-- Channel C bases: track the game's own values while we are silent.
local baseArm, baseFov = nil, nil
local baseSockX, baseSockY, baseSockZ = 0, 0, 0

-- Channel C smoothed additive state (offset space; survives external writes).
local sScale, vScale = 1.0, 0.0
local sFov,   vFov   = 0.0, 0.0
local sSockX, sSockY, sSockZ = 0, 0, 0

-- Channel C write tracking / contention.
local lastArm, lastFov = nil, nil
local lastSockX, lastSockY, lastSockZ = nil, nil, nil
local haveLastSock = false
local yielding     = false  -- the game currently owns the channel
local quietFrames  = 0      -- consecutive frames the game left it alone
local authority    = 1.0    -- 0..1 blend of our whole contribution

-- Values observed last frame, used to tell whether the GAME is still driving
-- the channel while we are silent. A frame counter cannot tell that; this
-- can, which is what lets us resume at the right moment instead of probing.
local obsArm, obsSockX, obsSockY, obsSockZ = nil, nil, nil, nil

-- Channel A latch: last banked values, so we only write the bank on change.
local bankArm, bankX, bankY, bankZ = nil, nil, nil, nil
local vanillaBank = nil     -- captured once, restored by Release()

-- Channel B shake class resolution.
local shakeResolved, shakeClass, shakeWarned = false, nil, false
local SHAKE_CANDIDATES = {
    "DamageCameraShake", "PlayerDamageCameraShake", "DamageCamShake", "CameraShake",
}

-- UE4SS FVector write path differs by build: assign fields, or replace the
-- struct. Probed once, then cached.
local vecPath = nil

-- Telemetry.
local stats = { t = 0, arm = { w = 0, s = 0 }, fov = { w = 0, s = 0 },
                sock = { w = 0, s = 0 }, yields = 0, impulses = 0 }

-- Per-frame request accumulator. HOISTED — Begin() resets these fields in
-- place rather than rebuilding them, where v2 built three fresh tables here
-- every frame.
local req = {
    framing = false, fArm = 0, fX = 0, fY = 0, fZ = 0,
    hasBank = false, bArm = 0, bX = 0, bY = 0, bZ = 0,
    armScale = 1.0, fovAdd = 0.0,
    sockX = 0, sockY = 0, sockZ = 0,
    jitterX = 0, jitterY = 0, jitterZ = 0,
    impulse = 0,
}
local open = false      -- true between Begin() and Finish()

-- ==== utilities ==========================================================

local function ValidArm() return C and C.arm and C.arm:IsValid() end
local function ValidCam() return C and C.cam and C.cam:IsValid() end

--- Write an FVector-valued property, probing the working path on first use.
local function WriteVec(owner, prop, x, y, z)
    if vecPath == "struct" then
        return pcall(function() owner[prop] = { X = x, Y = y, Z = z } end)
    end

    local ok = pcall(function()
        local v = owner[prop]
        v.X = x; v.Y = y; v.Z = z
    end)

    if vecPath == "field" then return ok end

    -- Unprobed: verify the field write actually landed before trusting it.
    if ok then
        local good = false
        pcall(function()
            local v = owner[prop]
            good = math.abs(v.X - x) < 0.01
               and math.abs(v.Y - y) < 0.01
               and math.abs(v.Z - z) < 0.01
        end)
        if good then
            vecPath = "field"
            dbg("FVector write path: field")
            return true
        end
    end

    local ok2 = pcall(function() owner[prop] = { X = x, Y = y, Z = z } end)
    if ok2 then
        vecPath = "struct"
        dbg("FVector write path: struct")
    else
        warn("no FVector write path works — framing offsets are disabled")
    end
    return ok2
end

local function ReadVec(owner, prop)
    local x, y, z
    local ok = pcall(function()
        local v = owner[prop]
        x, y, z = v.X, v.Y, v.Z
    end)
    if ok and x then return x, y, z end
    return nil
end

local function RouteHas(kind, letter)
    local route = CFG and CFG.channels and CFG.channels[kind]
    if route == nil then return false end
    return route:find(letter, 1, true) ~= nil
end

-- ==== subsystem-facing request API =======================================

function M.Begin()
    req.framing  = false
    req.hasBank  = false
    req.armScale = 1.0
    req.fovAdd   = 0.0
    req.sockX, req.sockY, req.sockZ    = 0, 0, 0
    req.jitterX, req.jitterY, req.jitterZ = 0, 0, 0
    req.impulse  = 0
    open = true
end

--- Absolute framing target. Already eased by the caller; not re-smoothed.
function M.Framing(r)
    if not open then return end
    req.framing = true
    req.fArm = r.arm or 0
    local o = r.offset
    if o then req.fX, req.fY, req.fZ = o.x or 0, o.y or 0, o.z or 0
    else      req.fX, req.fY, req.fZ = 0, 0, 0 end

    local b = r.bank
    if b then
        req.hasBank = true
        req.bArm = b.arm or req.fArm
        local bo = b.offset
        if bo then req.bX, req.bY, req.bZ = bo.x or 0, bo.y or 0, bo.z or 0
        else       req.bX, req.bY, req.bZ = req.fX, req.fY, req.fZ end
    end
end

--- Additive modifiers. Composed across every caller in the frame.
function M.Add(r)
    if not open then return end
    if r.armScale then req.armScale = req.armScale * r.armScale end
    if r.fovAdd   then req.fovAdd   = req.fovAdd + r.fovAdd end
    local s = r.sock
    if s then
        req.sockX = req.sockX + (s.x or 0)
        req.sockY = req.sockY + (s.y or 0)
        req.sockZ = req.sockZ + (s.z or 0)
    end
    local j = r.jitter
    if j then
        req.jitterX = req.jitterX + (j.x or 0)
        req.jitterY = req.jitterY + (j.y or 0)
        req.jitterZ = req.jitterZ + (j.z or 0)
    end
end

--- One-shot rotational shake. Largest request in the frame wins.
function M.Impulse(scale)
    if not open then
        -- Out-of-band call (e.g. from a hook): fire immediately.
        M.FireImpulse(scale)
        return
    end
    if scale > req.impulse then req.impulse = scale end
end

-- ==== channel A: source parameters (the state bank) ======================
-- Contention-free by construction: we write what the game interpolates from.
-- Latched — the game re-reads these on locomotion-state transitions only,
-- which is why Channel C still carries the immediate response.

local function BankFieldNames(prefix)
    return prefix .. "CameraArmLength", prefix .. "CameraOffset"
end

local function CaptureVanillaBank()
    if vanillaBank ~= nil or not ValidArm() then return end
    local arm = C.arm
    local snap = {}
    for _, prefix in ipairs(CFG.bankPrefixes or {}) do
        local lenName, offName = BankFieldNames(prefix)
        local entry = {}
        pcall(function() entry.len = arm[lenName] end)
        local x, y, z = ReadVec(arm, offName)
        if x then entry.x, entry.y, entry.z = x, y, z end
        if entry.len or entry.x then snap[prefix] = entry end
    end
    vanillaBank = snap
end

local function WriteBank(armLen, x, y, z)
    if not ValidArm() then return end
    -- Latch: the bank is state, not a per-frame value. Writing it every
    -- frame is pure waste and floods the log on transitions.
    if bankArm == armLen and bankX == x and bankY == y and bankZ == z then return end
    bankArm, bankX, bankY, bankZ = armLen, x, y, z

    local arm = C.arm
    local written = 0
    for _, prefix in ipairs(CFG.bankPrefixes or {}) do
        local lenName, offName = BankFieldNames(prefix)
        if pcall(function() arm[lenName] = armLen end) then written = written + 1 end
        WriteVec(arm, offName, x, y, z)
    end
    dbg("channel A bank -> arm=%.0f offset=(%.0f, %.0f, %.0f) [%d fields]",
        armLen, x, y, z, written)
end

local function RestoreBank()
    if vanillaBank == nil or not ValidArm() then return end
    local arm = C.arm
    for prefix, entry in pairs(vanillaBank) do
        local lenName, offName = BankFieldNames(prefix)
        if entry.len then pcall(function() arm[lenName] = entry.len end) end
        if entry.x then WriteVec(arm, offName, entry.x, entry.y, entry.z) end
    end
    bankArm, bankX, bankY, bankZ = nil, nil, nil, nil
    dbg("channel A bank restored to vanilla")
end

-- ==== channel B: the shake pipeline ======================================
-- Applied inside camera evaluation, after the game computes its POV, so it
-- cannot be contested by anything we do elsewhere. Absorbed from the old
-- camimpulse.lua.

local function ResolveShake()
    shakeResolved = true
    shakeClass = nil
    if not (C and C.pc and C.pc:IsValid()) then return end
    for _, name in ipairs(SHAKE_CANDIDATES) do
        local ok, v = pcall(function() return C.pc[name] end)
        if ok and v ~= nil then
            shakeClass = v
            dbg("channel B shake class resolved via pc.%s", name)
            return
        end
    end
    warn("channel B unavailable: no camera shake class on the controller "
      .. "(rotational impulses disabled; positional effects unaffected)")
end

--- Play a one-shot shake. `scale` ~0.1 subtle footfall, ~1.0 hard landing.
function M.FireImpulse(scale)
    if scale == nil or scale <= 0 then return false end
    if not shakeResolved then ResolveShake() end
    if shakeClass == nil then return false end

    local mgr = nil
    pcall(function() mgr = C.pc.PlayerCameraManager end)
    if not (mgr and mgr:IsValid()) then return false end

    local ok = pcall(function()
        -- ECameraShakePlaySpace::CameraLocal = 0
        mgr:StartCameraShake(shakeClass, scale, 0, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok then
        if not shakeWarned then
            shakeWarned = true
            dbg("StartCameraShake failed; re-resolving on next use")
        end
        shakeResolved = false      -- stale class after a level change
        return false
    end
    stats.impulses = stats.impulses + 1
    return true
end

-- ==== channel C: output writes, with the yield policy ====================

--- Sample the live outputs, classify last frame's write, and decide whether
--- the game currently owns the channel. Returns false if the properties are
--- unreadable.
---
--- Two distinct questions are answered here:
---   * did the game overwrite OUR value?  (we wrote last frame)
---   * is the game still moving the value ON ITS OWN?  (we were silent)
--- The second is what tells us when it is safe to come back. A fixed frame
--- countdown cannot know that, so it has to guess — and every wrong guess is
--- a write the game immediately reverts, i.e. a visible pop.
local function ClassifyAndTrack()
    local arm, cam = C.arm, C.cam
    local okA, nowArm = pcall(function() return arm.TargetArmLength end)
    local okF, nowFov = pcall(function() return cam.FieldOfView end)
    local nx, ny, nz = ReadVec(arm, "SocketOffset")
    if not (okA and okF and nx) then return false end

    local eps = CFG.contention
    local wroteLastFrame = (lastArm ~= nil) or haveLastSock

    -- While silent: is the game still driving the channel by itself?
    -- This uses `quietEps`, NOT the write-survival epsilons. The two answer
    -- different questions and need very different magnitudes: eps* asks "is
    -- this the value we wrote" (tolerant, ~0.5uu), quietEps asks "has this
    -- stopped moving at all" (strict). Reusing eps* here reads a slow
    -- interpolation as stationary and walks us straight back into the fight.
    if not wroteLastFrame and obsArm ~= nil then
        local q = eps.quietEps
        local moved = math.abs(nowArm - obsArm) > q
                   or math.abs(nx - obsSockX)   > q
                   or math.abs(ny - obsSockY)   > q
                   or math.abs(nz - obsSockZ)   > q
        if moved then
            quietFrames = 0
        else
            quietFrames = quietFrames + 1
            if yielding and quietFrames >= eps.quietFrames then
                yielding = false
                dbg("channel C quiet for %d frames — resuming", quietFrames)
            end
        end
    end
    obsArm, obsSockX, obsSockY, obsSockZ = nowArm, nx, ny, nz

    local stomped = false

    if lastArm then
        if math.abs(nowArm - lastArm) <= CFG.contention.epsArm then
            stats.arm.w = stats.arm.w + 1
        else
            stats.arm.s = stats.arm.s + 1
            baseArm = nowArm
            stomped = true
        end
    else
        baseArm = nowArm
    end

    if lastFov then
        if math.abs(nowFov - lastFov) <= CFG.contention.epsFov then
            stats.fov.w = stats.fov.w + 1
        else
            stats.fov.s = stats.fov.s + 1
            baseFov = nowFov
            stomped = true
        end
    else
        baseFov = nowFov
    end

    if haveLastSock then
        local d = math.max(math.abs(nx - lastSockX),
                           math.abs(ny - lastSockY),
                           math.abs(nz - lastSockZ))
        if d <= CFG.contention.epsSock then
            stats.sock.w = stats.sock.w + 1
        else
            stats.sock.s = stats.sock.s + 1
            baseSockX, baseSockY, baseSockZ = nx, ny, nz
            stomped = true
        end
    else
        baseSockX, baseSockY, baseSockZ = nx, ny, nz
    end

    if stomped then
        -- Do NOT re-apply on top of the game's value — that is the
        -- oscillator v2 built. Stand down and let its interpolation finish.
        if not yielding then stats.yields = stats.yields + 1 end
        yielding    = true
        quietFrames = 0
        lastArm, lastFov, haveLastSock = nil, nil, false
    end
    return true
end

local function ClearWriteTracking()
    lastArm, lastFov, haveLastSock = nil, nil, false
end

-- ==== lifecycle ==========================================================

function M.RefreshConfig(c)
    if c == nil then return end
    CFG = c
    -- Cache the bank prefix list from framing's config (set by main.lua).
    CFG.bankPrefixes = CFG.bankPrefixes or {}
    dbg("config refreshed: framing=%s jitter=%s fov=%s impulse=%s quiet=%d",
        tostring(CFG.channels.framing), tostring(CFG.channels.jitter),
        tostring(CFG.channels.fov),     tostring(CFG.channels.impulse),
        CFG.contention.quietFrames)
end

--- Tell the rig which bank prefixes Channel A may write (from config.framing).
function M.SetBankPrefixes(list)
    if CFG then CFG.bankPrefixes = list or {} end
end

function M.OnCached(ctx)
    C = ctx

    baseArm, baseFov = nil, nil
    baseSockX, baseSockY, baseSockZ = 0, 0, 0
    sScale, vScale, sFov, vFov = 1.0, 0.0, 0.0, 0.0
    sSockX, sSockY, sSockZ = 0, 0, 0
    ClearWriteTracking()
    yielding, quietFrames, authority = false, 0, 1.0
    obsArm, obsSockX, obsSockY, obsSockZ = nil, nil, nil, nil
    bankArm, bankX, bankY, bankZ = nil, nil, nil, nil
    vecPath = nil
    shakeResolved, shakeClass, shakeWarned = false, nil, false
    stats = { t = 0, arm = { w = 0, s = 0 }, fov = { w = 0, s = 0 },
              sock = { w = 0, s = 0 }, yields = 0, impulses = 0 }

    if ValidArm() then
        pcall(function() baseArm = C.arm.TargetArmLength end)
        local x, y, z = ReadVec(C.arm, "SocketOffset")
        if x then baseSockX, baseSockY, baseSockZ = x, y, z end
    end
    if ValidCam() then
        pcall(function() baseFov = C.cam.FieldOfView end)
    end

    -- Snapshot the vanilla bank BEFORE anything writes it, so F11 can restore.
    vanillaBank = nil
    CaptureVanillaBank()

    dbg("bases: arm=%s fov=%s sock=(%.1f, %.1f, %.1f)",
        tostring(baseArm), tostring(baseFov), baseSockX, baseSockY, baseSockZ)
end

--- Go fully neutral: restore the vanilla bank and stop writing. Used by the
--- F11 master toggle and whenever every subsystem is disabled.
function M.Release()
    RestoreBank()
    sScale, vScale, sFov, vFov = 1.0, 0.0, 0.0, 0.0
    sSockX, sSockY, sSockZ = 0, 0, 0
    ClearWriteTracking()
    yielding, quietFrames, authority = false, 0, 1.0
    obsArm, obsSockX, obsSockY, obsSockZ = nil, nil, nil, nil
    open = false
end

-- ==== finish: compose, route, write ======================================

function M.Finish(dt, ctx)
    if not open then return end
    open = false
    C = ctx
    if not (ValidArm() and ValidCam() and CFG) then return end

    -- ---- channel B: one-shots ----
    if req.impulse > 0 and RouteHas("impulse", "B") then
        M.FireImpulse(req.impulse)
    end

    -- ---- channel A: bank the framing destination ----
    if req.framing and req.hasBank and RouteHas("framing", "A") then
        WriteBank(req.bArm, req.bX, req.bY, req.bZ)
    end

    -- ---- channel C ----
    if not ClassifyAndTrack() then return end
    if baseArm == nil or baseFov == nil then return end

    -- Smooth the additive layer even while yielding, so resuming does not snap.
    local sm = CFG.smooth
    sScale, vScale = U.SmoothDamp(sScale, req.armScale, vScale, sm.armTime, dt)
    sFov,   vFov   = U.SmoothDamp(sFov,   req.fovAdd,   vFov,   sm.fovTime, dt)
    sSockX = U.ExpApproach(sSockX, req.sockX, sm.sockRate, dt)
    sSockY = U.ExpApproach(sSockY, req.sockY, sm.sockRate, dt)
    sSockZ = U.ExpApproach(sSockZ, req.sockZ, sm.sockRate, dt)

    -- AUTHORITY: how much of our contribution is currently applied. It rides
    -- to 0 while the game owns the channel and back to 1 when it lets go, so
    -- entering and leaving a contested window is a blend rather than a pop.
    -- Without this, resuming after a yield writes the full accumulated offset
    -- in a single frame — measured at ~40uu, which is exactly the kind of
    -- snap this rewrite exists to eliminate.
    -- Asymmetric on purpose. Letting go must be FAST: every frame we spend
    -- fading out is a frame we write a value the game immediately reverts,
    -- which is contention we chose to have. Coming back is slow, because a
    -- quick re-entry reads as a pop even when it is technically correct.
    local rate = yielding and CFG.contention.releaseRate or CFG.contention.resumeRate
    authority = U.ExpApproach(authority, yielding and 0.0 or 1.0, rate, dt)

    -- Fully yielded: the game owns this channel outright. Write nothing.
    if authority < 0.01 then
        ClearWriteTracking()
        return
    end

    local framingOnC = req.framing and RouteHas("framing", "C")

    -- Neutrality: with nothing to say, write nothing and let the game own
    -- the channel outright.
    local jitterActive = req.jitterX ~= 0 or req.jitterY ~= 0 or req.jitterZ ~= 0
    local n = CFG.neutral
    local active = framingOnC or jitterActive
        or math.abs(sScale - 1.0) > n.scale
        or math.abs(sFov)         > n.fov
        or math.abs(sSockX)       > n.sock
        or math.abs(sSockY)       > n.sock
        or math.abs(sSockZ)       > n.sock

    if not active then
        ClearWriteTracking()
        return
    end

    -- Framing supplies the absolute base when present; otherwise the base
    -- tracks whatever the game last produced. Everything we add on top is
    -- scaled by authority, and framing itself blends from the game's own
    -- value toward ours, so a partial authority is a partial effect rather
    -- than a half-applied jump.
    local a = authority
    local rootArm = framingOnC and (baseArm   + (req.fArm - baseArm)   * a) or baseArm
    local rootX   = framingOnC and (baseSockX + (req.fX   - baseSockX) * a) or baseSockX
    local rootY   = framingOnC and (baseSockY + (req.fY   - baseSockY) * a) or baseSockY
    local rootZ   = framingOnC and (baseSockZ + (req.fZ   - baseSockZ) * a) or baseSockZ

    local outArm = rootArm * (1.0 + (sScale - 1.0) * a)
    local outX   = rootX + (sSockX + req.jitterX) * a
    local outY   = rootY + (sSockY + req.jitterY) * a
    local outZ   = rootZ + (sSockZ + req.jitterZ) * a

    if pcall(function() C.arm.TargetArmLength = outArm end) then
        lastArm = outArm
    end
    if WriteVec(C.arm, "SocketOffset", outX, outY, outZ) then
        lastSockX, lastSockY, lastSockZ = outX, outY, outZ
        haveLastSock = true
    end

    if RouteHas("fov", "C") then
        local outFov = baseFov + sFov * a
        if pcall(function() C.cam.FieldOfView = outFov end) then
            lastFov = outFov
        end
    end

    -- ---- telemetry ----
    if Log.Enabled("rig") then
        stats.t = stats.t + dt
        if stats.t >= 1.0 then
            dbg("arm[w=%d s=%d out=%.0f] fov[w=%d s=%d] sock[w=%d s=%d] "
             .. "auth=%.2f yields=%d",
                stats.arm.w, stats.arm.s, outArm,
                stats.fov.w, stats.fov.s,
                stats.sock.w, stats.sock.s, authority, stats.yields)
            stats.t = 0
            stats.arm.w, stats.arm.s   = 0, 0
            stats.fov.w, stats.fov.s   = 0, 0
            stats.sock.w, stats.sock.s = 0, 0
            stats.yields = 0
        end
    end
end

-- ==== F9 state dump ======================================================

function M.DumpState(out)
    out("-- rig --")
    out("  channels    : framing=%s jitter=%s fov=%s impulse=%s",
        CFG and CFG.channels.framing or "?", CFG and CFG.channels.jitter or "?",
        CFG and CFG.channels.fov or "?",     CFG and CFG.channels.impulse or "?")
    out("  bases       : arm=%s fov=%s sock=(%.1f, %.1f, %.1f)",
        tostring(baseArm), tostring(baseFov), baseSockX, baseSockY, baseSockZ)
    out("  smoothed    : scale=%.3f fovAdd=%.2f sock=(%.1f, %.1f, %.1f)",
        sScale, sFov, sSockX, sSockY, sSockZ)
    out("  channel A   : banked arm=%s offset=(%s, %s, %s)",
        tostring(bankArm), tostring(bankX), tostring(bankY), tostring(bankZ))
    out("  channel B   : shake=%s impulses=%d",
        shakeClass and "resolved" or "UNAVAILABLE", stats.impulses)
    out("  channel C   : %s authority=%.2f quiet=%d vecPath=%s",
        yielding and "YIELDING (game owns it)" or "active",
        authority, quietFrames, tostring(vecPath))
    out("  contention  : arm w=%d s=%d | fov w=%d s=%d | sock w=%d s=%d",
        stats.arm.w, stats.arm.s, stats.fov.w, stats.fov.s,
        stats.sock.w, stats.sock.s)
    if stats.arm.s > stats.arm.w or stats.sock.s > stats.sock.w then
        out("  NOTE: channel C is losing. Framing should ride channel A —"
         .. " run xray to find more bank fields, then extend config.framing.bank")
    end
end

return M
