-- =========================================================================
-- PalFeel subsystem: climb — slide-on-entry + climb jump (v7).
--
-- v7 is a readability refactor of v6 plus three stale-state fixes:
--
--   FIX A — `inClimb` was sampled once at tick start, but TickClimbJump
--   can force-attach MID-TICK. The frame after, `cj` cleared and the
--   slide-arm check saw a fabricated "entered climb" edge (stale
--   prevCustomIs5=false, cj already nil) — a forced attach after a long
--   hug fall could arm the slide, the exact case the guard existed to
--   prevent. Mode/custom are now re-read after TickClimbJump so the
--   slide, frame-cache, and prevCustomIs5 sections see reality.
--
--   FIX B — `lastFallVz` was never cleared, so a hard fall followed
--   minutes later by a gentle climb entry still satisfied the slide
--   trigger. It now zeroes on grounded modes.
--
--   FIX C — the hop had no landing check: touching ground inside
--   HOP_LOCK kept writing horizontal velocity while grounded, shoving
--   the pawn along the floor. It now ends on leaving Falling, mirroring
--   the hug.
--
-- v6 recap (kept):
--   * SWEPT WALL PROBE gates every attach attempt: K2_AddActorWorldOffset
--     by PROBE_DIST along the wall facing with sweep ON; blocked
--     (< half commanded) => wall present, force the attach; unblocked =>
--     revert exactly and keep flying. No engine trace plumbing.
--   * The hug ends when Falling is left WITHOUT entering climb (clearing
--     a wall top ends on the ledge in mode 1 — the BotW vault).
--   * CanClimbing is sampled BEFORE forcing; probes log moved/commanded.
--
-- REQUIRES: climb ticks AFTER jump in main.lua's Subsystems list —
-- jump.lua writes GravityScale every mode-3 frame and our override must
-- run second.
--
-- ---------------------------------------------------------------------
-- Ground truth (17:39 / 18:04 / 18:32 / 21:05 sessions):
--   * Vanilla climb jump has NO directional variation: identical 870
--     launch and +159 uu peak all four directions; all differences were
--     the player's held input surviving into air control (cap 350).
--     Nothing pushes off the wall on its own.
--   * CanClimbing is a fixed ~504 ms cooldown; expiry is necessary but
--     not sufficient — the component's attach test reads the INPUT
--     channel (holding forward), not capsule velocity.
--   * Forced attach works: SetMovementMode(6,5) + CanClimbing/IsClimbing
--     writes are accepted and normal climbing resumes — verified over 10
--     jumps at ~345 ms, net ~+250 uu — PROVIDED a wall is actually there.
--   * Detection is the mode transition (detach runs in the movement
--     update, before the controller tick we hook), classified on the
--     cached previous climb frame. Launch measured 858-870.
--   * PrevClimbDirection is a smoothed wall-FACING accumulator (Z always
--     0, |.| relaxes to 2.0, normalize == pawn forward). Wall normal =
--     -(horizontal pawn forward). ClimbMaxSpeed = 125.
--   * Mode 3 obeys ordinary CMC physics, so velocity writes work there;
--     mode 6 does not (climb solver owns Velocity), hence the slide's
--     position writes. Per-tick velocity reassertion doubles as the
--     control lock.
--
-- OPEN: corner rounding for SIDE leaps. The probe direction is frozen at
-- the detach facing, so a leap past a convex corner probes into open air
-- and keeps flying rather than sticking to the new face. Doing this
-- properly needs the component's own trace/query functions — the dumps
-- in the project contain members only, so the function list (FModel BP
-- JSON export of BP_PalClimbingComponent) is still needed.
--
-- Movement modes: 1 = Walking, 3 = Falling, 6 = MOVE_Custom.
-- Custom modes:   2 = Sprint, 4 = Glide, 5 = Climb.
--
-- Layout: 1 tuning · 2 state · 3 utilities · 4 geometry ·
--         5 wall slide · 6 climb jump · 7 capture · 8 lifecycle
-- =========================================================================

-- =========================================================================
-- 1. TUNING
-- =========================================================================

local DEBUG   = true
local CAPTURE = false

-- ---- slide ----
local VZ_TRIGGER  = -600
local VZ_CAP      = 1600
local TRANSFER    = 0.45
local DECEL       = 1400
local MIN_SLIDE_V = 60
local BLOCK_RATIO = 0.4

