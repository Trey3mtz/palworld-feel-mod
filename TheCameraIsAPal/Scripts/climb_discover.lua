-- =========================================================================
-- climb_discover.lua -- one-shot investigations for the climbing component.
--
-- Not a subsystem. climb.lua requires this only when its DEBUG_DISCOVERY_DEEP
-- flag is on, and passes it a context once per player cache. Everything here
-- is read-only instrumentation whose questions have been answered at least
-- once; it exists so the next question can be asked without putting the
-- tooling back into the gameplay file.
--
-- Findings so far (Palworld 1.0.1, UE4SS 3.x):
--   * The component's ReceiveTick ran BEFORE the controller tick on 240 of
--     240 sampled frames. Tick ratio 1.00 (no double-registered hook).
--   * CanClimbingStart is a setter, not a predicate: zero calls per session.
--   * LineTraceSingle fills the hit struct through the passed table
--     (floor normal reads +1.00). Capsule/sphere sweeps are self-tested by
--     climb.lua at runtime instead.
--   * BP_PalClimbingComponent_C exposes StartClimbing, StartClimb,
--     StartClimbByNetwork, TryClimbAfterGrappling, ClimbingMainUpdate,
--     CheckClimbingMode, DelayCanClimbing, ForceCancelClimb, GroundCheck,
--     ClimbUpAtTopEvent, and the Center/Up/Side/DiagonalRayCast family.
--
-- pcall does not catch native access violations: every dereference of a
-- wrapper past the first is IsValid()-checked before it is touched. The
-- SuperStruct walk below is where a crash-on-load came from once.
-- =========================================================================

local D = {}

-- ---- what to run ----
D.DUMP_FUNCTIONS     = true    -- walk the class and its supers, list UFunctions
D.SAMPLE_TICK_ORDER  = true    -- component tick before/after ours, and the ratio
D.OBSERVE_CANSTART   = true    -- log CanClimbingStart call shape (never vetoes)
D.CHARACTERIZE_TRACE = true    -- does LineTraceSingle fill the hit struct?

D.TICK_ORDER_SAMPLE_MAX = 240  -- ~4s at 60fps, then silent
D.CANSTART_LOG_MAX      = 8
D.GRAB_WINDOW_LOG_MAX   = 3

local ctx = nil          -- { pawn, cmc, comp, compName, clsPath, capsuleRadius, capsuleHalfHeight, log }
local hooksRegistered = false
local S = nil

local function NewState()
    return {
        compTickHookAlive = false, compTickedBeforeUs = false,
        tickBefore = 0, tickAfter = 0, tickSamples = 0, compTicks = 0,
        grabWasClimbingPre = false, grabInsideTick = 0,
        canStartFires = 0, canStartLogged = 0,
    }
end

local function log(fmt, ...)
    if ctx and ctx.log then ctx.log(fmt, ...) end
end

local function IsLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function IsOurComponent(Context)
    local obj = nil
    pcall(function() obj = Context:get() end)
    if obj == nil or ctx == nil or ctx.compName == nil then return false end
    local name = nil
    pcall(function() name = obj:GetFullName() end)
    return name == ctx.compName
end

-- =========================================================================
-- Investigations
-- =========================================================================

local function DumpFunctions(cls, label)
    if not IsLive(cls) then
        log("  [%s] not a live object -- skipped", label)
        return
    end
    local seen, named = 0, 0
    local okEach = pcall(function()
        cls:ForEachFunction(function(fn)
            seen = seen + 1
            local n = nil
            pcall(function() n = fn:GetFullName() end)
            if n == nil then pcall(function() n = fn:GetName() end) end
            if n ~= nil then
                named = named + 1
                log("  [%s] fn: %s", label, tostring(n))
            end
        end)
    end)
    log("  [%s] ForEachFunction: callable=%s visited=%d named=%d",
        label, tostring(okEach), seen, named)
end

local function DumpClassFunctions()
    pcall(function()
        log("---- functions on %s ----", ctx.clsPath)
        local cls = ctx.comp:GetClass()
        if not IsLive(cls) then return end
        DumpFunctions(cls, "class")

        local parent, depth = nil, 0
        pcall(function() parent = cls:GetSuperStruct() end)
        while IsLive(parent) and depth < 4 do
            local pname = nil
            pcall(function() pname = parent:GetFullName() end)
            -- An unreadable name means the wrapper is not a real live
            -- UStruct: stop rather than touch it again.
            if type(pname) ~= "string" then
                log("  -- super[%d]: unreadable, stopping walk", depth)
                break
            end
            log("  -- super[%d]: %s", depth, pname)
            DumpFunctions(parent, "super" .. depth)

            local nxt = nil
            pcall(function() nxt = parent:GetSuperStruct() end)
            if not IsLive(nxt) then break end
            parent = nxt
            depth = depth + 1
        end
        log("---- end functions ----")
    end)
end

