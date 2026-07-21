-- =========================================================================
-- PalFeel helper: jumpkey — engine-level jump-button state, device-agnostic
--
-- Why polling: the CXX dump shows APalPlayerController exposes
-- OnPressedJumpDelegate but no released counterpart (other buttons get
-- press/release delegate pairs; jump does not), so the game broadcasts no
-- event for the release edge. PlayerController:IsInputKeyDown reads the
-- engine's PlayerInput key state directly — beneath game bindings,
-- identical for keyboard and gamepad — so a per-tick edge detector is the
-- reliable route.
--
-- Usage, once per tick, BEFORE any early-outs (the edge state lives in
-- this module; skipping ticks delays edges into the next Poll call):
--   local down, pressed, released = JumpKey.Poll()
--
-- Semantics: 'down' is the OR of every listed key. 'released' is true for
-- exactly one tick — the first on which all listed keys are up after at
-- least one was down. Holding keyboard and pad simultaneously therefore
-- releases only when both are up, which is the correct behavior for a
-- jump-cut input.
-- =========================================================================

local UEHelpers = require("UEHelpers")

local M = {}

-- Keys treated as "the jump button" (engine EKeys names). Edit if jump is
-- rebound in-game; resolving these dynamically from the Enhanced Input
-- mappings is possible later but needs the IA_Jump asset path first.
local KEY_NAMES = {
    "SpaceBar",                   -- keyboard
    "Gamepad_FaceButton_Bottom",  -- south button (A / Cross)
}

local keys = nil          -- FKey structs (as tables), built once
local pc = nil            -- cached local player controller
local wasDown = false
local callFailed = false  -- log only the first hard failure

local function EnsureKeys()
    if keys then return end
    keys = {}
    for i, name in ipairs(KEY_NAMES) do
        keys[i] = { KeyName = FName(name) }   -- FKey's sole member
    end
end

local function EnsurePC()
    if pc and pc:IsValid() then return true end
    local ok, c = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and c and c:IsValid() then
        pc = c
        return true
    end
    return false
end

function M.Poll()
    EnsureKeys()
    if not EnsurePC() then return false, false, false end

    local down = false
    for _, k in ipairs(keys) do
        local ok, d = pcall(function() return pc:IsInputKeyDown(k) end)
        if ok then
            if d then
                down = true
                break
            end
        elseif not callFailed then
            callFailed = true
            print(string.format(
                "[PalFeel:jumpkey] IsInputKeyDown call failed"
                .. " (FKey-as-table unsupported on this UE4SS build?): %s\n",
                tostring(d)))
        end
    end

    local pressed  = down and not wasDown
    local released = wasDown and not down
    wasDown = down
    return down, pressed, released
end

return M
