-- =========================================================================
-- PalFeel subsystem: slide — momentum-based sliding
--
-- Field model (from the UPalCharacterMovementComponent dump):
--   SlidingStartSpeed  : speed set on slide entry
--   bUseCurrentSpeedIfOverSlidingStartSpeed :
--       false (suspected vanilla) = entering faster than StartSpeed CLAMPS
--       you down to it — the momentum killer. true = keep current speed.
--   SlidingMaxSpeed    : slide speed ceiling
--   SlidingAddRate / SlidingSubRate : build / decay rates
--       (longer slides = lower SubRate)
--   bUseSlidingAddValue/SlidingAddValue, bUseSlidingSubValue/SlidingSubValue :
--       alternate flat-value modes; exact semantics unknown — experiment
--   SlidingYawRate     : steering rate while sliding (carve control)
--   bIsEnableSkySliding: slide state surviving loss of ground (experiment)
--
-- First run: prints every vanilla value (including both flags' startup
-- state), then applies non-nil overrides. Slide once to learn the custom
-- movement mode ID — needed later for the slide-jump push.
-- =========================================================================

-- nil = leave vanilla. Both experiment flags enabled per current test plan.
local OVERRIDES = {
    { "bUseCurrentSpeedIfOverSlidingStartSpeed", true },  -- experiment 1
    { "bIsEnableSkySliding",                     true },  -- experiment 2
    { "SlidingStartSpeed",  nil },   -- vanilla 500 (slow entries snap UP to this)
    { "SlidingMaxSpeed",    1200 },   -- vanilla 1500
    { "SlidingAddRate",     2 },   -- vanilla 2.0 (build; raise for downhill snowball)
    { "SlidingSubRate",     0.65 },  -- vanilla 1.0; duration ~ 1/SubRate => ~2.2x longer
    { "SlidingYawRate",     0.05 },  -- vanilla 0.01 (rail-straight); step 0.03/0.06/0.10
    { "bUseSlidingAddValue", nil },
    { "SlidingAddValue",     nil },
    { "bUseSlidingSubValue", nil },
    { "SlidingSubValue",     nil },
}

local DEBUG = true

local M = { name = "slide" }

local lastMode, lastCustom = nil, nil

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:slide] " .. fmt .. "\n", ...)) end
end

local function ReadOpt(cmc, prop)
    local ok, v = pcall(function() return cmc[prop] end)
    if not ok then return "<unreadable>" end
    return tostring(v)
end

function M.OnPlayerCached(pawn, cmc)
    if true then return end
    dbg("---- vanilla sliding values ----")
    for _, o in ipairs(OVERRIDES) do
        dbg("  %-42s = %s", o[1], ReadOpt(cmc, o[1]))
    end
    dbg("--------------------------------")
    for _, o in ipairs(OVERRIDES) do
        if o[2] ~= nil then
            local ok, err = pcall(function() cmc[o[1]] = o[2] end)
            if ok then dbg("override: %s -> %s", o[1], tostring(o[2]))
            else dbg("WRITE FAILED for %s: %s", o[1], tostring(err)) end
        end
    end
    lastMode, lastCustom = nil, nil
end

function M.OnTick(dt, pawn, cmc)
    if true then return end
    if not DEBUG then return end
    -- Movement-mode transition watcher: identifies the slide's custom-mode
    -- enum value (and glide/climb IDs as a side effect) for later phases.
    local mode = cmc.MovementMode
    local custom = 0
    pcall(function() custom = cmc.CustomMovementMode end)
    if mode ~= lastMode or custom ~= lastCustom then
        dbg("movement mode %d (custom %d)", mode, custom)
        lastMode, lastCustom = mode, custom
    end
end

return M