-- ---- climb jump: detection ----
local JUMP_DETECT_VZ = 600
local IDLE_BAND      = 25
local DOWN_BAND      = -60

-- ---- climb jump: wall hug (UP / SIDE / IDLE) ----
local CLIMB_JUMP_VZ      = 1550
local CLIMB_JUMP_GRAVITY = 5.0
local HUG_IN             = 150
local SIDE_CARRY         = 450
local REGRAB_VZ          = 0      -- probe for attach at/below this vz
local HUG_TIMEOUT        = 1.5

-- ---- climb jump: forced-attach probe ----
local PROBE_DIST   = 40     -- swept distance into the wall facing
local PROBE_BLOCK  = 0.5    -- moved/commanded below this = wall present

-- ---- climb jump: hop away (DOWN) ----
local HOP_VZ    = 620
local HOP_OUT   = 300
local HOP_LOCK  = 0.20

local LOCK_ROTATION = true


-- ---- component flag reconciliation ----
local RECONCILE_TICKS = 3   -- consecutive desynced ticks before repair


-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "climb" }

-- Published for jump.lua's jump-cut guard; the cut multiplies Velocity.Z
-- by 0.6 on release and would clip our launch if the released edge ever
-- starts firing.
M.InClimbJump = false

local comp, compName = nil, nil
local scanned        = false

-- ---- fall / climb frame cache ----
local lastFallVz     = 0
local prevCustomIs5  = false
local prevClimbVel   = { X = 0, Y = 0, Z = 0 }
local prevWallFwd    = { X = 1, Y = 0 }
local prevClimbZ     = nil
local hbT = 0    -- airborne flag-heartbeat accumulator

-- ---- slide state ----
local sliding        = false
local slideV         = 0
local savedClimbMax  = nil

-- ---- climb jump state ----
local cj             = nil

-- ---- capture state ----
local CAP_PRE, CAP_POST = 12, 30
local ring, ringN, capLeft = {}, 0, 0
local prevCan, prevIs, prevCustom = nil, nil, nil

-- ---- flag watch state ----
local prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
local stuckIsTicks = 0
local KSL = nil             -- KismetSystemLibrary default object, lazy

-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end

local function ReadOpt(obj, prop)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if not ok then return nil end
    return v
end

local function IsLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- pcall does NOT protect against native AVs: every dereference is
-- individually null-checked.
local function FindClimbingComponent(pawn)
    local ok, arr = pcall(function() return pawn.BlueprintCreatedComponents end)
    if not ok or arr == nil then return nil, nil end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local okC, c = pcall(function() return arr[i] end)
        if okC and c ~= nil and IsLive(c) then
            local okN, name = pcall(function() return c:GetFullName() end)
            if okN and type(name) == "string" and name:find("Climb") then
                return c, name
            end
        end
    end
    return nil, nil
end

-- =========================================================================
-- 4. GEOMETRY
-- =========================================================================

local function GetLoc(pawn)
    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc == nil then return nil end
    local out = nil
    pcall(function() out = { X = loc.X, Y = loc.Y, Z = loc.Z } end)
    return out
end

local function GetZ(pawn)
    local l = GetLoc(pawn)
    return l and l.Z or nil
end

local function WallFwd(pawn)
    local fwd = nil
    pcall(function() fwd = pawn:GetActorForwardVector() end)
    if fwd == nil then return nil end
    local x, y = 0, 0
    local ok = pcall(function() x, y = fwd.X, fwd.Y end)
    if not ok then return nil end
    local m = math.sqrt(x * x + y * y)
    if m < 1e-4 then return nil end
    return { X = x / m, Y = y / m }
end

-- Decompose a world vector into (into-wall, along-wall, up) components.
local function WallRelative(v, f)
    if v == nil or f == nil then return 0, 0, 0 end
    return  v.X * f.X + v.Y * f.Y,
           -v.X * f.Y + v.Y * f.X,
            v.Z
end

local function SetHorizVel(cmc, x, y)
    pcall(function()
        cmc.Velocity.X = x
        cmc.Velocity.Y = y
    end)
end

local function FaceYaw(pawn, f)
    if not LOCK_ROTATION or f == nil then return end
    local yaw = math.deg(math.atan(f.Y, f.X))
    pcall(function()
        pawn:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false)
    end)
end

