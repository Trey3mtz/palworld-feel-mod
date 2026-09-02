-- =========================================================================
-- Author: TheTr3y
-- Date: 2026-07-25
-- =========================================================================

local CommonState = require("commonstate")
local Easing = require("easingfunctions")
local Input       = require("input")

-- TraceViz lives in UE4SS's shared/ folder and may simply not be installed.
-- A hard require would take the whole climbing subsystem down with it, so a
-- missing visualiser degrades to no visualisation and nothing else.
local okViz, Viz = pcall(require, "TraceViz")
if not okViz then Viz = nil end

-- =========================================================================
-- 1. TUNING
-- =========================================================================

local DEBUG   = false

-- Per-frame logging, separated from DEBUG so it cannot be left on. print()
-- feeds UE4SS's console buffer and log file, neither of which is trimmed.
local DEBUG_FRAME = false

-- One-shot discovery output: component properties, class functions, hook
-- results, and the tick-order summary. Separate from DEBUG and defaulted ON
-- because it is bounded -- each line prints once per session and then goes
-- quiet forever, so it cannot grow the log the way DEBUG_FRAME can. These
-- answer questions this file cannot answer by reasoning (what the component
-- actually exposes, what its reach values really are, which tick runs
-- first), and gating them behind a per-frame flag meant a whole session
-- produced none of them.
local DEBUG_DISCOVERY = true

-- The function dump is a one-time question that has been answered (the class
-- exposes CanClimbingStart, StartClimbing, ClimbingMainUpdate, CheckClimbingMode,
-- DelayCanClimbing, ForceCancelClimb, GroundCheck, and the CenterRayCast /
-- UpRayCast / SideRayCast / DiagonalRayCast family). Off by default: it costs
-- a startup hitch and walks object graph edges that must each be IsValid()
-- checked, which is where a crash-on-load came from once already.
local DEBUG_DUMP_FUNCTIONS = false

-- Frames between init-climb wall probes. 1 = every frame (original
-- behaviour). Each LineTraceSingle costs three UE4SS
-- "[push_weakobjectproperty] Operation::Set is not supported" lines, because
-- UE4SS builds the FHitResult out-param by Set-ing every property of the
-- STRUCT (not the table) and three of them are TWeakObjectPtr. At 60fps that
-- is ~180 lines/sec. Set this to 4 to cut it by three quarters; the cost is
-- up to 66ms of extra latency detecting a wall you have pressed into.
local PROBE_FRAME_INTERVAL = 1

-- Unreal compiles debug drawing out of shipping builds (ENABLE_DRAW_DEBUG is
-- 0), and that includes the DrawDebugType visualisation built into every
-- UKismetSystemLibrary trace: the trace runs, the drawing does not. So the
-- EDrawDebugTrace argument below is pinned to None, and everything visual
-- goes through TraceViz, which draws on the HUD canvas instead -- gameplay
-- code that survives shipping.
--
-- This was not a hypothesis that could be tested from here: passing a debug
-- draw mode looks correct, compiles, runs, and silently draws nothing.
local TRACE_DRAW_NONE = 0
local TRACE_DRAW_TIME = 0.0

local DEBUG_VOLUMES = false
-- How long each drawn frame persists. 0 = one frame (cleanest while moving);
-- a small value leaves a short trail, which is easier to read in a screenshot.
local DEBUG_VOLUME_TIME = 0.0

-- ---- slide ----
local VZ_TRIGGER  = -600
local VZ_CAP      = 1600
local TRANSFER    = 0.45
local DECEL       = 1400
local MIN_SLIDE_V = 60
local BLOCK_RATIO = 0.4


-- Speed profile along the leap direction: EaseOutQuint from START to
-- END. Drive time is derived from the curve's time-average speed
-- (START/6 + 5*END/6 for out-quint) so travel is exactly LEAP_DIST
-- regardless of tuning. Keep (driveTime + ATTACH_WINDOW) under ~0.50s or
-- the component's cooldown expires mid-leap and organic re-grabs
-- return. Current average = 900 -> driveTime = 0.278s, same as the
-- constant-speed build.
local LEAP_SPEED_START = 2200
local LEAP_SPEED_END   = 162
local LEAP_EASE        = Easing.EaseOutCirc
local LEAP_DIST     = 175    -- uu of travel before the attach check
local LEAP_ANGLES   = { UP = 0.0, DIAG = 45.0, SIDE = 90.0 }
local ATTACH_WINDOW = 0.10   -- s at leap end to confirm a wall

-- Init-climb tuning lives in one table rather than ~27 separate locals:
-- the file was at Lua's 200-local ceiling for a main chunk, and the project
-- standard is to expose tuning through config tables anyway.
local InitClimb = {}

-- ---- init climb: wall detection ----
InitClimb.CONE_DEG    = 40    -- max angle between input and into-wall
-- Gap (from the capsule SURFACE) at which a GROUNDED walk-in commits.
InitClimb.MAX_GAP     = 21
-- Minimum |Acceleration.XY| that counts as holding a direction. Deliberately
-- an absolute floor and deliberately tiny: Acceleration's scale here depends
-- on MaxAcceleration and AnalogInputModifier, neither of which is verified,
-- and a threshold expressed as a fraction of MaxAcceleration silently
-- rejects every input if the real scale is lower than assumed. Detection
-- must never be the thing that fails.
InitClimb.INPUT_FLOOR = 0.6
InitClimb.CONE_COS    = math.cos(math.rad(InitClimb.CONE_DEG))
local WALKABLE_FLOOR_Z_FALLBACK = 0.6428   -- cos(50 deg); BP_PlayerBase default

-- ---- init climb: winning the race against the game's own grab ----
-- The component latches on its own as soon as its forward ray finds a face.
-- That happens before this script's tick sees anything, so by the time we
-- look, MovementMode is already 6/5 and the whole sequence is gated out --
-- the reason the auto-latch "sometimes just climbs" instead of hopping.
--
-- So the guard reaches FURTHER than the component does and suppresses
-- CanClimbing while closing, buying the frames needed to run our own hop.
-- Deliberately generous: over-reaching only starts the guard early, while
-- under-reaching loses the race outright.
InitClimb.GUARD_GAP = 130   -- uu from capsule surface: start suppressing
-- Committing further out than the hop needs, because the approach hold
-- below spends time closing the rest. InitClimb.IN_MAX caps the closing
-- speed, so this is roughly what the hold can actually cover.
InitClimb.HOP_GAP   = 80    -- uu from capsule surface: commit + lock out
-- Suppression is conditioned on ASCENDING, not merely airborne. Falling into
-- a face must still reach the component's organic grab, or the wall slide
-- (VZ_TRIGGER) loses its entry and a fast fall just splats.
InitClimb.GUARD_VZ_MIN = 5  -- uu/s of rise required to suppress

-- The guard holds the vanilla grab off while closing. If our own commit then
-- never fires, the player gets neither -- they walk into the face and nothing
-- happens, which is strictly worse than not running the mod at all. So the
-- guard is time-boxed: hold it off only as long as an approach could still
-- plausibly be converging, then hand the wall back and stay out of the way
-- for a moment so it cannot immediately re-arm and re-suppress.
InitClimb.GUARD_TIMEOUT  = 0.45  -- s armed without committing -> give up
InitClimb.GUARD_COOLDOWN = 0.80  -- s of vanilla ownership after giving up
-- Probe loss can be a single bad frame on uneven geometry. Tolerating a few
-- costs nothing and stops one unlucky trace from surrendering the wall.
InitClimb.GUARD_LOST_TICKS = 6

-- Below this multiple of the commit gap the probe upgrades to the vertical
-- fan. Arming stays a single ray (it runs while merely walking near a face,
-- and each trace costs three UE4SS log lines), but the commit decision is
-- worth three: a face recessed at capsule-centre height is exactly the
-- "some walls are finicky" case, and by then it is only the last few frames.
InitClimb.FAN_NEAR_MULT = 2.5

-- Small penetration is normal: UE resolves overlap over several frames and
-- a capsule pressed into a wall routinely reads a hair inside it. Only a
-- trace that starts genuinely inside geometry (where the returned normal
-- faces back down the trace and reads as a perfect head-on wall) is junk.
local PROBE_PENETRATION_SLOP = 6   -- uu of negative gap treated as "touching"

-- Vertical fan for the airborne probe, as a fraction of capsule half height.
-- One ray at capsule centre misses a face that is recessed at waist height
-- but present at chest or shin height -- the "surface shape" failure. The
-- offset is clamped so every ray still leaves from the cylindrical section
-- of the capsule, where `Distance - radius` is the true perpendicular gap.
local PROBE_FAN_HEIGHT_FRAC = 0.45
local PROBE_FAN_HEIGHT_PAD  = 4    -- uu kept clear of the capsule's end caps

-- ---- wall shape checks ----
-- A hit at waist height is not a wall. A rock, a plinth, a rise in the ground
-- all hit at waist height, and a horizontal probe cannot tell them from a
-- cliff face -- the visualiser showed the capsule sweep stopping on exactly
-- such a rock while the real player would have stepped over it. So a face
-- has to pass two more tests before it counts, the same two the standard
-- Unreal climbing pattern uses:
--   eye level : a probe at eye height must ALSO find it. A hit at waist that
--               misses at eye is a step, not a wall.
--   width     : probes offset left and right must both find it. A post or an
--               edge you would slip off is not a wall either.
local WallDetect = {}
WallDetect.EYE_OFFSET_FRAC = 0.70   -- of capsule half height, above centre
WallDetect.WIDTH_HALF      = 40     -- uu each side of the approach line
WallDetect.REQUIRE_EYE     = true
WallDetect.REQUIRE_WIDTH   = true
-- The side and eye probes reach a little further than the waist probe: on a
-- rough face they land at slightly different depths, and a wall should not
-- fail its width test because one flank is 10uu further back.
WallDetect.SLACK           = 30

-- ---- init climb: launch ----
InitClimb.LAUNCH_GRACE = 0.12   -- s to leave the ground before the jump counts as refused
-- Overwrites whatever the game's jump produced so the arc is identical every
-- time. nil keeps the game's launch (and with it the game's variance).
InitClimb.LAUNCH_VZ    = 1050
-- Owned for the whole ascent: jump.lua is gated off by ClimbHasPriority, so
-- its velocity bands and its jump-cut can no longer reshape this arc.
InitClimb.GRAVITY      = 2.2

-- ---- init climb: mini hop (airborne entry) ----
-- Written directly rather than routed through RequestJump. DoJump takes
-- max(Velocity.Z, JumpZVelocity), which is a no-op while still rising --
-- exactly the case this move exists for -- and CanJump refuses outright
-- when falling with JumpCurrentCount == 0. ADD is the kick, MIN guarantees
-- the pop is visible even out of a dive, MAX keeps it a hop and not a jump.
InitClimb.HOP_VZ_ADD   = 500
InitClimb.HOP_VZ_MIN   = 460
InitClimb.HOP_VZ_MAX   = 1000
InitClimb.HOP_IN_SPEED = 220    -- uu/s into the wall on the hop frame

-- Airborne entry commits, locks the climb out, and then holds for this long
-- while the closed loop drives the pawn at the face -- the hop only fires
-- after. Committing at the old distance meant hopping the instant the wall
-- came in range, which read as jumping too early. The lock is what makes the
-- hold safe: the component cannot grab during it, so the extra time cannot
-- be spent being latched by vanilla instead.
InitClimb.APPROACH_HOLD = 0.12

-- ---- init climb: attach schedule ----
-- Attach the instant it is viable rather than on a fixed clock: air time and
-- rise only exist to let the hop read as a hop before the latch lands.
-- Both windows carry +20% over the first tuning pass: the latch was landing
-- before the jump had read as a jump. A bespoke animation is going in here
-- eventually, which wants the room too.
InitClimb.MIN_AIR_TIME = 0.18   -- s aloft before the first attempt
InitClimb.MIN_RISE     = 95     -- uu above launch Z before the first attempt
InitClimb.LOCK_TIME    = 0.72   -- s of air time before giving up
InitClimb.RETRY_INTERVAL = 0.06 -- s between forced attaches that did not take
InitClimb.LOST_TICKS   = 5      -- consecutive all-miss probes -> abort

-- ---- init climb: hold against the wall ----
-- Closed loop over the probed gap, same shape as the hug leap's. Without it
-- the ascent coasts on whatever momentum survived the wall collision, which
-- is why the latch used to depend on approach angle and surface shape.
InitClimb.HOLD_GAP  = 8      -- uu gap to hold while rising
-- Proportional, so a face that recedes as you rise (anything leaning back)
-- holds a steady-state error of recessionRate/gain. At 10 degrees of lean
-- and a 900uu/s launch the face retreats ~160uu/s, which a gain of 8 held at
-- ~20uu of error -- half the attach budget spent on nothing. Discrete gain
-- is gain*dt (~0.23 at 60fps), far below the oscillation threshold.
InitClimb.IN_GAIN   = 14.0   -- 1/s; inward vel = gain * (gap - target)
InitClimb.IN_MAX    = 320    -- uu/s inward correction cap
InitClimb.YAW_RATE  = 900    -- deg/s slew cap while tracking the face

-- ---- climb jump: catching the top-out ----
-- A leap up a face that ends mid-leap currently sails past the lip and free
-- falls. The component already owns a vault (ClimbUpAtTopEvent); this is
-- about noticing the lip in time to hand off to it.
--
-- Detection is a two-ray disagreement: the face is still there at shoulder
-- height and gone above it, which is what a top edge IS. Both rays are cast
-- along the leap's own facing, so a wall that merely gets thinner does not
-- read as a top.
local TopOut = {}
TopOut.ENABLED    = true
TopOut.LOW_OFFSET  = -10   -- uu from capsule centre: must still find wall
TopOut.HIGH_OFFSET = 46    -- uu above centre: must find nothing
TopOut.MAX_GAP     = 60    -- uu; lip must be within grabbing distance

