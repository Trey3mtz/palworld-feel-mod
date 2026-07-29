-- =========================================================================
-- TheCameraIsAPal: log — one gate, one formatting path
--
-- Replaces the eight hand-rolled dbg() copies, seven of which had NO debug
-- gate at all and ran string.format unconditionally on the hot path. Every
-- logger built here early-returns BEFORE string.format, so a disabled
-- channel costs one table lookup and allocates nothing.
--
--   local dbg = Log.Make("rig", "rig")   -- tag, optional gate channel
--   dbg("arm=%.0f", arm)
--
-- Channel gating is config-driven (config.log.channels). A channel with no
-- entry defaults to ON, so a new logger is visible until you decide to mute
-- it. Loggers are created once at module load and keep working across F10
-- reloads because they read the shared upvalues below, not a captured copy.
-- =========================================================================

local M = {}

local enabled  = true
local channels = {}

-- ------------------------------ config -----------------------------------

--- Called by main.lua on load and on every F10 reload.
function M.RefreshConfig(c)
    c = c or {}
    enabled  = (c.enabled ~= false)
    channels = c.channels or {}
end

--- True if a line on `ch` would print. Use to skip expensive log-only work
--- (building a table dump, walking properties) rather than to skip a call.
function M.Enabled(ch)
    if not enabled then return false end
    if ch == nil then return true end
    return channels[ch] ~= false
end

-- ------------------------------ factory ----------------------------------

--- Build a logger. `tag` prefixes the line, `ch` is an optional gate channel.
function M.Make(tag, ch)
    local prefix = "[TheCameraIsAPal:" .. tag .. "] "
    return function(fmt, ...)
        -- Gate first: nothing below this line runs while muted.
        if not enabled then return end
        if ch ~= nil and channels[ch] == false then return end
        local ok, line = pcall(string.format, fmt, ...)
        print(prefix .. (ok and line or ("<bad format: " .. tostring(fmt) .. ">")) .. "\n")
    end
end

--- Ungated logger for load/error lines that must always be visible.
function M.MakeAlways(tag)
    local prefix = "[TheCameraIsAPal:" .. tag .. "] "
    return function(fmt, ...)
        local ok, line = pcall(string.format, fmt, ...)
        print(prefix .. (ok and line or ("<bad format: " .. tostring(fmt) .. ">")) .. "\n")
    end
end

return M
