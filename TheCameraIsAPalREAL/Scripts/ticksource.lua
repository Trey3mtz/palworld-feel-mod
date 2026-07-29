-- =========================================================================
-- TheCameraIsAPal: ticksource — swappable, measured tick origin
--
-- WHY THIS MODULE EXISTS. Our writes land wherever our hook sits relative to
-- the game's own camera update, and that relative position is the entire
-- jitter question. It is not answerable by argument, only by measurement —
-- so the tick origin is config-selectable and this module reports whether
-- the chosen one actually fires.
--
--   controller_bp    BP_PalPlayerController_C:ReceiveTick
--                    The original. Fires during controller tick, well before
--                    camera evaluation, so Channel C writes are exposed to
--                    everything the game does afterward.
--   manager_bp       BP_PalPlayerCameraManager_C:ReceiveTick
--                    The camera manager's own tick — later in the frame.
--   manager_bp_upd   /Script/Engine.PlayerCameraManager:BlueprintUpdateCamera
--                    Called from inside DoUpdateCamera. If this fires, it is
--                    the best available position: writes land inside camera
--                    evaluation. It is a BlueprintImplementableEvent, so
--                    whether it dispatches through ProcessEvent depends on
--                    whether the Pal BP overrides it — hence "if it fires".
--
-- Switch with config.tick.source + F10, then read the F9 dump: the right
-- source drives rig channel-C stomps toward zero.
--
-- NOT AN OPTION: driving the tick from LoopAsync. UE4SS runs those callbacks
-- off the game thread; touching UObject properties there races the game
-- thread and still cannot guarantee landing after the camera's own update.
-- Write ordering is a frame-graph problem, not a polling-rate problem.
--
-- Hook management follows the pattern proven in HelpfulHolster
-- (HelpfulHolster/Scripts/main.lua:223-253): native paths bind at load, BP
-- paths rebind on pawn construction, and preId/postId tracking means a
-- re-fire or a UE4SS script reload never stacks a second hook on the same
-- path. The old LoopAsync retry loop had no such guard.
-- =========================================================================

local Log = require("log")

local M = {}

local dbg  = Log.Make("ticksrc", "ticksrc")
local warn = Log.MakeAlways("ticksrc")

-- ==== source catalogue ===================================================

local SOURCES = {
    controller_bp = {
        path = "/Game/Pal/Blueprint/Controller/BP_PalPlayerController.BP_PalPlayerController_C:ReceiveTick",
        hasDelta = true,
    },
    manager_bp = {
        path = "/Game/Pal/Blueprint/Camera/BP_PalPlayerCameraManager.BP_PalPlayerCameraManager_C:ReceiveTick",
        hasDelta = true,
    },
    manager_bp_upd = {
        path = "/Script/Engine.PlayerCameraManager:BlueprintUpdateCamera",
        hasDelta = false,     -- no DeltaSeconds param; we time it ourselves
    },
}

-- ==== state ==============================================================

local CFG       = nil
local onTick    = nil        -- function(dt) supplied by main.lua
local active    = nil        -- name of the installed source
local bound     = {}         -- path -> { preId, postId }
local pending   = nil        -- source entry awaiting a retry
local fireCount = 0
local everFired = false
local lastDt    = 1 / 60     -- last-known-good; replaces the old 0.0083 guess
local lastTime  = nil        -- for sources with no DeltaSeconds

-- ==== helpers ============================================================

local function IsNativePath(path)
    return path:sub(1, 8) == "/Script/"
end

--- Resolve the frame delta. Sources that carry DeltaSeconds use it (clamped
--- against load-screen spikes); sources that do not are timed against the
--- OS clock. Either way a bad read falls back to the last good value rather
--- than a hardcoded constant.
local function ResolveDelta(entry, DeltaSeconds)
    local dt
    if entry.hasDelta and DeltaSeconds ~= nil then
        local ok, v = pcall(function() return DeltaSeconds:get() end)
        if ok and type(v) == "number" then dt = v end
    end
    if dt == nil then
        local now = os.clock()
        if lastTime then dt = now - lastTime end
        lastTime = now
    end
    if dt == nil or dt <= 0 or dt ~= dt then return lastDt end
    local clamp = (CFG and CFG.dtClamp) or 0.1
    if dt > clamp then return lastDt end
    lastDt = dt
    return dt
end

local function MakeCallback(entry)
    return function(Context, DeltaSeconds)
        if onTick == nil then return end
        fireCount = fireCount + 1
        if not everFired then
            everFired = true
            dbg("source '%s' is firing", active)
        end
        onTick(ResolveDelta(entry, DeltaSeconds))
    end
end

--- Bind a path once. Returns true if the hook is (or already was) installed.
local function Bind(name, entry, context)
    if bound[entry.path] then return true end
    local ok, preId, postId = pcall(RegisterHook, entry.path, MakeCallback(entry))
    if ok then
        bound[entry.path] = { preId = preId, postId = postId }
        dbg("hook installed (%s): %s", context, name)
        return true
    end
    dbg("hook pending (%s): %s -- %s", context, name, tostring(preId))
    return false
end

-- ==== public API =========================================================

--- Install the configured source. Safe to call repeatedly; already-bound
--- paths are skipped, so pawn respawns and reloads never double-bind.
--- `context` is a short string for the log line.
function M.Install(context)
    if CFG == nil then return end

    local name  = CFG.source
    local entry = SOURCES[name]
    if entry == nil then
        warn("unknown tick source '%s'; falling back to '%s'",
             tostring(name), tostring(CFG.fallback))
        name  = CFG.fallback
        entry = SOURCES[name]
        if entry == nil then
            warn("fallback tick source is also unknown — no tick installed")
            return
        end
    end

    active = name
    if Bind(name, entry, context) then
        pending = nil
    else
        pending = entry
    end
end

--- Retry a source that was not bindable at load (its BP class had not been
--- loaded yet). Called from main.lua on pawn construction / respawn.
function M.Retry(context)
    if pending == nil then return end
    if Bind(active, pending, context) then pending = nil end
end

function M.RefreshConfig(c)
    if c == nil then return end
    local previous = CFG and CFG.source
    CFG = c
    if previous ~= nil and previous ~= CFG.source then
        -- UE4SS gives no way to unregister a hook, so a source switch takes
        -- a game restart. Say so plainly instead of pretending it worked.
        warn("tick source change (%s -> %s) requires a game restart; "
          .. "still running on '%s'", previous, CFG.source, tostring(active))
    end
end

function M.SetHandler(fn)
    onTick = fn
end

function M.DumpState(out)
    out("-- ticksource --")
    out("  active      : %s", tostring(active))
    out("  configured  : %s", CFG and tostring(CFG.source) or "?")
    out("  firing      : %s (%d ticks since last dump)",
        everFired and "yes" or "NO — source never fired", fireCount)
    out("  lastDt      : %.4f s (%.0f fps)", lastDt, lastDt > 0 and 1 / lastDt or 0)
    local n = 0
    for _ in pairs(bound) do n = n + 1 end
    out("  hooks bound : %d%s", n, pending and " (1 pending retry)" or "")
    fireCount = 0
end

return M
