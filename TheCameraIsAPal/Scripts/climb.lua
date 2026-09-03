-- =========================================================================
-- climb.lua -- PalFeel climbing: a state machine layered over Palworld's
-- BP_PalClimbingComponent.
--
-- Author: TheTr3y
--
-- The component owns the climb itself. This file owns everything around it:
-- deciding when a climb should begin (and winning that decision from the
-- component's own grab), the hop that precedes a latch, the jump off a wall
-- and the leap along it, the slide that catches a fast fall, and the
-- hand-off to the component's vault at the top.
--
-- One mode at a time. Every frame reads the game once into a Frame, the
-- current mode's tick runs against that Frame and returns the next mode or
-- nothing, and SetMode is the only place a transition happens. Everything
-- taken from the game (input holds, the glider, the climb suppression, the
-- rotation flags, ...) is taken through the ledger in section 5 and given
-- back when the owning mode exits, so an exit cannot forget.
--
--   IDLE      nothing owned; watching for an approach, a grab, a vault
--   APPROACH  a face is in reach and the component is held off while we close
--   ASCENT    the hop: launch, hold the face, attach when viable
--   LATCHED   climbing; the latch watch, the wall slide, raw stick input
--   LEAP      the wall-plane jump: drive, track the face, re-attach
--   DISMOUNT  the hop away from the wall
--   VAULT     the component's own top-out; we only hold input off
-- =========================================================================

-- =========================================================================
-- 1. REQUIRES + DEBUG FLAGS
-- =========================================================================

local CommonState = require("commonstate")
local Easing      = require("easingfunctions")
local Input       = require("input")

-- TraceViz lives in UE4SS's shared/ folder and may not be installed. A hard
-- require would take the whole subsystem down with it.
local okViz, Viz = pcall(require, "TraceViz")
if not okViz then Viz = nil end

local DEBUG       = false   -- state-change lines
local DEBUG_FRAME = false   -- per-frame lines; never leave on, the log is untrimmed

-- Bounded discovery output: each line prints a fixed number of times per
-- session and then goes quiet. Defaulted ON because it answers questions
-- this file cannot answer by reasoning (what the component exposes, whether
-- a forced latch held, which reason ended a sequence).
local DEBUG_DISCOVERY = true

-- Deeper one-shot investigations (class function dump, tick-order sampling,
-- CanClimbingStart observation, trace-struct check) live in
-- climb_discover.lua. Off by default: their questions are answered, and
-- the function dump costs a startup hitch.
local DEBUG_DISCOVERY_DEEP = false
local Discover = nil
if DEBUG_DISCOVERY_DEEP then
    local okD, mod = pcall(require, "climb_discover")
    if okD then Discover = mod end
end

-- HUD-canvas visualisation of the checks through TraceViz. Unreal compiles
-- DrawDebug* out of shipping builds, so the DrawDebugType argument on every
-- Kismet trace is pinned to None and does nothing; TraceViz is the only
-- drawing that survives shipping.
local DEBUG_VOLUMES      = false
local DEBUG_VOLUME_TIME  = 0.0     -- s each drawn frame persists; 0 = one frame
local DEBUG_VOLUME_GATES = false   -- threshold bars along the approach line

-- =========================================================================
-- 2. TUNING
-- Distances are uu from the capsule SURFACE unless a name says otherwise.
-- =========================================================================

local T = {}

-- ---- wall detection ----
T.Detect = {
    CONE_DEG        = 40,     -- max angle between the stick and into-wall
    INPUT_FLOOR     = 0.6,    -- |Acceleration.XY| that counts as holding a direction (absolute, tiny on purpose)
    -- The primary check is a capsule sweep: the player's own radius, swept
    -- forward along the stick, spanning from just above step height to eye
    -- level. It starts above MaxStepHeight so a rock the player walks over
    -- is outside the volume entirely.
    SHAPE           = "capsule",   -- "capsule" | "line" (line is the fallback if the sweep does not report)
    FOOT_CLEARANCE  = 48,     -- uu above the feet the sweep starts; > MaxStepHeight (45)
    -- A hit at waist height is not a wall until it also passes:
    EYE_OFFSET_FRAC = 0.70,   -- of capsule half height, above centre: must also find the face
    WIDTH_HALF      = 40,     -- uu each side of the approach line: both must find the face
    REQUIRE_EYE     = true,
    REQUIRE_WIDTH   = true,
    SLACK           = 30,     -- uu of extra reach for the eye/width probes on a rough face
    -- 0 = line probes for the fan/eye/width rays. > 0 = sphere sweeps of
    -- that radius. Only lines are proven to fill the hit struct on this
    -- UE4SS build; safe to try, since a sweep that does not report arms nothing.
    PROBE_RADIUS    = 0,
    PENETRATION_SLOP = 6,     -- uu of negative gap still treated as contact, not "inside geometry"
    FAN_HEIGHT_FRAC = 0.45,   -- of half height: the airborne fan's vertical offset
    FAN_HEIGHT_PAD  = 4,      -- uu kept clear of the capsule end caps
    WALKABLE_Z_FALLBACK = 0.6428,  -- cos(50 deg), BP_PlayerBase default
    -- Clearance at which a face counts as grabbable. A plain tunable: the
    -- component's Const_ForwardRayLength has unverified units/origin and a
    -- derivation from it once made the latch harder, not easier.
    ATTACH_GAP      = 55,
}
T.Detect.CONE_COS = math.cos(math.rad(T.Detect.CONE_DEG))

-- ---- approach guard: winning the wall from the component's own grab ----
-- The component latches the moment its forward ray finds a face, and its
-- tick runs before ours (measured: 240 of 240 frames). So the guard reaches
-- further than the component does and suppresses CanClimbing while closing,
-- buying the frames our own hop needs. Suppression is time-boxed: if our
-- commit never fires the wall goes back to the game, or the player would
-- get neither.
T.Guard = {
    REACH        = 87,     -- uu: arm and suppress from here in
    COMMIT_WALK  = 21,     -- uu: a grounded walk-in commits here
    COMMIT_AIR   = 80,     -- uu: an airborne approach commits here (the hold closes the rest)
    RISE_VZ_MIN  = 5,      -- uu/s of rise required to arm while airborne; a fall is vanilla's
    TIMEOUT      = 0.45,   -- s armed without committing -> give the wall back
    COOLDOWN     = 0.80,   -- s of vanilla ownership after giving up, or after a spent jump
    LOST_TICKS   = 6,      -- consecutive probe misses tolerated before giving up
    FAN_NEAR_MULT = 2.5,   -- line mode only: below this multiple of the commit gap, re-probe with the fan
}

-- ---- ascent: the hop before the latch ----
T.Ascent = {
    LAUNCH_GRACE  = 0.12,  -- s for the game's jump to leave the ground before it counts as refused
    LAUNCH_VZ     = 1050,  -- overwrites the game's launch so every arc is identical; nil keeps the game's
    GRAVITY       = 2.2,   -- owned for the whole ascent (jump.lua is gated off by priority)
    -- Airborne entry: the mini hop, written straight onto velocity. DoJump
    -- is a no-op while rising and CanJump refuses while falling.
    HOP_VZ_ADD    = 500,
    HOP_VZ_MIN    = 460,
    HOP_VZ_MAX    = 1000,
    HOP_IN_SPEED  = 220,   -- uu/s into the wall on the hop frame
    APPROACH_HOLD = 0.12,  -- s of closing under the lock before the hop fires
    -- Attach the instant it is viable; these only let the hop read as a hop.
    MIN_AIR_TIME  = 0.18,
    MIN_RISE      = 95,    -- uu above launch before the first attempt (or at apex if lower)
    LOCK_TIME     = 0.72,  -- s of air time before giving up
    RETRY_INTERVAL = 0.06, -- s between forced attaches that did not take
    LOST_TICKS    = 5,     -- consecutive all-miss probes -> abort
    -- Closed loop holding the gap while rising, so the latch does not depend
    -- on what the wall collision left of the approach momentum.
    HOLD_GAP      = 8,
    IN_GAIN       = 14.0,  -- 1/s
    IN_MAX        = 320,   -- uu/s
    YAW_RATE      = 900,   -- deg/s slew cap while tracking the face
}

-- ---- latch watch ----
-- Forcing climb mode puts the pawn on the wall but the component's own
-- entry never ran, and its update can exit a state it did not set up. A
-- forced latch is watched: a drop back to falling while the face is still
-- in reach is answered once by the component's own external entry, then by
-- re-forcing, a bounded number of times.
T.Latch = {
    HOLD        = 0.40,    -- s after a forced latch to guard it
    MAX_REFORCE = 6,
}

-- ---- wall slide: a fast fall into a wall skids to a halt ----
T.Slide = {
    VZ_TRIGGER  = -600,    -- uu/s: entry speed at or below this starts a slide
    VZ_CAP      = 1600,
    TRANSFER    = 0.45,    -- fraction of entry speed carried into the slide
    DECEL       = 1400,    -- uu/s^2
    MIN_V       = 60,      -- uu/s: below this the slide has halted
    BLOCK_RATIO = 0.4,     -- moved/commanded below this = blocked
}

-- ---- leap: the wall-plane jump ----
-- Speed eases from START to END; drive time is derived from the curve's
-- time-average so travel is exactly DIST. Keep drive + ATTACH_WINDOW under
-- ~0.5s or the component's own cooldown expires mid-leap.
T.Leap = {
    SPEED_START  = 2200,
    SPEED_END    = 162,
    EASE         = Easing.EaseOutCirc,
    DIST         = 175,    -- uu of travel before the attach check
    ANGLES       = { UP = 0.0, DIAG = 45.0, SIDE = 90.0 },
    ATTACH_WINDOW = 0.10,  -- s at leap end to confirm a wall
    ATTACH_TRIES = 3,
    HOLD_GAP     = 5,      -- uu gap the inward correction holds
    RAY_LEN      = 112,    -- uu; fan reach (~1.4x the component's own ray)
    FAN_DEG      = 30,     -- side ray splay
    YAW_RATE     = 800,    -- deg/s slew cap
    PARALLEL     = 0.90,   -- facing.normal above this = the gap reading is trusted
    IN_GAIN      = 6.0,
    IN_MAX       = 400,
    WRAP_COS     = -0.70,  -- new normal vs facing below this (~135 deg) = corner too sharp -> detach
    LOST_TICKS   = 4,
    LEAD_RAY_BONUS = 8,    -- uu of score preference for the ray angled toward travel
    NORMAL_SMOOTHING = 12, -- 1/s; higher = snappier facing
    JUMP_VZ_MIN  = 600,    -- uu/s: rising faster than this out of climb mode is the player's jump
}

-- ---- dismount: the hop away (jump with the stick down) ----
T.Dismount = {
    VZ   = 620,
    OUT  = 300,   -- uu/s away from the wall
    LOCK = 0.20,  -- s the push and facing are held
}

-- ---- top-out: catching the lip mid-leap ----
-- Two-ray disagreement along the leap's facing: face still there at
-- shoulder height, gone above it. The latch is what stops the leap sailing
-- past; the component then runs its own vault with its own state.
--
-- NEVER call ClimbUpAtTopEvent by hand. Called outside the component's
-- state machine it runs against a stale destination and moved the player
-- across the map into the ocean. A pcall does not help: the call succeeds.
T.TopOut = {
    ENABLED     = true,
    LOW_OFFSET  = -10,     -- uu from capsule centre: must still find the face
    HIGH_OFFSET = 46,      -- uu above centre: must find nothing
    MAX_GAP     = 60,
}

-- ---- log budgets (lines per session) ----
T.Log = {
    TRANSITIONS = 120,
    LATCH       = 16,
    GIVEUPS     = 12,
    TELEPORTS   = 6,
    TELEPORT_JUMP_UU = 1500,   -- a single-frame displacement above this is a teleport, not movement
}

local TRACE_DRAW_NONE = 0
local TRACE_COLOR_A   = { R = 1, G = 0, B = 0, A = 1 }
local TRACE_COLOR_B   = { R = 0, G = 1, B = 0, A = 1 }

-- =========================================================================
-- 3. MODULE + STATE
-- =========================================================================

local M = { name = "climb" }

local Mode = {
    IDLE = "IDLE", APPROACH = "APPROACH", ASCENT = "ASCENT", LATCHED = "LATCHED",
    LEAP = "LEAP", DISMOUNT = "DISMOUNT", VAULT = "VAULT",
}
M.Mode = Mode.IDLE
-- Published booleans derived from the mode, for readers that only need these.
M.InInitClimbState = false
M.InClimbJump      = false

-- Modes in which this file (or the component) owns the pawn: jump.lua is
-- gated off and the rotation flags are ours.
local PRIORITY = { [Mode.ASCENT] = true, [Mode.LATCHED] = true,
                   [Mode.LEAP] = true, [Mode.VAULT] = true }

local JUMP_DIRECTIONS = {
    { name = "SIDE", sign = -1, x = -1.0, y =  0.0 },
    { name = "DIAG", sign = -1, x = -0.5, y =  0.5 },
    { name = "UP",   sign =  0, x =  0.0, y =  1.0 },
    { name = "DIAG", sign =  1, x =  0.5, y =  0.5 },
    { name = "SIDE", sign =  1, x =  1.0, y =  0.0 },
    { name = "DOWN", sign =  0, x =  0.0, y = -1.0 },
}

-- All mutable state. Rebuilt whole on every player cache, so nothing can
-- survive a respawn by being forgotten in a reset list.
local function NewState()
    return {
        mode = Mode.IDLE, modeTime = 0, inTransition = false,

        -- per-pawn constants, filled by OnPlayerCached
        comp = nil, compName = nil, clsPath = nil,
        radius = 34, halfH = 90, walkableZ = T.Detect.WALKABLE_Z_FALLBACK,
        fanOffset = 0, channel = 0,
        defaultOrient = nil, defaultDesiredRot = nil,
        KSL = nil,
        capsuleTraceOk = nil,      -- nil = untested; decided on the first grounded frame
        grappleCallable = nil,     -- true only if the signature dump shows no parameters

        -- mode-scoped state
        guard  = { armedTime = 0, lostFrames = 0, cooldown = 0, pending = nil },
        ascent = nil, watch = nil, leap = nil, slide = nil,

        -- carried between frames
        prev = { wallFwd = { X = 1, Y = 0 }, alongWall = 0, upward = 0,
                 sideSign = 0, fallVz = 0 },
        lastGroundCheck = nil,

        -- resource ledger: name -> { owners = {set}, applied = bool, saved = any }
        own = {},
        wantSuppress = false, heldSuppress = false,

        -- log budgets and the teleport watchdog
        log = {}, lastLoc = nil,
    }
end
local S = NewState()

local hooksRegistered = false   -- class-level hooks persist across respawns

-- =========================================================================
-- 4. UTILITIES
-- Every game access goes through a pcall. pcall does NOT catch native
-- access violations, so each dereference is validity-checked individually
-- and nothing is called on a guessed signature. The raw* functions exist
-- so pcall gets a static function plus arguments instead of a fresh
-- closure: these run dozens of times per frame.
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end
local function fdbg(fmt, ...)
    if DEBUG_FRAME then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end
local function ddbg(fmt, ...)
    if DEBUG_DISCOVERY then print(string.format("[PalFeel:climb/DISCOVER] " .. fmt .. "\n", ...)) end
end

-- true while the named budget has lines left this session
local function Budget(key, max)
    local n = S.log[key] or 0
    if n >= max then return false end
    S.log[key] = n + 1
    return true
end

local function rawGet(o, k) return o[k] end
local function ReadOpt(o, k)
    if o == nil then return nil end
    local ok, v = pcall(rawGet, o, k)
    if ok then return v end
    return nil
end

local function rawSet(o, k, v) o[k] = v end
local function WriteOpt(o, k, v)
    if o == nil then return false end
    return (pcall(rawSet, o, k, v))
end

-- Nested write (obj.field.sub = v), e.g. cmc.Velocity.Z
local function rawSet2(o, k1, k2, v) o[k1][k2] = v end
local function WriteOpt2(o, k1, k2, v)
    if o == nil then return false end
    return (pcall(rawSet2, o, k1, k2, v))
end

local function rawIsValid(o) return o:IsValid() end
local function IsLive(o)
    if o == nil then return false end
    local ok, v = pcall(rawIsValid, o)
    return ok and v == true
end

local function rawCall(o, m, ...) return o[m](o, ...) end
-- Returns ok, result...
local function CallOpt(o, m, ...)
    if o == nil then return false end
    return pcall(rawCall, o, m, ...)
end

local function Clamp(value, low, high)
    if value < low  then return low  end
    if value > high then return high end
    return value
end

local function NormalizeXY(x, y)
    local length = math.sqrt(x * x + y * y)
    if length < 1e-3 then return nil end
    return { X = x / length, Y = y / length }
end

local function rawLoc(p) local l = p:K2_GetActorLocation() return l.X, l.Y, l.Z end
local function GetLoc(pawn)
    local ok, x, y, z = pcall(rawLoc, pawn)
    if not ok or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

local function rawFwd(p) local f = p:GetActorForwardVector() return f.X, f.Y end
-- Horizontal forward direction. While climbing the character is pressed
-- flat to the wall, so this doubles as the into-wall direction.
local function WallFwd(pawn)
    local ok, x, y = pcall(rawFwd, pawn)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
    return NormalizeXY(x, y)
end

local function rawAccel(c) local a = c.Acceleration return a.X, a.Y end
-- Where the player is asking to go. Acceleration rather than Velocity:
-- pressed against a wall the velocity collapses while the input stays.
local function GetInputDirection(cmc)
    local ok, x, y = pcall(rawAccel, cmc)
    if not ok or type(x) ~= "number" then return nil end
    local mag = math.sqrt(x * x + y * y)
    if mag < T.Detect.INPUT_FLOOR then return nil end
    return { X = x / mag, Y = y / mag }
end

local function SetHorizVel(cmc, x, y)
    WriteOpt2(cmc, "Velocity", "X", x)
    WriteOpt2(cmc, "Velocity", "Y", y)
end

local function SetVertVel(cmc, z)
    WriteOpt2(cmc, "Velocity", "Z", z)
end

local function FaceYaw(pawn, faceDir)
    if faceDir == nil then return end
    local yaw = math.deg(math.atan(faceDir.Y, faceDir.X))
    CallOpt(pawn, "K2_SetActorRotation", { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false)
end

-- Slews a yaw angle toward a target direction in angle space, so the result
-- cannot jitter or shorten. Returns the new angle and its unit vector.
local function SlewYawToward(currentAngle, targetX, targetY, dt, rateDegPerSec)
    local targetAngle = math.deg(math.atan(targetY, targetX))
    if currentAngle == nil then currentAngle = targetAngle end
    local delta = targetAngle - currentAngle
    while delta >  180 do delta = delta - 360 end
    while delta < -180 do delta = delta + 360 end
    local factor = math.min(1.0, dt * (rateDegPerSec / 45.0))
    local newAngle = currentAngle + delta * factor
    local rad = math.rad(newAngle)
    return newAngle, { X = math.cos(rad), Y = math.sin(rad) }
end

-- Whatever produced the input, the movement component gets zero this tick.
-- SetIgnoreMoveInput is not honoured by every input path.
local function DrainMoveInput(cmc)
    CallOpt(cmc, "ConsumeInputVector")
end

-- =========================================================================
-- 5. RESOURCES
-- Everything this file takes from the game, taken and given back through
-- one ledger. A resource is applied when its first owner takes it and
-- released when its last owner gives it. GiveAll(owner) runs on every mode
-- exit, so an exit cannot leave a hold behind.
--
-- Take/Give only change ownership; the game writes happen in Settle. During
-- a transition Settle is deferred until the new mode has taken what it
-- needs, so a resource handed from one mode to the next is never released
-- and re-applied in between.
-- =========================================================================

local function ApplyClimbSuppression()
    -- Only ever writes false to suppress, or true to release a suppression
    -- it applied itself. The game sets CanClimbing false for its own
    -- reasons (stamina, water) and a blanket true would override those.
    if not IsLive(S.comp) then return end
    if S.wantSuppress then
        WriteOpt(S.comp, "CanClimbing", false)
        S.heldSuppress = true
    elseif S.heldSuppress then
        WriteOpt(S.comp, "CanClimbing", true)
        S.heldSuppress = false
    end
end

local function rawController(p) return p:GetController() end
local function GetController(pawn)
    local ok, c = pcall(rawController, pawn)
    if ok and IsLive(c) then return c end
    return nil
end

local Resources = {
    -- SetIgnoreMoveInput is a COUNTER on the controller: true increments,
    -- false decrements. ResetIgnoreMoveInput assigns the CDO default and
    -- releases every hold including other systems'; it is never used.
    moveinput = {
        take = function(F) CallOpt(GetController(F.pawn), "SetIgnoreMoveInput", true) end,
        give = function(F) CallOpt(GetController(F.pawn), "SetIgnoreMoveInput", false) end,
    },
    glider = {
        take = function(F)
            local glider = ReadOpt(F.pawn, "BP_GliderComponent")
            if IsLive(glider) then
                CallOpt(F.cmc, "SetGliderDisbleFlag", ReadOpt(glider, "GliderDisableFlag"), true)
            end
        end,
        give = function(F)
            local glider = ReadOpt(F.pawn, "BP_GliderComponent")
            if IsLive(glider) then
                CallOpt(F.cmc, "SetGliderDisbleFlag", ReadOpt(glider, "GliderDisableFlag"), false)
            end
        end,
    },
    -- JumpMaxCount = 0 makes ACharacter::CanJump fail.
    nativejump = {
        take = function(F, r)
            r.saved = ReadOpt(F.pawn, "JumpMaxCount") or 1
            WriteOpt(F.pawn, "JumpMaxCount", 0)
        end,
        give = function(F, r) WriteOpt(F.pawn, "JumpMaxCount", r.saved or 1) end,
    },
    -- The write itself is also applied from the component's ReceiveTick
    -- pre-hook, the only point provably ahead of its logic this frame.
    suppress = {
        take = function() S.wantSuppress = true;  ApplyClimbSuppression() end,
        give = function() S.wantSuppress = false; ApplyClimbSuppression() end,
    },
    -- Rotation is ours while we own the pawn. OrientRotationToMovement left
    -- on spins the character toward the stick every frame. Restored to the
    -- SPAWN values: a value read at take time can be the game's own false
    -- from a climb already in progress.
    rotation = {
        take = function(F)
            WriteOpt(F.cmc, "bUseControllerDesiredRotation", false)
            WriteOpt(F.cmc, "bOrientRotationToMovement", false)
        end,
        give = function(F)
            local desired = S.defaultDesiredRot
            if desired == nil then desired = true end
            WriteOpt(F.cmc, "bUseControllerDesiredRotation", desired)
            if S.defaultOrient ~= nil then
                WriteOpt(F.cmc, "bOrientRotationToMovement", S.defaultOrient)
            end
        end,
    },
    -- ClimbMaxSpeed = 0 doubles as the input lock during a slide.
    climbmax = {
        take = function(F, r)
            r.saved = ReadOpt(F.cmc, "ClimbMaxSpeed")
            if r.saved ~= nil and not WriteOpt(F.cmc, "ClimbMaxSpeed", 0) then
                dbg("WARN: ClimbMaxSpeed write failed -- slide input not locked")
                r.saved = nil
            end
        end,
        give = function(F, r)
            if r.saved ~= nil then WriteOpt(F.cmc, "ClimbMaxSpeed", r.saved) end
        end,
    },
}

local function SettleResources(F)
    for name, r in pairs(S.own) do
        local wanted = next(r.owners) ~= nil
        if wanted and not r.applied then
            r.applied = true
            Resources[name].take(F, r)
        elseif not wanted and r.applied then
            r.applied = false
            Resources[name].give(F, r)
            S.own[name] = nil
        elseif not wanted then
            S.own[name] = nil
        end
    end
end

local function Take(F, name, owner)
    local r = S.own[name]
    if r == nil then
        r = { owners = {}, applied = false }
        S.own[name] = r
    end
    r.owners[owner] = true
    if not S.inTransition then SettleResources(F) end
end

local function Give(F, name, owner)
    local r = S.own[name]
    if r == nil or not r.owners[owner] then return end
    r.owners[owner] = nil
    if not S.inTransition then SettleResources(F) end
end

local function GiveAll(F, owner)
    for _, r in pairs(S.own) do r.owners[owner] = nil end
    if not S.inTransition then SettleResources(F) end
end

-- =========================================================================
-- 6. SENSING
-- Traces on the climbing component's own channel. A hit is normalised to
-- { normalX, normalY, normalZ, gap } where gap is clearance from the
-- capsule SURFACE, so every threshold in section 2 means the same thing.
-- =========================================================================

local function EnsureKSL()
    if IsLive(S.KSL) then return S.KSL end
    S.KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if IsLive(S.KSL) then return S.KSL end
    return nil
end

local function rawReadHit(h)
    local n = h.ImpactNormal
    return n.X, n.Y, n.Z, h.Distance
end
local function ReadHit(hitResult)
    local ok, nx, ny, nz, dist = pcall(rawReadHit, hitResult)
    if not ok or type(nx) ~= "number" or type(ny) ~= "number"
       or type(nz) ~= "number" or type(dist) ~= "number" then
        return nil
    end
    return nx, ny, nz, dist
end

-- One trace. radius 0 = line; radius > 0 without halfH = sphere; with
-- halfH = upright capsule. Returns normalX, normalY, normalZ, distance, or nil.
local function Trace(pawn, from, to, channel, radius, halfH)
    local KSL = EnsureKSL()
    if KSL == nil then return nil end
    local hitResult, ok, didHit = {}, false, nil
    if halfH ~= nil then
        ok, didHit = CallOpt(KSL, "CapsuleTraceSingle", pawn, from, to, radius, halfH,
            channel, false, {}, TRACE_DRAW_NONE, hitResult, true,
            TRACE_COLOR_A, TRACE_COLOR_B, 0.0)
    elseif radius > 0 then
        ok, didHit = CallOpt(KSL, "SphereTraceSingle", pawn, from, to, radius,
            channel, false, {}, TRACE_DRAW_NONE, hitResult, true,
            TRACE_COLOR_A, TRACE_COLOR_B, 0.0)
    else
        ok, didHit = CallOpt(KSL, "LineTraceSingle", pawn, from, to,
            channel, false, {}, TRACE_DRAW_NONE, hitResult, true,
            TRACE_COLOR_A, TRACE_COLOR_B, 0.0)
    end
    if not ok or not didHit then return nil end
    return ReadHit(hitResult)
end

-- A level probe from the capsule centre (offset up/down by heightOffset and
-- sideways by lateral; positive lateral is to the left of travel). `origin`
-- is the frame's location when the caller has it; nothing moves the pawn
-- before sensing within a tick.
local function TraceAlongDirection(pawn, direction, rayLength, heightOffset, lateral, origin)
    local base = origin or GetLoc(pawn)
    if base == nil then return nil end
    local start = { X = base.X, Y = base.Y, Z = base.Z + (heightOffset or 0) }
    if lateral and lateral ~= 0 then
        start.X = start.X - direction.Y * lateral
        start.Y = start.Y + direction.X * lateral
    end
    local finish = { X = start.X + direction.X * rayLength,
                     Y = start.Y + direction.Y * rayLength, Z = start.Z }
    local radius = T.Detect.PROBE_RADIUS
    local nx, ny, nz, dist = Trace(pawn, start, finish, S.channel, radius, nil)
    if nx == nil then return nil end
    -- A sweep's Distance is how far the sphere's CENTRE travelled; the
    -- surface it touched is one radius further on.
    return { normalX = nx, normalY = ny, normalZ = nz, gap = dist + radius - S.radius }
end

-- Vertical extent of the capsule check relative to the actor origin: bottom
-- just above step height, top at eye level. Half height never drops below
-- the radius (a capsule shorter than it is wide is a sphere).
local function CapsuleCheckExtent()
    local bottom = -S.halfH + T.Detect.FOOT_CLEARANCE
    local top    =  S.halfH * T.Detect.EYE_OFFSET_FRAC
    local centre = (bottom + top) * 0.5
    local half   = math.max((top - bottom) * 0.5, S.radius)
    return centre, half
end

-- The capsule check. Because the swept radius IS the player's radius, the
-- sweep distance is the clearance from the player's surface: gap = Distance.
local function CapsuleSweepAhead(pawn, direction, maxGap, origin)
    origin = origin or GetLoc(pawn)
    if origin == nil then return nil end
    local zc, half = CapsuleCheckExtent()
    local from = { X = origin.X, Y = origin.Y, Z = origin.Z + zc }
    local to   = { X = origin.X + direction.X * maxGap,
                   Y = origin.Y + direction.Y * maxGap, Z = origin.Z + zc }
    local nx, ny, nz, dist = Trace(pawn, from, to, S.channel, S.radius, half)
    if nx == nil then return nil end
    return { normalX = nx, normalY = ny, normalZ = nz, gap = dist }
end

-- Decided once, on the first grounded frame: a sweep straight down must
-- find the floor and report a readable distance, or every wall would be
-- invisible, silently. Visibility channel: the floor blocks it regardless.
local function SelfTestCapsuleTrace(pawn)
    local origin = GetLoc(pawn)
    if origin == nil then return end
    local from = { X = origin.X, Y = origin.Y, Z = origin.Z + 150 }
    local to   = { X = origin.X, Y = origin.Y, Z = origin.Z - 150 }
    local KSL = EnsureKSL()
    if KSL == nil then return end
    local hitResult = {}
    local ok, didHit = CallOpt(KSL, "CapsuleTraceSingle", pawn, from, to, S.radius, S.halfH,
        0, false, {}, TRACE_DRAW_NONE, hitResult, true, TRACE_COLOR_A, TRACE_COLOR_B, 0.0)
    if not ok or not didHit then return end   -- nothing under us yet; next grounded frame
    local dist = ReadOpt(hitResult, "Distance")
    S.capsuleTraceOk = (type(dist) == "number")
    if S.capsuleTraceOk then
        ddbg("capsule trace self-test: OK (floor at %.1f) -- capsule check active", dist)
    else
        ddbg("capsule trace self-test: FAILED -- CapsuleTraceSingle does not fill "
            .. "the hit struct on this build. Falling back to line probes.")
    end
end

local function UsingCapsuleCheck()
    return T.Detect.SHAPE == "capsule" and S.capsuleTraceOk ~= false
end

-- Everything that makes a hit a climbable wall, in one place, so detection
-- and attach cannot drift apart. Returns { faceDir, gap } or nil.
local function ClassifyWallHit(hit, maxGap)
    if hit == nil then return nil end
    -- Deep negative gap: the trace started inside geometry, where UE returns
    -- a normal facing back down the trace (a perfect head-on wall, always).
    if hit.gap < -T.Detect.PENETRATION_SLOP then return nil end
    if hit.gap > maxGap then return nil end
    -- The game's own line between "walk up it" and "must climb it".
    if hit.normalZ >= S.walkableZ then return nil end
    local intoWall = NormalizeXY(-hit.normalX, -hit.normalY)
    if intoWall == nil then return nil end
    return { faceDir = intoWall, gap = math.max(hit.gap, 0) }
end

-- Probes at three heights and keeps the nearest climbable face. `gap` is
-- the nearest reading (what a hold loop should chase); `centreGap` is the
-- centre ray alone, the ray the component itself casts, and the one an
-- attach is judged on.
local function ProbeWallFan(pawn, direction, rayLength, maxGap, origin)
    local bestWall, centreGap = nil, nil
    local function ProbeAt(heightOffset)
        local wall = ClassifyWallHit(
            TraceAlongDirection(pawn, direction, rayLength, heightOffset, 0, origin), maxGap)
        if wall == nil then return nil end
        if bestWall == nil or wall.gap < bestWall.gap then bestWall = wall end
        return wall
    end
    local centre = ProbeAt(0)
    if centre ~= nil then centreGap = centre.gap end
    if S.fanOffset > 0 then
        ProbeAt(S.fanOffset)
        ProbeAt(-S.fanOffset)
    end
    if bestWall ~= nil then bestWall.centreGap = centreGap end
    return bestWall
end

-- The two tests that separate a wall from something merely in the way.
-- Both probe along the APPROACH direction: "would the player, going this
-- way, meet a face here".
local function PassesWallShapeChecks(pawn, direction, reach, origin)
    local probeReach = reach + T.Detect.SLACK
    if T.Detect.REQUIRE_EYE then
        local eye = TraceAlongDirection(pawn, direction, probeReach,
            S.halfH * T.Detect.EYE_OFFSET_FRAC, 0, origin)
        if eye == nil then return false, "not at eye level (low obstacle)" end
        if eye.normalZ >= S.walkableZ then
            return false, string.format("walkable at eye level (normalZ %.2f)", eye.normalZ)
        end
    end
    if T.Detect.REQUIRE_WIDTH then
        local w = T.Detect.WIDTH_HALF
        local left  = TraceAlongDirection(pawn, direction, probeReach, 0,  w, origin)
        local right = TraceAlongDirection(pawn, direction, probeReach, 0, -w, origin)
        if left == nil or right == nil then
            return false, string.format("too narrow (left %s, right %s)",
                left and "hit" or "miss", right and "hit" or "miss")
        end
    end
    return true
end

-- Is the player moving into a wall, rather than past one or up a slope?
-- Returns { faceDir, gap } or nil plus a short reason.
local function WallInMovementPath(F, maxGap, useFan)
    local inputDirection = F.input
    if inputDirection == nil then return nil, "no input held" end

    local rayLength = S.radius + maxGap
    local hit, wall
    if UsingCapsuleCheck() then
        hit = CapsuleSweepAhead(F.pawn, inputDirection, maxGap, F.loc)
        if hit == nil then return nil, "capsule found nothing" end
        wall = ClassifyWallHit(hit, maxGap)
        if wall == nil then
            if hit.normalZ >= S.walkableZ then
                return nil, string.format("capsule hit walkable (normalZ %.2f)", hit.normalZ)
            end
            return nil, "capsule hit unclassifiable"
        end
    elseif useFan then
        wall = ProbeWallFan(F.pawn, inputDirection, rayLength, maxGap, F.loc)
        if wall == nil then return nil, "fan found no climbable face" end
    else
        hit = TraceAlongDirection(F.pawn, inputDirection, rayLength, 0, 0, F.loc)
        if hit == nil then return nil, "ray missed" end
        wall = ClassifyWallHit(hit, maxGap)
        if wall == nil then
            if hit.gap < -T.Detect.PENETRATION_SLOP then
                return nil, string.format("trace inside geometry (gap %.1f)", hit.gap)
            elseif hit.gap > maxGap then
                return nil, string.format("beyond reach (gap %.1f > %.0f)", hit.gap, maxGap)
            elseif hit.normalZ >= S.walkableZ then
                return nil, string.format("surface walkable (normalZ %.2f)", hit.normalZ)
            end
            return nil, "unclassifiable hit"
        end
    end

    local alignment = inputDirection.X * wall.faceDir.X + inputDirection.Y * wall.faceDir.Y
    if alignment < T.Detect.CONE_COS then
        return nil, string.format("outside cone (%.0f deg)",
            math.deg(math.acos(Clamp(alignment, -1, 1))))
    end

    local shapeOk, shapeWhy = PassesWallShapeChecks(F.pawn, inputDirection, rayLength, F.loc)
    if not shapeOk then return nil, shapeWhy end
    return wall
end

-- Three rays in a fan around the leap's facing; the best hit or nil.
-- Returns { normalX, normalY, gap, rayAngle }: a non-zero rayAngle means the
-- face is off to that side, which is what identifies a corner.
local function SenseWall(pawn, wallFacing, leapSideSign, origin)
    local bestHit, bestScore = nil, math.huge
    local function CastRay(angleDeg)
        local a = math.rad(angleDeg)
        local dir = { X = wallFacing.X * math.cos(a) - wallFacing.Y * math.sin(a),
                      Y = wallFacing.X * math.sin(a) + wallFacing.Y * math.cos(a) }
        local hit = TraceAlongDirection(pawn, dir, T.Leap.RAY_LEN, 0, 0, origin)
        if hit == nil then return end
        -- The ray angled toward the leap's travel side sees corners first,
        -- so it wins near-ties.
        local leading = (leapSideSign ~= 0) and (angleDeg * leapSideSign > 0)
        local score = hit.gap - (leading and T.Leap.LEAD_RAY_BONUS or 0)
        if score < bestScore then
            bestScore = score
            bestHit = { normalX = hit.normalX, normalY = hit.normalY, gap = hit.gap, rayAngle = angleDeg }
        end
    end
    CastRay(0)
    if leapSideSign ~= 0 then
        CastRay(T.Leap.FAN_DEG * leapSideSign)
        CastRay(-T.Leap.FAN_DEG * leapSideSign)
    end
    return bestHit
end

-- Is the face about to end just above us? Low ray still finds it, high ray
-- finds nothing: that difference is the lip.
local function SenseTopEdge(pawn, faceDir, origin)
    local reach = S.radius + T.TopOut.MAX_GAP
    local low = TraceAlongDirection(pawn, faceDir, reach, T.TopOut.LOW_OFFSET, 0, origin)
    if low == nil or low.gap > T.TopOut.MAX_GAP then return false end
    if low.normalZ >= S.walkableZ then return false end   -- a slope rolling over, not a lip
    local high = TraceAlongDirection(pawn, faceDir, reach, T.TopOut.HIGH_OFFSET, 0, origin)
    return high == nil
end

-- =========================================================================
-- 7. STATES
-- Each mode is { enter(F, from, payload), tick(F) -> next, why, payload | nil,
-- exit(F, to, why) }. Ticks read the Frame and never re-read the game for
-- what the Frame already holds. ReadModes re-reads the movement mode after
-- this file's own writes, the only reads that can change mid-tick.
-- =========================================================================

local function ReadModes(F)
    F.mode       = ReadOpt(F.cmc, "MovementMode") or 0
    F.custom     = ReadOpt(F.cmc, "CustomMovementMode") or 0
    F.isClimbing = (F.mode == 6 and F.custom == 5)
    F.isWalking  = (F.mode == 1 or F.mode == 2 or (F.mode == 6 and F.custom == 2))
    F.isFalling  = (F.mode == 3)
end

local function rawVz(c) return c.Velocity.Z end
local function ReadFrame(pawn, cmc, dt)
    local F = { pawn = pawn, cmc = cmc, dt = dt }
    ReadModes(F)
    local okVz, vz = pcall(rawVz, cmc)
    F.vz    = (okVz and type(vz) == "number") and vz or 0
    F.loc   = GetLoc(pawn)
    F.input = GetInputDirection(cmc)
    F.atTop = IsLive(S.comp) and ReadOpt(S.comp, "UpAtTopMode") == true
    return F
end

-- This frame's height, from the Frame. Only the slide moves the pawn
-- mid-tick, and it re-reads for itself.
local function GetZ(F)
    return F.loc and F.loc.Z or 0
end

local function GetLocZ(pawn)
    local loc = GetLoc(pawn)
    return loc and loc.Z or nil
end

-- Writes the component into its organic post-attach signature and forces
-- climb mode. Reports whether the writes were kept: latched or not.
local function ForceAttach(F)
    if not IsLive(S.comp) then
        dbg("WARN: climb component stale -- attach skipped")
        return false
    end
    -- Direct CanClimbing write: the suppression bookkeeping follows it or a
    -- later release would believe it still holds the component off.
    if WriteOpt(S.comp, "CanClimbing", true) then
        S.wantSuppress = false
        S.heldSuppress = false
    end
    local ok = CallOpt(F.cmc, "SetMovementMode", 6, 5)
    if not ok then
        WriteOpt(F.cmc, "MovementMode", 6)
        WriteOpt(F.cmc, "CustomMovementMode", 5)
    end
    WriteOpt(S.comp, "IsClimbing", true)
    WriteOpt(S.comp, "IsEnding", false)
    ReadModes(F)
    return F.isClimbing
end

-- The component's own external entry: "try to start climbing now", built
-- for the moment a grapple lands the player against a face. Called only
-- when the signature dump has shown it takes no arguments.
local function TryComponentClimbEntry()
    if S.grappleCallable ~= true or not IsLive(S.comp) then return false end
    return (CallOpt(S.comp, "TryClimbAfterGrappling"))
end

-- Bucket and side sign for a climb jump, from the stick in wall space.
-- Neutral maps to UP.
local function ClassifyJumpDirection(alongWall, upward)
    local mag = math.sqrt(alongWall * alongWall + upward * upward)
    if mag < 1e-3 then return "UP", 0 end
    local x, y = alongWall / mag, upward / mag
    local best, bestDot = nil, -math.huge
    for _, d in ipairs(JUMP_DIRECTIONS) do
        local len = math.sqrt(d.x * d.x + d.y * d.y)
        local dot = x * (d.x / len) + y * (d.y / len)
        if dot > bestDot then bestDot, best = dot, d end
    end
    return best.name, best.sign
end

local States = {}

-- ---- IDLE ---------------------------------------------------------------
-- Nothing owned. Arms the approach on a walk-in or a rise at a face; a
-- plain fall is left to the component's organic grab so the wall slide
-- keeps its entry.
States[Mode.IDLE] = {
    enter = function() end,
    tick = function(F)
        if F.isClimbing then return Mode.LATCHED, "organic grab" end
        if F.atTop then return Mode.VAULT, "component vault" end

        if S.guard.cooldown > 0 then
            S.guard.cooldown = math.max(0, S.guard.cooldown - F.dt)
            return nil
        end
        local rising = F.isFalling and F.vz >= T.Guard.RISE_VZ_MIN
        if not (F.isWalking or rising) then return nil end
        -- Without a component to hand the wall to, a hop would spend the
        -- player's jump for nothing.
        if not IsLive(S.comp) then return nil end

        local wall = WallInMovementPath(F, T.Guard.REACH, false)
        if wall == nil then return nil end
        S.guard.pending = wall
        return Mode.APPROACH, "face in reach"
    end,
    exit = function() end,
}

-- ---- APPROACH -----------------------------------------------------------
-- Holds the component off from REACH in and commits once close enough.
-- Once armed it holds through the whole approach: a jump at a wall arcs
-- over long before the face is in range, and checking "still rising" every
-- frame would drop the guard exactly when it is needed.
local function YieldWall(F, reason, gap)
    if Budget("giveups", T.Log.GIVEUPS) then
        ddbg("guard gave up (%s, lastGap=%s) -- wall handed back to the vanilla "
            .. "grab for %.2fs", reason, gap and string.format("%.1f", gap) or "none",
            T.Guard.COOLDOWN)
    end
    S.guard.cooldown = T.Guard.COOLDOWN
end

States[Mode.APPROACH] = {
    enter = function(F)
        S.guard.armedTime  = 0
        S.guard.lostFrames = 0
        Take(F, "suppress", Mode.APPROACH)
    end,
    tick = function(F)
        if F.isClimbing then return Mode.LATCHED, "organic grab" end
        -- The wall slide's own entry speed: hand off at exactly one boundary.
        if F.isFalling and F.vz <= T.Slide.VZ_TRIGGER then
            return Mode.IDLE, "falling hard: wall slide's entry"
        end

        -- The wall IDLE found this frame is reused rather than re-probed.
        local wall, why = S.guard.pending, nil
        S.guard.pending = nil
        if wall == nil then
            wall, why = WallInMovementPath(F, T.Guard.REACH, false)
            -- Line mode only: the single centre ray is blind to a face recessed
            -- at waist height; the fan gets the second look. The capsule sweep
            -- already spans the height, so a second call would repeat it.
            if wall == nil and why ~= "no input held" and not UsingCapsuleCheck() then
                wall = WallInMovementPath(F, T.Guard.REACH, true)
            end
        end

        if wall == nil then
            -- Releasing the stick is the absence of a request, not a failure
            -- to converge: no cooldown, ready to re-arm the instant it returns.
            if why == "no input held" then return Mode.IDLE, "input released" end
            S.guard.lostFrames = S.guard.lostFrames + 1
            if S.guard.lostFrames < T.Guard.LOST_TICKS then return nil end
            YieldWall(F, why or "probe lost the face", nil)
            return Mode.IDLE, "face lost"
        end
        S.guard.lostFrames = 0
        S.guard.armedTime  = S.guard.armedTime + F.dt

        -- A walk-in commits close, where it reads as intent; an airborne
        -- approach commits as soon as the hop can still land before contact.
        local commitGap = F.isWalking and T.Guard.COMMIT_WALK or T.Guard.COMMIT_AIR
        if wall.gap <= commitGap * T.Guard.FAN_NEAR_MULT and not UsingCapsuleCheck() then
            local fanned = WallInMovementPath(F, T.Guard.REACH, true)
            if fanned ~= nil and fanned.gap < wall.gap then wall = fanned end
        end
        fdbg("guard: gap=%.1f vz=%.0f walk=%s armed=%.2fs", wall.gap, F.vz,
            tostring(F.isWalking), S.guard.armedTime)

        if wall.gap <= commitGap then
            return Mode.ASCENT, F.isWalking and "ground entry" or "air entry", wall
        end
        if S.guard.armedTime >= T.Guard.TIMEOUT then
            YieldWall(F, "no commit before timeout", wall.gap)
            return Mode.IDLE, "timeout"
        end
        return nil
    end,
    exit = function(F) GiveAll(F, Mode.APPROACH) end,
}

-- ---- ASCENT -------------------------------------------------------------
-- Walk or fly into a face -> hop -> latch. One state for both entries.
--   launch : ground asks the game to jump and waits for MOVE_Falling
--            (RequestJump only raises bPressedJump); air is airborne
--            already and holds APPROACH_HOLD before writing the hop.
--   rise   : every frame re-probes the face, re-squares to it, and holds
--            the gap with a closed loop.
--   attach : the moment the centre gap is inside ATTACH_GAP, on every frame
--            until the window closes.
-- Owns: suppression, move input, glider, gravity, rotation (via priority).
local function AscentFail(F, reason)
    -- A sequence that spent its jump hands the wall to vanilla for the same
    -- cooldown a guard give-up takes; otherwise a player still pushing at a
    -- face this file could not take re-arms next frame and jumps again.
    S.guard.cooldown = T.Guard.COOLDOWN
    return Mode.IDLE, reason
end

-- Ground entry: false until the character has actually left the ground.
local function AscentConfirmLaunch(F, a)
    if a.hasLaunched then return true end
    a.timeSinceRequest = a.timeSinceRequest + F.dt
    if not F.isFalling then return false end
    a.hasLaunched = true
    a.launchZ     = GetZ(F)
    if T.Ascent.LAUNCH_VZ ~= nil then SetVertVel(F.cmc, T.Ascent.LAUNCH_VZ) end
    return true
end

local function AscentMiniHop(F, a)
    local hopVz = Clamp(F.vz + T.Ascent.HOP_VZ_ADD, T.Ascent.HOP_VZ_MIN, T.Ascent.HOP_VZ_MAX)
    SetVertVel(F.cmc, hopVz)
    SetHorizVel(F.cmc, a.faceDir.X * T.Ascent.HOP_IN_SPEED, a.faceDir.Y * T.Ascent.HOP_IN_SPEED)
    a.phase   = "rise"
    a.airTime = 0
    a.launchZ = GetZ(F)
    dbg("mini hop after %.2fs approach: vz %.0f -> %.0f", a.approachTime, F.vz, hopVz)
end

-- Air time and rise only let the hop read as a hop before the latch lands.
-- The apex clause guarantees the gate opens for a minimum-strength hop.
local function AscentGateOpen(F, a)
    if a.airTime < T.Ascent.MIN_AIR_TIME then return false end
    if GetZ(F) - a.launchZ >= T.Ascent.MIN_RISE then return true end
    return F.vz <= 0
end

States[Mode.ASCENT] = {
    enter = function(F, from, wall)
        local a = {
            type = F.isWalking and "ground" or "air",
            faceDir = wall.faceDir,
            currentYaw = math.deg(math.atan(wall.faceDir.Y, wall.faceDir.X)),
            phase = "launch", timeSinceRequest = 0, hasLaunched = false,
            approachTime = 0, airTime = 0, launchZ = GetZ(F),
            tries = 0, retryCooldown = 0, framesWithoutWall = 0, inVel = 0,
            refused = false,
        }
        S.ascent = a
        FaceYaw(F.pawn, a.faceDir)
        Take(F, "suppress",  Mode.ASCENT)
        Take(F, "moveinput", Mode.ASCENT)
        Take(F, "glider",    Mode.ASCENT)

        if a.type == "ground" then
            -- The game's own jump keeps its animation and stamina cost.
            if not CallOpt(F.pawn, "RequestJump") then a.refused = true end
        else
            a.phase = "hold"
            a.hasLaunched = true
        end
        S.log.seq = (S.log.seq or 0) + 1
        dbg("ascent #%d start: %s entry, gap=%.1f", S.log.seq, a.type, wall.gap)
    end,
    tick = function(F)
        local a = S.ascent
        if F.isClimbing then return Mode.LATCHED, "climb reached outside the sequence" end
        if a.refused then return AscentFail(F, "RequestJump call failed") end
        if not AscentConfirmLaunch(F, a) then
            if a.timeSinceRequest > T.Ascent.LAUNCH_GRACE then
                return AscentFail(F, "jump never executed")
            end
            return nil
        end

        if a.phase == "hold" then
            a.approachTime = a.approachTime + F.dt
        else
            a.airTime = a.airTime + F.dt
            if a.airTime > T.Ascent.LOCK_TIME then
                return AscentFail(F, "window closed without a latch")
            end
        end

        WriteOpt(F.cmc, "GravityScale", T.Ascent.GRAVITY)
        DrainMoveInput(F.cmc)

        -- Tracks well past grab range so the hold loop can pull a drifting
        -- ascent back in instead of losing the face.
        local wall = ProbeWallFan(F.pawn, a.faceDir, S.radius + T.Guard.REACH, T.Guard.REACH, F.loc)
        if wall == nil then
            a.framesWithoutWall = a.framesWithoutWall + 1
            a.inVel = 0
            if a.framesWithoutWall >= T.Ascent.LOST_TICKS then
                return AscentFail(F, "wall lost during ascent")
            end
        else
            a.framesWithoutWall = 0
            a.currentYaw, a.faceDir = SlewYawToward(a.currentYaw, wall.faceDir.X, wall.faceDir.Y,
                F.dt, T.Ascent.YAW_RATE)
            a.inVel = Clamp((wall.gap - T.Ascent.HOLD_GAP) * T.Ascent.IN_GAIN,
                -T.Ascent.IN_MAX, T.Ascent.IN_MAX)
        end
        FaceYaw(F.pawn, a.faceDir)
        SetHorizVel(F.cmc, a.faceDir.X * a.inVel, a.faceDir.Y * a.inVel)

        -- The hold: same tracking and the same loop driving at the face, but
        -- no attach attempts, so the hop reads as a deliberate move.
        if a.phase == "hold" then
            if a.approachTime >= T.Ascent.APPROACH_HOLD then AscentMiniHop(F, a) end
            return nil
        end

        a.retryCooldown = math.max(0, a.retryCooldown - F.dt)
        -- Judged on the centre ray, the one the component re-casts to decide
        -- whether to keep the climb.
        local attachGap = wall and (wall.centreGap or wall.gap)
        if attachGap == nil or a.retryCooldown > 0 or attachGap > T.Detect.ATTACH_GAP
           or not AscentGateOpen(F, a) then
            return nil
        end

        local latched = ForceAttach(F)
        a.tries         = a.tries + 1
        a.retryCooldown = T.Ascent.RETRY_INTERVAL
        if Budget("latch", T.Log.LATCH) then
            ddbg("attach try %d: gap=%.1f (reach %.1f) rise=%.0f air=%.2fs groundCheck=%s -> %s",
                a.tries, attachGap, T.Detect.ATTACH_GAP, GetZ(F) - a.launchZ, a.airTime,
                tostring(S.lastGroundCheck), latched and "LATCHED" or "refused")
        end
        if latched then
            S.watch = { left = T.Latch.HOLD, faceDir = a.faceDir, launchZ = a.launchZ,
                        reforces = 0, rescued = false, drops = 0 }
            return Mode.LATCHED, "attached"
        end
        return nil
    end,
    exit = function(F, to, why)
        local a = S.ascent
        S.ascent = nil
        GiveAll(F, Mode.ASCENT)
        if Budget("transitions", T.Log.TRANSITIONS) and to ~= Mode.LATCHED then
            ddbg("ascent #%d end: %s (%s entry, %.2fs aloft) <-- a jump spent without "
                .. "a latch; wall handed to vanilla for %.2fs",
                S.log.seq or 0, why or "?", a and a.type or "?", a and a.airTime or 0,
                T.Guard.COOLDOWN)
        end
    end,
}

-- ---- LATCHED ------------------------------------------------------------
-- Climbing. Raw stick input goes to the component in wall space, the latch
-- watch guards a forced attach, the wall slide catches a fast entry, and
-- the player's jump out of climb mode is classified into LEAP or DISMOUNT.
-- Owns: rotation (via priority); climbmax while sliding.

local function SlideBegin(F, entryVz)
    S.slide = { v = math.min(math.abs(entryVz), T.Slide.VZ_CAP) * T.Slide.TRANSFER }
    Take(F, "climbmax", Mode.LATCHED)
    dbg("slide start: entryVz=%.0f v0=%.0f", entryVz, S.slide.v)
end

local function SlideEnd(F, reason)
    if S.slide == nil then return end
    S.slide = nil
    Give(F, "climbmax", Mode.LATCHED)
    dbg("slide end: %s", reason)
end

-- Position writes: in climb mode the component's solver owns Velocity.
local function SlideTick(F)
    local s = S.slide
    local deltaZ = s.v * F.dt
    local z0 = GetLocZ(F.pawn)
    local ok = CallOpt(F.pawn, "K2_AddActorWorldOffset", { X = 0, Y = 0, Z = -deltaZ }, true, {}, false)
    if not ok then SlideEnd(F, "K2_AddActorWorldOffset call failed") return end
    local z1 = GetLocZ(F.pawn)
    if deltaZ > 0.5 and z0 ~= nil and z1 ~= nil then
        local moved = z0 - z1
        if moved < deltaZ * T.Slide.BLOCK_RATIO then
            SlideEnd(F, string.format("blocked (commanded %.1f, moved %.1f)", deltaZ, moved))
            return
        end
    end
    s.v = s.v - T.Slide.DECEL * F.dt
    if s.v <= T.Slide.MIN_V then SlideEnd(F, "decayed to halt") end
end

-- Discard the camera-derived input vector and feed the stick in wall space.
local function ApplyRawClimbInput(F)
    DrainMoveInput(F.cmc)
    local along, up, mag = Input.GetStick()
    if mag == 0 then return end
    local fwd = S.prev.wallFwd
    local rightX, rightY = -fwd.Y, fwd.X
    CallOpt(F.pawn, "AddMovementInput", { X = rightX * along, Y = rightY * along, Z = up }, 1.0, false)
end

-- Runs while a forced latch is under watch. Returns true if the drop was
-- answered and the pawn is climbing again.
local function LatchWatchTick(F)
    local w = S.watch
    if w == nil then return false end
    w.left = w.left - F.dt
    if w.left <= 0 then
        if Budget("latch", T.Log.LATCH) then
            ddbg("latch watch over: %s after %d drop(s), %d re-force(s), rescue=%s",
                F.isClimbing and "HELD" or "not climbing", w.drops, w.reforces, tostring(w.rescued))
        end
        S.watch = nil
        return false
    end
    if F.isClimbing then return false end
    if not F.isFalling then S.watch = nil return false end    -- landed or another mode: theirs

    local face
    if UsingCapsuleCheck() then
        face = CapsuleSweepAhead(F.pawn, w.faceDir, T.Detect.ATTACH_GAP, F.loc)
    else
        face = TraceAlongDirection(F.pawn, w.faceDir, S.radius + T.Detect.ATTACH_GAP, 0, 0, F.loc)
    end
    if face == nil or face.gap > T.Detect.ATTACH_GAP then S.watch = nil return false end

    w.drops = w.drops + 1
    local rise = GetZ(F) - w.launchZ
    -- The component's own entry first, once. If it takes, its state is set
    -- up the way its update expects and the drops should stop.
    if not w.rescued then
        w.rescued = true
        if TryComponentClimbEntry() then
            ReadModes(F)
            if Budget("latch", T.Log.LATCH) then
                ddbg("latch DROPPED (#%d, rise=%.0f gap=%.1f groundCheck=%s): component entry -> %s",
                    w.drops, rise, face.gap, tostring(S.lastGroundCheck),
                    F.isClimbing and "CLIMBING" or "no effect")
            end
            if F.isClimbing then return true end
        end
    end
    if w.reforces >= T.Latch.MAX_REFORCE then
        if Budget("latch", T.Log.LATCH) then
            ddbg("latch DROPPED #%d: re-force budget spent, letting it go", w.drops)
        end
        S.watch = nil
        return false
    end
    w.reforces = w.reforces + 1
    local held = ForceAttach(F)
    if Budget("latch", T.Log.LATCH) then
        ddbg("latch DROPPED (#%d, rise=%.0f gap=%.1f groundCheck=%s): re-forced #%d",
            w.drops, rise, face.gap, tostring(S.lastGroundCheck), w.reforces)
    end
    return held
end

States[Mode.LATCHED] = {
    enter = function(F, from)
        -- A fast fall the component caught organically becomes a slide.
        -- Our own attaches and leap re-attaches arrive slowly by design.
        if from == Mode.IDLE or from == Mode.APPROACH then
            local entryVz = math.min(S.prev.fallVz, F.vz)
            if entryVz <= T.Slide.VZ_TRIGGER then SlideBegin(F, entryVz) end
        end
    end,
    tick = function(F)
        -- The player's jump out of climb mode. Checked before the latch
        -- watch, or a jump inside the watch window would be re-forced.
        if F.isFalling and F.vz > T.Leap.JUMP_VZ_MIN then
            local bucket, sign = ClassifyJumpDirection(S.prev.alongWall, S.prev.upward)
            if bucket == "DOWN" then return Mode.DISMOUNT, "jump: hop away" end
            return Mode.LEAP, "jump: " .. bucket, { bucket = bucket, sign = sign }
        end

        -- The watch runs every frame so it expires while the latch holds;
        -- a drop it answers leaves the pawn climbing again.
        local answered = LatchWatchTick(F)
        if not F.isClimbing and not answered then
            return Mode.IDLE, "left climb mode"
        end
        if F.atTop then return Mode.VAULT, "component vault" end

        -- This frame's facing first: the stick is decomposed against it, and
        -- the jump classifier and the leap's initial facing read it later.
        local fwd = WallFwd(F.pawn)
        if fwd ~= nil then S.prev.wallFwd = fwd end

        ApplyRawClimbInput(F)
        if S.slide ~= nil then SlideTick(F) end

        local along, up = Input.GetStick()
        S.prev.alongWall, S.prev.upward = along, up
        if along > 0 then S.prev.sideSign = 1 elseif along < 0 then S.prev.sideSign = -1 end
        return nil
    end,
    exit = function(F)
        SlideEnd(F, "left climb mode")
        S.watch = nil
        GiveAll(F, Mode.LATCHED)
    end,
}

-- ---- LEAP ---------------------------------------------------------------
-- Driven wall-plane leap: an eased speed along the leap direction, an
-- inward correction that holds the gap, and a scheduled attach window at
-- the end. Owns: move input, glider, gravity (0 during the drive), rotation.

local function LeapGapCorrection(l, gap, alignment)
    -- Off-angle the ray hits obliquely and reads longer than the true gap,
    -- which would drive the correction backwards.
    if alignment < T.Leap.PARALLEL then l.inVel = 0 return end
    l.inVel = Clamp((gap - T.Leap.HOLD_GAP) * T.Leap.IN_GAIN, -T.Leap.IN_MAX, T.Leap.IN_MAX)
end

-- Turns this frame's wall reading into a facing update and a gap
-- correction. Returns nil to continue, or a reason to end the leap.
local function LeapTrackSurface(F, l, hit)
    if hit == nil then
        l.framesWithoutWall = l.framesWithoutWall + 1
        l.inVel = 0
        if l.framesWithoutWall >= T.Leap.LOST_TICKS then return "wall lost" end
        return nil
    end
    l.framesWithoutWall = 0

    local toward = NormalizeXY(-hit.normalX, -hit.normalY)
    if toward == nil then return nil end   -- not vertical enough to face

    -- Smooth the raw normal to remove high-frequency trace jitter.
    local cur = l.smoothFaceDir or l.faceDir
    local k = math.min(1.0, F.dt * T.Leap.NORMAL_SMOOTHING)
    local sm = NormalizeXY(cur.X + (toward.X - cur.X) * k, cur.Y + (toward.Y - cur.Y) * k) or toward
    l.smoothFaceDir = sm

    local alignment = l.faceDir.X * sm.X + l.faceDir.Y * sm.Y
    if alignment < T.Leap.WRAP_COS then return "corner too sharp" end

    l.currentYaw, l.faceDir = SlewYawToward(l.currentYaw, sm.X, sm.Y, F.dt, T.Leap.YAW_RATE)
    LeapGapCorrection(l, hit.gap, alignment)
    return nil
end

local function LeapApplyVelocity(F, l)
    local alongX, alongY = -l.faceDir.Y, l.faceDir.X
    local progress = math.min(l.deltaTime / l.driveTime, 1.0)
    local speed = T.Leap.EASE(T.Leap.SPEED_START, T.Leap.SPEED_END, progress)
    local inward = l.inVel or 0
    SetHorizVel(F.cmc,
        alongX * l.dirSide * speed + l.faceDir.X * inward,
        alongY * l.dirSide * speed + l.faceDir.Y * inward)
    SetVertVel(F.cmc, l.dirUp * speed)
    FaceYaw(F.pawn, l.faceDir)
end

States[Mode.LEAP] = {
    enter = function(F, from, jump)
        local ang  = math.rad(T.Leap.ANGLES[jump.bucket])
        local mean = T.Leap.SPEED_START / 6 + 5 * T.Leap.SPEED_END / 6
        local fwd  = S.prev.wallFwd
        S.leap = {
            kind = jump.bucket, deltaTime = 0, faceDir = fwd,
            currentYaw = math.deg(math.atan(fwd.Y, fwd.X)),
            dirUp = math.cos(ang), dirSide = math.sin(ang) * jump.sign,
            driveTime = T.Leap.DIST / mean,
            tries = 0, framesWithoutWall = 0, inVel = 0, smoothFaceDir = nil,
        }
        Take(F, "glider",    Mode.LEAP)
        Take(F, "moveinput", Mode.LEAP)
        dbg("leap [%s%s]: drive %.0fms", jump.bucket,
            jump.sign ~= 0 and (jump.sign > 0 and "/R" or "/L") or "", S.leap.driveTime * 1000)
    end,
    tick = function(F)
        local l = S.leap
        DrainMoveInput(F.cmc)
        l.deltaTime = l.deltaTime + F.dt
        if F.isClimbing then return Mode.LATCHED, "leap attached" end
        if not F.isFalling then return Mode.IDLE, "leap ended: not falling" end

        -- Catch the top-out before anything else, while rising only.
        if T.TopOut.ENABLED and l.dirUp > 0 and SenseTopEdge(F.pawn, l.faceDir, F.loc) then
            if ForceAttach(F) then
                dbg("top-out caught mid-leap")
                return Mode.LATCHED, "top-out"
            end
        end

        local inWindow  = l.deltaTime < l.driveTime + T.Leap.ATTACH_WINDOW
        local atAttach  = l.deltaTime >= l.driveTime
        local hit = SenseWall(F.pawn, l.faceDir, l.dirSide, F.loc)

        if inWindow then
            WriteOpt(F.cmc, "GravityScale", 0.0)
            local why = LeapTrackSurface(F, l, hit)
            if why ~= nil then return Mode.IDLE, "leap ended: " .. why end
            LeapApplyVelocity(F, l)
        end
        if atAttach then
            LeapApplyVelocity(F, l)
            if l.tries < T.Leap.ATTACH_TRIES and hit ~= nil and hit.gap <= T.Detect.ATTACH_GAP then
                l.tries = l.tries + 1
                if ForceAttach(F) then return Mode.LATCHED, "leap attached" end
            end
            if l.deltaTime > l.driveTime + T.Leap.ATTACH_WINDOW then
                return Mode.IDLE, "leap ended: window closed"
            end
        end
        return nil
    end,
    exit = function(F)
        S.leap = nil
        GiveAll(F, Mode.LEAP)
    end,
}

-- ---- DISMOUNT -----------------------------------------------------------
-- The hop away. A normal-ish jump: no priority, so jump.lua's gravity bands
-- resume at once. Owns: move input, glider, for the lock window only.
States[Mode.DISMOUNT] = {
    enter = function(F)
        S.leap = { deltaTime = 0, faceDir = S.prev.wallFwd }
        Take(F, "glider",    Mode.DISMOUNT)
        Take(F, "moveinput", Mode.DISMOUNT)
        SetVertVel(F.cmc, T.Dismount.VZ)
        SetHorizVel(F.cmc, -S.prev.wallFwd.X * T.Dismount.OUT, -S.prev.wallFwd.Y * T.Dismount.OUT)
        dbg("dismount: out=%d vz=%d lock=%.2fs", T.Dismount.OUT, T.Dismount.VZ, T.Dismount.LOCK)
    end,
    tick = function(F)
        local l = S.leap
        DrainMoveInput(F.cmc)
        l.deltaTime = l.deltaTime + F.dt
        if F.isClimbing then return Mode.LATCHED, "re-grabbed during dismount" end
        if not F.isFalling then return Mode.IDLE, "dismount landed" end
        if l.deltaTime >= T.Dismount.LOCK then return Mode.IDLE, "dismount lock over" end
        local awayX, awayY = -l.faceDir.X, -l.faceDir.Y
        SetHorizVel(F.cmc, awayX * T.Dismount.OUT, awayY * T.Dismount.OUT)
        FaceYaw(F.pawn, { X = awayX, Y = awayY })
        return nil
    end,
    exit = function(F)
        S.leap = nil
        GiveAll(F, Mode.DISMOUNT)
    end,
}

-- ---- VAULT --------------------------------------------------------------
-- The component's own top-out animation owns the pawn; input and the native
-- jump are held off so it cannot be cancelled early.
States[Mode.VAULT] = {
    enter = function(F)
        Take(F, "moveinput",  Mode.VAULT)
        Take(F, "nativejump", Mode.VAULT)
    end,
    tick = function(F)
        if F.atTop then return nil end
        if F.isClimbing then return Mode.LATCHED, "vault over, still climbing" end
        return Mode.IDLE, "vault over"
    end,
    exit = function(F) GiveAll(F, Mode.VAULT) end,
}

-- ---- transitions --------------------------------------------------------

local function SetMode(F, next, why, payload)
    local from = S.mode
    S.inTransition = true
    States[from].exit(F, next, why)
    S.mode     = next
    S.modeTime = 0
    ReadModes(F)
    States[next].enter(F, from, payload)

    -- Priority is a function of the mode: jump.lua is gated off and the
    -- rotation flags are ours while it holds.
    local priority = PRIORITY[next] == true
    if priority then Take(F, "rotation", "priority") else Give(F, "rotation", "priority") end
    CommonState.ClimbHasPriority = priority

    S.inTransition = false
    SettleResources(F)

    M.Mode = next
    M.InInitClimbState = (next == Mode.ASCENT)
    M.InClimbJump      = (next == Mode.LEAP or next == Mode.DISMOUNT)
    if Budget("transitions", T.Log.TRANSITIONS) then
        ddbg("%s -> %s (%s)", from, next, why or "?")
    end
end

-- =========================================================================
-- 8. VISUALISATION (TraceViz; inert unless DEBUG_VOLUMES)
-- The capsule drawn IS the capsule check: same origin, extent, reach and
-- channel as CapsuleSweepAhead. The eye and width sweeps are the filters.
-- The green ring appears only when all of it would count as a wall.
-- =========================================================================

local COLOR_GUARD  = { R = 1.0,  G = 0.25, B = 0.10, A = 1.0 }
local COLOR_COMMIT = { R = 0.15, G = 1.0,  B = 0.25, A = 1.0 }
local COLOR_ATTACH = { R = 0.20, G = 0.55, B = 1.0,  A = 1.0 }
local COLOR_PROBE  = { R = 1.0,  G = 0.0,  B = 0.0,  A = 1.0 }
local COLOR_HIT    = { R = 0.0,  G = 1.0,  B = 0.0,  A = 1.0 }
local COLOR_RANGE  = { R = 0.35, G = 0.85, B = 1.0,  A = 0.8 }
local VIZ_MIN_PROBE_RADIUS = 18
local vizCategory = nil

local function VizCategory()
    if vizCategory == nil and Viz ~= nil then
        pcall(function() vizCategory = Viz.MakeCategory("PalFeel.Climb") end)
    end
    return vizCategory
end

local function DrawGate(origin, dir, dist, color, cat)
    local x, y = origin.X + dir.X * dist, origin.Y + dir.Y * dist
    pcall(function()
        Viz.DrawLine({ X = x, Y = y, Z = origin.Z - S.halfH * 0.5 },
                     { X = x, Y = y, Z = origin.Z + S.halfH * 0.5 },
                     color, 2.0, DEBUG_VOLUME_TIME, cat)
    end)
end

local function DrawSweep(from, to, radius, cat)
    local hit = nil
    pcall(function()
        hit = Viz.SphereTrace(from, to, radius, {
            Channel = S.channel, Duration = DEBUG_VOLUME_TIME, Category = cat,
            HitColor = COLOR_PROBE, MissColor = COLOR_PROBE,
            DrawImpactNormal = false, DrawSweptVolume = true })
    end)
    if hit and hit.bBlockingHit and hit.Location then
        pcall(function() Viz.DrawSphere(hit.Location, radius, 12, COLOR_HIT, 1.5, DEBUG_VOLUME_TIME, cat) end)
        return hit
    end
    return nil
end

local function VisualiseClimbChecks(F)
    if not DEBUG_VOLUMES or Viz == nil then return end
    local origin = F.loc
    if origin == nil then return end
    local dir = F.input or WallFwd(F.pawn)
    if dir == nil then return end

    local cat    = VizCategory()
    local radius = math.max(T.Detect.PROBE_RADIUS, VIZ_MIN_PROBE_RADIUS)
    local reach  = S.radius + T.Guard.REACH

    local function Sweep(h, lateral, len)
        local sx, sy = origin.X - dir.Y * lateral, origin.Y + dir.X * lateral
        return DrawSweep({ X = sx, Y = sy, Z = origin.Z + h },
                         { X = sx + dir.X * len, Y = sy + dir.Y * len, Z = origin.Z + h }, radius, cat)
    end

    local face = nil
    if UsingCapsuleCheck() then
        local zc, half = CapsuleCheckExtent()
        pcall(function()
            face = Viz.CapsuleTrace(
                { X = origin.X, Y = origin.Y, Z = origin.Z + zc },
                { X = origin.X + dir.X * T.Guard.REACH, Y = origin.Y + dir.Y * T.Guard.REACH, Z = origin.Z + zc },
                S.radius, half,
                { Channel = S.channel, Duration = DEBUG_VOLUME_TIME, Category = cat,
                  HitColor = COLOR_RANGE, MissColor = COLOR_RANGE,
                  DrawImpactNormal = true, DrawSweptVolume = true })
        end)
        if face and not face.bBlockingHit then face = nil end
    else
        local waist = Sweep(0, 0, reach)
        local low   = (S.fanOffset > 0) and Sweep(-S.fanOffset, 0, reach) or nil
        face = waist or low
    end

    local eye   = Sweep(S.halfH * T.Detect.EYE_OFFSET_FRAC, 0, reach)
    local left  = Sweep(0,  T.Detect.WIDTH_HALF, reach)
    local right = Sweep(0, -T.Detect.WIDTH_HALF, reach)
    if face and eye and left and right and face.ImpactPoint then
        pcall(function() Viz.DrawSphere(face.ImpactPoint, radius * 1.8, 24, COLOR_HIT, 3.0, DEBUG_VOLUME_TIME, cat) end)
    end

    if DEBUG_VOLUME_GATES then
        DrawGate(origin, dir, S.radius + T.Guard.REACH,       COLOR_GUARD,  cat)
        DrawGate(origin, dir, S.radius + T.Guard.COMMIT_AIR,  COLOR_COMMIT, cat)
        DrawGate(origin, dir, S.radius + T.Guard.COMMIT_WALK, COLOR_COMMIT, cat)
        DrawGate(origin, dir, S.radius + T.Detect.ATTACH_GAP, COLOR_ATTACH, cat)
    end
end

-- Any single-frame displacement large enough to be a teleport, with the
-- mode this file was in when it happened. This file writes movement modes,
-- velocities and component flags, and any of those can hand the pawn to
-- game code that relocates it.
local function WatchForTeleport(F)
    local here = F.loc
    if here == nil then S.lastLoc = nil return end
    local last = S.lastLoc
    S.lastLoc = here
    if last == nil then return end
    local dx, dy, dz = here.X - last.X, here.Y - last.Y, here.Z - last.Z
    local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    if moved < T.Log.TELEPORT_JUMP_UU then return end
    if not Budget("teleports", T.Log.TELEPORTS) then return end
    ddbg("TELEPORT: moved %.0fuu in one frame (%.0f,%.0f,%.0f) -> (%.0f,%.0f,%.0f) | mode=%s "
        .. "phase=%s suppressed=%s movement=%d/%d",
        moved, last.X, last.Y, last.Z, here.X, here.Y, here.Z, S.mode,
        S.ascent and S.ascent.phase or "-", tostring(S.wantSuppress), F.mode, F.custom)
end

-- =========================================================================
-- 9. HOOKS
-- Class-level BP function hooks: registered once per session (the class
-- persists across respawns; re-registering would double-fire), instance-
-- filtered in the callbacks.
-- =========================================================================

local function FindClimbingComponent(pawn)
    local ok, arr = pcall(rawGet, pawn, "BlueprintCreatedComponents")
    if not ok or arr == nil then return nil, nil end
    local okN, n = pcall(function() return #arr end)
    if not okN then return nil, nil end
    for i = 1, n do
        local okC, c = pcall(rawGet, arr, i)
        if okC and IsLive(c) then
            local okName, name = CallOpt(c, "GetFullName")
            if okName and type(name) == "string" and name:find("Climb") then
                return c, name
            end
        end
    end
    return nil, nil
end

local function IsOurComponent(Context)
    local ok, obj = pcall(function() return Context:get() end)
    if not ok or obj == nil or S.compName == nil then return false end
    local okName, name = CallOpt(obj, "GetFullName")
    return okName and name == S.compName
end

local function NoOp() end

local function RegisterComponentHooks()
    if hooksRegistered or S.clsPath == nil then return end
    local clsPath = S.clsPath

    local okTop, errTop = pcall(function()
        RegisterHook(clsPath .. ":ClimbUpAtTopEvent", function(Context)
            if not IsOurComponent(Context) then return end
            dbg("ClimbUpAtTopEvent fired")
        end)
    end)
    ddbg("hook ClimbUpAtTopEvent: %s", okTop and "registered" or ("FAILED: " .. tostring(errTop)))

    -- Ground contact as the component sees it. The return value only exists
    -- post-execution: NoOp pre-slot, post callback, value as the last vararg.
    local okGnd, errGnd = pcall(function()
        RegisterHook(clsPath .. ":GroundCheck", NoOp, function(Context, ...)
            if not IsOurComponent(Context) then return end
            local args = { ... }
            local ret = nil
            if #args > 0 then pcall(function() ret = args[#args]:get() end) end
            if ret ~= S.lastGroundCheck then
                S.lastGroundCheck = ret
                if Budget("latch", T.Log.LATCH) then ddbg("GroundCheck -> %s", tostring(ret)) end
            end
        end)
    end)
    ddbg("hook GroundCheck: %s", okGnd and "registered" or ("FAILED: " .. tostring(errGnd)))

    -- ReceiveTick pre-hook: the only point in the frame provably ahead of
    -- the component's own logic. A suppression written here lands THIS frame.
    local okTick, errTick = pcall(function()
        RegisterHook(clsPath .. ":ReceiveTick", function(Context)
            if not IsOurComponent(Context) then return end
            ApplyClimbSuppression()
        end)
    end)
    ddbg("hook ReceiveTick: %s -- if FAILED, the component's tick is native and the "
        .. "grab decision cannot be pre-empted this way",
        okTick and "registered" or ("FAILED: " .. tostring(errTick)))

    -- Signatures of the component's entry/exit functions, read from the
    -- UFunction objects without calling anything. Decides whether
    -- TryClimbAfterGrappling is provably no-arg, the only condition under
    -- which the latch watch may invoke it.
    pcall(function()
        for _, fname in ipairs({ "TryClimbAfterGrappling", "StartClimbing", "StartClimb",
                                 "StartClimbByNetwork", "RequestEndClimbing" }) do
            local fn = nil
            for _, base in ipairs({ clsPath, "/Script/Pal.PalClimbingComponent" }) do
                if not IsLive(fn) then
                    pcall(function() fn = StaticFindObject(base .. ":" .. fname) end)
                end
            end
            if not IsLive(fn) then
                ddbg("sig %s: not found", fname)
            else
                local params = {}
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        local n, t = "?", "?"
                        pcall(function() n = prop:GetFName():ToString() end)
                        pcall(function() t = prop:GetClass():GetFName():ToString() end)
                        params[#params + 1] = n .. ":" .. t
                    end)
                end)
                ddbg("sig %s(%s)", fname, table.concat(params, ", "))
                if fname == "TryClimbAfterGrappling" then
                    local noArgs = (#params == 0)
                        or (#params == 1 and params[1]:sub(1, 11) == "ReturnValue")
                    S.grappleCallable = noArgs
                    ddbg("TryClimbAfterGrappling: %s", noArgs and "no-arg, latch watch may use it"
                        or "has parameters, latch watch will NOT call it")
                end
            end
        end
    end)

    hooksRegistered = true
end

-- =========================================================================
-- 10. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    -- Whatever the previous pawn's modes still owned is given back on this
    -- one (the controller survives a respawn and keeps its counters), then
    -- every piece of state starts over.
    local F0 = { pawn = pawn, cmc = cmc, dt = 0 }
    for name, r in pairs(S.own) do
        if r.applied then r.applied = false; Resources[name].give(F0, r) end
    end
    S = NewState()
    CommonState.ClimbHasPriority = false
    M.Mode, M.InInitClimbState, M.InClimbJump = Mode.IDLE, false, false

    S.comp, S.compName = FindClimbingComponent(pawn)
    S.walkableZ = ReadOpt(cmc, "WalkableFloorZ") or T.Detect.WALKABLE_Z_FALLBACK
    S.defaultOrient     = ReadOpt(cmc, "bOrientRotationToMovement")
    S.defaultDesiredRot = ReadOpt(cmc, "bUseControllerDesiredRotation")
    local capsule = ReadOpt(pawn, "CapsuleComponent")
    S.radius = ReadOpt(capsule, "CapsuleRadius")     or S.radius
    S.halfH  = ReadOpt(capsule, "CapsuleHalfHeight") or S.halfH
    -- Fan rays must leave from the cylindrical section of the capsule, where
    -- Distance - radius is the true perpendicular gap.
    S.fanOffset = math.max(0, math.min(T.Detect.FAN_HEIGHT_FRAC * S.halfH,
        S.halfH - S.radius - T.Detect.FAN_HEIGHT_PAD))

    if S.comp == nil then
        ddbg("climbing component NOT FOUND")
        return
    end
    S.channel = ReadOpt(S.comp, "Const_RayChannel") or 0
    local okCls, clsName = pcall(function() return S.comp:GetClass():GetFullName() end)
    if okCls and type(clsName) == "string" then
        S.clsPath = clsName:match("(%S+)$")   -- strip "BlueprintGeneratedClass "
    end
    ddbg("component: %s  ClimbMaxSpeed=%s  fwdRay=%s  rayChannel=%s", S.compName,
        tostring(ReadOpt(cmc, "ClimbMaxSpeed")),
        tostring(ReadOpt(S.comp, "Const_ForwardRayLength")), tostring(S.channel))
    ddbg("geom: capsuleR=%.1f halfH=%.1f fanOffset=%.1f | attachGap=%.1f guardReach=%.1f",
        S.radius, S.halfH, S.fanOffset, T.Detect.ATTACH_GAP, T.Guard.REACH)
    RegisterComponentHooks()
    if Discover ~= nil then
        Discover.OnPlayerCached({ pawn = pawn, cmc = cmc, comp = S.comp,
            compName = S.compName, clsPath = S.clsPath, log = ddbg })
    end
end

function M.OnTick(dt, pawn, cmc)
    if Discover ~= nil then Discover.OnTick() end

    local F = ReadFrame(pawn, cmc, dt)
    if S.capsuleTraceOk == nil and T.Detect.SHAPE == "capsule" and F.isWalking then
        SelfTestCapsuleTrace(pawn)
    end
    WatchForTeleport(F)
    VisualiseClimbChecks(F)

    -- Run to completion: a mode entered this frame ticks this frame, so a
    -- commit, a latch or a jump is acted on without a frame of delay.
    S.modeTime = S.modeTime + dt
    for _ = 1, 4 do
        local next, why, payload = States[S.mode].tick(F)
        if next == nil or next == S.mode then break end
        SetMode(F, next, why, payload)
    end

    S.prev.fallVz = F.isFalling and F.vz or 0
end

return M
