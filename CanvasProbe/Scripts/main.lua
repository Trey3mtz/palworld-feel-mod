---@diagnostic disable: inject-field, need-check-nil, undefined-field, undefined-global
-- =========================================================================
-- CanvasProbe — real-time UCanvas drawing feasibility probe
-- author  = TheTr3y
-- version = 0.1.0
-- date    = 2026-08-11
--
-- GOAL: prove we can draw to the screen every frame from UE4SS Lua.
--
-- WHY NOT "OnTick"?  A UCanvas is only valid while the engine is inside its
-- HUD draw pass. Outside that window the object exists but its render
-- context is gone (draws no-op or crash). So instead of hooking a tick and
-- "finding our way" to a canvas, we hook the draw pass itself:
--
--   /Script/Engine.HUD:ReceiveDrawHUD   (fires once per frame, per HUD)
--
-- The hooked Context IS the AHUD actor, and during this event its `Canvas`
-- property is a live UCanvas — that is the object carrying K2_DrawLine
-- (offset 0x5861050, Final|Native|Public|BlueprintCallable).
--
-- ReceiveDrawHUD is a BlueprintImplementableEvent: it only *fires* if the
-- game's HUD class actually implements/receives it. Unknown for Palworld,
-- hence this probe. A tick-based watchdog (on the proven
-- BP_PalPlayerController:ReceiveTick path) reports every 5s whether the
-- draw hook has fired, what HUD actor exists, and what Canvas objects are
-- alive — so a failed run still tells us exactly which door to try next.
--
-- WHAT IT DRAWS when the hook fires:
--   * a green crosshair at screen center            (static reference)
--   * a magenta line sweeping around the center     (proves per-frame update)
-- =========================================================================

local UEHelpers = require("UEHelpers")

local DEBUG_PRINT = true

-- ---------------------- tuning / configuration ---------------------------

local Config = {
    DrawHookPath   = "/Script/Engine.HUD:ReceiveDrawHUD",
    TickHookPath   = "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick",

    CrosshairSize  = 14.0,                                  -- px, half-extent
    CrosshairColor = { R = 0.1, G = 1.0, B = 0.2, A = 1.0 },
    CrosshairThick = 2.0,

    SweepRadius    = 120.0,                                 -- px
    SweepSpeed     = 2.0,                                   -- rad/s
    SweepColor     = { R = 1.0, G = 0.1, B = 0.9, A = 1.0 },
    SweepThick     = 3.0,

    WatchdogPeriod = 5.0,                                   -- s between reports
}

-- ---------------------- state & cache ------------------------------------

local drawHookBound   = false   -- RegisterHook succeeded
local drawFrameCount  = 0       -- times ReceiveDrawHUD fired
local firstDrawDumped = false   -- one-shot success diagnostics
local sweepAngle      = 0.0
local watchdogTimer   = 0.0
local tickHookBound   = false

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

-- ---------------------- core logic: drawing ------------------------------

--- One-shot dump the moment we hold a live canvas, so the log records the
--- exact class/name we should target in future mods.
local function DumpDrawContext(hud, canvas, sizeX, sizeY)
    dbg("==== FIRST DRAW FRAME — the door is open ====")
    dbg("  HUD    : %s", FullNameOf(hud))
    dbg("  Canvas : %s", FullNameOf(canvas))
    dbg("  Size   : %d x %d", sizeX, sizeY)
    dbg("  Canvas.SizeX/SizeY : %s / %s",
        tostring(ReadOpt(canvas, "SizeX")), tostring(ReadOpt(canvas, "SizeY")))
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
    sweepAngle = (os.clock() * Config.SweepSpeed) % (2 * math.pi)
    local ex = cx + math.cos(sweepAngle) * Config.SweepRadius
    local ey = cy + math.sin(sweepAngle) * Config.SweepRadius
    local ok, err = DrawLine(canvas, cx, cy, ex, ey, Config.SweepThick, Config.SweepColor)
    if not ok and drawFrameCount == 1 then
        dbg("K2_DrawLine FAILED: %s", tostring(err))
    end
end

-- ---------------------- core logic: watchdog diagnostics -----------------

--- Fires only while the draw hook is silent. Answers, from live objects:
--- does a HUD exist, what class is it, and are any UCanvas objects alive?
local function ReportDrawPathState()
    dbg("---- watchdog: draw hook %s, fired %d frame(s) ----",
        drawHookBound and "BOUND" or "NOT BOUND", drawFrameCount)

    local hud = FindFirstOf("HUD")
    if hud and hud:IsValid() then
        dbg("  HUD actor exists : %s", FullNameOf(hud))
        dbg("  HUD.Canvas       : %s", tostring(ReadOpt(hud, "Canvas")))
    else
        dbg("  NO HUD actor found — ReceiveDrawHUD can never fire without one.")
    end

    local okAll, canvases = pcall(function() return FindAllOf("Canvas") end)
    if okAll and canvases then
        dbg("  live UCanvas objects: %d", #canvases)
        for i, c in ipairs(canvases) do
            if i <= 4 then dbg("    [%d] %s", i, FullNameOf(c)) end
        end
    else
        dbg("  live UCanvas objects: none found")
    end

    if drawHookBound and drawFrameCount == 0 then
        dbg("  hook is bound but silent -> Palworld's HUD likely never invokes")
        dbg("  ReceiveDrawHUD. Next doors: RegisterHook on the concrete HUD")
        dbg("  subclass's DrawHUD path, or a UDebugDrawService route.")
    end
end

-- ---------------------- hooks --------------------------------------------

local function OnReceiveDrawHUD(Context, SizeX, SizeY)
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
    sx = (okX and sx) or ReadOpt(canvas, "SizeX") or 1920
    sy = (okY and sy) or ReadOpt(canvas, "SizeY") or 1080

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

local function BindDrawHook()
    if drawHookBound then return end
    local ok, err = pcall(RegisterHook, Config.DrawHookPath, OnReceiveDrawHUD)
    drawHookBound = ok
    dbg("draw hook (%s): %s", Config.DrawHookPath, ok and "BOUND" or ("FAILED — " .. tostring(err)))
end

local function BindTickHook()
    if tickHookBound then return end
    local ok, err = pcall(RegisterHook, Config.TickHookPath, OnControllerTick)
    tickHookBound = ok
    if not ok then dbg("watchdog tick hook pending: %s", tostring(err)) end
end

dbg("loaded — probing for a real-time draw path")
BindDrawHook()

-- BP controller class may not be loaded yet at mod init; (re)bind when the
-- player pawn constructs, and immediately on hot-reload mid-session.
NotifyOnNewObject("/Script/Pal.PalPlayerCharacter", function()
    BindDrawHook()
    BindTickHook()
end)

ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then BindTickHook() end
end)