-- A floor's normal is +1.00 by definition, which distinguishes a populated
-- struct from a zero-initialised one (a vertical wall's normal cannot).
local function CharacterizeTraceStruct()
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not IsLive(KSL) then return end
    local origin = nil
    pcall(function() origin = ctx.pawn:K2_GetActorLocation() end)
    if origin == nil then return end

    local out, hit = {}, nil
    local ok = pcall(function()
        hit = KSL:LineTraceSingle(ctx.pawn,
            { X = origin.X, Y = origin.Y, Z = origin.Z },
            { X = origin.X, Y = origin.Y, Z = origin.Z - 300 },
            0, false, {}, 0, out, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0.0)
    end)
    if not ok then log("floor trace: call failed") return end
    local nz, dist = "?", "?"
    pcall(function() nz   = string.format("%+.2f", out.ImpactNormal.Z) end)
    pcall(function() dist = string.format("%.1f", out.Distance) end)
    log("floor trace: hit=%s dist=%s normalZ=%s  (+1.00 = struct fills, "
        .. "+0.00 = struct dead)", tostring(hit), dist, nz)
end

local function RegisterHooks()
    if hooksRegistered then return end
    local clsPath = ctx.clsPath

    if D.SAMPLE_TICK_ORDER then
        local ok, err = pcall(function()
            RegisterHook(clsPath .. ":ReceiveTick",
                function(Context)
                    if not IsOurComponent(Context) then return end
                    S.compTickHookAlive  = true
                    S.compTickedBeforeUs = true
                    S.compTicks          = S.compTicks + 1
                    local isClimbing = nil
                    pcall(function() isClimbing = ctx.comp.IsClimbing end)
                    S.grabWasClimbingPre = (isClimbing == true)
                end,
                function(Context)
                    if not IsOurComponent(Context) then return end
                    local isClimbing = nil
                    pcall(function() isClimbing = ctx.comp.IsClimbing end)
                    if isClimbing == true and not S.grabWasClimbingPre then
                        S.grabInsideTick = S.grabInsideTick + 1
                        if S.grabInsideTick <= D.GRAB_WINDOW_LOG_MAX then
                            log("GRAB WINDOW: IsClimbing false->true INSIDE the "
                                .. "component's BP tick (#%d)", S.grabInsideTick)
                        end
                    end
                end)
        end)
        log("discover hook ReceiveTick: %s", ok and "registered" or ("FAILED: " .. tostring(err)))
    end

    if D.OBSERVE_CANSTART then
        local ok, err = pcall(function()
            RegisterHook(clsPath .. ":CanClimbingStart", function() end,
                function(Context, ...)
                    if not IsOurComponent(Context) then return end
                    S.canStartFires = S.canStartFires + 1
                    if S.canStartLogged >= D.CANSTART_LOG_MAX then return end
                    S.canStartLogged = S.canStartLogged + 1
                    local args = { ... }
                    local ret = nil
                    if #args > 0 then pcall(function() ret = args[#args]:get() end) end
                    log("CanClimbingStart #%d: argc=%d last=%s (%s)",
                        S.canStartFires, #args, tostring(ret), type(ret))
                end)
        end)
        log("discover hook CanClimbingStart: %s", ok and "registered" or ("FAILED: " .. tostring(err)))
    end

    hooksRegistered = true
end

-- =========================================================================
-- Entry points
-- =========================================================================

-- context: pawn, cmc, comp, compName, clsPath, log(fmt, ...)
function D.OnPlayerCached(context)
    ctx = context
    S   = NewState()
    if ctx == nil or not IsLive(ctx.comp) then return end
    if D.DUMP_FUNCTIONS     then DumpClassFunctions() end
    if D.CHARACTERIZE_TRACE then CharacterizeTraceStruct() end
    RegisterHooks()
end

-- Called once per controller tick. Reads the flag the component hook set
-- and clears it, so each of our ticks learns whether the component ran first.
function D.OnTick()
    if S == nil or not D.SAMPLE_TICK_ORDER then return end
    if not S.compTickHookAlive then return end
    if S.tickSamples >= D.TICK_ORDER_SAMPLE_MAX then return end

    S.tickSamples = S.tickSamples + 1
    if S.compTickedBeforeUs then S.tickBefore = S.tickBefore + 1
    else S.tickAfter = S.tickAfter + 1 end
    S.compTickedBeforeUs = false

    if S.tickSamples == D.TICK_ORDER_SAMPLE_MAX then
        local ratio = S.compTicks > 0 and (S.tickSamples / S.compTicks) or 0
        log("TICK ORDER over %d ticks: component BEFORE us %d, AFTER (or absent) %d. "
            .. "A split means the order is not stable.",
            S.tickSamples, S.tickBefore, S.tickAfter)
        log("TICK RATIO: ours %d / component %d = %.2fx (~1.0 healthy; ~2.0 = "
            .. "controller tick hook double-registered)", S.tickSamples, S.compTicks, ratio)
        log("CanClimbingStart: %d calls in that window (0 = organic grab does not "
            .. "route through it)", S.canStartFires)
    end
end

return D
