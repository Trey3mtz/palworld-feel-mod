-- =========================================================================
-- TheCameraIsAPal module: holsterlink — where holster truth comes from
--
-- CURRENT REALITY (verified 2026-07-29): the bridge path is DEAD. Nothing in
-- this project ever calls SetSharedVariable("HelpfulHolster_IsHolstered").
-- HelpfulHolster defines a global IsHolstered() (HelpfulHolster/Scripts/
-- main.lua:88) but never publishes it, so every call here has always fallen
-- through to the game property. The previous header described a publisher
-- file that does not exist.
--
-- The fallback is not a downgrade: LoadoutSelectorComponent
-- .currentItemSlotIndex < 0 is the exact ground truth HelpfulHolster's own
-- IsHolstered() is built on, and reading it directly also catches holstering
-- done through the native weapon palette. The bridge is kept because it is
-- cheap and would become the better source the moment HelpfulHolster
-- publishes — UE4SS shared variables are the sanctioned cross-mod channel
-- (functions cannot cross mod boundaries, values can).
--
-- To activate the bridge, add to HelpfulHolster's main.lua:
--     ModRef:SetSharedVariable("HelpfulHolster_IsHolstered", IsHolstered())
-- wherever its holster state changes. This file will pick it up with no
-- change on our side and log the switch.
--
-- The source is resolved ONCE per cache, not per tick. The old version ran
-- a pcall + GetSharedVariable on the hot path 60 times a second and could
-- print from inside it.
-- =========================================================================

local Log = require("log")

local M = {}

local SHARED_NAME = "HelpfulHolster_IsHolstered"

local dbg = Log.MakeAlways("holsterlink")

local useBridge = false

--- Re-detect the source. Called from main.lua on each (re)cache, so a
--- HelpfulHolster hot reload is picked up without restarting the game.
function M.Resolve()
    local ok, v = pcall(function()
        return ModRef:GetSharedVariable(SHARED_NAME)
    end)
    local now = (ok and type(v) == "boolean")
    if now ~= useBridge then
        useBridge = now
        if now then
            dbg("source: HelpfulHolster bridge (shared variable)")
        else
            dbg("source: game property (currentItemSlotIndex) -- bridge not published")
        end
    end
    return useBridge
end

--- Holster ground truth. Hot path: no logging, no string work.
function M.IsHolstered(ctx)
    if useBridge then
        local ok, v = pcall(function()
            return ModRef:GetSharedVariable(SHARED_NAME)
        end)
        if ok and type(v) == "boolean" then return v end
        useBridge = false      -- bridge vanished; fall through to the property
    end

    local h = false
    if ctx.loadout and ctx.loadout:IsValid() then
        pcall(function() h = ctx.loadout.currentItemSlotIndex < 0 end)
    end
    return h
end

function M.DumpState(out)
    out("-- holsterlink --")
    out("  source      : %s", useBridge and "HelpfulHolster bridge" or "game property")
end

return M