-- DO NOT ENABLE. Calling ClimbUpAtTopEvent directly teleported the player
-- across the map and into the ocean.
--
-- It is the component's vault, and the component fires it from its own state
-- machine only AFTER CheckUpToTop and UpToTopUpdate have worked out where the
-- top actually is. Called cold it runs against whatever destination happens
-- to be stored -- uninitialised, or left over from a different climb
-- somewhere else entirely -- and moves the player there.
--
-- The original guard here was a pcall, which only catches the call ERRORING.
-- A function that relocates the player succeeding with garbage state is the
-- risk that mattered, and pcall does nothing about it.
--
-- The latch alone is what stops the leap sailing past the lip; once latched
-- at the top the component runs its own vault, with its own state, correctly.
-- Nothing here needs to invoke it by hand.
TopOut.CALL_EVENT  = false

-- ---- climb jump: attach verification ----
local ATTACH_MAX_TRIES = 3  -- attempts within the window; then free fall

-- ---- climb jump: hop away (DOWN) ----
local HOP_VZ    = 620
local HOP_OUT   = 300
local HOP_LOCK  = 0.20

local LOCK_ROTATION = true


-- ---- hug closed-loop (facing + distance hold) ----
local HUG_TARGET     = 5      -- uu gap to hold (matches observed ~55 rest)
local HUG_RAY_LEN    = 112     -- fwdRay(80) * 1.4; fan reach
local HUG_FAN_DEG    = 30      -- side ray splay
local HUG_YAW_RATE   = 800    -- deg/s slew cap (round-wall track / corner take)
local HUG_PARALLEL   = 0.90    -- facing.normal above this = gap trusted for dist
local HUG_IN_GAIN    = 6.0     -- 1/s; inward vel = gain * (gap - target)
local HUG_IN_MAX     = 400     -- uu/s inward correction cap
local HUG_WRAP_COS   = -0.70   -- new-normal vs facing dot below this = corner too
                               -- sharp (~135 deg) -> detach; >= wraps.
                               -- -0.50~120, -0.70~135, -0.87~150
local HUG_LOST_TICKS = 4       -- consecutive all-miss frames -> end leap
local LEAD_RAY_BONUS = 8    -- uu of score preference for the ray angled
                            -- toward travel; lets it win near-ties so
                            -- corners are seen before the forward ray

-- ---- attach reach ----
-- uu of clearance from the capsule surface at which a wall counts as
-- grabbable. A plain tunable on purpose. This was briefly derived from
-- Const_ForwardRayLength on the theory that the component measures it from
-- the actor origin -- but that is an UNVERIFIED reading of a property whose
-- units and origin nobody here has confirmed, and if it is surface-relative
-- (or a socket offset, or anything else) the derivation silently computes a
-- TIGHTER budget than this and the latch gets harder, not easier.
-- DEBUG_VOLUMES exists to settle that question from in-game before any figure
-- here is tied to it again.
local ATTACH_MAX_GAP = 55


-- =========================================================================
-- 2. MODULE + STATE
-- =========================================================================

local M = { name = "climb" }

-- Published for jump.lua's jump-cut guard during the HOP (which hands
-- gravity back to jump.lua and therefore isn't covered by the priority
-- gate). Hug leaps are protected by ClimbHasPriority itself.
M.InClimbJump = false
M.InInitClimbState = false

local comp, compName = nil, nil
local capsuleRadius = 34 -- this is a fallback for radius, found during runtime test
local capsuleHalfHeight = 90
local walkableFloorZ = WALKABLE_FLOOR_Z_FALLBACK
local probeFanOffset = 0        -- uu; 0 disables the vertical fan

-- ---- fall / climb frame cache ----
local lastFallVz     = 0
local prevModeWasClimb  = false
local prevWallFwd    = { X = 1, Y = 0 }
local prevClimbInputAlongWall = 0
local prevClimbInputUpward = 0
local prevAtTopAnimPlaying = false
local prevClimbZ     = nil

-- ---- slide state ----
local slidingDownWall        = false
local slideV         = 0
local savedClimbMax  = nil

-- ---- climb jump state ----
local climbJumpState = nil
local JUMP_DIRECTIONS = {
    { name = "SIDE", sign = -1, x = -1.0, y =  0.0 },
    { name = "DIAG", sign = -1, x = -0.5, y =  0.5 },
    { name = "UP",   sign =  0, x =  0.0, y =  1.0 },
    { name = "DIAG", sign =  1, x =  0.5, y =  0.5 },
    { name = "SIDE", sign =  1, x =  1.0, y =  0.0 },
    { name = "DOWN", sign =  0, x =  0.0, y = -1.0 },
}

-- ---- init climb state ----
-- Latched by the approach guard; declared here rather than beside the guard
-- itself because OnPlayerCached resets it and is defined earlier in the file.
local approachGuardArmed = false
local guardLostFrames    = 0
local guardArmedTime     = 0
local guardCooldown      = 0
local guardGiveUps       = 0
local GUARD_GIVEUP_LOG_MAX = 12

-- Shadowed by M.InInitClimbState: the two are written together, in
-- StartClimbFrom* and EndInitClimb, and nowhere else.
local initClimbState = nil

-- ---- flag watch state ----
local prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
local KSL = nil             -- KismetSystemLibrary default object, lazy

-- ---- component hook state ----
local hooksRegistered = false
local lastGroundCheck = nil

-- All discovery / watchdog state lives in one table. Eighteen separate
-- locals for it pushed the file past Lua's 200-local ceiling for a main
-- chunk, and they are one thing anyway: read-only instrumentation.
local Diag = {}

-- ---- tick-order diagnostic (read-only) ----
-- Everything currently runs off BP_PalPlayerController_C:ReceiveTick. The
-- controller and the climbing component both tick in TG_PrePhysics, and
-- within a tick group UE orders nothing unless a prerequisite says so -- so
-- which runs first is decided by registration order and can differ between
-- sessions, respawns, or streaming states. That is enough on its own to make
-- the same wall behave differently on different runs, and no tuning value
-- here can fix it.
--
-- These sample whether the component's tick is even hookable, and if so
-- whether it lands before or after our controller tick. Answering that is
-- the prerequisite for moving the grab decision onto the component's tick.
Diag.compTickHookAlive   = false
Diag.compTickedBeforeUs  = false
Diag.tickOrderBefore     = 0
Diag.tickOrderAfter      = 0
Diag.tickOrderSamples    = 0
Diag.compTicks           = 0   -- engine ticks a component once per frame
-- ---- teleport watchdog ----
-- This file writes movement modes, velocities and component flags, and any of
-- those can hand the pawn to game code that relocates it. A displacement this
-- large in a single frame is not movement, it is a teleport, and it should be
-- attributable to a frame and a state rather than to noticing you are in the
-- sea. Sprinting is ~10uu/frame and terminal velocity ~50uu/frame, so this
-- sits far above anything legitimate.
Diag.TELEPORT_JUMP_UU  = 1500
Diag.teleportLastLoc   = nil
Diag.teleportReports   = 0
Diag.TELEPORT_LOG_MAX  = 6

local savedOrientToMovement = nil   -- bOrientRotationToMovement before we took yaw

Diag.grabWasClimbingPre  = false
Diag.grabInsideTick      = 0

-- ---- CanClimbingStart gate ----
-- The component's own predicate for "may a climb begin". Holding CanClimbing
-- off across a whole 130uu approach is a blunt instrument: it suppresses
-- legitimate climbing over a wide area and needs the guard-arming state
-- machine to decide when to stop. Vetoing this one call instead is
-- per-decision and needs no area at all.
--
-- Off until a session proves the hook fires and the return slot is what this
-- assumes -- the last vararg, same shape GroundCheck already relies on.
-- Enabling it before that is how the last two regressions happened.
Diag.CANSTART_VETO_ENABLED = false
Diag.canStartFires     = 0
Diag.canStartVetoes    = 0
Diag.canStartLogged    = 0
Diag.CANSTART_LOG_MAX  = 8
Diag.TICK_ORDER_SAMPLE_MAX = 240   -- ~4s at 60fps, then it goes quiet



-- =========================================================================
-- 3. UTILITIES
-- =========================================================================

local function dbg(fmt, ...)
    if DEBUG then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end

local function fdbg(fmt, ...)
    if DEBUG_FRAME then print(string.format("[PalFeel:climb] " .. fmt .. "\n", ...)) end
end

-- One-shot discovery lines. Prefixed distinctly so they are greppable out of
-- a session log without the surrounding noise.
local function ddbg(fmt, ...)
    if DEBUG_DISCOVERY then print(string.format("[PalFeel:climb/DISCOVER] " .. fmt .. "\n", ...)) end
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

local function Clamp(value, low, high)
    if value < low  then return low  end
    if value > high then return high end
    return value
end

local function DisableGlider(playerPawn, cmc)
    local glider = ReadOpt(playerPawn, "BP_GliderComponent")
    if IsLive(glider) then
        local glidereKy = ReadOpt(glider, "GliderDisableFlag")
        -- Stop the component from ticking or processing activation events
        pcall(function() cmc:SetGliderDisbleFlag(glidereKy, true) end)
    end
end

local function EnableGlider(playerPawn, cmc)
    local glider = ReadOpt(playerPawn, "BP_GliderComponent")
    if IsLive(glider) then
        local glidereKy = ReadOpt(glider, "GliderDisableFlag")
        -- Restore component functionality
        pcall(function() cmc:SetGliderDisbleFlag(glidereKy, false) end)
    end
end

-- SetIgnoreMoveInput is a COUNTER on the controller: true increments, false
-- decrements with a clamp at zero. ResetIgnoreMoveInput does neither -- it
-- assigns the CDO default, releasing every hold including the ones
-- horizontalmove.lua and the game itself are carrying. Holds are therefore
-- keyed by owner and paired strictly, and the reset path is gone.
local moveInputHolds = {}

local function HoldMoveInput(pawn, holder)
    if moveInputHolds[holder] then return end
    if not IsLive(pawn) then return end
    local controller = nil
    pcall(function() controller = pawn:GetController() end)
    if not IsLive(controller) then return end
    -- Latch before the write so a failed release can never double-decrement.
    moveInputHolds[holder] = true
    pcall(function() controller:SetIgnoreMoveInput(true) end)
end

local function ReleaseMoveInput(pawn, holder)
    if not moveInputHolds[holder] then return end
    moveInputHolds[holder] = nil
    if not IsLive(pawn) then return end
    local controller = nil
    pcall(function() controller = pawn:GetController() end)
    if not IsLive(controller) then return end
    pcall(function() controller:SetIgnoreMoveInput(false) end)
end

local function ReleaseAllMoveInput(pawn)
    for holder in pairs(moveInputHolds) do
        ReleaseMoveInput(pawn, holder)
    end
end

local originalJumpMax = 1
local isJumpDisabled = false
-- When the player latches onto a wall and you want to lock out the native jump:
local function DisableNativeJump(playerPawn, cmc)
    if isJumpDisabled then return end
    if playerPawn and playerPawn:IsValid() then  
        -- Store the original max jump count
        originalJumpMax = playerPawn.JumpMaxCount
        -- Set to 0 so ACharacter::CanJump() fails
        playerPawn.JumpMaxCount = 0
        isJumpDisabled = true
    end
end

-- When the player leaps off the wall or touches the ground:
local function EnableNativeJump(playerPawn, cmc)
    if not isJumpDisabled then return end
    if playerPawn and playerPawn:IsValid() then
        -- Restore the original jump count
        playerPawn.JumpMaxCount = originalJumpMax
        isJumpDisabled = false
    end
end

local function SetCanClimb(pawn, allowed)
    local climbComp = ReadOpt(pawn, "BP_PalClimbingComponent")
    if not IsLive(climbComp) then return end
    pcall(function() climbComp.CanClimbing = allowed end)
end

-- Suppression is split into a WANT (decided by the approach guard, which
-- needs velocity and probes and so lives on the controller tick) and an
-- APPLY (the actual property write).
--
-- The split exists because of a measurement: over 240 consecutive frames the
-- climbing component's tick ran before our controller tick 240 times and
-- after it 0 times. The order is not a race -- the component always goes
-- first. So a CanClimbing write issued from the controller tick cannot take
-- effect until the NEXT frame, and the component gets first refusal on every
-- frame in between. That is the whole reason the guard has to reach 130uu:
-- it is buying frames of margin against a decision it always loses.
--
-- Applying from the component's own ReceiveTick pre-hook lands the write in
-- the SAME frame, immediately before the component's logic runs.
local wantClimbSuppressed  = false
local climbSuppressionHeld = false

-- Only ever writes to force suppression ON, or to release one it applied
-- itself. It must not write `true` freely: the game sets CanClimbing false
-- for its own reasons (stamina, water, state), and blanket-restoring it
-- every frame would override those.
local function ApplyClimbSuppression()
    if not IsLive(comp) then return end
    if wantClimbSuppressed then
        pcall(function() comp.CanClimbing = false end)
        climbSuppressionHeld = true
    elseif climbSuppressionHeld then
        pcall(function() comp.CanClimbing = true end)
        climbSuppressionHeld = false
    end
end

local function SuppressGameClimb(pawn, suppress)
    if suppress ~= wantClimbSuppressed then
        dbg("game climb %s", suppress and "SUPPRESSED" or "restored")
    end
    wantClimbSuppressed = suppress
    ApplyClimbSuppression()
end

-- SetIgnoreMoveInput is a controller-level counter, and nothing guarantees
-- every input path respects it -- Enhanced Input bindings can reach the
-- movement component without consulting it, which is the likeliest reason
-- a "locked" leap can still be steered away from the wall at the last
-- moment. Draining the pending vector every frame is the belt to that brace:
-- whatever produced the input, the movement component gets zero this tick.
local function DrainMoveInput(cmc)
    pcall(function() cmc:ConsumeInputVector() end)
end

