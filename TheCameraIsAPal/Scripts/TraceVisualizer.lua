local TraceVisualizer = {}

-- Cache the Kismet System Library for performance.
-- Resolved lazily rather than at require time: the default object does not
-- survive a world reload, and a stale handle here would silently stop every
-- visualization after the first level change.
local KismetSysLib = nil

local function GetKismet()
    if KismetSysLib ~= nil then
        local ok, valid = pcall(function() return KismetSysLib:IsValid() end)
        if ok and valid then return KismetSysLib end
    end
    KismetSysLib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    return KismetSysLib
end

-- EDrawDebugTrace::Type Enums
TraceVisualizer.DebugTypes = {
    None = 0,
    ForOneFrame = 1,
    ForDuration = 2,
    Persistent = 3
}

-- Default visualization colors (FLinearColor)
local DefaultTraceColor = {R = 1.0, G = 0.0, B = 0.0, A = 1.0} -- Red for the ray
local DefaultHitColor = {R = 0.0, G = 1.0, B = 0.0, A = 1.0}   -- Green for the impact point

-- Whatever a caller does not care about falls back to the originals, so the
-- two-argument-plus-duration form still behaves exactly as before.
local function Resolve(channel, traceColor, hitColor)
    return channel or 0,
           traceColor or DefaultTraceColor,
           hitColor or DefaultHitColor
end

--- Casts a line trace and visualizes it.
--- @param WorldContext UObject (Usually the Player Controller or Pawn)
--- @param Start FVector
--- @param End FVector
--- @param Duration float (Time in seconds to keep the line visible. 0 = 1 frame)
--- @param Channel number|nil ETraceTypeQuery. Defaults to 0 (Visibility).
---        Pass the channel the system under test actually uses -- a ray drawn
---        on a different channel hits different geometry, so it would show a
---        confident picture of something nobody is checking.
--- @param TraceColor table|nil FLinearColor for the ray
--- @param HitColor table|nil FLinearColor for the impact point
--- @return boolean (Did it hit?), FHitResult
function TraceVisualizer:DrawLineTrace(WorldContext, Start, End, Duration,
                                       Channel, TraceColor, HitColor)
    local Kismet = GetKismet()
    if not Kismet or not WorldContext then
        print("[TraceVis] Error: Invalid WorldContext or Kismet library not found.\n")
        return false, nil
    end

    local DrawMode = (Duration > 0) and self.DebugTypes.ForDuration or self.DebugTypes.ForOneFrame
    local IgnoreActors = {} -- Pass empty array of actors to ignore
    local ch, traceCol, hitCol = Resolve(Channel, TraceColor, HitColor)

    -- Call UKismetSystemLibrary::LineTraceSingle
    -- UE4SS handles out parameters (like HitResult) as return values
    local bHit, HitResult = Kismet:LineTraceSingle(
        WorldContext,
        Start,
        End,
        ch,
        false, -- bTraceComplex
        IgnoreActors,
        DrawMode,
        nil, -- OutHit (UE4SS ignores this input and returns it instead)
        true, -- bIgnoreSelf
        traceCol,
        hitCol,
        Duration
    )

    return bHit, HitResult
end

--- Casts a capsule sweep and visualizes it. Useful for character movement or wide attacks.
--- @param WorldContext UObject
--- @param Start FVector
--- @param End FVector
--- @param Radius float
--- @param HalfHeight float
--- @param Duration float
--- @param Channel number|nil ETraceTypeQuery. Defaults to 0 (Visibility).
--- @param TraceColor table|nil
--- @param HitColor table|nil
--- @return boolean, FHitResult
function TraceVisualizer:DrawCapsuleTrace(WorldContext, Start, End, Radius, HalfHeight,
                                          Duration, Channel, TraceColor, HitColor)
    local Kismet = GetKismet()
    if not Kismet or not WorldContext then return false, nil end

    local DrawMode = (Duration > 0) and self.DebugTypes.ForDuration or self.DebugTypes.ForOneFrame
    local IgnoreActors = {}
    local ch, traceCol, hitCol = Resolve(Channel, TraceColor, HitColor)

    local bHit, HitResult = Kismet:CapsuleTraceSingle(
        WorldContext,
        Start,
        End,
        Radius,
        HalfHeight,
        ch,
        false, -- bTraceComplex
        IgnoreActors,
        DrawMode,
        nil,
        true,
        traceCol,
        hitCol,
        Duration
    )

    return bHit, HitResult
end

return TraceVisualizer
