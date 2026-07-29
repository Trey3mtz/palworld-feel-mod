-- =========================================================================
-- TheCameraIsAPal — cinematic third-person camera rework for Palworld
-- UE4SS Lua, Palworld 1.0, offline/single-player.
--
-- Install: Pal\Binaries\Win64\ue4ss\Mods\TheCameraIsAPal\Scripts\
--          then add "TheCameraIsAPal : 1" to ue4ss\Mods\mods.txt
--
-- ------------------------------------------------------------------------
-- DEV KEYS
--   F10   reload config.lua FROM DISK and fan RefreshConfig out to every
--         module. Edit a number, save, press F10, see it — no restart.
--         A syntax error is logged and ignored; the last good config stays.
--   F11   master on/off. Drops every subsystem silent and restores the
--         vanilla state bank, for instant A/B against stock Palworld.
--   F9    dump live state: refs, tick source, per-channel contention counts.
-- ------------------------------------------------------------------------
--
-- ARCHITECTURE
--   config.lua       all tuning data, re-read from disk on F10
--   log.lua          one gated logger for every module
--   ticksource.lua   swappable, measured tick origin
--   rig.lua          THE ONLY MODULE THAT WRITES CAMERA PROPERTIES
--   camutil.lua      pure math (noise, smoothing, remap, bob)
--   easingfunctions  parametric easing curves, used by framing's glide
--   <subsystems>     read signals, request effects through the rig
--
-- main.lua owns: reference caching, respawn re-cache, per-tick signal
-- derivation, rig frame lifecycle, subsystem dispatch, config hot reload,
-- and the dev keys. Subsystems implement:
--
--   M.name                       string tag; MUST match its config sub-table
--   M.OnCached(ctx)              refs were (re)acquired
--   M.OnTick(dt, ctx, sig)       every tick, only while enabled
--   M.RefreshConfig(cfgSubTable) optional; on load and on every F10
--   M.Release()                  optional; subsystem was switched off
--   M.DumpState(out)             optional; F9 report
--
-- Tick order: BuildSignals -> Rig.Begin -> subsystems (request effects via
-- Rig.Framing / Rig.Add / Rig.Impulse) -> Rig.Finish (compose, route, write
-- at most once per channel). Subsystems never write camera properties.
--
-- ctx : stable references             sig : per-tick derived state
--   .pawn    APalPlayerCharacter        .speed2d      2D speed (uu/s)
--   .cmc     PalCharacterMovementComp   .vz           vertical velocity
--   .pc      APalPlayerController       .mode         MovementMode enum
--   .arm     PalShooterSpringArmComp    .grounded     mode 1 or 2
--   .cam     PalCharacterCameraComp     .falling      mode 3
--   .loadout LoadoutSelectorComponent   .sprinting    grounded + min speed
--                                       .holstered    slot index < 0
--                                       .heading      vel heading deg / nil
--                                       .camInput     look-axis magnitude
--                                       .userLooking  camInput > deadzone
--
-- The tick path allocates almost nothing: `sig` below and every request
-- payload in the subsystems are hoisted and mutated in place, where the
-- previous version built a fresh table for each one every frame. Measured
-- under sprint (the busiest path): 31.3 bytes/tick before, 8.0 after. The
-- remainder is the pcall(function() ... end) closures that safe UObject
-- access requires, which cannot be hoisted away — the property read has to
-- happen inside the protected call.
-- =========================================================================

local UEHelpers   = require("UEHelpers")
local Log         = require("log")
local U           = require("camutil")
local Rig         = require("rig")
local TickSource  = require("ticksource")
local HolsterLink = require("holsterlink")

