-- =========================================================================
-- PalFeel subsystem: climb — PHASE 0 RECON ONLY. Reads and logs; no writes.
--
-- Goal: answer the three questions that decide how the BotW-style hop-into-
-- climb has to be built.
--
--   Q1  Where is the climbing component, and can we read it reliably?
--       It lives on the Blueprint pawn, not native APalPlayerCharacter, so
--       it is found by scanning BlueprintCreatedComponents for a name
--       containing "Climbing". NOTE: matching is done on the component's
--       own GetFullName(), never GetClass():GetFullName() — the latter is
--       the call that produced unrecoverable native AVs in HelpfulHolster.
--
--   Q2  Does CanClimbing LEAD the climb state, and by how many frames?
--       If it leads, the hop can be applied before the latch — the correct
--       BotW ordering (hop, then grab). If it flips simultaneously with
--       IsClimbing / custom mode 5, the hop must instead be injected on
--       entry and reasserted, like the slide boost.
--
--   Q3  What does the game do to velocity on entry, and what is the
--       approach speed? Vz on the entry frames tells us whether the game
--       zeroes vertical velocity when latching (which would eat a hop
--       applied a frame early) and what headroom ClimbMaxSpeed leaves.
--
-- Movement modes: 6 = MOVE_Custom; custom 5 = Climbing. 1 = Walking,
--                 3 = MOVE_Falling.
--
-- Install: add require("climb") to the Subsystems list in main.lua.
-- =========================================================================

local DEBUG = true

-- Burst capture around any climb-relevant transition.
local CAP_PRE  = 10     -- frames of history replayed before the event
local CAP_POST = 25     -- frames logged after it

local M = { name = "climb" }

local comp        = nil
local compName    = nil
local scanned     = false
local ring, ringN = {}, 0
local capLeft     = 0
local prevCan, prevIs, prevMode, prevCustom = nil, nil, nil, nil

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end

-- Must not collapse a legitimate `false` to nil — CanClimbing being false
-- is exactly the state we need to distinguish from "unreadable".
local function ReadOpt(obj, prop)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

-- Scan the Blueprint-created components for the climbing component.
-- pcall around every dereference: pcall does NOT protect against native
-- access violations, so each step is null-checked before the next.
local function FindClimbComp(pawn)
    local ok, arr = pcall(function() return pawn.BlueprintCreatedComponents end)
    if not ok or arr == nil then
        dbg("BlueprintCreatedComponents unreadable")
        return nil, nil
    end

    local n = 0
    pcall(function() n = #arr end)
    dbg("scanning %d blueprint components", n)

    for i = 1, n do
        local okC, c = pcall(function() return arr[i] end)
        if okC and c ~= nil then
            local okV, valid = pcall(function() return c:IsValid() end)
            if okV and valid then
                local okN, name = pcall(function() return c:GetFullName() end)
                if okN and type(name) == "string" then
                    dbg("  [%d] %s", i, name)
                    if name:find("Climb") then
                        return c, name
                    end
                end
            end
        end
    end
    return nil, nil
end

function M.OnPlayerCached(pawn, cmc)
    comp, compName = nil, nil
    scanned        = false
    ring, ringN    = {}, 0
    capLeft        = 0
    prevCan, prevIs, prevMode, prevCustom = nil, nil, nil, nil

    comp, compName = FindClimbComp(pawn)
    scanned = true

    if comp == nil then
        dbg("climbing component NOT FOUND — hop cannot be gated on CanClimbing")
        return
    end

    dbg("component: %s", compName)
    dbg("  IsClimbing=%s CanClimbing=%s",
        tostring(ReadOpt(comp, "IsClimbing")),
        tostring(ReadOpt(comp, "CanClimbing")))
    dbg("  rays: fwd=%s up=%s right=%s offsetBack=%s",
        tostring(ReadOpt(comp, "Const_ForwardRayLength")),
        tostring(ReadOpt(comp, "Const_UpRayLength")),
        tostring(ReadOpt(comp, "Const_RightRayLength")),
        tostring(ReadOpt(comp, "Const_OffsetBack")))
    dbg("  ClimbMaxSpeed=%s", tostring(ReadOpt(cmc, "ClimbMaxSpeed")))
end

function M.OnTick(dt, pawn, cmc)
    if not scanned then return end

    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local v      = cmc.Velocity
    local spd    = math.sqrt(v.X * v.X + v.Y * v.Y)
    local can    = ReadOpt(comp, "CanClimbing")
    local is     = ReadOpt(comp, "IsClimbing")

    local line = string.format(
        "mode=%d/%d can=%s is=%s spd=%.0f vz=%.0f dt=%.4f",
        mode, custom, tostring(can), tostring(is), spd, v.Z, dt)

    if capLeft > 0 then
        capLeft = capLeft - 1
        dbg("  |%s", line)
        if capLeft == 0 then dbg("---- capture end ----") end
    else
        ringN = ringN + 1
        ring[(ringN - 1) % CAP_PRE + 1] = line

        -- Any climb-relevant edge opens a capture. Ordering between these
        -- edges is the whole point: which one fires first, and how many
        -- frames apart, decides where the hop is injected.
        local edge = nil
        if can ~= prevCan  then edge = "CanClimbing -> " .. tostring(can) end
        if is  ~= prevIs   then edge = "IsClimbing -> "  .. tostring(is)  end
        if mode == 6 and custom == 5 and prevCustom ~= 5 then
            edge = "entered climb mode (6/5)"
        end
        if prevCustom == 5 and custom ~= 5 then
            edge = "left climb mode"
        end

        if edge and prevCan ~= nil then
            dbg("---- %s ----", edge)
            for i = math.max(1, ringN - CAP_PRE + 1), ringN do
                dbg("  |%s", ring[(i - 1) % CAP_PRE + 1])
            end
            capLeft = CAP_POST
        end
    end

    prevCan, prevIs, prevMode, prevCustom = can, is, mode, custom
end

return M
