---@diagnostic disable: inject-field, need-check-nil, undefined-field, undefined-global
-- =========================================================================
-- CanvasProbe — real-time UCanvas drawing, CONFIRMED
-- author  = TheTr3y
-- version = 0.3.0
-- date    = 2026-09-01
--
-- FINDINGS (pass 2, 2026-09-01) — the door for all future screen drawing:
--   * Palworld's HUD Blueprint IMPLEMENTS ReceiveDrawHUD. Hooking the
--     concrete class path fires every frame:
--         /Game/Pal/Blueprint/UI/BP_PalHUD_InGame.BP_PalHUD_InGame_C:ReceiveDrawHUD
--     The engine stub /Script/Engine.HUD:ReceiveDrawHUD binds but never
--     fires — a BP-implemented event executes through its class's own
--     bytecode, so the hook must target the BP class path.
--   * During the event, Context (the HUD actor) .Canvas is a live UCanvas
--     (/Engine/Transient.CanvasObject) and K2_DrawLine works. FVector2D
--     marshals as {X=,Y=}, FLinearColor as {R=,G=,B=,A=}.
--   * bShowHUD was already true; forcing it was NOT the fix. Class chain:
--     BP_PalHUD_InGame_C -> /Script/Pal.PalHUDInGame -> /Script/Engine.HUD.
--   * SizeX/SizeY params carry the real viewport size (3840x2160 confirmed).
--
-- This pass strips the recon scaffolding down to the proven path plus one
-- resilience concern: the HUD BP class can be GC'd and reloaded on world
-- travel, which silently kills a bytecode hook. A lightweight tick
-- watchdog notices draw silence after previous success and rebinds.
--
-- DRAWS: green crosshair at screen center + magenta sweep line (per-frame
-- update proof).
-- =========================================================================

local UEHelpers = require("UEHelpers")

local DEBUG_PRINT = true

-- ---------------------- tuning / configuration ---------------------------

local Config = {
    DrawHookPath   = "/Game/Pal/Blueprint/UI/BP_PalHUD_InGame.BP_PalHUD_InGame_C:ReceiveDrawHUD",
    HudNativeClass = "/Script/Pal.PalHUDInGame",   -- construction signal for (re)binding
    TickHookPath   = "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick",

    CrosshairSize  = 14.0,                                  -- px, half-extent
    CrosshairColor = { R = 0.1, G = 1.0, B = 0.2, A = 1.0 },
    CrosshairThick = 2.0,

    SweepRadius    = 120.0,                                 -- px
    SweepSpeed     = 2.0,                                   -- rad/s
    SweepColor     = { R = 1.0, G = 0.1, B = 0.9, A = 1.0 },
    SweepThick     = 3.0,

    SilenceRebind  = 5.0,   -- s of draw silence (after success) before rebinding
}

-- ---------------------- state & cache ------------------------------------

local drawHookBound   = false
local drawFrameCount  = 0
local firstDrawDumped = false
local lastDrawClock   = nil     -- os.clock() of most recent draw frame
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

local function FirstLine(s)
    s = tostring(s)
    return s:match("^[^\r\n]*") or s
end

-- ---------------------- core logic: drawing ------------------------------

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
        dbg("K2_DrawLine FAILED: %s", FirstLine(err))
    end
end

-- ---------------------- hooks --------------------------------------------

local function OnReceiveDrawHUD(Context, SizeX, SizeY)
    local hud = Context:get()
    if not hud or not hud:IsValid() then return end

    local canvas = ReadOpt(hud, "Canvas")
    if not canvas or not canvas:IsValid() then return end

    drawFrameCount = drawFrameCount + 1
    lastDrawClock  = os.clock()

    local okX, sx = pcall(function() return SizeX:get() end)
    local okY, sy = pcall(function() return SizeY:get() end)
    sx = (okX and type(sx) == "number" and sx) or ReadOpt(canvas, "SizeX") or 1920
    sy = (okY and type(sy) == "number" and sy) or ReadOpt(canvas, "SizeY") or 1080

    if not firstDrawDumped then
        firstDrawDumped = true
        dbg("drawing live: %s (%dx%d)", Config.DrawHookPath, sx, sy)
    end

    DrawProbeFrame(canvas, sx, sy)
end

-- ---------------------- lifetime / registration --------------------------

local function BindDrawHook(context)
    if drawHookBound then return end
    local ok, err = pcall(RegisterHook, Config.DrawHookPath, OnReceiveDrawHUD)
    drawHookBound = ok
    dbg("draw hook (%s): %s", context, ok and "BOUND" or ("pending — " .. FirstLine(err)))
end

--- World travel can GC-reload the HUD BP class, silently killing the
--- bytecode hook. Draw silence after previous success = stale hook; mark
--- unbound so the next construction/tick pass rebinds.
local function OnControllerTick()
    if not (drawHookBound and lastDrawClock) then return end
    if os.clock() - lastDrawClock > Config.SilenceRebind then
        dbg("draw silent %.0fs after success — assuming class reload, rebinding", Config.SilenceRebind)
        drawHookBound = false
        lastDrawClock = nil
        BindDrawHook("silence recovery")
    end
end

local function BindTickHook()
    if tickHookBound then return end
    local ok = pcall(RegisterHook, Config.TickHookPath, OnControllerTick)
    tickHookBound = ok
end

dbg("loaded — confirmed draw door: %s", Config.DrawHookPath)
BindDrawHook("mod load")

-- HUD/controller BP classes may not be loaded at mod init; a fresh HUD
-- constructing is the exact moment its class (re)exists to hook.
NotifyOnNewObject(Config.HudNativeClass, function()
    BindDrawHook("HUD constructed")
    BindTickHook()
end)

ExecuteInGameThread(function()
    local ok, p = pcall(function() return UEHelpers.GetPlayer() end)
    if ok and p and p:IsValid() then
        BindDrawHook("mid-session load")
        BindTickHook()
    end
end)
