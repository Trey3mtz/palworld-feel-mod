-- =========================================================================
-- TheCameraIsAPal — standalone cinematic third-person camera mod, Palworld
-- UE4SS Lua, Palworld 1.0, offline/single-player.
--
-- Install: Pal\Binaries\Win64\ue4ss\Mods\TheCameraIsAPal\Scripts\
--          then add "TheCameraIsAPal : 1" to ue4ss\Mods\mods.txt
--
-- main.lua owns: reference caching (pawn / cmc / controller / spring arm /
-- camera / loadout), respawn re-cache, per-tick signal derivation, rig
-- frame lifecycle, and subsystem dispatch. Subsystems implement:
--
--   M.name                       string tag for logs
--   M.OnCached(ctx)              called when refs are (re)acquired
--   M.OnTick(dt, ctx, sig)       called every controller tick
--   M.Hooks (optional)           { {name=, path=, callback=}, ... }
--
-- Tick order: BuildSignals -> Rig.Begin -> subsystems (request effects via
-- Rig.Add) -> Rig.Finish (smooth + single write). Subsystems never write
-- camera properties directly.
--
-- ctx : stable references             sig : per-tick derived state
--   .pawn    APalPlayerCharacter        .speed2d      2D speed (uu/s)
--   .cmc     PalCharacterMovementComp   .vz           vertical velocity
--   .pc      APalPlayerController       .mode         MovementMode enum
--   .arm     PalShooterSpringArmComp    .grounded     mode 1 or 2
--   .cam     PalCharacterCameraComp     .falling      mode 3
--   .loadout LoadoutSelectorComponent   .sprinting    request + min speed
--                                       .holstered    slot index < 0
--                                       .heading      vel heading deg / nil
--                                       .camInput     look-axis magnitude
--                                       .userLooking  camInput > deadzone
-- =========================================================================

local UEHelpers   = require("UEHelpers")
local U           = require("camutil")
local Rig         = require("rig")
local HolsterLink = require("holsterlink")

local Subsystems = {
    require("probe"),          -- passive signal recon; keep WRITE_TEST=false
    require("xray"),           -- one-shot reflection dump of Pal camera classes
    require("statecam"),       -- holster framing, anti jump-zoom, camera lag
    require("sprintfx"),       -- sprint sway + FOV widening (via rig)
    require("fallfx"),         -- fall wobble + FOV, velocity-scaled (via rig)
    -- require("follow"),      -- phase D: delayed follow / sprint turn-follow
}

local DEBUG = true
local PATH_CONTROLLER_TICK =
    "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick"

-- signal tuning
local SPRINT_MIN_SPEED   = 420    -- uu/s; above walk cap 350, below sprint 610
local HEADING_MIN_SPEED  = 60     -- uu/s; below this heading = nil
local CAM_INPUT_DEADZONE = 0.05   -- axis magnitude regarded as "no input"

-- ------------------------------------------------------------------------

local ctx    = { pawn = nil, cmc = nil, pc = nil,
                 arm = nil, cam = nil, loadout = nil }
local subErr = {}

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[TheCameraIsAPal] " .. fmt .. "\n", ...)) end
end

-- ------------------------- UObject array helper --------------------------

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