-- =========================================================================
-- 5. WALL SLIDE
-- Fast fall into a wall skids down to a halt instead of latching dead.
-- Position writes (mode 6: the climb solver owns Velocity);
-- ClimbMaxSpeed = 0 doubles as the input lock.
-- =========================================================================

local function BeginWallSlide(cmc, entryVz)
    local v = math.min(math.abs(entryVz), VZ_CAP)
    slideV  = v * TRANSFER
    sliding = true
    savedClimbMax = ReadOpt(cmc, "ClimbMaxSpeed")
    if savedClimbMax ~= nil then
        local ok = pcall(function() cmc.ClimbMaxSpeed = 0 end)
        if not ok then
            dbg("WARN: ClimbMaxSpeed write failed -- input not locked")
            savedClimbMax = nil
        end
    else
        dbg("WARN: ClimbMaxSpeed unreadable -- input not locked")
    end
    dbg("slide start: entryVz=%.0f v0=%.0f (est dist %.0f uu) lock=%s",
        entryVz, slideV, (slideV * slideV) / (2 * DECEL),
        tostring(savedClimbMax ~= nil))
end

local function EndWallSlide(cmc, reason)
    if not sliding then return end
    sliding = false
    slideV  = 0
    if savedClimbMax ~= nil then
        pcall(function() cmc.ClimbMaxSpeed = savedClimbMax end)
        savedClimbMax = nil
    end
    dbg("slide end: %s", reason or "?")
end

local function TickWallSlide(dt, pawn, cmc)
    local dz = slideV * dt
    local z0 = GetZ(pawn)
    local okMove = pcall(function()
        pawn:K2_AddActorWorldOffset({ X = 0, Y = 0, Z = -dz }, true, {}, false)
    end)
    if not okMove then
        EndWallSlide(cmc, "K2_AddActorWorldOffset call failed")
        return
    end
    -- Displacement-ratio blockage check doubles as write-channel
    -- verification: commanded vs moved.
    if z0 ~= nil then
        local z1 = GetZ(pawn)
        if z1 ~= nil and dz > 0.5 then
            local moved = z0 - z1
            if moved < dz * BLOCK_RATIO then
                EndWallSlide(cmc, string.format(
                    "blocked (commanded %.1f, moved %.1f)", dz, moved))
                return
            end
        end
    end
    slideV = slideV - DECEL * dt
    if slideV <= MIN_SLIDE_V then
        EndWallSlide(cmc, "decayed to halt")
    end
end

-- Arm on a genuine fast-fall climb entry only: forced attaches land at
-- low vz and never arm mid climb jump (cj guard; FIX A supplies fresh
-- mode state so the guard actually holds on the post-attach frame).
local function UpdateWallSlide(dt, pawn, cmc, inClimb)
    if inClimb and not prevCustomIs5 and cj == nil then
        local entryVz = math.min(lastFallVz, cmc.Velocity.Z)
        if entryVz <= VZ_TRIGGER then
            BeginWallSlide(cmc, entryVz)
        end
    end

    if sliding and not inClimb then
        EndWallSlide(cmc, "left climb mode")
    end

    if sliding and inClimb then
        TickWallSlide(dt, pawn, cmc)
    end
end

-- =========================================================================
-- 6. CLIMB JUMP
-- Detach detection -> classify from the cached pre-detach frame ->
-- UP/SIDE/IDLE wall-hug leap with probe-gated re-attach, or DOWN hop away.
-- =========================================================================

local function ClassifyJumpDirection(vIn, vSide, vUp)
    if vUp < DOWN_BAND then
        return "DOWN"
    elseif math.abs(vUp) <= IDLE_BAND and math.abs(vSide) <= IDLE_BAND then
        return "IDLE"
    elseif math.abs(vSide) > math.abs(vUp) then
        return "SIDE"
    else
        return "UP"
    end
end

