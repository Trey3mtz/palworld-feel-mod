---@diagnostic disable: inject-field, need-check-nil, undefined-field, undefined-global
-- =========================================================================
-- HelpfulHolster
-- author  = TheTr3y
-- version = 1.0.0
--
-- Hook lifecycle (event-driven, no polling):
--   * /Script/ (native) paths exist from engine init -> registered once at
--     mod load.
--   * /Game/ (Blueprint) paths resolve only once their class is loaded.
--     NotifyOnNewObject on /Script/Pal.PalPlayerCharacter fires at class
--     load (CDO), first spawn, every respawn, and every world reload. By
--     pawn-spawn time the possessing BP_PalPlayerController_C exists, so
--     the controller tick is registrable. A failed attempt is NOT latched
--     -- the next construction event retries it.
--   * BP classes are GC'd and reloaded on world transitions, so Blueprint
--     hooks are unbound and rebound on each pass.
-- =========================================================================

local UEHelpers = require("UEHelpers")
local Config = require("config")

local DEBUGGING = true

local PATH_CONTROLLER_TICK =
    "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick"

-- Native base class of the player pawn; its construction is the
-- "blueprints are loaded" signal.
local PAWN_NATIVE_CLASS = "/Script/Pal.PalPlayerCharacter"

-- Input keys. FKey marshals from a table keyed by KeyName. Built once:
-- constructing FName every frame is wasteful.
local KEY_KEYBOARD   = { KeyName = FName(Config.Binding) }
local KEY_CONTROLLER = { KeyName = FName(Config.ControllerBinding) }

-- ---------------------------- state --------------------------------------

local playerController = nil

local LastEquippedIndex = 0
local TimeInputHeld     = 0
local IsInputKeyDown    = false

local function dbg(fmt, ...)
    if DEBUGGING then print(string.format("[Helpful Holster] " .. fmt .. "\n", ...)) end
end

-- ---------------------------- player cache -------------------------------

local function CacheController()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if not ok or not pc or not pc:IsValid() then return false end
    playerController = pc
    return true
end

local function ValidController()
    if playerController and playerController:IsValid() then return true end
    return CacheController()
end

--- Player's loadout component, or nil.
local function GetLoadout()
    if not ValidController() then return nil end
    local ok, pawn = pcall(function() return playerController.Pawn end)
    if not ok or not pawn or not pawn:IsValid() then return nil end
    local ok2, loadout = pcall(function() return pawn.LoadoutSelectorComponent end)
    if not ok2 or not loadout or not loadout:IsValid() then return nil end
    return loadout
end

-- ---------------------------- holster logic ------------------------------
local INV_NONE           = 6
local INV_WEAPON_LOADOUT = 3
function IsHolstered()
    local loadout = GetLoadout()
    if not loadout then return false end
    local ok, t = pcall(function() return loadout:GetPrimaryInventoryType() end)
    if ok and t then return t == INV_NONE end
    -- fall back to the property if the accessor doesn't marshal
    return loadout.primaryTargetInventoryType == INV_NONE
end
--- @param TargetIndex integer (-1 to holster, 0-3 for weapon slots)
local function SetWeaponIndex(TargetIndex)
    local loadout = GetLoadout()
    if not loadout then return end

    local ok, err = pcall(function()
        loadout:SetWeaponLoadoutIndex_Internal(TargetIndex)
        if loadout:TryEquipNowSelectedWeapon() then
            dbg("Equipped selected weapon")
        end
    end)
    if not ok then
        print("[Helpful Holster] Error setting weapon index: " .. tostring(err))
    end
end

local function ToggleHolsterState()
    local loadout = GetLoadout()
    if not loadout then return end

    dbg("before: type=%s idx=%s",
        tostring(loadout.primaryTargetInventoryType),
        tostring(loadout.currentItemSlotIndex))

-- ADDED FOR DEBUGGING, DELTET LATER
local ok, list = pcall(function() return loadout:GetWeaponList() end)
if not ok or not list then
    dbg("GetWeaponList failed: %s", tostring(list))
    return
end

