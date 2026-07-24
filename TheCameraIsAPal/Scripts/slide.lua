-- =========================================================================
-- PalFeel subsystem: slide — momentum-based sliding
--
-- Field model (from the UPalCharacterMovementComponent dump):
--   SlidingStartSpeed  : speed set on slide entry
--   bUseCurrentSpeedIfOverSlidingStartSpeed :
--       false (vanilla) = entering faster than StartSpeed CLAMPS you down
--       to it — the momentum killer. true = keep current speed.
--   SlidingMaxSpeed    : slide speed ceiling
--   SlidingAddRate / SlidingSubRate : build / decay rates
--   SlidingYawRate     : steering rate while sliding (carve control)
--   bIsEnableSkySliding: slide state surviving loss of ground
--
-- Boosts (this file's active behaviour):
--   Entry boost  — crouching out of a sprint into a slide adds a horizontal
--                  kick. SlidingSubRate decays hard (measured: ~605 down to
--                  ~400 within a second), so the floor is HELD for a while
--                  and then eased off; a short hold is bled away before it
--                  can be felt.
--   Slide-jump   — jumping out of a live slide adds the same kick. Air is
--                  ballistic (walking.lua disables the global braking-
--                  friction split while falling and zeroes
--                  FallingLateralFriction), so nothing bleeds it mid-arc
--                  and the hold can be short.
--
-- Both are applied as a FLOOR rather than a single write. Our tick may run
-- either side of Palworld's own slide-entry speed assignment, and
-- PhysCustom decays contested writes by ~10-15%/frame, so a one-shot write
-- is a race. A floor is ordering-independent and never clamps down a
-- naturally faster slide (downhill SlidingAddRate build).
--
-- Movement modes:  6 = MOVE_Custom;  custom 2 = Sprint, 3 = Sliding
--                  3 = MOVE_Falling
-- =========================================================================

-- nil = leave vanilla.
local OVERRIDES = {
    { "bUseCurrentSpeedIfOverSlidingStartSpeed", true },
    { "bIsEnableSkySliding",                     true },
    { "SlidingStartSpeed",  nil },   -- vanilla 500 (slow entries snap UP to this)
    { "SlidingMaxSpeed",    1200 },  -- vanilla 1500
    { "SlidingAddRate",     2 },     -- vanilla 2.0 (build; raise for downhill snowball)
    { "SlidingSubRate",     0.65 },  -- vanilla 1.0; duration ~ 1/SubRate
    { "SlidingYawRate",     0.05 },  -- vanilla 0.01 (rail-straight)
    { "bUseSlidingAddValue", nil },
    { "SlidingAddValue",     nil },
    { "bUseSlidingSubValue", nil },
    { "SlidingSubValue",     nil },
}

-- ---- boosts ----
-- ADD is flat uu/s so the kick reads the same regardless of entry speed.
-- MULT is available if you want fast entries rewarded more than slow ones.
-- 250 on a 605 entry is ~40%, comfortably above the ~20% needed for a speed
-- change to register at all.
local ENTRY_BOOST_MULT = 1.00
local ENTRY_BOOST_ADD  = 50
local ENTRY_HOLD       = 0.40   -- s the floor is held flat (beats SubRate decay)
local ENTRY_RELEASE    = 0.35   -- s easing the floor away afterwards

local JUMP_BOOST_MULT  = 1.00
local JUMP_BOOST_ADD   = 250
local JUMP_HOLD        = 0.10   -- air is ballistic; the write just has to land
local JUMP_RELEASE     = 0.10

local BOOST_CEILING    = 1000   -- keep in step with SlidingMaxSpeed
local BOOST_MIN_SPEED  = 120    -- no kick out of a standstill crouch
local JUMP_VZ_MIN      = 150    -- separates a jump from walking off a ledge
local JUMP_GRACE       = 0.12   -- s after slide ends that a jump still counts

local DEBUG = true

local M = { name = "slide" }

local lastMode, lastCustom = nil, nil
local sliding      = false
local sinceSlide   = math.huge   -- s since the slide ended
local boostT       = 0           -- elapsed time in the current boost
local boostHold    = 0
local boostRelease = 0
local boostTarget  = 0

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:slide] " .. fmt .. "\n", ...)) end
end

