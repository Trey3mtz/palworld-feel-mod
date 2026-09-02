-- =========================================================================
-- Regression suite for climb.lua.
--
--   lua5.4 tests/run_tests.lua          (from the repo root)
--
-- Each test encodes a failure that actually happened in a play session, so a
-- passing run means those specific regressions are absent -- not that the
-- system feels good. Feel is decided in the game.
-- =========================================================================

package.path = "./tests/?.lua;./TheCameraIsAPal/Scripts/?.lua;" .. package.path
local H = dofile("./tests/harness.lua")

local CLIMB = "./TheCameraIsAPal/Scripts/climb.lua"

local failures, checks = 0, 0
local function Check(name, cond, detail)
    checks = checks + 1
    if cond then
        print(string.format("  PASS  %s", name))
    else
        failures = failures + 1
        print(string.format("  FAIL  %s   (%s)", name, detail or ""))
    end
end

local function Wall(tiltDeg, bumpAmp)
    local tr = math.rad(tiltDeg or 0)
    return H.NewWall({ X = -math.cos(tr), Y = 0, Z = math.sin(tr) },
                     -200, bumpAmp or 0, 130)
end

local function Run(opts)
    local wall = opts.wall or Wall(0, 0)
    if opts.topZ then wall.topZ = opts.topZ end
    local a = math.rad(opts.angle or 0)
    local merged = {
        startX = 60, startY = 0,
        startZ = (opts.entry == "air") and 100 or 0,
        inputDir = { X = math.cos(a), Y = math.sin(a), Z = 0 },
        duration = 3.0, forwardRay = opts.reach or 80,
    }
    for k, v in pairs(opts) do
        if k ~= "wall" and k ~= "angle" and k ~= "topZ" and k ~= "reach" then
            merged[k] = v
        end
    end
    return H.Run(H.LoadClimb(CLIMB), wall, merged)
end

local ANGLES  = { 0, 15, 30 }
local SHAPES  = { { "flat", 0, 0 }, { "wavy", 14, 0 }, { "leanback", 0, 10 } }
local REACHES = { 60, 80, 100 }

-- =========================================================================
print("\n[1] The mod must win the wall from the vanilla grab")
-- The component grabs from its own ray, between our ticks. If it wins, our
-- sequence never runs and the mini hop is never seen.
-- =========================================================================
-- The slow-rise case starts closer. Arming needs "rising AND in range" by
-- design (a plain fall must reach the vanilla grab), and at 60uu/s the rise
-- lasts two frames -- so the wall has to already be inside GUARD_GAP when
-- the jump peaks, or there is nothing for this file to do. Starting it
-- outside the guard range would test the hand-off to vanilla, not the arm.
for _, case in ipairs({ { "airborne, rising", "air", 300, 60 },
                        { "airborne, slow rise", "air", 60, 110 },
                        { "walk-in", "ground", nil, 60 } }) do
    local ran, total = 0, 0
    for _, s in ipairs(SHAPES) do
        for _, ang in ipairs(ANGLES) do
            for _, reach in ipairs(REACHES) do
                local r = Run({ wall = Wall(s[3], s[2]), angle = ang,
                                entry = case[2], entryVz = case[3],
                                startX = case[4],
                                reach = reach, organicGrab = true,
                                approachSpeed = 550 })
                total = total + 1
                if r.modSequenceRan then ran = ran + 1 end
            end
        end
    end
    Check(string.format("%s: our sequence runs (%d/%d)", case[1], ran, total),
          ran >= total * 0.75, string.format("only %d/%d", ran, total))
end

-- =========================================================================
print("\n[2] A descending approach must be left to the vanilla grab")
-- The wall slide needs that entry. Arming on a plain fall would steal it.
-- Starts high so the fall never lands and turns into a walk-in.
-- =========================================================================
for _, vz in ipairs({ -100, -400, -650, -1200 }) do
    local intervened, total = 0, 0
    for _, ang in ipairs(ANGLES) do
        for _, reach in ipairs(REACHES) do
            local r = Run({ angle = ang, entry = "air", entryVz = vz,
                            reach = reach, organicGrab = true,
                            startZ = 4000, duration = 0.6, approachSpeed = 550 })
            total = total + 1
            if r.modSequenceRan then intervened = intervened + 1 end
        end
    end
    Check(string.format("falling at %d: mod stays out (%d/%d intervened)",
                        vz, intervened, total),
          intervened == 0, string.format("%d intervened", intervened))
end