-- Swept probe into the wall facing. Returns:
--   true,  moved  -- wall present; capsule left flush against it
--   false, moved  -- open air; offset fully reverted
--   nil           -- probe could not run (call failure); treat as no wall
local function ProbeWall(pawn, f)
    local l0 = GetLoc(pawn)
    if l0 == nil then return nil end
    local hitOut = {}
    local ok = pcall(function()
        pawn:K2_AddActorWorldOffset(
            { X = f.X * PROBE_DIST, Y = f.Y * PROBE_DIST, Z = 0 },
            true, hitOut, false)
    end)
    if not ok then return nil end
    local l1 = GetLoc(pawn)
    if l1 == nil then return nil end
    local moved = (l1.X - l0.X) * f.X + (l1.Y - l0.Y) * f.Y

    if moved < PROBE_DIST * PROBE_BLOCK then
        -- Forensics: what actually blocked us? Out-struct population
        -- through UE4SS is the thing under test here.
        local nz, hitName = "?", "?"
        pcall(function() nz = string.format("%+.2f", hitOut.ImpactNormal.Z) end)
        pcall(function() hitName = hitOut.Component:GetFullName() end)
        dbg("  probe blocked: normalZ=%s by %s", nz, tostring(hitName))
        return true, moved
    end
    pcall(function()
        pawn:K2_AddActorWorldOffset(
            { X = l0.X - l1.X, Y = l0.Y - l1.Y, Z = 0 }, false, {}, false)
    end)
    return false, moved
end


-- Write the component into the ORGANIC post-attach signature
-- (is=true can=true ending=false, per flag edges at 12:31:29 and
-- 12:31:46). The mode-only experiment attached mechanically but left
-- the component unaware -- is=false/ending=true while climbing -- so
-- the next detach ran no cooldown and the game re-grabbed the wall
-- 24ms into the following climb jump. Mimicking the organic signature
-- makes the detach path run normally; the reconciler remains the
-- safety net for flags our own maneuvers leave behind.
local function ForceClimbAttach(cmc)
    if not IsLive(comp) then
        dbg("WARN: climb component stale -- attach skipped")
        return false, false, false
    end
    local okCan = pcall(function() comp.CanClimbing = true end)
    local okMode = pcall(function() cmc:SetMovementMode(6, 5) end)
    if not okMode then
        okMode = pcall(function()
            cmc.MovementMode = 6
            cmc.CustomMovementMode = 5
        end)
    end
    local okIs = pcall(function()
        comp.IsClimbing = true
        comp.IsEnding   = false
    end)
    return okMode, okCan, okIs
end

-- Always-on flag history: any change of the component's state booleans is
-- logged with mode context. IsEnding included -- the dump shows a scripted
-- vault-to-top subsystem whose state can presumably desync the same way.
local function LogComponentFlagEdges(mode, custom)
    if not DEBUG then return end
    local is     = ReadOpt(comp, "IsClimbing")
    local can    = ReadOpt(comp, "CanClimbing")
    local ending = ReadOpt(comp, "IsEnding")
    if is ~= prevFlagIs or can ~= prevFlagCan or ending ~= prevFlagEnding then
        dbg("flags: is=%s can=%s ending=%s (mode %d/%d)",
            tostring(is), tostring(can), tostring(ending), mode, custom)
        prevFlagIs, prevFlagCan, prevFlagEnding = is, can, ending
    end
end

-- Repair the observed desync: IsClimbing latched true while not climbing.
-- Waits N consecutive ticks so the game's own detach transition frames
-- are never fought. CanClimbing is deliberately left alone -- its
-- cooldown is the component's business, and forcing it is how we got
-- here in the first place.
local function ReconcileStuckClimbFlag(inClimb)
    if inClimb then stuckIsTicks = 0 return end
    if ReadOpt(comp, "IsClimbing") ~= true then stuckIsTicks = 0 return end
    stuckIsTicks = stuckIsTicks + 1
    if stuckIsTicks >= RECONCILE_TICKS then
        local ok = pcall(function() comp.IsClimbing = false end)
        dbg("reconciled stuck IsClimbing -> false (write ok=%s)", tostring(ok))
        stuckIsTicks = 0
    end
end

local function TraceWallTest(pawn, f, cjState)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then return nil end
    end
    local l = GetLoc(pawn)
    if l == nil then return nil end

    local rayLen  = ReadOpt(comp, "Const_ForwardRayLength") or 80.0
    local channel = ReadOpt(comp, "Const_RayChannel") or 0
    local complex = ReadOpt(comp, "TraceComplex") or false
    local finish  = { X = l.X + f.X * rayLen, Y = l.Y + f.Y * rayLen, Z = l.Z }

    local hit, out = nil, {}
    local ok = pcall(function()
        hit = KSL:LineTraceSingle(pawn, l, finish, channel, complex, {},
            2, out, true,
            { R = 1.0, G = 0.0, B = 0.0, A = 1.0 },
            { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }, 2.0)
    end)
    if not ok then
        dbg("  trace: LineTraceSingle call failed")
        return nil
    end

    if cjState.lastTrace == nil or cjState.lastTrace ~= hit then
        cjState.lastTrace = hit
        local nz, dist = "?", "?"
        pcall(function() nz   = string.format("%+.2f", out.ImpactNormal.Z) end)
        pcall(function() dist = string.format("%.1f", out.Distance) end)
        dbg("  trace: hit=%s dist=%s normalZ=%s", tostring(hit), dist, nz)
    end
    return hit