-- The ascent owns the pawn outright: the game's organic climb is suppressed
-- so it cannot latch at a gap the mod has not verified, the glider cannot
-- deploy out from under the latch, and the stick cannot fight the closed
-- loop holding us against the face. Released exactly once, in EndInitClimb.
local function DisableForInitClimb(pawn, cmc)
    SuppressGameClimb(pawn, true)
    HoldMoveInput(pawn, "initclimb")
    DisableGlider(pawn, cmc)
end

local function EnableForInitClimb(pawn, cmc)
    SuppressGameClimb(pawn, false)
    ReleaseMoveInput(pawn, "initclimb")
    EnableGlider(pawn, cmc)
end

local function DisableForAtTopAnim(pawn, cmc)
    HoldMoveInput(pawn, "attop")
    DisableNativeJump(pawn, cmc)
end

local function EnableForAtTopAnim(pawn, cmc)
    ReleaseMoveInput(pawn, "attop")
    EnableNativeJump(pawn, cmc)
end

local function DisableForClimbingJump(pawn, cmc)
    DisableGlider(pawn, cmc)
    HoldMoveInput(pawn, "climbjump")
end

local function EnableForClimbingJump(pawn, cmc)
    EnableGlider(pawn, cmc)
    ReleaseMoveInput(pawn, "climbjump")
end

local function GetLoc(pawn)
    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc == nil then return nil end
    local out = nil
    pcall(function() out = { X = loc.X, Y = loc.Y, Z = loc.Z } end)
    return out
end

-- Unit XY direction, or nil when the vector is too short to have one.
local function NormalizeXY(x, y)
    local length = math.sqrt(x * x + y * y)
    if length < 1e-3 then return nil end
    return { X = x / length, Y = y / length }
end

local function EndClimbJumpState(pawn, cmc)
    if climbJumpState == nil then return end
    climbJumpState = nil
    M.InClimbJump = false
    EnableForClimbingJump(pawn, cmc)
    CommonState.ClimbHasPriority = false
    dbg("[Climb.lua] ENDING CLIMB STATE")
end

-- Write the component into the ORGANIC post-attach signature
-- (is=true can=true ending=false). Mode-only left it unaware (no
-- cooldown, 24ms re-grabs); writes without ending=false left is=true
-- stuck after hops. The reconciler remains the safety net.
local function ForceClimbAttach(cmc)
    if not IsLive(comp) then
        dbg("WARN: climb component stale -- attach skipped")
        return false, false, false
    end

    -- Writes CanClimbing directly, so the suppression bookkeeping has to
    -- follow it or the next SuppressGameClimb(false) would be a no-op and
    -- leave the flag believing it is still holding the component off.
    local okCan  = pcall(function() comp.CanClimbing = true end)
    if okCan then
        wantClimbSuppressed  = false
        climbSuppressionHeld = false
    end
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

-- Slews a yaw angle toward a target direction, in angle space rather than
-- vector space so the result cannot jitter or shorten. Returns the new
-- angle and the unit vector for it; the caller owns where both are stored.
local function SlewYawToward(currentAngle, targetX, targetY, dt, rateDegPerSec)
    local targetAngle = math.deg(math.atan(targetY, targetX))
    if currentAngle == nil then currentAngle = targetAngle end

    -- Handle angle wrapping (-180 to 180 delta)
    local angleDelta = targetAngle - currentAngle
    while angleDelta >  180 do angleDelta = angleDelta - 360 end
    while angleDelta < -180 do angleDelta = angleDelta + 360 end

    -- Exponential smoothing (lerp factor based on dt and the rate cap)
    -- This creates a naturally organic, silky-smooth acceleration curve.
    local smoothFactor = math.min(1.0, dt * (rateDegPerSec / 45.0))
    local newAngle = currentAngle + angleDelta * smoothFactor

    local rad = math.rad(newAngle)
    return newAngle, { X = math.cos(rad), Y = math.sin(rad) }
end

-- Smoothly interpolates and slews the yaw angle directly, preventing vector jitter.
local function SlewFacingToward(dt, targetX, targetY)
    climbJumpState.currentYaw, climbJumpState.faceDir =
        SlewYawToward(climbJumpState.currentYaw, targetX, targetY, dt, HUG_YAW_RATE)
end

-- Sets the inward velocity that pulls toward HUG_TARGET. Only trusted when
-- near-parallel: off-angle, the ray hits obliquely and reads longer than
-- the true perpendicular gap, which would drive the correction backwards.
local function UpdateGapCorrection(gap, facingAlignment)
    local gapReadingIsTrustworthy = facingAlignment >= HUG_PARALLEL
    if not gapReadingIsTrustworthy then
        climbJumpState.inVel = 0
        return
    end

    local gapError = gap - HUG_TARGET
    local correction = gapError * HUG_IN_GAIN
    climbJumpState.inVel = math.max(-HUG_IN_MAX, math.min(HUG_IN_MAX, correction))
end

-- No ray found the wall this frame. Coast on the last known facing; give up
-- once it's been gone long enough to mean the wall genuinely ended.
local function HandleLostWall(pawn, cmc)
    climbJumpState.framesWithoutWall = climbJumpState.framesWithoutWall + 1
    climbJumpState.inVel = 0

    local wallIsGoneForGood = climbJumpState.framesWithoutWall >= HUG_LOST_TICKS
    if wallIsGoneForGood then
        EndClimbJumpState(pawn, cmc)
        return false
    end
    return true
end

-- Where the player is asking to go, in world space. Acceleration rather
-- than Velocity: pressed against a wall the velocity collapses to zero
-- while the input stays populated.
local function GetInputDirection(cmc)
    local acceleration = ReadOpt(cmc, "Acceleration")
    if acceleration == nil then return nil end

    local inputX, inputY = 0, 0
    local readOk = pcall(function() inputX, inputY = acceleration.X, acceleration.Y end)
    if not readOk then return nil end

    local inputMagnitude = math.sqrt(inputX * inputX + inputY * inputY)
    local noInputHeld = inputMagnitude < InitClimb.INPUT_FLOOR
    if noInputHeld then return nil end

    return { X = inputX / inputMagnitude, Y = inputY / inputMagnitude }
end

-- One level ray from the capsule centre (optionally offset up or down the
-- capsule), on the climbing component's own trace channel. Returns
-- { normalX, normalY, normalZ, gap } or nil, where gap is measured from the
-- capsule SURFACE rather than its centre.
-- `lateral` shifts the origin sideways, perpendicular to `direction` in the
-- horizontal plane; positive is to the left of travel.
local function TraceAlongDirection(pawn, direction, rayLength, heightOffset, lateral)
    if not IsLive(KSL) then
        KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not IsLive(KSL) then
            dbg("[climb] Failed Trace Along")
            return nil
        end
    end

    local origin = GetLoc(pawn)
    if origin == nil then return nil end
    origin.Z = origin.Z + (heightOffset or 0)
    if lateral and lateral ~= 0 then
        origin.X = origin.X - direction.Y * lateral
        origin.Y = origin.Y + direction.X * lateral
    end

    local finish = {
        X = origin.X + direction.X * rayLength,
        Y = origin.Y + direction.Y * rayLength,
        Z = origin.Z,
    }

    local hitResult, didHit = {}, nil
    pcall(function()
        didHit = KSL:LineTraceSingle(pawn, origin, finish,
            ReadOpt(comp, "Const_RayChannel") or 0, false, {}, TRACE_DRAW_NONE,
            hitResult, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 },
            TRACE_DRAW_TIME)
    end)
    if not didHit then return nil end

    local normalX, normalY, normalZ, distanceFromCentre
    pcall(function() normalX = hitResult.ImpactNormal.X end)
    pcall(function() normalY = hitResult.ImpactNormal.Y end)
    pcall(function() normalZ = hitResult.ImpactNormal.Z end)
    pcall(function() distanceFromCentre = hitResult.Distance end)

    local hitIsReadable = type(normalX) == "number"
        and type(normalY) == "number"
        and type(normalZ) == "number"
        and type(distanceFromCentre) == "number"
    if not hitIsReadable then return nil end
    fdbg("[climb] hit is readable!")
    return {
        normalX = normalX,
        normalY = normalY,
        normalZ = normalZ,
        gap     = distanceFromCentre - capsuleRadius,
    }
end

-- Everything that makes a hit a climbable wall, in one place, so detection
-- and attach cannot drift apart. Returns { faceDir, gap } or nil.
local function ClassifyWallHit(hit, maxGap)
    if hit == nil then return nil end

    -- Deep negative gap means the trace started inside geometry, where UE
    -- returns a normal facing back down the trace -- which would read as a
    -- perfectly head-on wall every time. A shallow one is just contact.
    local traceStartedInsideGeometry = hit.gap < -PROBE_PENETRATION_SLOP
    if traceStartedInsideGeometry then return nil end

    local wallIsInReach = hit.gap <= maxGap
    if not wallIsInReach then return nil end

    -- The game's own line between "walk up it" and "must climb it".
    local surfaceIsTooSteepToWalk = hit.normalZ < walkableFloorZ
    if not surfaceIsTooSteepToWalk then return nil end

    local intoWall = NormalizeXY(-hit.normalX, -hit.normalY)
    if intoWall == nil then return nil end

    return { faceDir = intoWall, gap = math.max(hit.gap, 0) }
end

-- Probes at three heights and keeps the nearest climbable face. A single
-- ray at capsule centre is blind to a face that is recessed at waist height
-- but present at chest or shin height, which is what made the latch depend
-- on the shape of the surface. Costs two extra traces and so is reserved
-- for the ascent, where it runs for a few hundred milliseconds at most.
--
-- `gap` is the nearest reading, which is what the hold loop should chase.
-- `centreGap` is the centre ray alone, kept separate because that is the
-- ray the component itself casts: on a face that leans away, the low ray
-- reads shorter than centre, and attaching on that optimistic number is a
-- latch the component will not keep. nil when the centre ray missed.
local function ProbeWallFan(pawn, direction, rayLength, maxGap)
    local bestWall, centreGap = nil, nil

    local function ProbeAt(heightOffset)
        local wall = ClassifyWallHit(
            TraceAlongDirection(pawn, direction, rayLength, heightOffset), maxGap)
        if wall == nil then return nil end
        if bestWall == nil or wall.gap < bestWall.gap then bestWall = wall end
        return wall
    end

    local centre = ProbeAt(0)
    if centre ~= nil then centreGap = centre.gap end

    if probeFanOffset > 0 then
        ProbeAt(probeFanOffset)
        ProbeAt(-probeFanOffset)
    end

    if bestWall ~= nil then bestWall.centreGap = centreGap end
    return bestWall
end

-- Is the player moving into a wall, rather than past one or up a slope?
-- Returns the wall as { faceDir, gap } so the starter has a direction to
-- launch along and face; nil when any condition fails.
--
-- Single ray by design: this runs every frame the player is walking, and a
-- wall you can walk into is present at capsule centre height. The fan is for
-- the airborne re-probe, where the ray can end up over a lip or in a recess.
-- The two tests that separate a wall from something merely in the way. Both
-- probe along the APPROACH direction, not the wall normal, so what they ask
-- is "would the player, going this way, meet a face here" -- the question
-- the rest of the sequence is built on.
local function PassesWallShapeChecks(pawn, direction, wall, reach)
    local probeReach = reach + WallDetect.SLACK

    if WallDetect.REQUIRE_EYE then
        local eyeZ = capsuleHalfHeight * WallDetect.EYE_OFFSET_FRAC
        local eye  = TraceAlongDirection(pawn, direction, probeReach, eyeZ, 0)
        if eye == nil then
            return false, "not at eye level (low obstacle)"
        end
        -- Something IS there at eye height but it is walkable: the top of a
        -- boulder, a slope rolling over. Still not a face.
        if eye.normalZ >= walkableFloorZ then
            return false, string.format("walkable at eye level (normalZ %.2f)", eye.normalZ)
        end
    end

    if WallDetect.REQUIRE_WIDTH then
        local w = WallDetect.WIDTH_HALF
        local left  = TraceAlongDirection(pawn, direction, probeReach, 0,  w)
        local right = TraceAlongDirection(pawn, direction, probeReach, 0, -w)
        if left == nil or right == nil then
            return false, string.format("too narrow (left %s, right %s)",
                left and "hit" or "miss", right and "hit" or "miss")
        end
    end

    return true
end

-- Returns the wall, or nil plus a short reason. The reason exists because a
-- session reported twelve consecutive "probe lost the face" give-ups and
-- nothing distinguished "no input held" from "ray missed" from "surface is
-- walkable" -- four very different problems wearing one label.
local function WallInMovementPath(pawn, cmc, maxGap, useFan)
    local inputDirection = GetInputDirection(cmc)
    if inputDirection == nil then return nil, "no input held" end

    -- Ray length is derived from the grab distance, so "the ray hit" and
    -- "the wall is close enough" are one statement instead of two knobs.
    local rayLength = capsuleRadius + maxGap
    local hit, wall
    if useFan then
        wall = ProbeWallFan(pawn, inputDirection, rayLength, maxGap)
        if wall == nil then return nil, "fan found no climbable face" end
    else
        hit  = TraceAlongDirection(pawn, inputDirection, rayLength, 0)
        if hit == nil then return nil, "ray missed" end
        wall = ClassifyWallHit(hit, maxGap)
        if wall == nil then
            -- Say which rule rejected it: a face that is merely walkable is
            -- a tuning problem, one the trace started inside is a geometry
            -- problem, and they need opposite fixes.
            if hit.gap < -PROBE_PENETRATION_SLOP then
                return nil, string.format("trace inside geometry (gap %.1f)", hit.gap)
            elseif hit.gap > maxGap then
                return nil, string.format("beyond reach (gap %.1f > %.0f)", hit.gap, maxGap)
            elseif hit.normalZ >= walkableFloorZ then
                return nil, string.format("surface walkable (normalZ %.2f >= %.2f)",
                    hit.normalZ, walkableFloorZ)
            end
            return nil, "unclassifiable hit"
        end
    end

    local approachAlignment =
        inputDirection.X * wall.faceDir.X + inputDirection.Y * wall.faceDir.Y
    if approachAlignment < InitClimb.CONE_COS then
        return nil, string.format("outside cone (%.0f deg)",
            math.deg(math.acos(Clamp(approachAlignment, -1, 1))))
    end

    local shapeOk, shapeWhy = PassesWallShapeChecks(pawn, inputDirection, wall, rayLength)
    if not shapeOk then return nil, shapeWhy end

    fdbg("[climb] Walking into wall!")
    return wall
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