-- =========================================================================
print("\n[3] Never worse than not running the mod")
-- The guard holds the vanilla grab off while closing. If our commit cannot
-- fire -- something stops the capsule short -- the wall must go back to the
-- game rather than leaving the player unable to climb at all.
-- =========================================================================
for _, standoff in ipairs({ 0, 25, 35, 45 }) do
    local r = Run({ entry = "ground", organicGrab = true,
                    standoff = standoff, duration = 4.0 })
    Check(string.format("standoff %d: player ends up climbing", standoff),
          r.outcome == "latched",
          string.format("outcome=%s (nobody took the wall)", tostring(r.outcome)))
end

-- =========================================================================
print("\n[4] Releasing the stick must not lock our own entry out")
-- "no input held" is the absence of a request, not a failure to converge.
-- Taking the give-up cooldown there cost ~0.8s of our own entry and was the
-- ground-entry reliability regression.
-- =========================================================================
-- Starts far enough out that the approach takes real time, so the blip lands
-- mid-approach rather than after the sequence has already finished.
do
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 0, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    w.organicGrab = true          -- vanilla is competing for this wall
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt = 1 / 60
    local toward = { X = 1, Y = 0, Z = 0 }
    local none   = { X = 0, Y = 0, Z = 0 }
    local modRan, latched = false, false

    for i = 1, 180 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if Climb.InInitClimbState then modRan = true end
        if w.cmc.MovementMode == 6 and w.cmc.CustomMovementMode == 5 then
            latched = true break
        end
        -- Three frames of released input while still closing on the face.
        H.Step(w, dt, (i >= 8 and i <= 10) and none or toward)
    end

    -- With the cooldown bug the blip surrendered the wall for 0.8s and the
    -- vanilla grab took it instead, so "did we climb" alone does not
    -- discriminate -- "did OUR entry run" does.
    Check("momentary input drop: still climbs", latched, "never latched")
    Check("momentary input drop: our entry still won the wall", modRan,
          "guard was locked out; vanilla took the wall")
end

