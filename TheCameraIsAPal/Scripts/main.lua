-- =========================================================================
-- PalFeel — orchestrator / entry point
-- UE4SS Lua, Palworld 1.0.1, offline/single-player.
-- Install: Pal\Binaries\Win64\ue4ss\Mods\PalFeel\Scripts\   (all files)
--          then "PalFeel : 1" in ue4ss\Mods\mods.txt
--
-- Owns: player caching, respawn re-cache, event-driven hook lifecycle.
-- Subsystems implement: M.name, M.OnPlayerCached(pawn, cmc),
--                       M.OnTick(dt, pawn, cmc)
-- Optional:             M.Hooks = { { name, path, callback, post }, ... }
--                       callback = PRE  (may be nil)
--                       post     = POST (may be nil)
--   Use post whenever the value you want to read or edit is produced BY the
--   hooked function — e.g. a launch velocity. A pre callback runs before it
--   exists. UE4SS wants a pre slot regardless, so a no-op is substituted
--   when a subsystem declares post only.
--
-- Hook lifecycle (no polling, no timers):
--   * /Script/ (native) paths exist from engine init — registered once at
--     mod load, unconditionally.
--   * /Game/ (Blueprint) paths resolve only after their class is loaded.
--     The game's own signal for that is the construction of the player
--     character: BP_PlayerBase_C derives from
--     /Script/Pal.PalPlayerCharacter (SuperStruct, per the asset dump),
--     so NotifyOnNewObject on that native class fires when the class
--     loads (its CDO) and again when the pawn spawns. By pawn-spawn time
--     the possessing BP_PalPlayerController_C instance already exists,
--     so every /Game/ path in the registry is registrable in one pass.
--   * The same notification fires on every respawn and world (re)load,
--     so it doubles as the re-cache / re-bind trigger. It does NOT fire
--     on mount/dismount — possession changes construct no
--     PalPlayerCharacter. That is precisely the failure mode of
--     PlayerController:ClientRestart (fires on every mount swap), which
--     is why that hook no longer exists here.
-- =========================================================================

local UEHelpers = require("UEHelpers")

-- CHANGED: jumpspot added.
local Subsystems = {
    require("jump"),
    require("walking"),
    require("slide"),
}

local DEBUG = true

local PATH_CONTROLLER_TICK =
    "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick"

-- Native base class of the player pawn. Its construction (CDO at class
-- load, instance at spawn/respawn) is the load-complete signal.
local PAWN_NATIVE_CLASS = "/Script/Pal.PalPlayerCharacter"

local pawn, cmc = nil, nil
local subErr = {}

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel] " .. fmt .. "\n", ...)) end
end

-- ---------------------------- player cache -------------------------------

local function CachePlayer()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if not ok or not p or not p:IsValid() then return false end
    local ok2, c = pcall(function() return p.CharacterMovement end)
    if not ok2 or not c or not c:IsValid() then return false end
    pawn, cmc = p, c
    dbg("Player cached: %s", pawn:GetFullName())
    for _, sub in ipairs(Subsystems) do
        local okS, err = pcall(sub.OnPlayerCached, pawn, cmc)
        if not okS then dbg("[%s] OnPlayerCached error: %s", sub.name, tostring(err)) end
    end
    return true
end

local function ValidRefs()
    if pawn and pawn:IsValid() and cmc and cmc:IsValid() then return true end
    return CachePlayer()
end

local function Tick(dt)
    if not ValidRefs() then return end
    for _, sub in ipairs(Subsystems) do
        local ok, err = pcall(sub.OnTick, dt, pawn, cmc)
        if not ok and not subErr[sub.name] then
            subErr[sub.name] = true
            dbg("[%s] OnTick error (logged once): %s", sub.name, tostring(err))
        end
    end
end

-- ---------------------------- hook registry ------------------------------
-- The core tick hook plus everything declared by subsystems via M.Hooks.

local HookList = {
    { name = "controller tick", path = PATH_CONTROLLER_TICK,
        callback = function(Context, DeltaSeconds)
            local ok, dt = pcall(function() return DeltaSeconds:get() end)
            Tick(ok and dt or 0.0083)
        end },
}
for _, sub in ipairs(Subsystems) do
    for _, h in ipairs(sub.Hooks or {}) do
        HookList[#HookList + 1] = h
    end
end

local function IsNativePath(path)
    return path:sub(1, 8) == "/Script/"
end

local function NoOp() end

-- One registration attempt. On success stores the callback ids needed to
-- unbind later. A /Game/ failure here is not an error condition: it means
-- the class is not loaded yet, and the next construction event retries.
--
-- CHANGED: forwards h.post as the post callback. UE4SS expects a pre slot
-- even for post-only hooks, so NoOp fills it and preId stays valid for the
-- unregister path below.
local function Register(h, context)
    local preFn = h.callback or NoOp
    local ok, pre, post = pcall(RegisterHook, h.path, preFn, h.post)
    if ok then
        h.preId, h.postId = pre, post
        dbg("Hook installed (%s): %s%s", context, h.name,
            h.post and "  [pre+post]" or "")
    else
        h.preId, h.postId = nil, nil
        dbg("Hook pending (%s): %s -- %s", context, h.name, tostring(pre))
    end
    return ok
end

-- /Script/ paths exist from engine init: register once, at mod load.
local function InstallNativeHooks()
    for _, h in ipairs(HookList) do
        if IsNativePath(h.path) then Register(h, "mod load") end
    end
end

-- /Game/ paths: (re)bind on demand. Previously stored ids are unregistered
-- first, so a world reload (BP class GC'd and reloaded => old hook dead)
-- rebinds cleanly, and a same-world refire never double-registers.
local function RefreshBlueprintHooks(context)
    for _, h in ipairs(HookList) do
        if not IsNativePath(h.path) then
            local canRebind = true
            if h.preId then
                if type(UnregisterHook) == "function" then
                    pcall(UnregisterHook, h.path, h.preId, h.postId)
                    h.preId, h.postId = nil, nil
                else
                    -- Cannot unbind on this UE4SS build: keep the existing
                    -- registration rather than risk a double hook.
                    canRebind = false
                end
            end
            if canRebind then Register(h, context) end
        end
    end
end

--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\-- MOD ENTRY POINT --////////////////////////////////////--

do
    local names = {}
    for _, s in ipairs(Subsystems) do names[#names + 1] = s.name end
    dbg("PalFeel loaded. Subsystems: %s  |  hooks declared: %d",
        table.concat(names, ", "), #HookList)
end

InstallNativeHooks()

-- One notification per constructed player character: class load (CDO),
-- first spawn, every respawn, every world (re)load. The CDO pass can run
-- before the controller BP is loaded, in which case the tick hook logs as
-- pending once and the pawn-spawn pass resolves it. Refs are cleared here
-- but re-cached lazily on the next tick — at construction time the pawn's
-- components are not initialized yet, so it must not be touched directly.
---@diagnostic disable-next-line: undefined-global
NotifyOnNewObject(PAWN_NATIVE_CLASS, function()
    pawn, cmc = nil, nil
    RefreshBlueprintHooks("pawn constructed")
end)


-- Hot-reload mid-session: the pawn already exists, so no construction
-- notification is coming — bind immediately.
---@diagnostic disable-next-line: undefined-global
ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then
        RefreshBlueprintHooks("mid-session load")
    end
end)