local function GetZ(pawn)
    local l = GetLoc(pawn)
    return l and l.Z or nil
end

-- The pawn's horizontal forward direction. During climbing the character is
-- pressed flat against the wall, so this doubles as the into-wall direction.
local function WallFwd(pawn)
    if pawn == nil then return nil end

    local forwardX, forwardY = nil, nil
    local readSucceeded = pcall(function()
        local forward = pawn:GetActorForwardVector()
        forwardX = forward.X
        forwardY = forward.Y
    end)

    local gotUsableNumbers = readSucceeded
        and type(forwardX) == "number"
        and type(forwardY) == "number"
    if not gotUsableNumbers then return nil end

    local horizontalLength =
        math.sqrt(forwardX * forwardX + forwardY * forwardY)
    if horizontalLength < 1e-4 then return nil end

    return { X = forwardX / horizontalLength, Y = forwardY / horizontalLength }
end

local function SetHorizVel(cmc, x, y)
    pcall(function()
        cmc.Velocity.X = x
        cmc.Velocity.Y = y
    end)
end

local function FaceYaw(pawn, faceDir)
    if not LOCK_ROTATION or faceDir == nil then return end
    local yaw = math.deg(math.atan(faceDir.Y, faceDir.X))
    pcall(function()
        pawn:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false)
    end)
end

-- =========================================================================
--  DEBUG VISUALISATION
-- Everything here is inert unless DEBUG_VOLUMES is on, and every call is
-- pcall-wrapped: a missing DrawDebug* on some UE4SS build must never take
-- gameplay down with it.
-- =========================================================================

local COLOR_GUARD   = { R = 1.0, G = 0.25, B = 0.10, A = 1.0 }  -- arm range
local COLOR_COMMIT  = { R = 0.15, G = 1.0,  B = 0.25, A = 1.0 }  -- commit range
local COLOR_ATTACH  = { R = 0.20, G = 0.55, B = 1.0,  A = 1.0 }  -- grabbable
local COLOR_MISS    = { R = 0.45, G = 0.45, B = 0.50, A = 1.0 }  -- probe found nothing
local COLOR_CAPSULE = { R = 0.85, G = 0.30, B = 1.0,  A = 1.0 }  -- width probes

local vizCategory = nil

local function VizCategory()
    if vizCategory == nil and Viz ~= nil then
        pcall(function() vizCategory = Viz.MakeCategory("PalFeel.Climb") end)
    end
    return vizCategory
end

-- A short vertical bar at `dist` along the approach, marking one of the
-- distances this file changes behaviour at. Bars rather than ground rings:
-- the comparison that matters is "is the face nearer or further than this",
-- which reads directly when the marker sits on the same line as the probes.
local function DrawGate(origin, dir, dist, color, cat)
    local x, y = origin.X + dir.X * dist, origin.Y + dir.Y * dist
    pcall(function()
        Viz.DrawLine(
            { X = x, Y = y, Z = origin.Z - capsuleHalfHeight * 0.5 },
            { X = x, Y = y, Z = origin.Z + capsuleHalfHeight * 0.5 },
            color, 2.0, DEBUG_VOLUME_TIME, cat)
    end)
end