-- =========================================================================
print("\n[5] A climb jump must not sail past a wall's top")
-- =========================================================================
for _, topZ in ipairs({ 60, 100, 140, 180 }) do
    local Climb = H.LoadClimb(CLIMB)
    local wall = Wall(0, 0); wall.topZ = topZ
    local w = H.MakeWorld(wall, { startX = 160, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt = 1 / 60
    w.cmc.MovementMode, w.cmc.CustomMovementMode = 6, 5
    pcall(Climb.OnTick, dt, w.pawn, w.cmc)          -- caches the climb frame
    w.cmc.MovementMode, w.cmc.CustomMovementMode = 3, 0
    w.cmc.Velocity.Z = 800

    local caught = false
    for _ = 1, 90 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if w.cmc.MovementMode == 6 and w.cmc.CustomMovementMode == 5 then
            caught = true break
        end
        w.cmc.Velocity.Z = w.cmc.Velocity.Z - 980 * (w.cmc.GravityScale or 2.6) * dt
        w.pawn.pos.Z = w.pawn.pos.Z + w.cmc.Velocity.Z * dt
        w.pawn.pos.X = w.pawn.pos.X + w.cmc.Velocity.X * dt
        if w.pawn.pos.Z > topZ + 120 then break end
    end
    Check(string.format("wall top at %d: leap catches the lip", topZ), caught,
          "sailed past")

    -- The vault event must NOT be invoked by hand: called outside the
    -- component's own state machine it runs against a stale destination and
    -- teleported the player across the map into the ocean.
    Check(string.format("wall top at %d: no hand-fired vault", topZ),
          w.climbComp.vaultEvents == 0,
          string.format("%d vault calls", w.climbComp.vaultEvents))
end

-- =========================================================================
print("\n[6] Every exit releases what it took")
-- A stranded move-input hold or glider suppression disables the player for
-- the rest of the session.
-- =========================================================================
local function DriveTo(perturb)
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    w.gliderDisabled = false
    w.cmc.SetGliderDisbleFlag = function(_, _, v) w.gliderDisabled = v end
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt, dir = 1 / 60, { X = 1, Y = 0, Z = 0 }
    for i = 1, 220 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if perturb then perturb(w, Climb, i) end
        H.Step(w, dt, dir)
    end
    return w
end

do
    local w = DriveTo(nil)
    Check("normal latch: move input released", w.ctrl.ignoreMove == 0,
          "count=" .. w.ctrl.ignoreMove)
    Check("normal latch: glider re-enabled", w.gliderDisabled == false)
    Check("ResetIgnoreMoveInput never used", w.ctrl.resets == 0,
          "resets=" .. w.ctrl.resets)

    local w2 = DriveTo(function(world, Climb)
        if Climb.InInitClimbState and world.pawn.pos.Z > 60 then
            world.cmc.MovementMode, world.cmc.CustomMovementMode = 6, 5
        end
    end)
    Check("climb reached outside the sequence: input released",
          w2.ctrl.ignoreMove == 0, "count=" .. w2.ctrl.ignoreMove)
    Check("climb reached outside the sequence: glider re-enabled",
          w2.gliderDisabled == false)
end

-- =========================================================================
print("\n[7] Something in the way is not a wall")
-- The visualiser showed the approach reading a rock as a face. A wall has to
-- be there at eye level AND wide enough; a step or a post is neither.
-- Vanilla grab is off so the only way to end up climbing is our sequence,
-- which makes "did we run" the whole question.
-- =========================================================================
do
    -- Control: a real wall is still detected.
    local r = Run({ entry = "ground", duration = 2.0 })
    Check("control: full wall is detected", r.modSequenceRan, "sequence never ran")

    -- Low obstacle: present at waist, absent at eye level.
    -- Harness capsule half height is 90, eye probe sits at 0.70 * 90 = 63.
    local low = Wall(0, 0); low.topZ = 40
    r = H.Run(H.LoadClimb(CLIMB), low, { startX = 60, startZ = 0,
        inputDir = { X = 1, Y = 0, Z = 0 }, duration = 2.0, forwardRay = 80 })
    Check("low obstacle: NOT treated as a wall", not r.modSequenceRan,
          "committed to climbing a step")

    -- Narrow post: present dead ahead, absent 40uu to either side.
    local post = Wall(0, 0); post.halfWidth = 20
    r = H.Run(H.LoadClimb(CLIMB), post, { startX = 60, startZ = 0,
        inputDir = { X = 1, Y = 0, Z = 0 }, duration = 2.0, forwardRay = 80 })
    Check("narrow post: NOT treated as a wall", not r.modSequenceRan,
          "committed to climbing a post")

    -- Wide enough: a face just wider than the width probes still counts.
    local wide = Wall(0, 0); wide.halfWidth = 60
    r = H.Run(H.LoadClimb(CLIMB), wide, { startX = 60, startZ = 0,
        inputDir = { X = 1, Y = 0, Z = 0 }, duration = 2.0, forwardRay = 80 })
    Check("face wider than the probes: detected", r.modSequenceRan,
          "rejected a wall that is wide enough")
end

-- =========================================================================
print("\n[7b] The capsule check is the check")
-- A rock below step height must not even be a candidate: the capsule starts
-- above MaxStepHeight so it is outside the swept volume entirely. And the
-- self-test must pass on a build whose capsule traces report, so that the
-- capsule path -- not the line fallback -- is what the suite exercised.
-- =========================================================================
do
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    Climb.OnPlayerCached(w.pawn, w.cmc)
    pcall(Climb.OnTick, 1 / 60, w.pawn, w.cmc)          -- grounded: runs the self-test
    local src = io.open(CLIMB):read("a")
    Check("capsule is the default shape",
          src:find('WallDetect.SHAPE%s*=%s*"capsule"') ~= nil, "default is not capsule")

    -- Step-height rock: top 40uu above the feet (feet at -90 in the harness).
    local rock = Wall(0, 0); rock.topZ = -50
    local r = H.Run(H.LoadClimb(CLIMB), rock, { startX = 60, startZ = 0,
        inputDir = { X = 1, Y = 0, Z = 0 }, duration = 2.0, forwardRay = 80 })
    Check("rock below step height: not a candidate at all", not r.modSequenceRan,
          "capsule was stopped by something the player walks over")
end

-- =========================================================================
print("\n[7c] A forced latch the component drops is re-forced while the face is there")
-- The in-game failure: hop, a fraction of a second on the wall, drop, hop.
-- Modelled as a component that kicks the pawn back to falling on the frame
-- after each forced attach, twice, then accepts. The watch must re-force it
-- each time and the player must end up climbing, not on the ground.
-- =========================================================================
do
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt, dir = 1 / 60, { X = 1, Y = 0, Z = 0 }
    local dropsLeft, wasClimbing, reattaches, latched = 2, false, 0, false
    for _ = 1, 240 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        local climbing = (w.cmc.MovementMode == 6 and w.cmc.CustomMovementMode == 5)
        if climbing and not wasClimbing then
            reattaches = reattaches + 1
            if dropsLeft > 0 then
                -- The component rejects the state it did not set up.
                dropsLeft = dropsLeft - 1
                w.cmc.MovementMode, w.cmc.CustomMovementMode = 3, 0
                w.climbComp.IsClimbing = false
                climbing = false
            end
        end
        wasClimbing = climbing
        if climbing then latched = true break end
        H.Step(w, dt, dir)
    end
    Check("component drops twice: watch re-forces and the latch holds", latched,
          string.format("never held (attaches seen: %d)", reattaches))
    Check("re-forced at least twice", reattaches >= 3,
          string.format("attaches seen: %d", reattaches))
    Check("no guessed call to the component entry (signature unknown here)",
          w.climbComp.grappleCalls == 0,
          string.format("called %d times without a verified signature", w.climbComp.grappleCalls))
end

-- =========================================================================
print("\n[8] Yaw is ours while we own the wall, and the player's again after")
-- OrientRotationToMovement left on spins the character toward the stick every
-- frame -- the "rotates away right before the latch" report. Restoring it
-- wrongly is the "no longer rotates after climbing" report.
-- =========================================================================
do
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    w.cmc.bOrientRotationToMovement = true
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt, dir = 1 / 60, { X = 1, Y = 0, Z = 0 }
    local offDuringSequence, sawSequence = false, false
    for _ = 1, 120 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if Climb.InInitClimbState then
            sawSequence = true
            if w.cmc.bOrientRotationToMovement == false then offDuringSequence = true end
        end
        H.Step(w, dt, dir)
    end
    Check("orient-to-movement is off during the sequence",
          sawSequence and offDuringSequence,
          sawSequence and "still true mid-sequence" or "sequence never ran")

    w.cmc.MovementMode, w.cmc.CustomMovementMode = 1, 0
    w.cmc.Acceleration.X, w.cmc.Acceleration.Y = 0, 0
    for _ = 1, 5 do pcall(Climb.OnTick, dt, w.pawn, w.cmc); H.Step(w, dt, { X = 0, Y = 0, Z = 0 }) end
    Check("orient-to-movement restored after our own sequence",
          w.cmc.bOrientRotationToMovement == true,
          "left at " .. tostring(w.cmc.bOrientRotationToMovement))
end

-- The reported bug. The game grabs the wall itself and switches
-- OrientRotationToMovement off for its climb BEFORE we ever take priority.
-- Saving "the current value" at that moment saves the game's false and
-- restores false. Spawn is the only moment the original is certain.
do
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 160, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    w.cmc.bOrientRotationToMovement = true
    Climb.OnPlayerCached(w.pawn, w.cmc)                 -- spawn: true

    local dt = 1 / 60
    -- The game latches organically and, as its climb starts, turns it off.
    w.cmc.MovementMode, w.cmc.CustomMovementMode = 6, 5
    w.cmc.bOrientRotationToMovement = false
    w.cmc.Acceleration.X, w.cmc.Acceleration.Y = 0, 0
    for _ = 1, 10 do pcall(Climb.OnTick, dt, w.pawn, w.cmc) end   -- we take priority here

    -- The game ends its climb.
    w.cmc.MovementMode, w.cmc.CustomMovementMode = 1, 0
    for _ = 1, 5 do pcall(Climb.OnTick, dt, w.pawn, w.cmc); H.Step(w, dt, { X = 0, Y = 0, Z = 0 }) end
    Check("organic climb: orient-to-movement restored to the SPAWN value",
          w.cmc.bOrientRotationToMovement == true,
          "left at " .. tostring(w.cmc.bOrientRotationToMovement)
          .. " -- restored the game's false as if it were the original")
end

-- =========================================================================
print("\n[9] Sphere-sweep detection is a drop-in for line traces")
-- The reference pattern sweeps spheres. Kept opt-in until verified in-game,
-- but the gap arithmetic must already be right or turning it on would shift
-- every threshold by one radius.
-- =========================================================================
do
    local Climb = H.LoadClimb(CLIMB)
    -- Reach into the module's tuning through the same path a user would.
    local src = io.open(CLIMB):read("a")
    Check("PROBE_RADIUS defaults to line traces",
          src:find("WallDetect.PROBE_RADIUS%s*=%s*0") ~= nil, "default is not 0")

    -- Run the full suite of one scenario with spheres on, by patching the
    -- loaded module's table via a sentinel file.
    local tmp = "./tests/_climb_sphere.lua"
    local f = io.open(tmp, "w")
    f:write((src:gsub("WallDetect.PROBE_RADIUS%s*=%s*0", "WallDetect.PROBE_RADIUS = 15", 1)))
    f:close()
    local ClimbS = H.LoadClimb(tmp)
    os.remove(tmp)
    local r = H.Run(ClimbS, Wall(0, 0), { startX = 60, startZ = 0,
        inputDir = { X = 1, Y = 0, Z = 0 }, duration = 3.0, forwardRay = 80,
        organicGrab = true, approachSpeed = 550 })
    Check("radius 15: still detects and latches",
          r.outcome == "latched" and r.modSequenceRan,
          string.format("outcome=%s ran=%s", tostring(r.outcome), tostring(r.modSequenceRan)))
end

-- =========================================================================
print("\n[10] The guard hands off to the sequence and stays off afterwards")
-- The arm flag was never cleared at the hand-off, so after every sequence the
-- guard was still "armed" with no wall behind it. Two consequences, both seen
-- as noise or lockout in session logs: a failed hop chained straight into an
-- airborne one while falling (a plain fall is meant to be vanilla's), and a
-- climb exit ate a bogus "probe lost the face" give-up plus its 0.8s lockout.
-- =========================================================================
do
    -- A: the sequence fails mid-air because something holds the capsule off
    -- the face once airborne. The player then falls at the wall with the
    -- stick held. Falling is not an approach: no airborne re-entry.
    local Climb = H.LoadClimb(CLIMB)
    local w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local dt, dir = 1 / 60, { X = 1, Y = 0, Z = 0 }
    local wasInInit, airborneStarts, groundStarts = false, 0, 0
    for _ = 1, 240 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        local inInit = Climb.InInitClimbState == true
        if inInit and not wasInInit then
            if w.cmc.MovementMode == 3 then
                airborneStarts = airborneStarts + 1
            else
                groundStarts = groundStarts + 1
            end
        end
        wasInInit = inInit
        if w.cmc.MovementMode == 3 then w.standoff = 70 end
        H.Step(w, dt, dir)
    end
    Check("failed hop: the walk-in sequence ran", groundStarts >= 1, "never started")
    Check("failed hop: no airborne re-entry while falling", airborneStarts == 0,
          string.format("%d sequence(s) started mid-fall", airborneStarts))

    -- B: a climb exit. Latch through our own sequence, climb a moment, then
    -- the game ends the climb with the player dropping away from the face,
    -- stick still held toward it. Nothing is in reach, so an armed guard
    -- would "lose the face" and give up -- against a wall it never had.
    Climb = H.LoadClimb(CLIMB)
    w = H.MakeWorld(Wall(0, 0), { startX = 60, startZ = 0, forwardRay = 80 })
    H.setWorld(w)
    Climb.OnPlayerCached(w.pawn, w.cmc)

    local latched = false
    for _ = 1, 240 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if w.cmc.MovementMode == 6 and w.cmc.CustomMovementMode == 5 then
            latched = true break
        end
        H.Step(w, dt, dir)
    end
    for _ = 1, 10 do pcall(Climb.OnTick, dt, w.pawn, w.cmc); H.Step(w, dt, dir) end

    w.pawn.pos.X, w.pawn.pos.Z = -34, 100          -- 166uu off the face, in the air
    w.cmc.MovementMode, w.cmc.CustomMovementMode = 3, 0
    w.cmc.Velocity.X, w.cmc.Velocity.Y, w.cmc.Velocity.Z = 0, 0, 0
    w.climbComp.IsClimbing = false

    local realPrint, giveUps = print, {}
    print = function(s)
        if type(s) == "string" and s:find("guard gave up", 1, true) then giveUps[#giveUps + 1] = s end
    end
    local exitT, seqAt = w.t, nil
    for _ = 1, 120 do
        pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if Climb.InInitClimbState and seqAt == nil then seqAt = w.t - exitT end
        H.Step(w, dt, dir)
    end
    print = realPrint

    Check("climb exit: latched through our sequence first", latched, "never latched")
    Check("climb exit: no give-up against a wall the guard never had",
          #giveUps == 0, (giveUps[1] or ""):sub(1, 80))
    Check("climb exit: the next walk-in starts without the give-up lockout",
          seqAt ~= nil and seqAt < 0.75,
          string.format("next sequence at %s", seqAt and string.format("%.2fs", seqAt) or "never"))
end

-- =========================================================================
print(string.format("\n%d/%d checks passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