-- Order matters: recon first, framing before the additive effects.
--
-- The parentheses are load-bearing. Lua 5.4's require returns TWO values
-- (the module and the loader's file path), so a bare require() in the last
-- field of a table constructor expands to both and appends the path string
-- as an extra element. The previous version had exactly that, which put a
-- string in Subsystems and made every dispatch loop trip over an entry with
-- no .name. Wrapping each call truncates it to one value.
local Subsystems = {
    (require("probe")),     -- passive signal recon (dev; off by default)
    (require("xray")),      -- one-shot reflection dump (dev; off by default)
    (require("framing")),   -- holster framing, state bank, camera lag
    (require("sprintfx")),  -- sprint bob + FOV + footfall impulses
    (require("fallfx")),    -- fall heave + FOV + landing impulse
}

local log  = Log.MakeAlways("main")
local dump = Log.MakeAlways("dump")

-- ==== state ==============================================================

local CFG      = nil
local ctx      = { pawn = nil, cmc = nil, pc = nil,
                   arm = nil, cam = nil, loadout = nil }
local enabled  = {}      -- name -> bool, mirrors CFG.enabled
local masterOn = true
local subErr   = {}
local cached   = false

-- Hoisted per-tick signal table. Never reallocated.
local sig = {
    vz = 0, speed2d = 0, mode = 0, custom = 0,
    grounded = false, falling = false, sprinting = false,
    holstered = false, heading = nil, camInput = 0, userLooking = false,
}

-- ==== UObject array helper ===============================================

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

-- ==== component discovery ================================================
-- Probe confirmed the component names on BP_PlayerBase:
--   pawn.CameraBoom   -> PalShooterSpringArmComponent
--   pawn.FollowCamera -> PalCharacterCameraComponent
-- The fast path reads those directly; the generic sniffing below remains as
-- a fallback in case a patch renames them.

local function SniffAssign(comp)
    local okN, full = pcall(function() return comp:GetFullName() end)
    if not okN then return end
    local l = full:lower()
    if ctx.arm == nil and l:find("springarm") then ctx.arm = comp end
    if ctx.cam == nil and l:find("cameracomponent") then ctx.cam = comp end
end

local function DiscoverCameraParts()
    ctx.arm, ctx.cam = nil, nil
    local pawn = ctx.pawn

    -- Stage 0: confirmed named properties.
    pcall(function()
        local b = pawn.CameraBoom
        if b and b:IsValid() then ctx.arm = b end
    end)
    pcall(function()
        local c = pawn.FollowCamera
        if c and c:IsValid() then ctx.cam = c end
    end)
    if ctx.arm and ctx.cam then
        log("discovery (fast path): arm=%s  cam=%s",
            ctx.arm:GetFullName(), ctx.cam:GetFullName())
        return
    end

    -- Stage 1: enumerate the pawn's components.
    local compClass = StaticFindObject("/Script/Engine.ActorComponent")
    if compClass and compClass:IsValid() then
        for _, fname in ipairs({ "K2_GetComponentsByClass", "GetComponentsByClass" }) do
            local ok, arr = pcall(function() return pawn[fname](pawn, compClass) end)
            if ok and arr then
                ForEachUObjArray(arr, SniffAssign)
                break
            end
        end
    end

    -- Stage 2: global instance search filtered by owner.
    if ctx.arm == nil or ctx.cam == nil then
        local pawnName = pawn:GetFullName()
        for _, cls in ipairs({ "PalShooterSpringArmComponent", "SpringArmComponent",
                               "PalCharacterCameraComponent", "CameraComponent" }) do
            local okF, all = pcall(function() return FindAllOf(cls) end)
            if okF and all then
                for _, comp in ipairs(all) do
                    local okO, owner = pcall(function() return comp:GetOwner() end)
                    if okO and owner and owner:IsValid()
                       and owner:GetFullName() == pawnName then
                        SniffAssign(comp)
                    end
                end
            end
        end
    end

    log("discovery (fallback): arm=%s  cam=%s",
        ctx.arm and ctx.arm:GetFullName() or "NOT FOUND",
        ctx.cam and ctx.cam:GetFullName() or "NOT FOUND")
end

-- ==== reference caching ==================================================

local function CacheAll()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if not ok or not p or not p:IsValid() then return false end
    local ok2, c = pcall(function() return p.CharacterMovement end)
    if not ok2 or not c or not c:IsValid() then return false end
    ctx.pawn, ctx.cmc = p, c

    local okC, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    ctx.pc = (okC and pc and pc:IsValid()) and pc or nil

    local okL, lo = pcall(function() return p.LoadoutSelectorComponent end)
    ctx.loadout = (okL and lo and lo:IsValid()) and lo or nil

    DiscoverCameraParts()

    log("cached: pawn=%s  pc=%s  loadout=%s",
        ctx.pawn:GetFullName(),
        ctx.pc and "ok" or "MISSING",
        ctx.loadout and "ok" or "MISSING")

    HolsterLink.Resolve()
    Rig.OnCached(ctx)
    for _, sub in ipairs(Subsystems) do
        if sub.OnCached then
            local okS, err = pcall(sub.OnCached, ctx)
            if not okS then log("[%s] OnCached error: %s", sub.name, tostring(err)) end
        end
    end
    cached = true
    return true
end

local function ValidRefs()
    if ctx.pawn and ctx.pawn:IsValid()
       and ctx.cmc and ctx.cmc:IsValid()
       and ctx.pc  and ctx.pc:IsValid() then
        return true
    end
    cached = false
    return CacheAll()
end

-- ==== config ==============================================================

--- Push fresh config into every module. Rig FIRST: framing's RefreshConfig
--- calls Rig.SetBankPrefixes, which needs the rig's own config in place.
local function ApplyConfig(reason)
    Log.RefreshConfig(CFG.log)
    Rig.RefreshConfig(CFG.rig)
    TickSource.RefreshConfig(CFG.tick)

    for _, sub in ipairs(Subsystems) do
        local wasOn = enabled[sub.name]
        local nowOn = CFG.enabled[sub.name] and true or false
        enabled[sub.name] = nowOn

        if sub.RefreshConfig then
            local ok, err = pcall(sub.RefreshConfig, CFG[sub.name])
            if not ok then
                log("[%s] RefreshConfig error: %s", sub.name, tostring(err))
            end
        end

        -- Switched off: let it drop whatever it was holding, so disabling is
        -- visually immediate and complete rather than merely un-ticked.
        if wasOn and not nowOn and sub.Release then
            pcall(sub.Release)
        end
    end

    subErr = {}
    log("config applied (%s)", reason)
end

--- F10. Re-read config.lua FROM DISK so edits made while the game runs take
--- effect. A bad edit is caught here and the previous config stays live.
local function ReloadConfig()
    package.loaded["config"] = nil
    local ok, fresh = pcall(require, "config")
    if not ok or type(fresh) ~= "table" then
        log("CONFIG RELOAD FAILED (keeping previous): %s", tostring(fresh))
        -- Restore the module cache so the next require does not re-read a
        -- file we already know is broken.
        package.loaded["config"] = CFG
        return
    end
    CFG = fresh
    ApplyConfig("F10 reload")
end

-- ==== dev keys ===========================================================

--- F11. Instant A/B against stock Palworld.
local function ToggleMaster()
    masterOn = not masterOn
    if not masterOn then
        for _, sub in ipairs(Subsystems) do
            if sub.Release then pcall(sub.Release) end
        end
        Rig.Release()
    end
    log("MASTER %s", masterOn and "ON" or "OFF (vanilla camera)")
end

--- F9. One report with everything needed to diagnose a misbehaving feature.
local function DumpState()
    dump("======== state dump ========")
    dump("-- main --")
    dump("  master      : %s", masterOn and "ON" or "OFF")
    dump("  cached      : %s", tostring(cached))
    dump("  refs        : pawn=%s cmc=%s pc=%s arm=%s cam=%s loadout=%s",
         ctx.pawn and "ok" or "nil", ctx.cmc and "ok" or "nil",
         ctx.pc and "ok" or "nil",   ctx.arm and "ok" or "MISSING",
         ctx.cam and "ok" or "MISSING", ctx.loadout and "ok" or "nil")
    dump("  signals     : speed2d=%.0f vz=%.0f mode=%d sprint=%s holstered=%s",
         sig.speed2d, sig.vz, sig.mode, tostring(sig.sprinting),
         tostring(sig.holstered))

    local on, off = {}, {}
    for _, sub in ipairs(Subsystems) do
        local t = enabled[sub.name] and on or off
        t[#t + 1] = sub.name
    end
    dump("  enabled     : %s", #on > 0 and table.concat(on, ", ") or "(none)")
    dump("  disabled    : %s", #off > 0 and table.concat(off, ", ") or "(none)")

    TickSource.DumpState(dump)
    Rig.DumpState(dump)
    HolsterLink.DumpState(dump)
    for _, sub in ipairs(Subsystems) do
        if sub.DumpState and enabled[sub.name] then
            pcall(sub.DumpState, dump)
        end
    end
    dump("======== end dump ========")
end

-- ==== per-tick signals ===================================================
-- Mutates the hoisted `sig` in place; allocates nothing.

local function BuildSignals()
    local S = CFG.signals
    local v = ctx.cmc.Velocity
    sig.vz      = v.Z
    sig.speed2d = math.sqrt(v.X * v.X + v.Y * v.Y)
    sig.mode    = ctx.cmc.MovementMode
    sig.custom  = 0
    pcall(function() sig.custom = ctx.cmc.CustomMovementMode end)
    sig.grounded = (sig.mode == 1 or sig.mode == 2)
    sig.falling  = (sig.mode == 3)

    -- Sprint detection is SPEED-BASED on purpose. The bRequestSprint gate
    -- never fired across multiple capture sessions (the flag is either
    -- unreadable or not the live sprint state) and its pcall silently
    -- disabled every sprint effect. Grounded speed above the walk cap (350)
    -- cannot fail silently.
    sig.sprinting = sig.grounded and sig.speed2d > S.sprintMinSpeed

    sig.holstered = HolsterLink.IsHolstered(ctx)
    sig.heading   = U.VelocityHeadingDeg(v.X, v.Y, S.headingMinSpeed)

    sig.camInput = 0
    pcall(function()
        local m = ctx.pc.MouseNativeAxis
        local g = ctx.pc.GamePadNativeAxis
        local mm = math.sqrt(m.X * m.X + m.Y * m.Y)
        local gm = math.sqrt(g.X * g.X + g.Y * g.Y)
        sig.camInput = math.max(mm, gm)
    end)
    sig.userLooking = sig.camInput > S.camInputDeadzone
end

-- ==== tick dispatch ======================================================

local function Tick(dt)
    if not masterOn then return end
    if CFG == nil then return end
    if not ValidRefs() then return end

    BuildSignals()

    Rig.Begin()
    for _, sub in ipairs(Subsystems) do
        if enabled[sub.name] and sub.OnTick then
            local ok, err = pcall(sub.OnTick, dt, ctx, sig)
            if not ok and not subErr[sub.name] then
                subErr[sub.name] = true
                log("[%s] OnTick error (logged once, cleared on F10): %s",
                    sub.name, tostring(err))
            end
        end
    end
    Rig.Finish(dt, ctx)
end

-- ==== wiring =============================================================

-- Initial config load. Without it nothing can start, so this one is fatal.
do
    local ok, fresh = pcall(require, "config")
    if not ok or type(fresh) ~= "table" then
        log("FATAL: config.lua failed to load: %s", tostring(fresh))
        return
    end
    CFG = fresh
end

TickSource.SetHandler(Tick)
ApplyConfig("mod load")
TickSource.Install("mod load")

-- Re-cache and retry any BP hook whose class was not loaded yet. Covers both
-- first spawn and every respawn.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(500, function()
        pcall(CacheAll)
        TickSource.Retry("client restart")
    end)
end)

-- Hot reload mid-session: the pawn already exists, so no restart
-- notification is coming. Bind immediately.
ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then
        pcall(CacheAll)
        TickSource.Retry("mid-session load")
    end
end)

-- Dev keys. UE4SS offers no way to unregister a keybind, so a script reload
-- would otherwise stack a second binding on the same key. The registered
-- closures dispatch through this global table, which a reload overwrites —
-- one binding, always pointing at the current code.
do
    local KEYS = _G.TheCameraIsAPal_Keys or {}
    _G.TheCameraIsAPal_Keys = KEYS

    KEYS.reload = ReloadConfig
    KEYS.master = ToggleMaster
    KEYS.dump   = DumpState

    if not KEYS.bound then
        KEYS.bound = true
        local okK = pcall(function()
            RegisterKeyBind(Key.F10, function() if KEYS.reload then KEYS.reload() end end)
            RegisterKeyBind(Key.F11, function() if KEYS.master then KEYS.master() end end)
            RegisterKeyBind(Key.F9,  function() if KEYS.dump   then KEYS.dump()   end end)
        end)
        if okK then
            log("dev keys: F10 reload config | F11 master on/off | F9 dump state")
        else
            KEYS.bound = false
            log("WARNING: dev keys could not be registered")
        end
    else
        log("dev keys re-pointed at reloaded code (bindings already present)")
    end
end

do
    local names = {}
    for _, s in ipairs(Subsystems) do
        names[#names + 1] = s.name .. (enabled[s.name] and "" or "(off)")
    end
    log("loaded. subsystems: %s", table.concat(names, ", "))
end