-- Draws every check this file makes, in world space.
--
-- Rays go through Viz.LineTrace rather than being drawn from cached results,
-- because the library also draws the impact point and the SURFACE NORMAL --
-- and the normal is what the walkable-slope rejection turns on. A face this
-- file refuses to climb because "surface walkable (normalZ >= WalkableFloorZ)"
-- is invisible in any drawing that shows only where the ray stopped.
--
-- The capsule sweep answers the other half. The rays show where the face IS;
-- the capsule shows how close the player can actually GET to it. A capsule
-- that halts outside the green commit gate means the commit distance is
-- unreachable on that geometry, and no probe tuning will fix it.
--
-- Debug-only cost: three extra line traces and one capsule sweep per frame.
local function VisualiseClimbChecks(pawn, cmc)
    if not DEBUG_VOLUMES or Viz == nil then return end

    local origin = GetLoc(pawn)
    if origin == nil then return end

    local dir = GetInputDirection(cmc) or WallFwd(pawn)
    if dir == nil then return end

    local cat     = VizCategory()
    -- The component's own channel, not the library default. A ray drawn on
    -- Visibility while the real checks run on Const_RayChannel would show a
    -- confident picture of geometry nobody is testing against.
    local channel = ReadOpt(comp, "Const_RayChannel") or 0
    local reach   = capsuleRadius + InitClimb.GUARD_GAP

    local heights = { 0 }
    if probeFanOffset > 0 then
        heights[#heights + 1] =  probeFanOffset
        heights[#heights + 1] = -probeFanOffset
    end
    for _, h in ipairs(heights) do
        pcall(function()
            Viz.LineTrace(
                { X = origin.X, Y = origin.Y, Z = origin.Z + h },
                { X = origin.X + dir.X * reach,
                  Y = origin.Y + dir.Y * reach,
                  Z = origin.Z + h },
                { Channel  = channel,
                  Duration = DEBUG_VOLUME_TIME,
                  Category = cat,
                  HitColor = COLOR_ATTACH,
                  MissColor = COLOR_MISS,
                  DrawImpactNormal = true })
        end)
    end

    -- Thresholds, measured from the capsule surface exactly as the checks
    -- measure them, so what is drawn is what is compared.
    DrawGate(origin, dir, capsuleRadius + InitClimb.GUARD_GAP, COLOR_GUARD,  cat)
    DrawGate(origin, dir, capsuleRadius + InitClimb.HOP_GAP,   COLOR_COMMIT, cat)
    DrawGate(origin, dir, capsuleRadius + InitClimb.MAX_GAP,   COLOR_COMMIT, cat)
    DrawGate(origin, dir, capsuleRadius + ATTACH_MAX_GAP,      COLOR_ATTACH, cat)

    -- The shape checks, drawn the way the standard Unreal pattern draws them:
    -- eye-level probe above the waist probes, width probes either side. When
    -- the waist ray lands but the eye ray does not, that is a step, not a
    -- wall, and the picture says so directly. (A capsule sweep used to be
    -- drawn here; it was removed because a horizontal sweep has no step-up
    -- and halts on ground the real player walks over, which answered a
    -- question nobody was asking.)
    local probeReach = reach + WallDetect.SLACK
    local eyeZ = origin.Z + capsuleHalfHeight * WallDetect.EYE_OFFSET_FRAC
    pcall(function()
        Viz.LineTrace(
            { X = origin.X, Y = origin.Y, Z = eyeZ },
            { X = origin.X + dir.X * probeReach, Y = origin.Y + dir.Y * probeReach, Z = eyeZ },
            { Channel = channel, Duration = DEBUG_VOLUME_TIME, Category = cat,
              HitColor = COLOR_COMMIT, MissColor = COLOR_MISS, DrawImpactNormal = true })
    end)
    for _, side in ipairs({ 1, -1 }) do
        local w  = WallDetect.WIDTH_HALF * side
        local sx = origin.X - dir.Y * w
        local sy = origin.Y + dir.X * w
        pcall(function()
            Viz.LineTrace(
                { X = sx, Y = sy, Z = origin.Z },
                { X = sx + dir.X * probeReach, Y = sy + dir.Y * probeReach, Z = origin.Z },
                { Channel = channel, Duration = DEBUG_VOLUME_TIME, Category = cat,
                  HitColor = COLOR_CAPSULE, MissColor = COLOR_MISS })
        end)
    end
end

-- =========================================================================
--  INIT CLIMB SEQUENCE
-- Walk or fly into a climbable face -> hop -> latch. One state machine for
-- both entries; they differ only in how the hop is produced.
--
--   launch  : ground asks the game to jump and waits for MOVE_Falling;
--             air writes the hop impulse itself and is airborne already.
--   ascend  : every frame re-probes the face, re-squares to it, and holds
--             the gap with a closed loop. The old build launched blind and
--             coasted, so the gap at attach time was whatever the wall
--             collision left behind -- the source of the angle/shape
--             dependence.
--   attach  : the moment the gap is inside the component's own reach, on
--             every frame until the window closes, not on a fixed clock.
-- =========================================================================

local function EndInitClimb(pawn, cmc, reason)
    if not M.InInitClimbState then return end
    initClimbState     = nil
    M.InInitClimbState = false
    EnableForInitClimb(pawn, cmc)
    dbg("init climb end: %s", reason or "?")
end

-- Force the mode, then read it back: ForceClimbAttach reports whether its
-- writes succeeded, not whether the component kept them.
local function TryInitClimbAttach(pawn, cmc, wall, attachGap)
    ForceClimbAttach(cmc)
    initClimbState.tries         = initClimbState.tries + 1
    initClimbState.retryCooldown = InitClimb.RETRY_INTERVAL

    local movementMode       = cmc.MovementMode
    local customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0
    local latched = (movementMode == 6 and customMovementMode == 5)

    dbg("attach try %d: gap=%.1f/%.1f (reach %.1f) rise=%.0f air=%.2fs -> %s",
        initClimbState.tries, attachGap, wall.gap, ATTACH_MAX_GAP,
        (GetZ(pawn) or 0) - initClimbState.launchZ,
        initClimbState.airTime, latched and "LATCHED" or "refused")

    return latched
end

local function BeginInitClimb(pawn, cmc, wall, entryType)
    initClimbState = {
        type       = entryType,
        faceDir    = wall.faceDir,
        currentYaw = math.deg(math.atan(wall.faceDir.Y, wall.faceDir.X)),
        timeSinceRequest = 0,
        hasLaunched = false,
        airTime    = 0,
        launchZ    = GetZ(pawn) or 0,
        phase      = "ascend",
        approachTime = 0,
        tries      = 0,
        retryCooldown = 0,
        framesWithoutWall = 0,
        inVel      = 0,
    }

    -- Degree correction bounded by the detection cone.
    FaceYaw(pawn, wall.faceDir)

    M.InInitClimbState = true
    DisableForInitClimb(pawn, cmc)
end

-- Square up to the wall and hand off to the game's own jump, so the launch
-- keeps the game's jump animation and stamina cost. Nothing has left the
-- ground when this returns -- RequestJump only raises bPressedJump, and the
-- character's movement tick is what acts on it, which is why the launch is
-- confirmed by watching for MOVE_Falling rather than by the call returning.
local function StartClimbFromGround(pawn, cmc, wall)
    BeginInitClimb(pawn, cmc, wall, "ground")

    local jumpRequested = pcall(function() pawn:RequestJump() end)
    if not jumpRequested then
        EndInitClimb(pawn, cmc, "RequestJump call failed")
        return
    end

    dbg("init climb from ground: gap=%.1f face=(%+.2f,%+.2f)",
        wall.gap, wall.faceDir.X, wall.faceDir.Y)
end

-- Airborne entry: the mini hop. Written straight onto the velocity rather
-- than routed through the jump system, which could not express this move --
-- DoJump takes max(Velocity.Z, JumpZVelocity), a no-op while still rising,
-- and CanJump refuses outright when falling with JumpCurrentCount == 0.
-- Being already airborne, this launches on the spot.
-- The hop itself, once the approach hold has run its course.
local function ApplyMiniHop(pawn, cmc)
    local entryVz = 0
    pcall(function() entryVz = cmc.Velocity.Z end)
    local hopVz = Clamp(entryVz + InitClimb.HOP_VZ_ADD,
        InitClimb.HOP_VZ_MIN, InitClimb.HOP_VZ_MAX)

    pcall(function() cmc.Velocity.Z = hopVz end)
    SetHorizVel(cmc,
        initClimbState.faceDir.X * InitClimb.HOP_IN_SPEED,
        initClimbState.faceDir.Y * InitClimb.HOP_IN_SPEED)

    initClimbState.phase       = "ascend"
    initClimbState.hasLaunched = true
    initClimbState.airTime     = 0
    initClimbState.launchZ     = GetZ(pawn) or initClimbState.launchZ

    dbg("mini hop after %.2fs approach: vz %.0f -> %.0f",
        initClimbState.approachTime, entryVz, hopVz)
end

-- Airborne entry. Commits further out than the hop needs and locks the climb
-- out immediately, then spends INIT_CLIMB_APPROACH_HOLD driving the pawn at
-- the face before hopping. Hopping the instant the wall came into range read
-- as jumping too early; the lock is what makes waiting safe, since the
-- component cannot grab during the hold.
local function StartClimbFromAir(pawn, cmc, wall)
    BeginInitClimb(pawn, cmc, wall, "air")
    initClimbState.phase        = "approach"
    initClimbState.approachTime = 0
    initClimbState.hasLaunched  = true   -- already airborne; nothing to launch

    dbg("init climb from air: gap=%.1f face=(%+.2f,%+.2f) -- locked out, "
        .. "holding %.2fs before the hop",
        wall.gap, wall.faceDir.X, wall.faceDir.Y, InitClimb.APPROACH_HOLD)
end

-- Ground entry only: hold until the character actually leaves the ground,
-- then normalise the launch so every auto-latch flies the same arc.
-- Returns false while still waiting.
local function ConfirmLaunch(dt, pawn, cmc)
    if initClimbState.hasLaunched then return true end

    initClimbState.timeSinceRequest = initClimbState.timeSinceRequest + dt

    local hasLeftTheGround = (cmc.MovementMode == 3)
    if not hasLeftTheGround then
        local jumpWasRefused =
            initClimbState.timeSinceRequest > InitClimb.LAUNCH_GRACE
        if jumpWasRefused then
            EndInitClimb(pawn, cmc, "jump never executed")
        end
        return false
    end

    initClimbState.hasLaunched = true
    initClimbState.launchZ     = GetZ(pawn) or initClimbState.launchZ
    if InitClimb.LAUNCH_VZ ~= nil then
        pcall(function() cmc.Velocity.Z = InitClimb.LAUNCH_VZ end)
    end
    return true
end

-- Re-square to the live surface and set the inward velocity that holds the
-- gap. Returns false once the face has been missing long enough to mean the
-- player is no longer flying at a wall.
local function TrackInitClimbWall(dt, pawn, cmc, wall)
    if wall == nil then
        initClimbState.framesWithoutWall = initClimbState.framesWithoutWall + 1
        initClimbState.inVel = 0
        if initClimbState.framesWithoutWall >= InitClimb.LOST_TICKS then
            EndInitClimb(pawn, cmc, "wall lost during ascent")
            return false
        end
        return true
    end

    initClimbState.framesWithoutWall = 0

    initClimbState.currentYaw, initClimbState.faceDir = SlewYawToward(
        initClimbState.currentYaw, wall.faceDir.X, wall.faceDir.Y,
        dt, InitClimb.YAW_RATE)

    local gapError = wall.gap - InitClimb.HOLD_GAP
    initClimbState.inVel =
        Clamp(gapError * InitClimb.IN_GAIN, -InitClimb.IN_MAX, InitClimb.IN_MAX)
    return true
end

-- Air time and rise only exist so the hop reads as a hop before the latch
-- lands. The apex clause guarantees the gate always opens: a minimum
-- strength hop peaks below InitClimb.MIN_RISE and would otherwise never
-- qualify.
local function AttachGateIsOpen(pawn, cmc)
    if initClimbState.airTime < InitClimb.MIN_AIR_TIME then return false end

    local rise = (GetZ(pawn) or 0) - initClimbState.launchZ
    if rise >= InitClimb.MIN_RISE then return true end

    local vz = 0
    pcall(function() vz = cmc.Velocity.Z end)
    return vz <= 0
end

local function DriveInitClimb(dt, pawn, cmc)
    if not ConfirmLaunch(dt, pawn, cmc) then return end

    local inApproach = initClimbState.phase == "approach"
    if inApproach then
        initClimbState.approachTime = initClimbState.approachTime + dt
    else
        initClimbState.airTime = initClimbState.airTime + dt

        local windowHasClosed = initClimbState.airTime > InitClimb.LOCK_TIME
        if windowHasClosed then
            EndInitClimb(pawn, cmc, "window closed without a latch")
            return
        end
    end

    -- The ascent owns gravity outright (jump.lua is gated off by
    -- ClimbHasPriority), so the arc no longer changes with the velocity band
    -- the player happens to be in, or with a jump-cut fired mid-approach.
    pcall(function() cmc.GravityScale = InitClimb.GRAVITY end)
    DrainMoveInput(cmc)

    -- Tracks well past grab range so the hold loop can pull a drifting
    -- ascent back in instead of simply losing the face.
    local trackMaxGap    = InitClimb.GUARD_GAP
    local probeRayLength = capsuleRadius + trackMaxGap
    local wall = ProbeWallFan(pawn, initClimbState.faceDir, probeRayLength,
        trackMaxGap)

    if not TrackInitClimbWall(dt, pawn, cmc, wall) then return end

    FaceYaw(pawn, initClimbState.faceDir)
    SetHorizVel(cmc,
        initClimbState.faceDir.X * initClimbState.inVel,
        initClimbState.faceDir.Y * initClimbState.inVel)

    -- The approach hold: same tracking and the same closed loop driving the
    -- pawn at the face, but no attach attempts. Its whole job is to spend a
    -- moment closing the distance under the climb lock so the hop reads as a
    -- deliberate move rather than a twitch the instant the wall came in range.
    if inApproach then
        if initClimbState.approachTime >= InitClimb.APPROACH_HOLD then
            ApplyMiniHop(pawn, cmc)
        end
        return
    end

    initClimbState.retryCooldown = math.max(0, initClimbState.retryCooldown - dt)

    -- Judged on the centre ray, the one the component re-casts every frame
    -- to decide whether to keep the climb. The fan's nearest reading is for
    -- finding and holding the face, not for committing to it.
    local attachGap = wall and (wall.centreGap or wall.gap)
    local canAttachNow = attachGap ~= nil
        and initClimbState.retryCooldown <= 0
        and AttachGateIsOpen(pawn, cmc)
        and attachGap <= ATTACH_MAX_GAP
    if not canAttachNow then return end

    if TryInitClimbAttach(pawn, cmc, wall, attachGap) then
        EndInitClimb(pawn, cmc, "latched")
    end
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
    slidingDownWall = true
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
    if not slidingDownWall then return end
    slidingDownWall = false
    slideV  = 0
    if savedClimbMax ~= nil then
        pcall(function() cmc.ClimbMaxSpeed = savedClimbMax end)
        savedClimbMax = nil
    end
    dbg("slide end: %s", reason or "?")
end

local function TickWallSlide(dt, pawn, cmc)
    local deltaZ = slideV * dt
    local z0 = GetZ(pawn)
    local okMove = pcall(function()
        pawn:K2_AddActorWorldOffset({ X = 0, Y = 0, Z = -deltaZ }, true, {}, false)
    end)
    if not okMove then
        EndWallSlide(cmc, "K2_AddActorWorldOffset call failed")
        return
    end
    if z0 ~= nil then
        local z1 = GetZ(pawn)
        if z1 ~= nil and deltaZ > 0.5 then
            local moved = z0 - z1
            if moved < deltaZ * BLOCK_RATIO then
                EndWallSlide(cmc, string.format(
                    "blocked (commanded %.1f, moved %.1f)", deltaZ, moved))
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
-- mode state so the guard holds on the post-attach frame).
local function UpdateWallSlide(dt, pawn, cmc, isClimbing)
    if isClimbing and not prevModeWasClimb and climbJumpState == nil then
        local entryVz = math.min(lastFallVz, cmc.Velocity.Z)
        if entryVz <= VZ_TRIGGER then
            BeginWallSlide(cmc, entryVz)
        end
    end

    if slidingDownWall and not isClimbing then
        EndWallSlide(cmc, "left climb mode")
    end

    if slidingDownWall and isClimbing then
        TickWallSlide(dt, pawn, cmc)
    end
end

-- =========================================================================
-- 6. CLIMB JUMP
-- Detach detection -> angle-bucket classification -> driven wall-plane
-- leap with a scheduled attach window, or DOWN hop away.
-- =========================================================================



-- Fires three traces in a fan around the current wall facing and returns
-- the best hit, or nil if the wall was lost this frame.
--
-- Returns a table: { normalX, normalY, gap, rayAngle }
--   gap      = distance from the capsule SURFACE to the wall (not center)
--   rayAngle = which ray won, in degrees; 0 = straight ahead, sign gives
--              which side. Non-zero means the wall is off to that side,
--              which is what identifies a corner.
local function SenseWall(pawn, wallFacing, leapSideSign)
    if not IsLive(KSL) then return nil end

    local origin = GetLoc(pawn)
    if origin == nil then return nil end

    local traceChannel = ReadOpt(comp, "Const_RayChannel") or 0
    local bestHit = nil
    local bestScore = math.huge

    local function CastRay(rayAngleDegrees)
        local angle = math.rad(rayAngleDegrees)
        local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
        local directionX = wallFacing.X * cosAngle - wallFacing.Y * sinAngle
        local directionY = wallFacing.X * sinAngle + wallFacing.Y * cosAngle

        local hitResult, didHit = {}, nil
        pcall(function()
            didHit = KSL:LineTraceSingle(pawn, origin,
                { X = origin.X + directionX * HUG_RAY_LEN,
                  Y = origin.Y + directionY * HUG_RAY_LEN,
                  Z = origin.Z },
                traceChannel, false, {}, TRACE_DRAW_NONE, hitResult, true,
                {R=1,G=0,B=0,A=1}, {R=0,G=1,B=0,A=1}, TRACE_DRAW_TIME)
        end)
        if not didHit then return end

        local normalX, normalY, distanceFromCenter = nil, nil, nil
        pcall(function() normalX = hitResult.ImpactNormal.X end)
        pcall(function() normalY = hitResult.ImpactNormal.Y end)
        pcall(function() distanceFromCenter = hitResult.Distance end)
        if type(normalX) ~= "number" or type(distanceFromCenter) ~= "number" then
            return
        end

        local gapFromCapsuleSurface = distanceFromCenter - capsuleRadius

        -- The ray angled toward the leap's travel side sees corners before
        -- the forward ray does, so it wins near-ties. The ray angled away
        -- gets no such preference.
        local isLeadingRay = (leapSideSign ~= 0)
            and (rayAngleDegrees * leapSideSign > 0)
        local score = gapFromCapsuleSurface - (isLeadingRay and LEAD_RAY_BONUS or 0)

        if score < bestScore then
            bestScore = score
            bestHit = {
                normalX  = normalX,
                normalY  = normalY,
                gap      = gapFromCapsuleSurface,
                rayAngle = rayAngleDegrees,
            }
        end
    end

    CastRay(0)
    if leapSideSign ~= 0 then
        CastRay(HUG_FAN_DEG * leapSideSign)
        CastRay(-HUG_FAN_DEG * leapSideSign)
    end

    return bestHit
end

-- Drives the leap: along-wall travel from the eased speed curve, the
-- inward correction that holds the gap, and the vertical component.
local function ApplyHugVelocity(pawn, cmc)
    local faceDir = climbJumpState.faceDir
    local alongWallX, alongWallY = -faceDir.Y, faceDir.X

    local leapProgress =
        math.min(climbJumpState.deltaTime / climbJumpState.driveTime, 1.0)
    local driveSpeed = LEAP_EASE(LEAP_SPEED_START, LEAP_SPEED_END, leapProgress)

    local inwardSpeed = climbJumpState.inVel or 0

    SetHorizVel(cmc,
        alongWallX * climbJumpState.dirSide * driveSpeed + faceDir.X * inwardSpeed,
        alongWallY * climbJumpState.dirSide * driveSpeed + faceDir.Y * inwardSpeed)
    pcall(function() cmc.Velocity.Z = climbJumpState.dirUp * driveSpeed end)

    FaceYaw(pawn, faceDir)
end

-- Is the face about to end just above us? Low ray still finds wall, high ray
-- finds nothing: that gap between them is the lip. Only meaningful while
-- rising, so callers gate on that rather than paying for two traces a frame
-- on a sideways or downward leap.
local function SenseTopEdge(pawn, faceDir)
    local reach = capsuleRadius + TopOut.MAX_GAP

    local low = TraceAlongDirection(pawn, faceDir, reach, TopOut.LOW_OFFSET)
    if low == nil or low.gap > TopOut.MAX_GAP then return false end
    -- A walkable-normal hit is a slope rolling over, not a face with a lip.
    if low.normalZ >= walkableFloorZ then return false end

    local high = TraceAlongDirection(pawn, faceDir, reach, TopOut.HIGH_OFFSET)
    return high == nil
end

-- Latch at the lip and hand off to the game's own top-out. The attach is the
-- part that matters -- it stops the leap sailing past -- so the event call is
-- attempted after it and its failure is not fatal.
local function TryTopOut(pawn, cmc)
    ForceClimbAttach(cmc)

    local movementMode       = cmc.MovementMode
    local customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0
    local latched = (movementMode == 6 and customMovementMode == 5)
    if not latched then return false end

    -- See TopOut.CALL_EVENT: this is off, and is kept only so the reason is
    -- attached to the code rather than living in a commit message.
    local firedEvent = false
    if TopOut.CALL_EVENT and IsLive(comp) then
        firedEvent = pcall(function() comp:ClimbUpAtTopEvent() end)
    end

    dbg("top-out caught mid-leap: latched=%s vaultEvent=%s",
        tostring(latched), tostring(firedEvent))
    return true
end

-- The leap's scheduled end: both sensors must confirm a wall before the
-- attach is forced. Gives up once the window closes.
local function TryAttachToWall(pawn, cmc, wallHit) 
    local hasAttemptsLeft = climbJumpState.tries < ATTACH_MAX_TRIES
    local wallIsInReach   = (wallHit ~= nil) and (wallHit.gap <= ATTACH_MAX_GAP)

    fdbg("[climb.lua] TRYING TO LATCH ON TO WALL")

    if hasAttemptsLeft and wallIsInReach then
        ForceClimbAttach(cmc)
        climbJumpState.tries = climbJumpState.tries + 1
    end

    local attachWindowHasClosed = climbJumpState.deltaTime > climbJumpState.driveTime + ATTACH_WINDOW
    if attachWindowHasClosed then
        EndClimbJumpState(pawn, cmc)
    end
end

-- Returns bucket, sideSign. Angle is measured from the wall-up axis in
-- the wall plane. Neutral maps to UP (BotW: no direction held = straight
-- up). Velocity-based for now; see the input diagnostic in
-- DetectClimbJump.
local function ClassifyJumpDirection(inputAlongWall, inputUpward)
    local inputX = inputAlongWall
    local inputY = inputUpward
    local inputMagnitude = math.sqrt(inputX * inputX + inputY * inputY)

    local noInputHeld = inputMagnitude < 1e-3
    if noInputHeld then
        return "UP", 0
    end

    inputX = inputX / inputMagnitude
    inputY = inputY / inputMagnitude
    dbg("[climb.lua] inputX: %s , inputY: %s", inputX, inputY)
    local closestDirection = nil
    local closestDot = -math.huge

    for _, direction in ipairs(JUMP_DIRECTIONS) do
        local length = math.sqrt(direction.x * direction.x + direction.y * direction.y)
        local dot = inputX * (direction.x / length) + inputY * (direction.y / length)
        if dot > closestDot then
            closestDot = dot
            closestDirection = direction
        end
    end

    return closestDirection.name, closestDirection.sign
end

-- Turns this frame's wall reading into a facing update and a gap correction.
-- Returns false when the leap should end.
local function TrackWallSurface(dt, pawn, cmc, wallHit)
    local wallWasFound = wallHit ~= nil
    if not wallWasFound then
        return HandleLostWall(pawn, cmc)
    end

    climbJumpState.framesWithoutWall = 0

    -- ImpactNormal is unit length in 3D, so on any wall that isn't
    -- perfectly vertical its horizontal part is shorter than 1.
    -- Renormalize before using it as a 2D direction.
    local towardWallX = -wallHit.normalX
    local towardWallY = -wallHit.normalY
    local horizontalLength =
        math.sqrt(towardWallX * towardWallX + towardWallY * towardWallY)

    local surfaceIsVerticalEnough = horizontalLength > 1e-3
    if not surfaceIsVerticalEnough then
        return true
    end

    towardWallX = towardWallX / horizontalLength
    towardWallY = towardWallY / horizontalLength

    -- NEW: Smooth the raw ray normal vector to eliminate high-frequency raycast jitter
    local smoothness = 12.0 -- Higher = snappier, Lower = smoother
    local currentSmooth = climbJumpState.smoothFaceDir or climbJumpState.faceDir
    local smoothedX = currentSmooth.X + (towardWallX - currentSmooth.X) * math.min(1.0, dt * smoothness)
    local smoothedY = currentSmooth.Y + (towardWallY - currentSmooth.Y) * math.min(1.0, dt * smoothness)
    
    local smoothLen = math.sqrt(smoothedX * smoothedX + smoothedY * smoothedY)
    if smoothLen > 1e-3 then
        smoothedX = smoothedX / smoothLen
        smoothedY = smoothedY / smoothLen
    end
    climbJumpState.smoothFaceDir = { X = smoothedX, Y = smoothedY }

    local facingAlignment =
            climbJumpState.faceDir.X * smoothedX +
            climbJumpState.faceDir.Y * smoothedY

    local cornerIsTooSharpToWrap = facingAlignment < HUG_WRAP_COS
    if cornerIsTooSharpToWrap then
        EndClimbJumpState(pawn, cmc)
        return false
    end

    -- Pass the smoothed direction to the slewing logic
    SlewFacingToward(dt, smoothedX, smoothedY)
    UpdateGapCorrection(wallHit.gap, facingAlignment)
    return true
end

-- One-shot out-struct characterization: a floor's normal is +1.00 by
-- definition, distinguishing a populated normal from a zero-init struct
-- (vertical walls cannot). Runs once per pawn.
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

local function BeginWallHugLeap(pawn, cmc, bucket, sideSign)
    local ang  = math.rad(LEAP_ANGLES[bucket])
    local mean = LEAP_SPEED_START / 6 + 5 * LEAP_SPEED_END / 6
    local initialYaw = math.deg(math.atan(prevWallFwd.Y, prevWallFwd.X))

    climbJumpState = { mode = "hug", kind = bucket, deltaTime = 0, faceDir = prevWallFwd,
            currentYaw = initialYaw, -- NEW: Track continuous yaw angle
            dirUp   = math.cos(ang),
            dirSide = math.sin(ang) * sideSign,
            driveTime  = LEAP_DIST / mean,
            l0 = GetLoc(pawn),
            probes = 0, tries = 0, logged = false,
            framesWithoutWall = 0}
    M.InClimbJump = true
    dbg("climb jump [%s%s] -> eased leap (%d->%d dist=%d driveTime=%.0fms)",
        bucket, sideSign ~= 0 and (sideSign > 0 and "/R" or "/L") or "",
        LEAP_SPEED_START, LEAP_SPEED_END, LEAP_DIST, climbJumpState.driveTime * 1000)
end

local function BeginHopAway(pawn, cmc, bucket)
    climbJumpState = { mode = "hop", kind = bucket, deltaTime = 0, faceDir = prevWallFwd,
           l0 = GetLoc(pawn) }
    M.InClimbJump = true
    -- The hop is a normal-ish jump: release climb priority so jump.lua's
    -- gravity bands resume next tick. Without this, a gated jump.lua and
    -- a hop that doesn't manage gravity leaves NOBODY owning
    -- GravityScale -- and a preceding hug left it at 0.
    CommonState.ClimbHasPriority = false

    pcall(function() cmc.Velocity.Z = HOP_VZ end)
    SetHorizVel(cmc, -prevWallFwd.X * HOP_OUT, -prevWallFwd.Y * HOP_OUT)
    dbg("climb jump [%s] -> hop away (out=%d vz=%d lock=%.2fs)",
        bucket, HOP_OUT, HOP_VZ, HOP_LOCK)
end




local function DidClimbJumpStart(cmc, mode)
    local notGrounded = mode == 3
    local ascendingFast = cmc.Velocity.Z > 600
    return climbJumpState == nil and prevModeWasClimb and notGrounded and ascendingFast
end

-- classify the jump and launch.
local function StartClimbJump(pawn, cmc)
    local bucket, sign = ClassifyJumpDirection(prevClimbInputAlongWall, prevClimbInputUpward)
    EndWallSlide(cmc, "climb jump")
    DisableForClimbingJump(pawn, cmc)
    if bucket == "DOWN" then
        BeginHopAway(pawn, cmc, bucket)
    else
        BeginWallHugLeap(pawn, cmc, bucket, sign)
    end
end

-- Per-frame driver for a wall-hug climb jump. Ends when the leap attaches,
-- lands, loses the wall, or runs out its window.
local function TickHugWall(dt, pawn, cmc, mode, isClimbing)
    if isClimbing then
        dbg("I started climbing after jump...")
        EndClimbJumpState(pawn, cmc)
        return
    end

    local hasLeftFalling = mode ~= 3
    if hasLeftFalling then
        dbg("I have stopped falling after climb jump..?")
        EndClimbJumpState(pawn, cmc)
        return
    end

    -- Catch the top-out before anything else: a leap that is about to clear
    -- the lip should hand off to the vault rather than sail over it and fall.
    -- Only while rising, so a sideways or downward leap pays nothing.
    if TopOut.ENABLED and climbJumpState.dirUp > 0
       and SenseTopEdge(pawn, climbJumpState.faceDir) then
        if TryTopOut(pawn, cmc) then
            EndClimbJumpState(pawn, cmc)
            return
        end
    end

    local isWithinLeapWindow = climbJumpState.deltaTime < climbJumpState.driveTime + ATTACH_WINDOW
    local hasReachedAttachWindow = climbJumpState.deltaTime >= climbJumpState.driveTime 
    local wallHit = SenseWall(pawn, climbJumpState.faceDir, climbJumpState.dirSide)
  
    if isWithinLeapWindow then
        pcall(function() cmc.GravityScale = 0.0 end)
        local leapShouldContinue = TrackWallSurface(dt, pawn, cmc, wallHit)
        if not leapShouldContinue then return end
        ApplyHugVelocity(pawn, cmc)
    end

    -- If time spent in jumpstate is greater than the time we should be in it, ignoring the time it takes to do the attach animation
    if hasReachedAttachWindow then
        ApplyHugVelocity(pawn, cmc)
        TryAttachToWall(pawn, cmc, wallHit)
    end
end

-- Per-frame driver for the hop-off. Pushes away from the wall for a fixed
-- window, then hands control back. No wall sensing — this is a dismount.
local function TickHopOffWall(dt, pawn, cmc, mode)
    -- Landing inside the lock window must release control rather than keep
    -- shoving the pawn along the ground.
    local hasLeftFalling = mode ~= 3
    if hasLeftFalling then
        EndClimbJumpState(pawn, cmc)
        return
    end

    local isWithinPushWindow = climbJumpState.deltaTime < HOP_LOCK
    if not isWithinPushWindow then
        EndClimbJumpState(pawn, cmc)
        return
    end

    -- faceDir points INTO the wall, so the hop travels and faces the
    -- opposite direction.
    local intoWallDir = climbJumpState.faceDir
    local awayFromWallX = -intoWallDir.X
    local awayFromWallY = -intoWallDir.Y

    SetHorizVel(cmc, awayFromWallX * HOP_OUT, awayFromWallY * HOP_OUT)
    FaceYaw(pawn, { X = awayFromWallX, Y = awayFromWallY })
end

-- Hub function for anything with ticking the jump
local function TickClimbJump(dt, pawn, cmc, mode, isClimbing)
    if climbJumpState == nil then return end

    -- Before anything reads or writes velocity. The leap sets velocity and
    -- yaw every frame, but a live input vector still reaches the movement
    -- component underneath and steers the pawn off the face during the
    -- attach window -- the last moments, where the miss is most costly.
    DrainMoveInput(cmc)

    climbJumpState.deltaTime = climbJumpState.deltaTime + dt

    if climbJumpState.mode == "hug" then
        TickHugWall(dt, pawn, cmc, mode, isClimbing)
    else
        TickHopOffWall(dt, pawn, cmc, mode)
    end
end

local function ApplyRawClimbInput(pawn, cmc)
    if prevWallFwd == nil then return end

    -- Discard the camera-derived vector first, or ours sums with it.
    pcall(function() cmc:ConsumeInputVector() end)

    local stickAlongWall, stickUpward, stickMagnitude = Input.GetStick()

    local stickIsCentred = stickMagnitude == 0
    if stickIsCentred then return end

    local wallRightX, wallRightY = -prevWallFwd.Y, prevWallFwd.X

    local inputX = wallRightX * stickAlongWall
    local inputY = wallRightY * stickAlongWall
    local inputZ = stickUpward

    pcall(function()
        pawn:AddMovementInput({ X = inputX, Y = inputY, Z = inputZ }, 1.0, false)
    end)
end

-- =========================================================================
-- 7. CLIMB PRIORITY + COMPONENT HOOKS
-- ClimbHasPriority is the translated truth: the game's climb state is
-- raw data (drops to Falling mid-leap); this flag means "climbing, as
-- the mod understands it".
-- =========================================================================

-- Level-set while in climb mode; held while a hug leap is in flight;
-- otherwise a short watchdog releases it. The watchdog is the safety net
-- for exit paths not explicitly enumerated (e.g. stamina-out detach) --
-- a latched priority would otherwise permanently disable jump.lua.
local function UpdateClimbPriority(pawn, cmc, isClimbing)
    local shouldTakePriority = false

    if isClimbing then
        shouldTakePriority = true
    elseif climbJumpState ~= nil and climbJumpState.mode == "hug" then
        shouldTakePriority = true
    elseif M.InInitClimbState then
        -- The ascent writes its own gravity and squares its own yaw. Without
        -- the gate jump.lua's velocity bands reshape the arc frame by frame
        -- and its jump-cut can chop the launch by CutMultiplier, which made
        -- the flight time -- and therefore the latch -- depend on when the
        -- player happened to let go of the jump key.
        shouldTakePriority = true
    elseif CommonState.ClimbHasPriority then
        dbg("climb priority released (watchdog)")
    end

    if shouldTakePriority and not CommonState.ClimbHasPriority then
        pcall(function() cmc.bUseControllerDesiredRotation = false end)
        -- While on or at a wall this file (or the component) owns yaw. Left
        -- on, OrientRotationToMovement spins the character toward the stick
        -- every frame -- exactly the "rotates away right before the latch"
        -- report. The prior value is kept, not assumed, so a game that has
        -- its own reason to run with it off does not get it forced back on.
        -- Saved on the FIRST take only. GroundCheck, EndClimbJumpState and
        -- BeginHopAway all clear ClimbHasPriority directly, so a re-take can
        -- happen while our own `false` is still in place -- saving it again
        -- there would record our write as the original and restore that.
        pcall(function()
            if savedOrientToMovement == nil then
                savedOrientToMovement = cmc.bOrientRotationToMovement
            end
            cmc.bOrientRotationToMovement = false
        end)
        CommonState.ClimbHasPriority = true
    elseif not shouldTakePriority then
        pcall(function() cmc.bUseControllerDesiredRotation = true end)
        if savedOrientToMovement ~= nil then
            local restore = savedOrientToMovement
            savedOrientToMovement = nil
            pcall(function() cmc.bOrientRotationToMovement = restore end)
        end
        CommonState.ClimbHasPriority = false
    end
end

local function IsOurComponent(Context)
    local obj = nil
    pcall(function() obj = Context:get() end)
    if obj == nil or compName == nil then return false end
    local name = nil
    pcall(function() name = obj:GetFullName() end)
    return name == compName
end

local function NoOp() end

-- Class-level BP function hooks: register once per session (the class
-- object persists across respawns; re-registering would double-fire).
-- Instance-filtered in the callbacks. pcall-guarded registration logs
-- whether each function name actually exists on the class.
local function RegisterComponentHooks()
    if hooksRegistered or comp == nil then return end

    local clsPath = nil
    -- GetClass():GetFullName() on a live component: same pattern that
    -- safely identified ABP_Player_C. (The known-crash case was
    -- GetClass() on the holster's placeholder UObject, not this.)
    pcall(function() clsPath = comp:GetClass():GetFullName() end)
    if type(clsPath) ~= "string" then
        dbg("hook reg: component class path unreadable -- skipped")
        return
    end
    clsPath = clsPath:match("(%S+)$")   -- strip "BlueprintGeneratedClass "

    -- Vault-to-top: advisory clear (UpdateClimbPriority re-asserts while
    -- still in 6/5 during the vault curve, which is fine -- jump.lua has
    -- no business during a scripted vault). Registered pre-hook.
    local okTop, errTop = pcall(function()
        RegisterHook(clsPath .. ":ClimbUpAtTopEvent", function(Context)
            if not IsOurComponent(Context) then return end
            CommonState.ClimbHasPriority = false
            dbg("ClimbUpAtTopEvent fired -- priority released")
        end)
    end)
    ddbg("hook ClimbUpAtTopEvent: %s",
        okTop and "registered" or ("FAILED: " .. tostring(errTop)))

    -- Ground contact: the return value only exists post-execution, so
    -- NoOp pre-slot + post callback (established pattern). Return value
    -- expected as the final vararg; logged raw on change for first-run
    -- characterization.
    local okGnd, errGnd = pcall(function()
        RegisterHook(clsPath .. ":GroundCheck", NoOp, function(Context, ...)
            if not IsOurComponent(Context) then return end
            local args = { ... }
            local ret = nil
            if #args > 0 then
                pcall(function() ret = args[#args]:get() end)
            end
            if ret ~= lastGroundCheck then
                lastGroundCheck = ret
                dbg("GroundCheck -> %s", tostring(ret))
            end
            if ret == true and CommonState.ClimbHasPriority then
                CommonState.ClimbHasPriority = false
                dbg("GroundCheck true -- priority released")
            end
        end)
    end)
    ddbg("hook GroundCheck: %s",
        okGnd and "registered" or ("FAILED: " .. tostring(errGnd)))

    -- DIAGNOSTIC ONLY -- changes no behaviour.
    --
    -- ReceiveTick is UActorComponent's BlueprintImplementableEvent "Tick".
    -- It is only a hookable UFunction-with-script if this Blueprint actually
    -- implements an Event Tick node; if the climb logic lives in native
    -- UPalClimbingComponent::TickComponent then there is nothing here to
    -- hook at all, because a C++ virtual never crosses ProcessEvent.
    -- Registering against the BP class path (never the /Script/Engine base,
    -- which would fire for every component in the world) answers that.
    local okTick, errTick = pcall(function()
        RegisterHook(clsPath .. ":ReceiveTick",
            -- PRE: the only point in the frame that is provably ahead of the
            -- component's own logic. Measured: component tick before our
            -- controller tick on 240/240 frames, so this is where a
            -- suppression has to be written to matter this frame.
            function(Context)
                if not IsOurComponent(Context) then return end
                Diag.compTickHookAlive  = true
                Diag.compTickedBeforeUs = true
                Diag.compTicks          = Diag.compTicks + 1
                Diag.grabWasClimbingPre = ReadOpt(comp, "IsClimbing") == true
                ApplyClimbSuppression()
            end,
            -- POST: did the component decide to grab inside this call? A
            -- false->true flip across the pre/post boundary proves the grab
            -- happens AFTER the BP tick and can therefore be pre-empted from
            -- the pre-hook. Zero flips would mean the decision lives in
            -- native TickComponent ahead of ReceiveTick, and suppressing from
            -- here is still a frame late.
            function(Context)
                if not IsOurComponent(Context) then return end
                local nowClimbing = ReadOpt(comp, "IsClimbing") == true
                if nowClimbing and not Diag.grabWasClimbingPre then
                    Diag.grabInsideTick = Diag.grabInsideTick + 1
                    if Diag.grabInsideTick <= 3 then
                        ddbg("GRAB WINDOW: component went IsClimbing "
                            .. "false->true INSIDE its own BP tick (#%d) -- "
                            .. "a pre-hook suppression lands before it",
                            Diag.grabInsideTick)
                    end
                end
            end)
    end)
    ddbg("hook ReceiveTick: %s -- if FAILED, the component's tick is native "
        .. "and the grab decision cannot be pre-empted this way",
        okTick and "registered" or ("FAILED: " .. tostring(errTick)))

    -- CanClimbingStart: the component's own "may a climb begin" predicate,
    -- and the surgical alternative to holding CanClimbing off across an
    -- entire approach. Post-hook because a return value only exists after
    -- execution -- NoOp pre-slot, same shape GroundCheck uses.
    --
    -- This pass LOGS the call shape and only vetoes when Diag.CANSTART_VETO_ENABLED
    -- is set, because "the last vararg is the return value" is an assumption
    -- about this function's signature, not a fact. argc is logged so the shape
    -- can be read off a session before anything relies on it.
    local okStart, errStart = pcall(function()
        RegisterHook(clsPath .. ":CanClimbingStart", NoOp, function(Context, ...)
            if not IsOurComponent(Context) then return end
            Diag.canStartFires = Diag.canStartFires + 1

            local args = { ... }
            local argc = #args
            local ret  = nil
            if argc > 0 then
                pcall(function() ret = args[argc]:get() end)
            end

            -- Veto only while the guard actually wants this wall. Outside
            -- that, the component's own answer stands untouched.
            local vetoed = false
            if Diag.CANSTART_VETO_ENABLED and wantClimbSuppressed and argc > 0 then
                vetoed = pcall(function() args[argc]:set(false) end)
                if vetoed then Diag.canStartVetoes = Diag.canStartVetoes + 1 end
            end

            if Diag.canStartLogged < Diag.CANSTART_LOG_MAX then
                Diag.canStartLogged = Diag.canStartLogged + 1
                ddbg("CanClimbingStart #%d: argc=%d ret=%s (%s) "
                    .. "wantSuppressed=%s vetoed=%s",
                    Diag.canStartFires, argc, tostring(ret), type(ret),
                    tostring(wantClimbSuppressed), tostring(vetoed))
            end
        end)
    end)
    ddbg("hook CanClimbingStart: %s  (veto %s)",
        okStart and "registered" or ("FAILED: " .. tostring(errStart)),
        Diag.CANSTART_VETO_ENABLED and "ARMED" or "observing only")

    -- One-shot dump of the component's own BP functions. GroundCheck and
    -- ClimbUpAtTopEvent were found by hand; if one of the others IS the grab
    -- decision, pre-hooking that is far more surgical than a tick hook and
    -- would let the suppression be conditional instead of held across a
    -- whole approach.
    -- Dumping the class's functions answered what the component exposes, so
    -- this is OFF by default now: the answer is recorded in the notes above
    -- and re-running it costs a startup hitch for nothing.
    --
    -- It is also where a crash-on-load came from. The first version walked
    -- the SuperStruct chain with only a `parent ~= nil` guard. Past
    -- /Script/CoreUObject.Object, GetSuperStruct returns a NON-NIL but
    -- INVALID wrapper (it printed as "nil" because GetFullName gave nothing),
    -- and dereferencing that took a native access violation. pcall does not
    -- protect against those -- FindClimbingComponent says exactly this a few
    -- hundred lines up, and every dereference has to be IsValid()-checked
    -- individually. So: IsLive() before every single dereference, and the
    -- walk stops the moment a link fails to validate.
    if DEBUG_DUMP_FUNCTIONS then
        local function DumpFunctions(cls, label)
            if not IsLive(cls) then
                ddbg("  [%s] not a live object -- skipped", label)
                return false
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
                        ddbg("  [%s] fn: %s", label, tostring(n))
                    end
                end)
            end)
            ddbg("  [%s] ForEachFunction: callable=%s visited=%d named=%d",
                label, tostring(okEach), seen, named)
            return okEach
        end

        pcall(function()
            ddbg("---- functions on %s ----", clsPath)
            local cls = comp:GetClass()
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
                    ddbg("  -- super[%d]: unreadable, stopping walk", depth)
                    break
                end
                ddbg("  -- super[%d]: %s", depth, pname)
                DumpFunctions(parent, "super" .. depth)

                local nxt = nil
                pcall(function() nxt = parent:GetSuperStruct() end)
                if not IsLive(nxt) then break end
                parent = nxt
                depth = depth + 1
            end
            ddbg("---- end functions ----")
        end)
    end

    hooksRegistered = true
end

-- =========================================================================
-- 8. LIFECYCLE
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    comp, compName = FindClimbingComponent(pawn)
    lastFallVz     = 0
    prevModeWasClimb  = false
    prevWallFwd    = { X = 1, Y = 0 }
    slidingDownWall        = false
    slideV         = 0
    savedClimbMax  = nil
    climbJumpState             = nil
    M.InClimbJump  = false
    CommonState.ClimbHasPriority = false   -- belt; main.lua's Reset is braces
    prevFlagIs, prevFlagCan, prevFlagEnding = nil, nil, nil
    lastGroundCheck = nil
    KSL            = nil
    walkableFloorZ = ReadOpt(cmc, "WalkableFloorZ") or WALKABLE_FLOOR_Z_FALLBACK
    initClimbState     = nil
    M.InInitClimbState = false
    prevClimbZ     = nil
    wantClimbSuppressed = false   -- fresh component, fresh flags
    climbSuppressionHeld = false
    approachGuardArmed  = false
    guardLostFrames     = 0
    guardArmedTime      = 0
    guardCooldown       = 0
    guardGiveUps        = 0
    Diag.compTickedBeforeUs  = false
    Diag.tickOrderBefore, Diag.tickOrderAfter, Diag.tickOrderSamples = 0, 0, 0
    Diag.compTicks           = 0
    Diag.grabWasClimbingPre  = false
    Diag.grabInsideTick      = 0
    Diag.teleportLastLoc     = nil
    Diag.teleportReports     = 0
    savedOrientToMovement = nil
    Diag.canStartFires, Diag.canStartVetoes, Diag.canStartLogged = 0, 0, 0
    ReleaseAllMoveInput(pawn)

    pcall(function()
      capsuleRadius = pawn.CapsuleComponent.CapsuleRadius
    end)
    pcall(function()
      capsuleHalfHeight = pawn.CapsuleComponent.CapsuleHalfHeight
    end)

    -- Rays must leave from the cylindrical section of the capsule, where
    -- `Distance - radius` is the true perpendicular gap. Past that they exit
    -- through an end cap and read short.
    probeFanOffset = math.max(0, math.min(
        PROBE_FAN_HEIGHT_FRAC * capsuleHalfHeight,
        capsuleHalfHeight - capsuleRadius - PROBE_FAN_HEIGHT_PAD))

    if comp == nil then
        ddbg("climbing component NOT FOUND")
    else
        ddbg("component: %s  ClimbMaxSpeed=%s  fwdRay=%s",
            compName, tostring(ReadOpt(cmc, "ClimbMaxSpeed")),
            tostring(ReadOpt(comp, "Const_ForwardRayLength")))
        -- Everything the reach figures are guesses ABOUT. Read these off a
        -- real session before tying any tuning value to them, and turn on
        -- DEBUG_DRAW to confirm the rays match what is printed here.
        ddbg("geom: capsuleR=%.1f halfH=%.1f fanOffset=%.1f | attachGap=%.1f "
            .. "guardGap=%.1f hopGap=%.1f",
            capsuleRadius, capsuleHalfHeight, probeFanOffset,
            ATTACH_MAX_GAP, InitClimb.GUARD_GAP, InitClimb.HOP_GAP)
        ddbg("component props: fwdRay=%s rayChannel=%s (UNVERIFIED units/origin)",
            tostring(ReadOpt(comp, "Const_ForwardRayLength")),
            tostring(ReadOpt(comp, "Const_RayChannel")))
        CharacterizeTraceStruct(pawn)
        RegisterComponentHooks()
    end
end

-- FIX B: remember fall speed only while falling; grounded clears it so a
-- stale hard-fall value cannot arm a slide on a later gentle entry.
local function CacheFallSpeed(mode, cmc)
    if mode == 3 then
        lastFallVz = cmc.Velocity.Z
    else
        lastFallVz = 0
    end
end


local function LogComponentFlagEdges(mode, custom)
    if not DEBUG then return end
    local palgame_isClimbing     = ReadOpt(comp, "IsClimbing")
    local palgame_canClimb    = ReadOpt(comp, "CanClimbing")
    local palgame_isEndingClimb = ReadOpt(comp, "IsEnding")
    if palgame_isClimbing ~= prevFlagIs or palgame_canClimb ~= prevFlagCan or palgame_isEndingClimb ~= prevFlagEnding then
        dbg("flags: isClimbing=%s canClimb=%s endingClimb=%s (mode %d/%d)",
            tostring(palgame_isClimbing), tostring(palgame_canClimb), tostring(palgame_isEndingClimb), mode, custom)
        prevFlagIs, prevFlagCan, prevFlagEnding = palgame_isClimbing, palgame_canClimb, palgame_isEndingClimb
    end
end

-- Cache the climb frame for next tick's detach classification.
local function CacheClimbFrame(pawn, cmc, inClimb, isClimbingAtTop)
    if inClimb then
        -- Facing first: the input decomposition below needs THIS frame's
        -- wall facing, not the previous frame's.
        local faceDir = WallFwd(pawn)
        if faceDir ~= nil then
            prevWallFwd = faceDir
        end

        -- {X , Y, Z} where Z is the vertical direction 
        local stickAlongWall, stickUpward = Input.GetStick()
        prevClimbInputAlongWall = stickAlongWall
        prevClimbInputUpward    = stickUpward
        prevClimbZ = GetZ(pawn)
    end
    prevModeWasClimb = inClimb
    prevAtTopAnimPlaying = isClimbingAtTop
end


-- Hub for starting a climb: detect the entry, then drive it to a latch.
local probeFrameCounter = 0

-- Jumping UP at a face, as opposed to merely being off the ground. This is
-- the whole condition for taking the wall away from the component: a
-- descending approach is left alone so the organic grab still fires and the
-- wall slide keeps its entry.
local function IsRisingAtWall(cmc)
    return cmc.MovementMode == 3 and cmc.Velocity.Z >= InitClimb.GUARD_VZ_MIN
end

-- Runs every frame of an approach, before any sequence exists, and holds the
-- component off from InitClimb.GUARD_GAP out -- further than it can reach --
-- so the race is won during the approach rather than lost before this file's
-- tick ever runs. Returns the wall once close enough to commit; nil otherwise.
--
-- ARMING is the conservative half: only a walk-in or a rise arms it, so a
-- plain fall into a face is left entirely to the component's organic grab
-- and the wall slide keeps its entry.
--
-- HOLDING is the permissive half, and it is what makes the guard work. A
-- jump at a wall arcs over long before the face is in range -- checking
-- "still rising" every frame drops the guard exactly when it is needed, and
-- the component takes the wall. Once armed it holds through the whole
-- approach, releasing only when the face is gone or the fall has become
-- fast enough that the wall slide is the move that should catch it.
-- (approachGuardArmed is declared with the rest of the state, above.)
local function ReleaseApproachGuard(pawn)
    approachGuardArmed = false
    guardArmedTime     = 0
    guardLostFrames    = 0
    SuppressGameClimb(pawn, false)
end

-- Hands the wall back to the game and stays out of the way briefly, so a
-- failed approach cannot immediately re-arm and re-suppress.
local function YieldWallToGame(pawn, reason, gap)
    if approachGuardArmed and guardGiveUps < GUARD_GIVEUP_LOG_MAX then
        guardGiveUps = guardGiveUps + 1
        ddbg("guard gave up (%s, lastGap=%s) -- wall handed back to the "
            .. "vanilla grab for %.2fs. Frequent lines here mean the commit "
            .. "conditions are too strict for the faces being walked into.",
            reason, gap and string.format("%.1f", gap) or "none",
            InitClimb.GUARD_COOLDOWN)
    end
    approachGuardArmed = false
    guardArmedTime     = 0
    guardCooldown      = InitClimb.GUARD_COOLDOWN
    SuppressGameClimb(pawn, false)
end

local function TickApproachGuard(dt, pawn, cmc, isWalking)
    local vz = 0
    pcall(function() vz = cmc.Velocity.Z end)

    if guardCooldown > 0 then
        guardCooldown = math.max(0, guardCooldown - dt)
        ReleaseApproachGuard(pawn)
        return nil
    end

    -- VZ_TRIGGER is the wall slide's own entry speed, so the two features
    -- hand off at exactly one boundary instead of contending for the frame.
    local fallingHardEnoughToSlide = (cmc.MovementMode == 3) and (vz <= VZ_TRIGGER)
    if fallingHardEnoughToSlide then
        ReleaseApproachGuard(pawn)
        return nil
    end

    local mayArm = isWalking or IsRisingAtWall(cmc)
    if not mayArm and not approachGuardArmed then
        ReleaseApproachGuard(pawn)
        return nil
    end

    -- Single centre ray for ARMING. This runs every frame the player moves
    -- toward any climbable face within guard range, and each trace costs
    -- three UE4SS log lines (see PROBE_FRAME_INTERVAL) -- a fan here would
    -- be ~540 lines/sec just walking around.
    local wall, why = WallInMovementPath(pawn, cmc, InitClimb.GUARD_GAP, false)

    -- Every give-up in a real session came through here, never through the
    -- timeout: the guard armed and then the single centre ray stopped seeing
    -- the face. That ray is blind to anything recessed at capsule-centre
    -- height, and the fan was only ever reached AFTER it found something --
    -- so a lost face never got the second look that would have recovered it.
    if wall == nil and approachGuardArmed and why ~= "no input held" then
        wall = WallInMovementPath(pawn, cmc, InitClimb.GUARD_GAP, true)
        if wall ~= nil then why = nil end
    end

    if wall == nil then
        if not approachGuardArmed then
            ReleaseApproachGuard(pawn)
            return nil
        end

        -- Releasing the stick is not a failure to converge, it is the
        -- absence of a request. Taking the give-up cooldown here was the
        -- ground-entry regression: a momentary dip below the input floor
        -- locked our own entry out for 0.8s, and 7 of 8 give-ups in a
        -- session came through this path. Release, and stay ready to re-arm
        -- the instant input returns.
        if why == "no input held" then
            ReleaseApproachGuard(pawn)
            return nil
        end

        guardLostFrames = guardLostFrames + 1
        if guardLostFrames < InitClimb.GUARD_LOST_TICKS then return nil end
        YieldWallToGame(pawn, why or "probe lost the face", nil)
        return nil
    end
    guardLostFrames = 0

    approachGuardArmed = true
    guardArmedTime     = guardArmedTime + dt
    SuppressGameClimb(pawn, true)

    -- A walk-in commits close, where it reads as intent rather than as
    -- brushing past. An airborne approach commits as soon as the hop can
    -- still land before contact.
    local commitGap = isWalking and InitClimb.MAX_GAP or InitClimb.HOP_GAP

    -- Close in: re-probe with the vertical fan before deciding. The single
    -- centre ray is blind to a face recessed at waist height but present at
    -- chest or shin height, and committing on that reading is the difference
    -- between latching and walking into the wall doing nothing.
    if wall.gap <= commitGap * InitClimb.FAN_NEAR_MULT then
        local fanned = WallInMovementPath(pawn, cmc, InitClimb.GUARD_GAP, true)
        if fanned ~= nil and fanned.gap < wall.gap then wall = fanned end
    end

    local closeEnough = wall.gap <= commitGap
    fdbg("guard: gap=%.1f vz=%.0f walk=%s armed=%.2fs commit=%s",
        wall.gap, vz, tostring(isWalking), guardArmedTime, tostring(closeEnough))

    if closeEnough then
        guardArmedTime = 0
        return wall
    end

    -- Held the vanilla grab off long enough without converging: give the
    -- wall back rather than leave the player unable to climb it at all.
    if guardArmedTime >= InitClimb.GUARD_TIMEOUT then
        YieldWallToGame(pawn, "no commit before timeout", wall.gap)
    end
    return nil
end

local function TickInitClimbStart(dt, pawn, cmc, isWalking, isClimbing, isAtTop)
    -- An ascent already in flight is driven to an exit before anything else,
    -- and every exit runs through EndInitClimb. Reaching climb mode by some
    -- other route -- the game latching organically, a vault, a scripted
    -- state -- would otherwise strand the sequence with the move-input hold
    -- and the glider still suppressed, since the caller's gate would stop
    -- dispatching here the moment isClimbing went true.
    if M.InInitClimbState then
        if isClimbing or isAtTop then
            EndInitClimb(pawn, cmc, "climb reached outside the sequence")
            return
        end
        fdbg("driveinit: air=%.3f launched=%s mode=%d tries=%d",
            initClimbState.airTime, tostring(initClimbState.hasLaunched),
            cmc.MovementMode, initClimbState.tries)
        DriveInitClimb(dt, pawn, cmc)
        return
    end

    -- Rate limit ONLY the probe. PROBE_FRAME_INTERVAL = 1 reproduces the
    -- original exactly; the counter is primed whenever a start is
    -- impossible so the first eligible frame always probes.
    local canStartFromHere = isWalking or IsRisingAtWall(cmc) or approachGuardArmed
    if guardCooldown > 0 then
        -- Vanilla owns the wall for a moment after a failed approach.
        guardCooldown = math.max(0, guardCooldown - dt)
        ReleaseApproachGuard(pawn)
        return
    end
    if not canStartFromHere then
        -- Nothing to guard: make sure nothing is left suppressed. This covers
        -- every plain fall, including the one the wall slide needs.
        ReleaseApproachGuard(pawn)
        probeFrameCounter = PROBE_FRAME_INTERVAL
        return
    end
    probeFrameCounter = probeFrameCounter + 1
    if probeFrameCounter < PROBE_FRAME_INTERVAL then return end
    probeFrameCounter = 0

    local wallAhead = TickApproachGuard(dt, pawn, cmc, isWalking)
    if wallAhead == nil then return end

    -- The guard hands off to whichever launch fits where the pawn is: on the
    -- ground the game's own jump carries the animation, in the air the hop
    -- has to be written directly.
    if isWalking then
        StartClimbFromGround(pawn, cmc, wallAhead)
    else
        StartClimbFromAir(pawn, cmc, wallAhead)
    end
end


-- Reads the flag the component's tick hook sets, then clears it, so each
-- controller tick learns whether the component ran ahead of it. Sampled for
-- a few seconds and then silent. A split result is the finding: it means the
-- order is not stable, and no probe range tuned from this file can fix that.
local function SampleTickOrder()
    if not DEBUG_DISCOVERY then return end
    if not Diag.compTickHookAlive then return end
    if Diag.tickOrderSamples >= Diag.TICK_ORDER_SAMPLE_MAX then return end

    Diag.tickOrderSamples = Diag.tickOrderSamples + 1
    if Diag.compTickedBeforeUs then
        Diag.tickOrderBefore = Diag.tickOrderBefore + 1
    else
        Diag.tickOrderAfter = Diag.tickOrderAfter + 1
    end
    Diag.compTickedBeforeUs = false

    if Diag.tickOrderSamples == Diag.TICK_ORDER_SAMPLE_MAX then
        ddbg("TICK ORDER over %d of our ticks: component ran BEFORE us %d, "
            .. "AFTER (or not at all) %d. A split means the order is not "
            .. "stable, which on its own is enough to make the same wall "
            .. "behave differently between runs.",
            Diag.tickOrderSamples, Diag.tickOrderBefore, Diag.tickOrderAfter)

        -- The engine ticks a component exactly once per frame, so the
        -- component's count is a reference clock for real frames. Our tick
        -- comes from a hook on the controller's ReceiveTick, and a session
        -- log showed that function registered TWICE. If both registrations
        -- are live, every subsystem runs twice per frame on the same dt --
        -- and every duration in this file (airTime, LOCK_TIME, retry
        -- intervals) then advances at double real time, which no amount of
        -- tuning would explain away.
        local ratio = Diag.compTicks > 0 and (Diag.tickOrderSamples / Diag.compTicks) or 0
        ddbg("TICK RATIO: our ticks %d vs component ticks %d = %.2fx. "
            .. "~1.0 is healthy; ~2.0 means the controller tick hook is "
            .. "double-registered and every duration here runs at 2x.",
            Diag.tickOrderSamples, Diag.compTicks, ratio)

        ddbg("CanClimbingStart: %d calls in that window, %d vetoed. "
            .. "0 calls means the organic grab does not route through it "
            .. "and the veto cannot work; calls only while approaching a "
            .. "face means it is the right lever.",
            Diag.canStartFires, Diag.canStartVetoes)
    end
end

-- Reports any single-frame displacement large enough to be a teleport,
-- naming the state this file was in when it happened.
local function WatchForTeleport(pawn, cmc)
    local here = GetLoc(pawn)
    if here == nil then Diag.teleportLastLoc = nil return end

    local last = Diag.teleportLastLoc
    Diag.teleportLastLoc = here
    if last == nil then return end

    local dx, dy, dz = here.X - last.X, here.Y - last.Y, here.Z - last.Z
    local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    if moved < Diag.TELEPORT_JUMP_UU then return end
    if Diag.teleportReports >= Diag.TELEPORT_LOG_MAX then return end
    Diag.teleportReports = Diag.teleportReports + 1

    ddbg("TELEPORT: moved %.0fuu in one frame (%.0f,%.0f,%.0f) -> "
        .. "(%.0f,%.0f,%.0f) | initClimb=%s phase=%s climbJump=%s "
        .. "suppressed=%s mode=%d/%d",
        moved, last.X, last.Y, last.Z, here.X, here.Y, here.Z,
        tostring(M.InInitClimbState),
        initClimbState and tostring(initClimbState.phase) or "-",
        climbJumpState and tostring(climbJumpState.mode) or "-",
        tostring(wantClimbSuppressed),
        cmc.MovementMode, ReadOpt(cmc, "CustomMovementMode") or 0)
end

function M.OnTick(dt, pawn, cmc)
    SampleTickOrder()
    WatchForTeleport(pawn, cmc)
    VisualiseClimbChecks(pawn, cmc)

    local movementMode    = cmc.MovementMode
    local customMovementMode  = ReadOpt(cmc, "CustomMovementMode") or 0
    local isClimbing = (movementMode == 6 and customMovementMode == 5)
    local isWalking = (movementMode == 1 or movementMode == 2 or (movementMode == 6 and customMovementMode == 2))
    local climbingComponent = ReadOpt(pawn, "BP_PalClimbingComponent")
    local isClimbingAtTop = false
    if IsLive(climbingComponent) then
        isClimbingAtTop = ReadOpt(climbingComponent, "UpAtTopMode") == true
    end

    -- Tick climb starts. A sequence in flight always gets dispatched so it
    -- can reach an exit; only NEW entries are gated. The vault-to-top curve
    -- is a scripted animation that already owns the pawn, so a re-entry
    -- during it would fight it.
    local canEnterInitClimb = not isClimbing and not M.InClimbJump and not isClimbingAtTop
    if M.InInitClimbState or canEnterInitClimb then
        TickInitClimbStart(dt, pawn, cmc, isWalking, isClimbing, isClimbingAtTop)
    end

    -- Guard against early animation cancels
    if isClimbingAtTop then
        DisableForAtTopAnim(pawn, cmc)
    end
    if prevAtTopAnimPlaying and not isClimbingAtTop then
        EnableForAtTopAnim(pawn, cmc)
    end

    customMovementMode  = ReadOpt(cmc, "CustomMovementMode") or 0
    CacheFallSpeed(cmc.MovementMode, cmc)
    LogComponentFlagEdges(cmc.MovementMode, customMovementMode)

    -- Tick climb jumps
    if DidClimbJumpStart(cmc, movementMode) and not isClimbingAtTop then
        StartClimbJump(pawn, cmc)
    end
    TickClimbJump(dt, pawn, cmc, movementMode, isClimbing)
    
   -- Fix vanilla climbing input values
    if isClimbing then
        ApplyRawClimbInput(pawn, cmc)
    end

    -- Refresh values that may have changes from the start of the frame
    movementMode    = cmc.MovementMode
    customMovementMode = ReadOpt(cmc, "CustomMovementMode") or 0
    isClimbing = (movementMode == 6 and customMovementMode == 5)

    UpdateClimbPriority(pawn, cmc, isClimbing)
    UpdateWallSlide(dt, pawn, cmc, isClimbing)

    -- Cache values for next frame comparisons
    CacheClimbFrame(pawn, cmc, isClimbing, isClimbingAtTop)
end

return M