-- Must not collapse a legitimate `false` to nil.
local function ReadOpt(cmc, prop)
    local ok, v = pcall(function() return cmc[prop] end)
    if not ok then return nil end
    return v
end

local function Speed2D(v)
    return math.sqrt(v.X * v.X + v.Y * v.Y)
end

-- Arm a boost: capture the target once, then let OnTick hold it as a floor
-- for `hold` seconds and ease it away over `release`.
local function ArmBoost(spd, mult, add, hold, release, label)
    if spd < BOOST_MIN_SPEED then
        dbg("%s skipped (spd %.0f < %.0f)", label, spd, BOOST_MIN_SPEED)
        return
    end
    boostTarget  = math.min(spd * mult + add, BOOST_CEILING)
    boostHold    = hold
    boostRelease = release
    boostT       = 0
    dbg("%s: %.0f -> %.0f (hold %.2fs)", label, spd, boostTarget, hold)
end

-- Floor for this frame: flat through the hold, then eased to nothing. Once
-- the floor drops under actual speed it simply stops applying, so the
-- release blends back into the game's own slide decay instead of snapping.
local function CurrentFloor()
    if boostT < boostHold then return boostTarget end
    if boostRelease <= 0 then return 0 end
    local u = (boostT - boostHold) / boostRelease
    if u >= 1 then return 0 end
    return boostTarget * (1 - u)
end

function M.OnPlayerCached(pawn, cmc)
    dbg("---- vanilla sliding values ----")
    for _, o in ipairs(OVERRIDES) do
        dbg("  %-42s = %s", o[1], tostring(ReadOpt(cmc, o[1])))
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
    sliding      = false
    sinceSlide   = math.huge
    boostT       = 0
    boostHold    = 0
    boostRelease = 0
    boostTarget  = 0
end

function M.OnTick(dt, pawn, cmc)
    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local v      = cmc.Velocity
    local spd    = Speed2D(v)

    local isSliding = (mode == 6 and custom == 3)

    -- ---------------- entry edge ----------------
    if isSliding and not sliding then
        ArmBoost(spd, ENTRY_BOOST_MULT, ENTRY_BOOST_ADD,
                 ENTRY_HOLD, ENTRY_RELEASE, "slide entry")
    end

    -- ---------------- slide -> jump edge ----------------
    -- Both a jump and a ledge drop exit sliding into MOVE_Falling; only a
    -- jump carries JumpZVelocity, so Vz is the discriminator. The grace
    -- window covers the case where slide ends a frame or two before the
    -- falling mode is set.
    if sliding then
        sinceSlide = 0
    else
        sinceSlide = sinceSlide + dt
    end

    if mode == 3 and sinceSlide <= JUMP_GRACE and v.Z > JUMP_VZ_MIN then
        ArmBoost(spd, JUMP_BOOST_MULT, JUMP_BOOST_ADD,
                 JUMP_HOLD, JUMP_RELEASE, "slide jump")
        sinceSlide = math.huge          -- one boost per exit
    end

    sliding = isSliding

    -- ---------------- hold the floor ----------------
    -- Never clamps down: a downhill slide building past the floor keeps its
    -- own speed. Direction is left untouched so carving still steers.
    if boostT < boostHold + boostRelease then
        boostT = boostT + dt
        local floor = CurrentFloor()
        if floor > 0 and spd > 1e-3 and spd < floor then
            local k = floor / spd
            cmc.Velocity.X = v.X * k
            cmc.Velocity.Y = v.Y * k
        end
    end

    -- Movement-mode transition watcher (kept: cheap, and the custom-mode
    -- IDs are the primary debugging signal for every other subsystem).
    if DEBUG and (mode ~= lastMode or custom ~= lastCustom) then
        dbg("movement mode %d (custom %d) spd=%.0f vz=%.0f", mode, custom, spd, v.Z)
        lastMode, lastCustom = mode, custom
    end
end

return M
