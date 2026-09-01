---@diagnostic disable: inject-field, need-check-nil, undefined-field, undefined-global
-- =========================================================================
-- CanvasProbe — real-time UCanvas drawing feasibility probe
-- author  = TheTr3y
-- version = 0.2.0
-- date    = 2026-09-01
--
-- GOAL: prove we can draw to the screen every frame from UE4SS Lua.
--
-- Pass 1 (2026-08-11) confirmed:
--   * HUD actor exists: BP_PalHUD_InGame_C (per-world instance)
--   * HUD.Canvas holds a FRESH UCanvas pointer every sample -> AHUD::
--     PostRender IS running and receives a canvas each frame. The draw
--     window exists; only the event we hooked never fires.
--   * /Script/Engine.HUD:ReceiveDrawHUD binds but stays silent.
--
-- UE5.1 PostRender only calls DrawHUD() -> ReceiveDrawHUD when bShowHUD
-- is true. Palworld renders its UI in UMG, so the two prime suspects:
--   (1) bShowHUD ships false            -> pass 2 force-enables it
--   (2) PalHUD overrides DrawHUD() natively without Super::DrawHUD()
--       -> pass 2 hooks ReceiveDrawHUD at EVERY level of the concrete
--          class chain (BP class paths hook bytecode directly) and scans
--          each class's function surface for draw/render-named UFunctions
--          to expose alternate doors.
--
-- WHAT IT DRAWS once any draw event fires:
--   * a green crosshair at screen center            (static reference)
--   * a magenta line sweeping around the center     (proves per-frame update)
-- =========================================================================

local UEHelpers = require("UEHelpers")

local DEBUG_PRINT = true

-- ---------------------- tuning / configuration ---------------------------

local Config = {
    EngineDrawHookPath = "/Script/Engine.HUD:ReceiveDrawHUD",
    TickHookPath       = "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick",

    ForceShowHUD       = true,   -- pass-2 experiment: un-gate AHUD::DrawHUD

    CrosshairSize      = 14.0,                                  -- px, half-extent
    CrosshairColor     = { R = 0.1, G = 1.0, B = 0.2, A = 1.0 },
    CrosshairThick     = 2.0,

    SweepRadius        = 120.0,                                 -- px
    SweepSpeed         = 2.0,                                   -- rad/s
    SweepColor         = { R = 1.0, G = 0.1, B = 0.9, A = 1.0 },
    SweepThick         = 3.0,

    WatchdogPeriod     = 5.0,                                   -- s between reports

    -- UFunction names worth surfacing while scanning the HUD class chain.
    FnScanPattern      = "[Dd]raw",
    FnScanExtra        = { "Render", "Canvas", "Paint", "HUD" },
}

-- ---------------------- state & cache ------------------------------------

local drawFrameCount  = 0       -- times any draw hook fired
local firstDrawDumped = false   -- one-shot success diagnostics
local watchdogTimer   = 0.0
local tickHookBound   = false
local triedHookPaths  = {}      -- path  -> "BOUND" | "failed"
local scannedClasses  = {}      -- class -> true (chain walk is one-shot per class)
local showHudForced   = false   -- log the bShowHUD flip only once

local function dbg(fmt, ...)
    if DEBUG_PRINT then print(string.format("[CanvasProbe] " .. fmt .. "\n", ...)) end
end

-- ---------------------- utility ------------------------------------------