end

-- One-shot out-struct characterization. Every wall tested is vertical,
-- where normalZ=0.00 is both the true value and the zero-init value, so
-- wall hits cannot distinguish a populated normal from a dead struct. A
-- floor trace can: its normal is +1.00 by definition. Runs once per pawn.
local function CharacterizeTraceStruct(pawn)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then return end
    end
    local l = GetLoc(pawn)
    if l == nil then return end
    local out, hit = {}, nil
    local ok = pcall(function()
        hit = KSL:LineTraceSingle(pawn, l,
            { X = l.X, Y = l.Y, Z = l.Z - 200 },
            ReadOpt(comp, "Const_RayChannel") or 0, false, {},
            0, out, true,
            { R = 1.0, G = 0.0, B = 0.0, A = 1.0 },
            { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }, 0.0)
    end)
    if not ok then dbg("floor trace: call failed") return end
    local nz, dist = "?", "?"
    pcall(function() nz   = string.format("%+.2f", out.ImpactNormal.Z) end)
    pcall(function() dist = string.format("%.1f", out.Distance) end)
    dbg("floor trace: hit=%s dist=%s normalZ=%s  (+1.00 = normals live, "
        .. "+0.00 = struct dead)", tostring(hit), dist, nz)
end

local function BeginWallHugLeap(pawn, cmc, kind, sideSign)
    cj = { mode = "hug", kind = kind, t = 0, f = prevWallFwd,
           side = sideSign, z0 = prevClimbZ or GetZ(pawn),
           probes = 0, logged = false }
    M.InClimbJump = true
    pcall(function() cmc.Velocity.Z = CLIMB_JUMP_VZ end)
    dbg("climb jump [%s] -> wall hug (vz=%d G=%.1f in=%d side=%d)",
        kind, CLIMB_JUMP_VZ, CLIMB_JUMP_GRAVITY, HUG_IN,
        math.floor(SIDE_CARRY * sideSign))
end

local function BeginHopAway(pawn, cmc, kind)
    cj = { mode = "hop", kind = kind, t = 0, f = prevWallFwd,
           z0 = prevClimbZ or GetZ(pawn) }
    M.InClimbJump = true
    pcall(function() cmc.Velocity.Z = HOP_VZ end)
    SetHorizVel(cmc, -prevWallFwd.X * HOP_OUT, -prevWallFwd.Y * HOP_OUT)
    dbg("climb jump [%s] -> hop away (out=%d vz=%d lock=%.2fs)",
        kind, HOP_OUT, HOP_VZ, HOP_LOCK)
end

local function EndClimbJump(pawn, cmc, reason)
    if cj == nil then return end
    local z = GetZ(pawn)
    dbg("  climb jump end [%s/%s]: %s  t=%.0fms net=%+.0f uu probes=%d",
        cj.kind, cj.mode, reason, cj.t * 1000,
        (z and cj.z0) and (z - cj.z0) or 0, cj.probes or 0)
    cj = nil
    M.InClimbJump = false
end

-- Detach detection: the component detaches inside the movement update
-- (before the controller tick we hook), so the trigger is the mode
-- transition, classified on the cached previous climb frame.
-- Returns the capture-edge string, or nil.
local function DetectClimbJump(pawn, cmc, mode)
    if not (cj == nil and prevCustomIs5 and mode == 3
            and cmc.Velocity.Z > JUMP_DETECT_VZ) then
        return nil
    end

    local vIn, vSide, vUp = WallRelative(prevClimbVel, prevWallFwd)
    local kind = ClassifyJumpDirection(vIn, vSide, vUp)
    local edge = string.format(
        "CLIMB JUMP [%s]  preVel vIn=%+.1f vSide=%+.1f vUp=%+.1f",
        kind, vIn, vSide, vUp)

    EndWallSlide(cmc, "climb jump")

    if kind == "DOWN" then
        BeginHopAway(pawn, cmc, kind)
    else
        local sign = 0
        if kind == "SIDE" then sign = (vSide >= 0) and 1 or -1 end
        BeginWallHugLeap(pawn, cmc, kind, sign)
    end
    return edge
