-- =========================================================================
-- Test harness for climb.lua
--
-- Stubs the UE4SS / Unreal surface so the climbing state machine can be run
-- headless: movement modes, traces, the climbing component, and a coarse
-- model of UCharacterMovementComponent.
--
-- It is a MODEL, not the game. It is good for comparing behaviour across
-- approach angles, wall shapes and component reach, and for proving that a
-- specific failure mode is or is not present. It is not a substitute for
-- playing the game, and every number it produces should be read as "this
-- logic does X under these assumptions", not "the mod feels like X".
--
-- Lives in the repo rather than a scratch directory because a container
-- reset once destroyed the entire suite, and a regression net that does not
-- survive the session is not a net.
--
--   lua5.4 tests/run_tests.lua
-- =========================================================================

local M = {}

-- ---------------- vector helpers ----------------
local function dot3(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function norm3(v)
    local l = math.sqrt(dot3(v, v))
    return { X = v.X / l, Y = v.Y / l, Z = v.Z / l }
end
local function Vec(x, y, z) return { X = x, Y = y, Z = z } end
M.Vec = Vec

-- ---------------- the wall ----------------
-- Plane: dot(n, p) = offset(z). `n` points AWAY from the wall, toward the
-- approaching player. `bumpAmp` makes the offset vary with height, modelling
-- an uneven face; `topZ` ends the wall, giving it a lip to find.
function M.NewWall(normal, offset, bumpAmp, bumpPeriod)
    return {
        n = norm3(normal), offset = offset,
        bumpAmp = bumpAmp or 0, bumpPeriod = bumpPeriod or 120,
    }
end

local function WallOffsetAt(wall, z)
    if wall.bumpAmp == 0 then return wall.offset end
    return wall.offset + wall.bumpAmp * math.sin(z / wall.bumpPeriod * math.pi * 2)
end

local function RayHit(wall, origin, dir, rayLen)
    if wall.topZ ~= nil and origin.Z > wall.topZ then return nil end
    local nd = dot3(wall.n, dir)
    if nd >= -1e-6 then return nil end                 -- parallel / backface
    local t = (WallOffsetAt(wall, origin.Z) - dot3(wall.n, origin)) / nd
    if t < 0 or t > rayLen then return nil end
    -- `halfWidth` bounds the face sideways, so a post or a thin edge can be
    -- modelled: a hit outside it lands on nothing.
    if wall.halfWidth ~= nil then
        local hx, hy = origin.X + dir.X * t, origin.Y + dir.Y * t
        local lateral = -wall.n.Y * hx + wall.n.X * hy
        if math.abs(lateral) > wall.halfWidth then return nil end
    end
    return t
end

-- ---------------- mock objects ----------------
local function MakeController()
    return {
        ignoreMove = 0, resets = 0,
        IsValid = function() return true end,
        SetIgnoreMoveInput = function(self, b)
            if b then self.ignoreMove = self.ignoreMove + 1
            else self.ignoreMove = math.max(0, self.ignoreMove - 1) end
        end,
        -- Present so a caller that uses it can be caught doing so: it assigns
        -- the CDO default rather than decrementing, releasing holds other
        -- systems are carrying.
        ResetIgnoreMoveInput = function(self)
            self.ignoreMove = 0; self.resets = self.resets + 1
        end,
        GetInputAnalogKeyState = function() return 0 end,
    }
end

function M.MakeWorld(wall, opts)
    local w = { wall = wall, t = 0 }
    local ctrl = MakeController()

    local climbComp = {
        CanClimbing = true, IsClimbing = false, IsEnding = false,
        UpAtTopMode = false,
        vaultEvents = 0,
        ClimbUpAtTopEvent = function(self) self.vaultEvents = self.vaultEvents + 1 end,
        grappleCalls = 0,
        TryClimbAfterGrappling = function(self) self.grappleCalls = self.grappleCalls + 1 end,
        Const_RayChannel = 0,
        Const_ForwardRayLength = opts.forwardRay or 80,
        IsValid = function() return true end,
        GetFullName = function() return "BP_PalClimbingComponent_C /Game/C.C:Comp" end,
        GetClass = function()
            return {
                GetFullName = function() return "BlueprintGeneratedClass /Game/C.C_C" end,
                IsValid = function() return true end,
                ForEachFunction = function() end,
                GetSuperStruct = function() return nil end,
            }
        end,
    }

    local cmc = {
        Velocity = Vec(0, 0, 0), Acceleration = Vec(0, 0, 0),
        MovementMode = 1, CustomMovementMode = 0,
        GravityScale = 2.6, JumpZVelocity = 1050,
        MaxAcceleration = 2048, WalkableFloorZ = 0.6428, ClimbMaxSpeed = 300,
        IsValid = function() return true end,
        SetMovementMode = function(self, m, c)
            self.MovementMode = m; self.CustomMovementMode = c or 0
        end,
        ConsumeInputVector = function() end,
        SetGliderDisbleFlag = function() end,
    }

    local pawn = {
        pos = Vec(opts.startX or 0, opts.startY or 0, opts.startZ or 0),
        yaw = 0, JumpMaxCount = 1,
        CharacterMovement = cmc,
        BP_PalClimbingComponent = climbComp,
        BP_GliderComponent = { GliderDisableFlag = 0, IsValid = function() return true end },
        CapsuleComponent = { CapsuleRadius = 34, CapsuleHalfHeight = 90,
                             IsValid = function() return true end },
        BlueprintCreatedComponents = { climbComp },
        IsValid = function() return true end,
        GetFullName = function() return "BP_PlayerBase_C /Game/P.P:Pawn" end,
        GetController = function() return ctrl end,
        K2_GetActorLocation = function(self) return Vec(self.pos.X, self.pos.Y, self.pos.Z) end,
        K2_GetActorRotation = function(self) return { Pitch = 0, Yaw = self.yaw, Roll = 0 } end,
        K2_SetActorRotation = function(self, rot) self.yaw = rot.Yaw end,
        GetActorForwardVector = function(self)
            local r = math.rad(self.yaw)
            return Vec(math.cos(r), math.sin(r), 0)
        end,
        K2_AddActorWorldOffset = function(self, off)
            self.pos.X = self.pos.X + off.X
            self.pos.Y = self.pos.Y + off.Y
            self.pos.Z = self.pos.Z + off.Z
        end,
        RequestJump = function() w.jumpPressed = true end,
    }

    w.pawn, w.cmc, w.ctrl, w.climbComp = pawn, cmc, ctrl, climbComp
    return w
end

-- ---------------- UE4SS globals ----------------
local activeWorld = nil
function M.setWorld(w) activeWorld = w end

function FName(s) return s end
function RegisterHook() return 1, 2 end
function ExecuteInGameThread(f) f() end
function NotifyOnNewObject() end

local KSL = {
    IsValid = function() return true end,
    LineTraceSingle = function(self, actor, startV, endV, channel, complex,
                               ignore, drawType, hitResult)
        local w = activeWorld
        local d = Vec(endV.X - startV.X, endV.Y - startV.Y, endV.Z - startV.Z)
        local len = math.sqrt(dot3(d, d))
        if len < 1e-6 then return false end
        local dir = { X = d.X / len, Y = d.Y / len, Z = d.Z / len }
        local t = RayHit(w.wall, startV, dir, len)
        if t == nil then return false end
        hitResult.Distance = t
        hitResult.ImpactNormal = Vec(w.wall.n.X, w.wall.n.Y, w.wall.n.Z)
        hitResult.ImpactPoint = Vec(startV.X + dir.X * t, startV.Y + dir.Y * t,
                                    startV.Z + dir.Z * t)
        return true
    end,
    -- Upright capsule sweep. Against the wall: the volume only meets the
    -- face if the face exists somewhere in the capsule's vertical span, and
    -- the sweep stops one radius before the line would. Straight down: the
    -- floor at z=0 is found when the capsule's bottom reaches it.
    CapsuleTraceSingle = function(self, actor, startV, endV, radius, halfH,
                                  channel, complex, ignore, drawType, hitResult)
        local w = activeWorld
        local d = Vec(endV.X - startV.X, endV.Y - startV.Y, endV.Z - startV.Z)
        local len = math.sqrt(dot3(d, d))
        if len < 1e-6 then return false end
        local dir = { X = d.X / len, Y = d.Y / len, Z = d.Z / len }

        if dir.Z < -0.9 then
            local travel = (startV.Z - halfH) - 0
            if travel < 0 or travel > len then return false end
            hitResult.Distance = travel
            hitResult.ImpactNormal = Vec(0, 0, 1)
            hitResult.ImpactPoint = Vec(startV.X, startV.Y, 0)
            return true
        end

        -- Does the face occupy any of the capsule's span?
        local zLo, zHi = startV.Z - halfH, startV.Z + halfH
        local wall = w.wall
        if wall.topZ ~= nil and zLo > wall.topZ then return false end
        local probeZ = math.min(zHi, wall.topZ or zHi)
        local o = Vec(startV.X, startV.Y, probeZ)
        local t = RayHit(wall, o, dir, len + radius)
        if t == nil or t - radius > len then return false end
        hitResult.Distance = math.max(0, t - radius)
        hitResult.ImpactNormal = Vec(wall.n.X, wall.n.Y, wall.n.Z)
        hitResult.ImpactPoint = Vec(startV.X + dir.X * t, startV.Y + dir.Y * t, probeZ)
        return true
    end,
    -- A sphere sweep against a plane contacts one radius before the line
    -- would, so Distance is the line distance minus the radius.
    SphereTraceSingle = function(self, actor, startV, endV, radius, channel,
                                 complex, ignore, drawType, hitResult)
        local w = activeWorld
        local d = Vec(endV.X - startV.X, endV.Y - startV.Y, endV.Z - startV.Z)
        local len = math.sqrt(dot3(d, d))
        if len < 1e-6 then return false end
        local dir = { X = d.X / len, Y = d.Y / len, Z = d.Z / len }
        local t = RayHit(w.wall, startV, dir, len + radius)
        if t == nil or t - radius > len then return false end
        hitResult.Distance = math.max(0, t - radius)
        hitResult.ImpactNormal = Vec(w.wall.n.X, w.wall.n.Y, w.wall.n.Z)
        hitResult.ImpactPoint = Vec(startV.X + dir.X * t, startV.Y + dir.Y * t,
                                    startV.Z + dir.Z * t)
        return true
    end,
}
-- Only the Kismet default object exists here; function-object lookups (the
-- signature dump) come back nil, as they would for a name that is not there.
function StaticFindObject(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return KSL end
    return nil
end

package.preload["UEHelpers"] = function()
    return {
        GetPlayer = function() return activeWorld and activeWorld.pawn end,
        GetPlayerController = function() return activeWorld and activeWorld.ctrl end,
    }
end

-- ---------------- physics ----------------
-- Coarse UCharacterMovementComponent: gravity, integration, depenetration,
-- and the base game's own climb grab competing for the same wall.
function M.Step(w, dt, inputDir)
    local pawn, cmc, wall = w.pawn, w.cmc, w.wall

    cmc.Acceleration.X = inputDir.X * cmc.MaxAcceleration
    cmc.Acceleration.Y = inputDir.Y * cmc.MaxAcceleration

    if w.jumpPressed then
        w.jumpPressed = false
        cmc.MovementMode = 3
        cmc.Velocity.Z = math.max(cmc.Velocity.Z, cmc.JumpZVelocity)
    end

    -- The vanilla grab, running BETWEEN the mod's ticks. This is the race the
    -- guard exists to win: in a real session the component's tick ran before
    -- the controller tick on 240 of 240 frames.
    if w.organicGrab and w.climbComp.CanClimbing
       and not (cmc.MovementMode == 6 and cmc.CustomMovementMode == 5) then
        local o = pawn:K2_GetActorLocation()
        local vlen = math.sqrt(cmc.Velocity.X^2 + cmc.Velocity.Y^2)
        local dir
        if vlen > 1e-3 then
            dir = Vec(cmc.Velocity.X / vlen, cmc.Velocity.Y / vlen, 0)
        else
            local r = math.rad(pawn.yaw); dir = Vec(math.cos(r), math.sin(r), 0)
        end
        if RayHit(wall, o, dir, w.climbComp.Const_ForwardRayLength) ~= nil then
            cmc.MovementMode, cmc.CustomMovementMode = 6, 5
            w.climbComp.IsClimbing = true
            w.organicGrabbedAt = w.organicGrabbedAt or w.t
        end
    end

    if cmc.MovementMode == 6 and cmc.CustomMovementMode == 5 then
        -- The component drops the climb when its own forward ray misses.
        local o = pawn:K2_GetActorLocation()
        local r = math.rad(pawn.yaw)
        if RayHit(wall, o, Vec(math.cos(r), math.sin(r), 0),
                  w.climbComp.Const_ForwardRayLength) == nil then
            cmc.MovementMode, cmc.CustomMovementMode = 3, 0
            w.climbComp.IsClimbing = false
            w.detachedAt = w.t
        end
        w.t = w.t + dt
        return
    end

    if cmc.MovementMode == 3 then
        cmc.Velocity.Z = cmc.Velocity.Z - 980 * cmc.GravityScale * dt
        if w.ctrl.ignoreMove == 0 then
            local ac = 0.35
            cmc.Velocity.X = cmc.Velocity.X + inputDir.X * cmc.MaxAcceleration * ac * dt
            cmc.Velocity.Y = cmc.Velocity.Y + inputDir.Y * cmc.MaxAcceleration * ac * dt
        end
    else
        local target = (w.ctrl.ignoreMove ~= 0) and 0 or 550
        cmc.Velocity.X = cmc.Velocity.X + (inputDir.X * target - cmc.Velocity.X) * math.min(1, 8 * dt)
        cmc.Velocity.Y = cmc.Velocity.Y + (inputDir.Y * target - cmc.Velocity.Y) * math.min(1, 8 * dt)
        cmc.Velocity.Z = 0
    end

    pawn.pos.X = pawn.pos.X + cmc.Velocity.X * dt
    pawn.pos.Y = pawn.pos.Y + cmc.Velocity.Y * dt
    pawn.pos.Z = pawn.pos.Z + cmc.Velocity.Z * dt

    if pawn.pos.Z <= 0 and cmc.MovementMode == 3 and cmc.Velocity.Z < 0 then
        pawn.pos.Z = 0; cmc.Velocity.Z = 0; cmc.MovementMode = 1
    end

    -- `standoff` models anything blocking the capsule further out than the
    -- face itself -- rubble, a plinth, a root -- so the reachable gap
    -- plateaus above the mod's commit distance.
    local r = 34 + (w.standoff or 0)
    local pen = (WallOffsetAt(wall, pawn.pos.Z) + r) - dot3(wall.n, pawn.pos)
    if pen > 0 then
        pawn.pos.X = pawn.pos.X + wall.n.X * pen
        pawn.pos.Y = pawn.pos.Y + wall.n.Y * pen
        local vn = cmc.Velocity.X * wall.n.X + cmc.Velocity.Y * wall.n.Y
        if vn < 0 then
            cmc.Velocity.X = cmc.Velocity.X - wall.n.X * vn
            cmc.Velocity.Y = cmc.Velocity.Y - wall.n.Y * vn
        end
    end

    w.t = w.t + dt
end

function M.CurrentGap(w)
    local p = w.pawn.pos
    return dot3(w.wall.n, p) - WallOffsetAt(w.wall, p.Z) - 34
end

-- ---------------- module loading ----------------
-- Fresh module table per run so no state carries between scenarios.
function M.LoadClimb(path)
    for _, m in ipairs({ "climb", "commonstate", "input", "easingfunctions", "jumpkey" }) do
        package.loaded[m] = nil
    end
    return dofile(path or "./TheCameraIsAPal/Scripts/climb.lua")
end

-- ---------------- scenario runner ----------------
function M.Run(Climb, wall, opts)
    local w = M.MakeWorld(wall, opts)
    M.setWorld(w)
    w.t = 0
    w.organicGrab = opts.organicGrab
    w.standoff    = opts.standoff
    Climb.OnPlayerCached(w.pawn, w.cmc)

    if opts.entry == "air" then
        w.cmc.MovementMode = 3
        w.cmc.Velocity.Z = opts.entryVz or 300
        w.cmc.Velocity.X = -w.wall.n.X * (opts.approachSpeed or 500)
        w.cmc.Velocity.Y = -w.wall.n.Y * (opts.approachSpeed or 500)
    end

    local dt = 1 / 60
    local latchedAt, gapAtAttach, peakGap = nil, nil, 0
    local wasAirborne, attempts, wasInInit = false, 0, false

    for _ = 1, math.floor((opts.duration or 3.0) / dt) do
        local ok, err = pcall(Climb.OnTick, dt, w.pawn, w.cmc)
        if not ok then return { outcome = "error", detail = tostring(err) } end

        local inInit = Climb.InInitClimbState == true
        if inInit and not wasInInit then attempts = attempts + 1 end
        wasInInit = inInit
        if inInit then w.modSequenceRan = true end

        -- Real collision leaves a little outward momentum: depenetration, and
        -- approach velocity redirected by convexity. Applied on the frame that
        -- leaves the ground, which is where it actually happens.
        if opts.outwardKick and w.cmc.MovementMode == 3 and not wasAirborne then
            wasAirborne = true
            w.cmc.Velocity.X = w.cmc.Velocity.X + w.wall.n.X * opts.outwardKick
            w.cmc.Velocity.Y = w.cmc.Velocity.Y + w.wall.n.Y * opts.outwardKick
        end

        M.Step(w, dt, opts.inputDir)

        local climbing = (w.cmc.MovementMode == 6 and w.cmc.CustomMovementMode == 5)
        if w.cmc.MovementMode == 3 then
            local g = M.CurrentGap(w)
            if g > peakGap then peakGap = g end
        end
        if climbing and latchedAt == nil then
            latchedAt = w.t; gapAtAttach = M.CurrentGap(w)
        end
        if latchedAt and not climbing then
            return { outcome = "dropped", heldFor = w.t - latchedAt,
                     gapAtAttach = gapAtAttach, peakGap = peakGap,
                     latchedAt = latchedAt, attempts = attempts,
                     modSequenceRan = w.modSequenceRan == true,
                     organicGrabbedAt = w.organicGrabbedAt, world = w }
        end
    end

    local base = { peakGap = peakGap, attempts = attempts,
                   modSequenceRan = w.modSequenceRan == true,
                   organicGrabbedAt = w.organicGrabbedAt, world = w }
    if latchedAt then
        base.outcome = "latched"; base.latchedAt = latchedAt
        base.gapAtAttach = gapAtAttach; base.heldFor = w.t - latchedAt
    else
        base.outcome = "none"
    end
    return base
end

return M
