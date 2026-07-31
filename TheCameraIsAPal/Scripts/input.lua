-- =========================================================================
-- input.lua — raw input read (gamepad stick + WASD keyboard, camera-independent)
--
-- WHY THIS EXISTS
-- cmc.Acceleration is not an input source. It is the *result* of
-- AddMovementInput, which the controller builds by rotating the stick
-- vector into world space using the control rotation. Anything downstream
-- of that is camera-relative by construction, and no amount of correction
-- at that layer removes the dependency.
--
-- UPlayerInput::KeyStateMap is upstream of all of it. The engine writes the
-- analog value for each axis key and digital key state there as reported,
-- before any axis mapping, before any basis rotation, and independently of
-- whether gameplay code consumes it that frame.
--
-- FKey marshals from a table keyed by KeyName; built once, not per frame.
-- =========================================================================

local UEHelpers = require("UEHelpers")

local M = { name = "input" }

-- Static FKey tables (Built ONCE at file initialization to ensure 0 GC per frame)
local KEY_STICK_X = { KeyName = FName("Gamepad_LeftX") }
local KEY_STICK_Y = { KeyName = FName("Gamepad_LeftY") }

local KEY_W       = { KeyName = FName("W") }
local KEY_A       = { KeyName = FName("A") }
local KEY_S       = { KeyName = FName("S") }
local KEY_D       = { KeyName = FName("D") }

local STICK_DEADZONE = 0.10

local DEBUG          = false

-- Pre-calculated 1 / sqrt(2) constant for zero-allocation WASD diagonal normalization
local INV_SQRT_2     = 0.7071067811865475

local playerController = nil

-- This frame's sample. Deadzoned and rescaled; Y is positive-up (forward).
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

-- Synthesizes raw WASD key states into a normalized [-1, 1] 2D vector
local function ReadWASD()
    local w = ReadAxis(KEY_W)
    local s = ReadAxis(KEY_S)
    local a = ReadAxis(KEY_A)
    local d = ReadAxis(KEY_D)

    local x = d - a -- Right (+X), Left (-X)
    local y = w - s -- Forward (+Y), Backward (-Y)

    -- Normalize diagonal WASD input to prevent moving ~41.4% faster diagonally
    if x ~= 0 and y ~= 0 then
        x = x * INV_SQRT_2
        y = y * INV_SQRT_2
    end

    return x, y
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

    -- 1. Sample Gamepad Analog Left Stick
    local padX = ReadAxis(KEY_STICK_X)
    local padY = ReadAxis(KEY_STICK_Y)

    -- 2. Sample Keyboard WASD Vector
    local kbX, kbY = ReadWASD()

    -- 3. Combine inputs
    local rawX = padX + kbX
    local rawY = padY + kbY

    -- 4. Clamp combined vector length to unit circle (1.0)
    local rawMagSq = rawX * rawX + rawY * rawY
    if rawMagSq > 1.0 then
        local rawMag = math.sqrt(rawMagSq)
        rawX = rawX / rawMag
        rawY = rawY / rawMag
    end

    -- 5. Process radial deadzone & output
    stickX, stickY, stickMagnitude = ApplyRadialDeadzone(rawX, rawY)

    -- Log only while input is active
    local stickIsDeflected = stickMagnitude > 0
    if DEBUG and stickIsDeflected then
        dbg("raw=(%+.3f, %+.3f) -> vector=(%+.3f, %+.3f) mag=%.3f",
            rawX, rawY, stickX, stickY, stickMagnitude)
    end
end

-- ---------------------------- public API ---------------------------------

--- This frame's raw movement deflection (Gamepad stick or WASD keys).
--- X is Right (+1) / Left (-1), Y is Forward (+1) / Backward (-1),
--- magnitude is in [0, 1]. Camera-independent.
function M.GetStick()
    return stickX, stickY, stickMagnitude
end

function M.HasStickInput()
    return stickMagnitude > 0
end

return M