local okN, n = pcall(function() return #list end)
dbg("weapons: %s", tostring(okN and n))

for i = 1, (okN and n or 0) do
    local w = list[i]
    if w then
        local okT, wt  = pcall(function() return w.WeaponType end)
        local okI, idx = pcall(function() return w.LoadoutSelectorIndex end)
        local okF, fn  = pcall(function() return w:GetFullName() end)
        dbg("  [%d] type=%s loadoutIdx=%s %s", i,
            tostring(okT and wt), tostring(okI and idx), tostring(okF and fn))
    end
end
-- END OF DELETE LATER
    
    if not IsHolstered() then
        LastEquippedIndex = loadout.currentItemSlotIndex
        loadout:SelectItem(INV_WEAPON_LOADOUT, -1)
        loadout:TryEquipNowSelectedWeapon()
        dbg("Holstered (saved slot %d)", LastEquippedIndex)
    else
        local RestoreIndex = (LastEquippedIndex >= 0) and LastEquippedIndex or 0
        loadout:SelectItem(INV_WEAPON_LOADOUT, RestoreIndex)
        loadout:TryEquipNowSelectedWeapon()
        dbg("Restored slot %d", RestoreIndex)
    end

    dbg("after: type=%s idx=%s",
    tostring(loadout.primaryTargetInventoryType),
    tostring(loadout.currentItemSlotIndex))
end

local function ResetInputState()
    IsInputKeyDown = false
    TimeInputHeld  = 0
end

-- ---------------------------- tick ---------------------------------------

--- Gamepad input cannot be serviced by RegisterKeyBind, so both bindings
--- are sampled here per frame.
local function Tick(dt)
    if not ValidController() then return end

    if IsInputKeyDown then
        TimeInputHeld = TimeInputHeld + dt
    end

    local okP, pressed = pcall(function()
        return playerController:WasInputKeyJustPressed(KEY_KEYBOARD)
            or playerController:WasInputKeyJustPressed(KEY_CONTROLLER)
    end)
    if okP and pressed then
        IsInputKeyDown = true
        dbg("Input pressed")
    end

    local okR, released = pcall(function()
        return playerController:WasInputKeyJustReleased(KEY_KEYBOARD)
            or playerController:WasInputKeyJustReleased(KEY_CONTROLLER)
    end)
    if okR and released then
        ResetInputState()
        dbg("Input released")
    end

    if Config.HoldToHolster then
        if IsInputKeyDown and TimeInputHeld >= Config.HoldTimeSeconds then
            ToggleHolsterState()
            ResetInputState()
        end
    else
        if IsInputKeyDown then
            ToggleHolsterState()
            ResetInputState()
        end
    end
end

-- ---------------------------- hook registry ------------------------------

local HookList = {
    { name = "controller tick", path = PATH_CONTROLLER_TICK,
        callback = function(Context, DeltaSeconds)
            local ok, dt = pcall(function() return DeltaSeconds:get() end)
            Tick(ok and dt or 0.0083)
        end },

    -- Weapon switch: if holstered, come out of the holster. Native, so
    -- these register at mod load.
    { name = "next weapon", path = "/Script/Pal.PalPlayerController:OnPressedWeaponNextButtonKeyboard",
        callback = function(Context)
            if IsHolstered() then ToggleHolsterState() end
        end },

    { name = "prev weapon", path = "/Script/Pal.PalPlayerController:OnPressedWeaponPrevButton",
        callback = function(Context)
            if IsHolstered() then ToggleHolsterState() end
        end },
}

local function IsNativePath(path)
    return path:sub(1, 8) == "/Script/"
end

--- One registration attempt. Failure on a /Game/ path is not an error:
--- it means the class is not loaded yet, and the next construction event
--- retries. Nothing is latched.
local function Register(h, context)
    local ok, pre, post = pcall(RegisterHook, h.path, h.callback)
    if ok then
        h.preId, h.postId = pre, post
        dbg("Hook installed (%s): %s", context, h.name)
    else
        h.preId, h.postId = nil, nil
        dbg("Hook pending (%s): %s -- %s", context, h.name, tostring(pre))
    end
    return ok
end

local function InstallNativeHooks()
    for _, h in ipairs(HookList) do
        if IsNativePath(h.path) then Register(h, "mod load") end
    end
end

--- Blueprint hooks: unbind stale registrations first, since a world reload
--- GCs and reloads the BP class, leaving the old hook bound to a dead one.
local function RefreshBlueprintHooks(context)
    for _, h in ipairs(HookList) do
        if not IsNativePath(h.path) and not h.preId then
            Register(h, context)
        end
    end
end

-- ---------------------------- entry point --------------------------------

dbg("Loaded. Hooks declared: %d", #HookList)

InstallNativeHooks()

-- Fires at class load (CDO), first spawn, every respawn, every world
-- reload. Refs are cleared here and re-cached lazily on the next tick:
-- at construction time the pawn is not fully initialized.
NotifyOnNewObject(PAWN_NATIVE_CLASS, function()
    playerController = nil
    ResetInputState()
    RefreshBlueprintHooks("pawn constructed")
end)

-- Hot-reload mid-session: the pawn already exists, so no construction
-- notification is coming -- bind immediately.
ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then
        RefreshBlueprintHooks("mid-session load")
    end
end)