end

local function TickHug(dt, pawn, cmc, mode, inClimb)
    if inClimb then
        EndClimbJump(pawn, cmc, "attached")
        return
    end
    -- Left Falling without entering climb: landed on a ledge top
    -- (mode 1, the vault case) or another state grabbed us. Stop.
    if mode ~= 3 then
        EndClimbJump(pawn, cmc,
            string.format("left falling (mode %d)", mode))
        return
    end
    if cj.t > HUG_TIMEOUT then
        EndClimbJump(pawn, cmc, "hug timeout")
        return
    end

    -- Own gravity for the whole leap (jump.lua wrote its band this
    -- frame; we run after it).
    pcall(function() cmc.GravityScale = CLIMB_JUMP_GRAVITY end)

    local f = cj.f
    local rx, ry = -f.Y, f.X
    SetHorizVel(cmc,
        f.X * HUG_IN + rx * SIDE_CARRY * cj.side,
        f.Y * HUG_IN + ry * SIDE_CARRY * cj.side)
    FaceYaw(pawn, f)

    -- Past apex: probe, and only attach when a wall is confirmed.
    local vz = 0
    pcall(function() vz = cmc.Velocity.Z end)
    if vz <= REGRAB_VZ then
        local hit, moved = ProbeWall(pawn, f)
        TraceWallTest(pawn, f, cj)      -- parallel diagnostic; not gating yet
        cj.probes = (cj.probes or 0) + 1
        if hit == true then
            local canBefore = ReadOpt(comp, "CanClimbing")
            local okMode, okCan, okIs = ForceClimbAttach(cmc)
            dbg("  wall probe hit (moved %.1f/%d) -> forced attach at "
                .. "t=%.0fms vz=%.0f (mode=%s can=%s is=%s, "
                .. "CanClimbing before=%s)",
                moved, PROBE_DIST, cj.t * 1000, vz,
                tostring(okMode), tostring(okCan), tostring(okIs),
                tostring(canBefore))
        elseif not cj.logged then
            cj.logged = true
            dbg("  wall probe open (moved %.1f/%d) at t=%.0fms -- "
                .. "flying on, will keep probing",
                moved or -1, PROBE_DIST, cj.t * 1000)
        end
    end
end

local function TickHop(dt, pawn, cmc, mode)
    -- FIX C: landing inside the lock window releases control instead of
    -- shoving the pawn along the ground.
    if mode ~= 3 then
        EndClimbJump(pawn, cmc,
            string.format("left falling (mode %d)", mode))
        return
    end
    if cj.t < HOP_LOCK then
        local f = cj.f
        SetHorizVel(cmc, -f.X * HOP_OUT, -f.Y * HOP_OUT)
        FaceYaw(pawn, f)
    else
        EndClimbJump(pawn, cmc, "control released")
    end
end

local function TickClimbJump(dt, pawn, cmc, mode, inClimb)
    if cj == nil then return end
    cj.t = cj.t + dt
    if cj.mode == "hug" then
        TickHug(dt, pawn, cmc, mode, inClimb)
    else
        TickHop(dt, pawn, cmc, mode)
    end
end

-- =========================================================================
-- 7. CAPTURE
-- Ring-buffered burst logger around climb-relevant edges. Ring clears on
-- burst end so stale frames never replay as new bursts.
-- =========================================================================

local function BuildLine(dt, pawn, cmc)
    local mode   = cmc.MovementMode
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local v      = cmc.Velocity
    local is     = ReadOpt(comp, "IsClimbing")
    local can    = ReadOpt(comp, "CanClimbing")
    local vIn, vSide, vUp = WallRelative(v, prevWallFwd)
    return string.format(
        "mode=%d/%d is=%s can=%s  vIn=%+7.1f vSide=%+7.1f vUp=%+7.1f  dt=%.4f",
        mode, custom, tostring(is), tostring(can), vIn, vSide, vUp, dt)
end

