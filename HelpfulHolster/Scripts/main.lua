---@diagnostic disable: inject-field, need-check-nil, undefined-field, undefined-global
-- =========================================================================
-- HelpfulHolster
-- author  = TheTr3y
-- version = 1.0.0
-- date    = 2026-07-22
-- =========================================================================

local UEHelpers = require("UEHelpers")
local Config    = require("config")

local DEBUGGING = false

local PATH_CONTROLLER_TICK =
    "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick"
local PAWN_NATIVE_CLASS = "/Script/Pal.PalPlayerCharacter"

-- FKey marshals from a table keyed by KeyName.
local KEY_KEYBOARD   = { KeyName = FName(Config.KeyboardBinding) }
local KEY_CONTROLLER = { KeyName = FName(Config.ControllerBinding) }

-- ---------------------------- state --------------------------------------

local playerController   = nil
local _didHolster        = false
local LastEquippedWeapon = nil
local TimeInputHeld      = 0
local IsInputKeyDown     = false

local function dbg(fmt, ...)
    if DEBUGGING then print(string.format("[Helpful Holster] " .. fmt .. "\n", ...)) end
end

-- ---------------------------- component access ---------------------------

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

local function GetPawn()
    if not ValidController() then return nil end
    local ok, pawn = pcall(function() return playerController.Pawn end)
    if not ok or not pawn or not pawn:IsValid() then return nil end
    return pawn
end

local function GetShooter()
    local pawn = GetPawn()
    if not pawn then return nil end
    local ok, shooter = pcall(function() return pawn.ShooterComponent end)
    if not ok or not shooter or not shooter:IsValid() then return nil end
    return shooter
end

-- ---------------------------- weapon detection ---------------------------

--- True when the shooter holds a REAL drawn weapon. Reads only the type
--- prefix from tostring() -- never dereferences the object's class, which
--- crashes on the holstered placeholder. "AActor:" = real weapon;
--- "UObject:" = holstered placeholder; nil = nothing.
local function HasRealWeapon()
    local shooter = GetShooter()
    if not shooter then return false end
    local okF, w = pcall(function() return shooter.HasWeapon end)
    if not okF or w == nil then return false end
    local okT, s = pcall(function() return tostring(w) end)
    if not okT or type(s) ~= "string" then return false end
    return s:sub(1, 7) == "AActor:"
end

-- ---------------------------- holster logic ------------------------------

local function AbandonHolsterState(reason)
    _didHolster        = false
    LastEquippedWeapon = nil
    dbg("Holster state cleared: %s", reason)
end

--- True when the native unarmed slot is selected, or we holstered a weapon.
function IsHolstered()
    local pawn = GetPawn()
    if pawn then
        local ok, loadout = pcall(function() return pawn.LoadoutSelectorComponent end)
        if ok and loadout then
            local okI, idx = pcall(function() return loadout.currentItemSlotIndex end)
            if okI and idx == -1 then return true end
        end
    end
    return _didHolster and not HasRealWeapon()
end

--- Save the current weapon, then clear it. Refuses when no real weapon is
--- drawn, so holstering while already unarmed is a no-op (issue 1).
local function Unequip()
    local shooter = GetShooter()
    if not shooter then return false end

    if not HasRealWeapon() then
        dbg("Nothing to holster")
        return false
    end

    local okF, w = pcall(function() return shooter.HasWeapon end)
    if not okF or w == nil then return false end

    local ok, err = pcall(function() shooter:ChangeWeapon(nil, true) end)
    if not ok then
        dbg("Unequip failed: %s", tostring(err))
        return false
    end
    dbg("[after changed to nil] OverrideWeapontype: %s ", shooter.OverrideWeapontype)
    LastEquippedWeapon = w
    return true
end

--- Hand the saved weapon back. Guards against a stale/destroyed reference.
local function RestoreEquipped()
    local shooter = GetShooter()
    if not shooter then return false end
    if not (LastEquippedWeapon and LastEquippedWeapon:IsValid()) then
        return false
    end
    local ok, err = pcall(function() shooter:ChangeWeapon(LastEquippedWeapon, true) end)
    if not ok then dbg("Restore failed: %s", tostring(err)) end
    return ok
end

local function ToggleHolsterState()
    if _didHolster then
        if RestoreEquipped() then
            _didHolster        = false
            LastEquippedWeapon = nil
            dbg("Restored")
        else
            AbandonHolsterState("restore unavailable")
        end
    elseif Unequip() then
        _didHolster = true
        dbg("Holstered")
    end
end

local function ResetInputState()
    IsInputKeyDown = false
    TimeInputHeld  = 0
end

-- ---------------------------- tick ---------------------------------------

--- Gamepad input cannot be serviced by RegisterKeyBind, so both bindings are sampled here per frame.
--- Also reconciles holster state against the game (see State integrity, header).
local function Tick(dt)
    if not ValidController() then return end

    -- Reconciliation: game re-armed us through a path we do not hook. The
    -- weapon is a real AActor again while we still think we holstered.
    if _didHolster and HasRealWeapon() then
        AbandonHolsterState("re-armed by game")
    end

    if IsInputKeyDown then
        TimeInputHeld = TimeInputHeld + dt
    end

    local okP, pressed = pcall(function()
        return playerController:WasInputKeyJustPressed(KEY_KEYBOARD)
            or playerController:WasInputKeyJustPressed(KEY_CONTROLLER)
    end)
    if okP and pressed then
        IsInputKeyDown = true
    end

    local okR, released = pcall(function()
        return playerController:WasInputKeyJustReleased(KEY_KEYBOARD)
            or playerController:WasInputKeyJustReleased(KEY_CONTROLLER)
    end)
    if okR and released then
        ResetInputState()
    end

    if Config.HoldToHolster then
        if IsInputKeyDown and TimeInputHeld >= Config.HoldTimeSeconds then
            ToggleHolsterState()
            ResetInputState()
        end
    elseif IsInputKeyDown then
        ToggleHolsterState()
        ResetInputState()
    end
end

-- ---------------------------- hook registry ------------------------------

local HookList = {
    { name = "controller tick", path = PATH_CONTROLLER_TICK,
        callback = function(Context, DeltaSeconds)
            local ok, dt = pcall(function() return DeltaSeconds:get() end)
            Tick(ok and dt or 0.0083)
        end },

    -- Weapon switch via held-modifier d-pad (the paths that cross ProcessEvent).
    -- Drop our stale state immediately rather than waiting for tick reconciliation.
    -- Other switch paths (tap) are caught by the reconciliation above.
    { name = "next weapon", path = "/Script/Pal.PalPlayerController:OnPressedWeaponNextButtonKeyboard",
        callback = function(Context)
            if _didHolster then AbandonHolsterState("weapon switch (next)") end
        end },

    { name = "prev weapon", path = "/Script/Pal.PalPlayerController:OnPressedWeaponPrevButton",
        callback = function(Context)
            if _didHolster then AbandonHolsterState("weapon switch (prev)") end
        end },
}

local function IsNativePath(path)
    return path:sub(1, 8) == "/Script/"
end

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

--- (Re)bind Blueprint hooks whose class was (re)loaded. Only attempts a
--- path that is not currently bound, so a same-world refire never doubles up.
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

NotifyOnNewObject(PAWN_NATIVE_CLASS, function()
    playerController = nil
    AbandonHolsterState("pawn constructed")
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
