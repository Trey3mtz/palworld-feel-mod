-- =========================================================================
-- input.lua — raw left-thumbstick read (camera-independent)
--
-- WHY THIS EXISTS
-- cmc.Acceleration is not an input source. It is the *result* of
-- AddMovementInput, which the controller builds by rotating the stick
-- vector into world space using the control rotation. Anything downstream
-- of that is camera-relative by construction, and no amount of correction
-- at that layer removes the dependency.
--
-- UPlayerInput::KeyStateMap is upstream of all of it. The engine writes the
-- analog value for each axis key there as the device reports it, before any
-- axis mapping, before any basis rotation, and independently of whether
-- gameplay code consumes it that frame. APlayerController exposes that map
-- through GetInputAnalogKeyState, which is BlueprintCallable and therefore
-- reachable from UE4SS.
--
-- Consequences worth knowing before wiring this into anything:
--   * Keyboard reads 0. Gamepad_LeftX/Y populate only from a pad.
--   * KeyStateMap holds the RAW value. The game's configured deadzone is
--     applied later, during axis-mapping processing, so it is absent here.
--     The deadzone below is therefore not optional.
--   * Because the read bypasses gameplay, gameplay cannot suppress it:
--     these values stay populated in movement modes where Acceleration
--     does not.
--
-- Register BEFORE any subsystem that consumes it — main.lua ticks
-- subsystems in list order, and OnTick is what refreshes the sample.
-- =========================================================================

local UEHelpers = require("UEHelpers")

local M = { name = "input" }

-- FKey marshals from a table keyed by KeyName; built once, not per frame.
local KEY_STICK_X = { KeyName = FName("Gamepad_LeftX") }
local KEY_STICK_Y = { KeyName = FName("Gamepad_LeftY") }

local STICK_DEADZONE = 0.10

local DEBUG      = false


local playerController = nil

-- This frame's sample. Deadzoned and rescaled; Y is positive-up.
local stickX, stickY, stickMagnitude = 0, 0, 0

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel/input] " .. fmt .. "\n", ...)) end
end

-- ---------------------------- controller access --------------------------

local function CacheController()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if not ok or not pc or not pc:IsValid() then return false end
    playerController = pc
    return true
end

local function ValidController()
    if playerController and playerController:IsValid() then return true end
    return CacheController()
end

-- ---------------------------- sampling -----------------------------------

local function ReadAxis(key)
    local readOk, value = pcall(function()
        return playerController:GetInputAnalogKeyState(key)
    end)

    local gotUsableNumber = readOk and type(value) == "number"
    if not gotUsableNumber then return 0 end
    return value
end

-- Radial rather than per-axis: a per-axis deadzone squares off the neutral
-- region, so a diagonal barely off centre passes on both axes at once.
-- Rescaling means the first frame past the threshold reads near 0 instead
-- of snapping to STICK_DEADZONE.
local function ApplyRadialDeadzone(rawX, rawY)
    local rawMagnitude = math.sqrt(rawX * rawX + rawY * rawY)

    local insideDeadzone = rawMagnitude < STICK_DEADZONE
    if insideDeadzone then return 0, 0, 0 end

    local clampedMagnitude = math.min(rawMagnitude, 1.0)
    local scaledMagnitude =
        (clampedMagnitude - STICK_DEADZONE) / (1.0 - STICK_DEADZONE)

    local directionX = rawX / rawMagnitude
    local directionY = rawY / rawMagnitude

    return directionX * scaledMagnitude,
           directionY * scaledMagnitude,
           scaledMagnitude
end

-- ---------------------------- subsystem contract -------------------------

function M.OnPlayerCached(pawn, cmc)
    playerController = nil
    CacheController()
end

function M.OnTick(dt, pawn, cmc)
    if not ValidController() then
        stickX, stickY, stickMagnitude = 0, 0, 0
        return
    end

    local rawX = ReadAxis(KEY_STICK_X)
    local rawY = ReadAxis(KEY_STICK_Y)

    stickX, stickY, stickMagnitude = ApplyRadialDeadzone(rawX, rawY)

    -- Log only while the stick is actually deflected, to keep the console
    -- usable. Raw values are logged alongside the processed ones so a dead
    -- read is distinguishable from an all-deadzone read.
    local stickIsDeflected = stickMagnitude > 0
    if DEBUG and stickIsDeflected then
        dbg("raw=(%+.3f, %+.3f) -> stick=(%+.3f, %+.3f) mag=%.3f",
            rawX, rawY, stickX, stickY, stickMagnitude)
    end
end

-- ---------------------------- public API ---------------------------------

--- This frame's left-stick deflection. X is stick-right, Y is stick-up,
--- both in [-1, 1]; magnitude is in [0, 1]. No camera term anywhere.
function M.GetStick()
    return stickX, stickY, stickMagnitude
end

function M.HasStickInput()
    return stickMagnitude > 0
end

return M
