-- =========================================================================
-- PalFeel helper: jumpkey — engine-level jump-button state, device-agnostic
-- =========================================================================

local UEHelpers = require("UEHelpers")

local M = {}

local KEY_NAMES = {
    "SpaceBar",                   
    "Gamepad_FaceButton_Bottom",  
}

local keys = nil          
local pc = nil            
local wasDown = false

local function EnsureKeys()
    if keys then return end
    keys = {}
    for i = 1, #KEY_NAMES do
        keys[i] = { KeyName = FName(KEY_NAMES[i]) } 
    end
end

local function EnsurePC()
    if pc and pc:IsValid() then return true end
    
    local c = UEHelpers.GetPlayerController()
    if c and c:IsValid() then
        pc = c
        return true
    end
    return false
end

function M.Poll()
    EnsureKeys()
    if not EnsurePC() then return false, false, false end

    local down = false
    -- Numeric loop prevents iterator allocation on the heap
    for i = 1, #keys do
        if pc:IsInputKeyDown(keys[i]) then
            down = true
            break
        end
    end

    local pressed  = down and not wasDown
    local released = wasDown and not down
    wasDown = down
    return down, pressed, released
end

return M