-- ------------------------- component discovery ---------------------------
-- Probe confirmed the component names on BP_PlayerBase:
--   pawn.CameraBoom   -> PalShooterSpringArmComponent
--   pawn.FollowCamera -> PalCharacterCameraComponent
-- Fast path reads those directly; generic sniffing remains as a fallback
-- in case a patch renames them.

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
        dbg("discovery (fast path): arm=%s  cam=%s",
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

    dbg("discovery (fallback): arm=%s  cam=%s",
        ctx.arm and ctx.arm:GetFullName() or "NOT FOUND",
        ctx.cam and ctx.cam:GetFullName() or "NOT FOUND")
end

-- ------------------------- reference caching -----------------------------

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

    dbg("cached: pawn=%s  pc=%s  loadout=%s",
        ctx.pawn:GetFullName(),
        ctx.pc and "ok" or "MISSING",
        ctx.loadout and "ok" or "MISSING")

    Rig.OnCached(ctx)
    for _, sub in ipairs(Subsystems) do
        local okS, err = pcall(sub.OnCached, ctx)
        if not okS then dbg("[%s] OnCached error: %s", sub.name, tostring(err)) end
    end
    return true
end

local function ValidRefs()
    if ctx.pawn and ctx.pawn:IsValid()
       and ctx.cmc and ctx.cmc:IsValid()
       and ctx.pc  and ctx.pc:IsValid() then
        return true
    end
    return CacheAll()
end

-- ------------------------- per-tick signals ------------------------------

local function BuildSignals()
    local s = {}
    local v = ctx.cmc.Velocity
    s.vz      = v.Z
    s.speed2d = math.sqrt(v.X * v.X + v.Y * v.Y)
    s.mode    = ctx.cmc.MovementMode
    s.custom  = 0
    pcall(function() s.custom = ctx.cmc.CustomMovementMode end)
    s.grounded = (s.mode == 1 or s.mode == 2)
    s.falling  = (s.mode == 3)

    -- Sprint detection is SPEED-BASED. The bRequestSprint gate never fired
    -- across multiple capture sessions (flag unreadable or not the live
    -- sprint state) and its pcall silently disabled every sprint effect.
    -- Grounded speed above the walk cap (350) cannot silently fail.
    s.sprinting = s.grounded and s.speed2d > SPRINT_MIN_SPEED

    -- Holster state comes from the HelpfulHolster bridge when available
    -- (its IsHolstered(), published via shared variable), with the game
    -- property as fallback. See holsterlink.lua.
    s.holstered = HolsterLink.IsHolstered(ctx)

    s.heading = U.VelocityHeadingDeg(v.X, v.Y, HEADING_MIN_SPEED)

    s.camInput = 0
    pcall(function()
        local m = ctx.pc.MouseNativeAxis
        local g = ctx.pc.GamePadNativeAxis
        local mm = math.sqrt(m.X * m.X + m.Y * m.Y)
        local gm = math.sqrt(g.X * g.X + g.Y * g.Y)
        s.camInput = math.max(mm, gm)
    end)
    s.userLooking = s.camInput > CAM_INPUT_DEADZONE

    return s
end

-- ------------------------- tick dispatch ---------------------------------

local function Tick(dt)
    if not ValidRefs() then return end
    local sig = BuildSignals()
    Rig.Begin()
    for _, sub in ipairs(Subsystems) do
        local ok, err = pcall(sub.OnTick, dt, ctx, sig)
        if not ok and not subErr[sub.name] then
            subErr[sub.name] = true
            dbg("[%s] OnTick error (logged once): %s", sub.name, tostring(err))
        end
    end
    Rig.Finish(dt, ctx)
end

-- ------------------------- wiring ----------------------------------------

local pendingHooks = { { name = "controller tick",
                         path = PATH_CONTROLLER_TICK,
                         callback = function(Context, DeltaSeconds)
                             local ok, dt = pcall(function() return DeltaSeconds:get() end)
                             Tick(ok and dt or 0.0083)
                         end } }

for _, sub in ipairs(Subsystems) do
    if sub.Hooks then
        for _, h in ipairs(sub.Hooks) do pendingHooks[#pendingHooks + 1] = h end
    end
end

LoopAsync(1000, function()
    local remaining = {}
    for _, h in ipairs(pendingHooks) do
        if pcall(RegisterHook, h.path, h.callback) then
            dbg("hook installed: %s", h.name)
        else
            remaining[#remaining + 1] = h
        end
    end
    pendingHooks = remaining
    return #pendingHooks == 0        -- true stops the loop
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(500, function() pcall(CacheAll) end)
end)

local names = {}
for _, s in ipairs(Subsystems) do names[#names + 1] = s.name end
dbg("TheCameraIsAPal loaded. Subsystems: %s", table.concat(names, ", "))