local function TickCapture(dt, pawn, cmc, jumpEdge)
    local custom = ReadOpt(cmc, "CustomMovementMode") or 0
    local can    = ReadOpt(comp, "CanClimbing")
    local is     = ReadOpt(comp, "IsClimbing")
    local line   = BuildLine(dt, pawn, cmc)

    if capLeft > 0 then
        capLeft = capLeft - 1
        dbg("  |%s", line)
        if capLeft == 0 then
            dbg("---- capture end ----")
            ring, ringN = {}, 0
        end
    else
        ringN = ringN + 1
        ring[(ringN - 1) % CAP_PRE + 1] = line
        local edge = nil
        if can ~= prevCan then edge = "CanClimbing -> " .. tostring(can) end
        if is  ~= prevIs  then edge = "IsClimbing -> "  .. tostring(is)  end
        if custom == 5 and prevCustom ~= 5 then edge = "entered climb mode (6/5)" end
        if prevCustom == 5 and custom ~= 5 then edge = "left climb mode" end
        if jumpEdge then edge = jumpEdge end
        if edge and prevCan ~= nil then
            dbg("---- %s ----", edge)
            for i = math.max(1, ringN - CAP_PRE + 1), ringN do
                dbg("  |%s", ring[(i - 1) % CAP_PRE + 1])
            end
            capLeft = CAP_POST
        end
    end
    prevCan, prevIs, prevCustom = can, is, custom
end




-- =========================================================================
-- 8. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    comp, compName = FindClimbingComponent(pawn)
    scanned        = true
    lastFallVz     = 0
    prevCustomIs5  = false
    prevClimbVel   = { X = 0, Y = 0, Z = 0 }
    prevWallFwd    = { X = 1, Y = 0 }
    prevClimbZ     = nil
    sliding        = false
    slideV         = 0
    savedClimbMax  = nil
    cj             = nil
    M.InClimbJump  = false
    hbT = 0
    prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
    stuckIsTicks = 0
    KSL = nil
    ring, ringN, capLeft = {}, 0, 0
    prevCan, prevIs, prevCustom = nil, nil, nil

    if comp == nil then
        dbg("climbing component NOT FOUND")
    else
        dbg("component: %s  ClimbMaxSpeed=%s  fwdRay=%s",
            compName, tostring(ReadOpt(cmc, "ClimbMaxSpeed")),
            tostring(ReadOpt(comp, "Const_ForwardRayLength")))
        CharacterizeTraceStruct(pawn)
    end
end

-- FIX B: remember fall speed only while falling; grounded clears it so a
-- stale hard-fall value cannot arm a slide on a later gentle entry.
local function RememberFallSpeed(mode, cmc)
    if mode == 3 then
        lastFallVz = cmc.Velocity.Z
    elseif mode == 1 or mode == 2 then
        lastFallVz = 0
    end
end

-- Cache the climb frame for next tick's detach classification.
local function CacheClimbFrame(pawn, cmc, inClimb)
    if inClimb then
        local v = cmc.Velocity
        prevClimbVel = { X = v.X, Y = v.Y, Z = v.Z }
        local f = WallFwd(pawn)
        if f ~= nil then prevWallFwd = f end
        prevClimbZ = GetZ(pawn)
    end
    prevCustomIs5 = inClimb
end

function M.OnTick(dt, pawn, cmc)
    if not scanned then return end

    local mode    = cmc.MovementMode
    local custom  = ReadOpt(cmc, "CustomMovementMode") or 0
    local inClimb = (mode == 6 and custom == 5)

    RememberFallSpeed(mode, cmc)
    LogComponentFlagEdges(mode, custom)

    local jumpEdge = DetectClimbJump(pawn, cmc, mode)
    TickClimbJump(dt, pawn, cmc, mode, inClimb)

    -- FIX A: TickClimbJump may have force-attached this very tick; the
    -- reconcile, slide, frame cache, and prevCustomIs5 must see the real
    -- state.
    mode    = cmc.MovementMode
    custom  = ReadOpt(cmc, "CustomMovementMode") or 0
    inClimb = (mode == 6 and custom == 5)

    ReconcileStuckClimbFlag(inClimb)
    UpdateWallSlide(dt, pawn, cmc, inClimb)
    CacheClimbFrame(pawn, cmc, inClimb)

    if CAPTURE and comp ~= nil then
        TickCapture(dt, pawn, cmc, jumpEdge)
    end
end

return M
