-- =========================================================================
-- TheCameraIsAPal module: holsterlink — the HelpfulHolster connection
--
-- Primary source: the shared variable "HelpfulHolster_IsHolstered",
-- published by HelpfulHolster's bridge file (which calls its own public
-- IsHolstered() inside its Lua state and broadcasts the result). UE4SS
-- shared variables are the sanctioned cross-mod channel: functions cannot
-- cross mod boundaries, values can.
--
-- Fallback: if HelpfulHolster is absent or has not published yet, the game
-- property (LoadoutSelectorComponent.currentItemSlotIndex < 0) is used —
-- the same ground truth IsHolstered() is built on.
--
-- The active source is logged whenever it changes, so the UE4SS log shows
-- explicitly whether the bridge is live.
-- =========================================================================

local SHARED_NAME = "HelpfulHolster_IsHolstered"

local M = {}

local activeSource = nil    -- "bridge" | "property"

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:holsterlink] " .. fmt .. "\n", ...))
end

local function Announce(source)
    if activeSource == source then return end
    activeSource = source
    if source == "bridge" then
        dbg("bridge active: using HelpfulHolster.IsHolstered() via shared variable")
    else
        dbg("bridge not detected: falling back to game property (currentItemSlotIndex)")
    end
end

function M.IsHolstered(ctx)
    local ok, v = pcall(function()
        return ModRef:GetSharedVariable(SHARED_NAME)
    end)
    if ok and type(v) == "boolean" then
        Announce("bridge")
        return v
    end

    Announce("property")
    local h = false
    if ctx.loadout and ctx.loadout:IsValid() then
        pcall(function() h = ctx.loadout.currentItemSlotIndex < 0 end)
    end
    return h
end

return M