local function ReadOpt(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function FullNameOf(obj)
    local ok, s = pcall(function() return obj:GetFullName() end)
    return ok and s or "<unreadable>"
end

--- "BlueprintGeneratedClass /Game/X.Y_C" -> "/Game/X.Y_C" (path after the
--- first space); nil when the shape is unexpected.
local function ObjectPathOf(obj)
    local full = FullNameOf(obj)
    return full:match("%s(.+)$")
end

local function FnNameOf(fn)
    local ok, s = pcall(function() return fn:GetFName():ToString() end)
    if ok and type(s) == "string" then return s end
    return FullNameOf(fn)
end

-- ---------------------- core logic: drawing ------------------------------

--- One-shot dump the moment we hold a live canvas, so the log records the
--- exact class/name we should target in future mods.
local function DumpDrawContext(hud, canvas, sizeX, sizeY)
    dbg("==== FIRST DRAW FRAME — the door is open ====")
    dbg("  HUD    : %s", FullNameOf(hud))
    dbg("  Canvas : %s", FullNameOf(canvas))
    dbg("  Size   : %d x %d", sizeX, sizeY)
end

local function DrawLine(canvas, x1, y1, x2, y2, thick, color)
    return pcall(function()
        canvas:K2_DrawLine({ X = x1, Y = y1 }, { X = x2, Y = y2 }, thick, color)
    end)
end

local function DrawProbeFrame(canvas, sizeX, sizeY)
    local cx, cy = sizeX * 0.5, sizeY * 0.5
    local s      = Config.CrosshairSize

    DrawLine(canvas, cx - s, cy, cx + s, cy, Config.CrosshairThick, Config.CrosshairColor)
    DrawLine(canvas, cx, cy - s, cx, cy + s, Config.CrosshairThick, Config.CrosshairColor)

    -- ReceiveDrawHUD carries no delta-time; os.clock() gives us a monotonic
    -- animation clock without touching game state.
    local angle = (os.clock() * Config.SweepSpeed) % (2 * math.pi)
    local ex = cx + math.cos(angle) * Config.SweepRadius
    local ey = cy + math.sin(angle) * Config.SweepRadius
    local ok, err = DrawLine(canvas, cx, cy, ex, ey, Config.SweepThick, Config.SweepColor)
    if not ok and drawFrameCount == 1 then
        dbg("K2_DrawLine FAILED: %s", tostring(err))
    end
end

-- ---------------------- core logic: class-chain recon --------------------

local function FnNameIsInteresting(name)
    if name:match(Config.FnScanPattern) then return true end
    for _, pat in ipairs(Config.FnScanExtra) do
        if name:match(pat) then return true end
    end
    return false
end

--- Forward decl — hook targets defined in section 6 need TryHookPath here.
local OnReceiveDrawHUD

local function TryHookPath(path)
    if triedHookPaths[path] then return end
    local ok, err = pcall(RegisterHook, path, function(...) OnReceiveDrawHUD(...) end)
    triedHookPaths[path] = ok and "BOUND" or "failed"
    dbg("hook %s : %s", path, ok and "BOUND" or ("failed — " .. tostring(err)))
end

--- Walk the live HUD's class chain. At each level: (a) try binding
--- ReceiveDrawHUD on the concrete class path — a BP-implemented event only
--- fires through its class's own bytecode, never the /Script/Engine stub —
--- and (b) list draw/render-flavored UFunctions as alternate hook doors.
local function ProbeHudClassChain(hud)
    local ok, cls = pcall(function() return hud:GetClass() end)
    if not ok or not cls or not cls:IsValid() then
        dbg("class-chain probe: HUD class unreadable")
        return
    end

    while cls and cls:IsValid() do
        local clsPath = ObjectPathOf(cls)
        if clsPath and not scannedClasses[clsPath] then
            scannedClasses[clsPath] = true
            dbg("---- class-chain: %s ----", clsPath)

            TryHookPath(clsPath .. ":ReceiveDrawHUD")

            local okScan = pcall(function()
                cls:ForEachFunction(function(fn)
                    local name = FnNameOf(fn)
                    if FnNameIsInteresting(name) then
                        dbg("  fn: %s", name)
                    end
                    return false -- keep iterating
                end)
            end)
            if not okScan then dbg("  (ForEachFunction unavailable on this build)") end
        end

        local okS, super = pcall(function() return cls:GetSuperStruct() end)
        cls = (okS and super) or nil
    end
end

--- PostRender gates DrawHUD (and thus every ReceiveDrawHUD) on bShowHUD.
local function ForceShowHUD(hud)
    if not Config.ForceShowHUD then return end
    local shown = ReadOpt(hud, "bShowHUD")
    if shown == false then
        local ok = pcall(function() hud.bShowHUD = true end)
        if not showHudForced then
            showHudForced = true
            dbg("bShowHUD was FALSE -> forced true : %s (this gate alone silences DrawHUD)",
                ok and "OK" or "WRITE FAILED")
        end
    elseif not showHudForced then
        showHudForced = true
        dbg("bShowHUD already %s — the gate is not the blocker", tostring(shown))
    end
end

-- ---------------------- core logic: watchdog diagnostics -----------------

--- Fires only while every draw hook is silent.
local function ReportDrawPathState()
    dbg("---- watchdog: fired %d draw frame(s) ----", drawFrameCount)

    local hud = FindFirstOf("HUD")
    if not hud or not hud:IsValid() then
        dbg("  NO HUD actor found — nothing can draw without one.")
        return
    end

    ForceShowHUD(hud)
    ProbeHudClassChain(hud)

    dbg("  bShowHUD=%s bShowDebugInfo=%s",
        tostring(ReadOpt(hud, "bShowHUD")), tostring(ReadOpt(hud, "bShowDebugInfo")))
end

-- ---------------------- hooks --------------------------------------------

--- Shared target for every ReceiveDrawHUD-shaped hook (engine stub + each
--- concrete class binding). Multiple bound paths can alias the same call;
--- draw work is idempotent so double-fire per frame is cosmetic only.
OnReceiveDrawHUD = function(Context, SizeX, SizeY)
    local hud = Context:get()
    if not hud or not hud:IsValid() then return end

    local canvas = ReadOpt(hud, "Canvas")
    if not canvas or not canvas:IsValid() then
        if drawFrameCount == 0 then dbg("draw event fired but HUD.Canvas invalid") end
        return
    end

    drawFrameCount = drawFrameCount + 1
    local okX, sx = pcall(function() return SizeX:get() end)
    local okY, sy = pcall(function() return SizeY:get() end)
    sx = (okX and type(sx) == "number" and sx) or ReadOpt(canvas, "SizeX") or 1920
    sy = (okY and type(sy) == "number" and sy) or ReadOpt(canvas, "SizeY") or 1080

    if not firstDrawDumped then
        firstDrawDumped = true
        DumpDrawContext(hud, canvas, sx, sy)
    end

    DrawProbeFrame(canvas, sx, sy)
end

local function OnControllerTick(Context, DeltaSeconds)
    -- Watchdog only has a job while the draw path is unproven.
    if drawFrameCount > 0 then return end
    local ok, dt = pcall(function() return DeltaSeconds:get() end)
    watchdogTimer = watchdogTimer + ((ok and dt) or 0.0083)
    if watchdogTimer >= Config.WatchdogPeriod then
        watchdogTimer = 0.0
        ReportDrawPathState()
    end
end

-- ---------------------- lifetime / registration --------------------------

local function BindTickHook()
    if tickHookBound then return end
    local ok, err = pcall(RegisterHook, Config.TickHookPath, OnControllerTick)
    tickHookBound = ok
    if not ok then dbg("watchdog tick hook pending: %s", tostring(err)) end
end

dbg("loaded — pass 2: force bShowHUD + class-chain hooks")
TryHookPath(Config.EngineDrawHookPath)

-- BP controller class may not be loaded yet at mod init; (re)bind when the
-- player pawn constructs, and immediately on hot-reload mid-session.
NotifyOnNewObject("/Script/Pal.PalPlayerCharacter", function()
    BindTickHook()
end)

ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then
        BindTickHook()
        ReportDrawPathState() -- immediate pass on hot-reload
    end
end)
