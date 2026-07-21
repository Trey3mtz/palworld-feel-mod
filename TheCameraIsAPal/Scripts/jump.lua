-- =========================================================================
-- PalFeel subsystem: jump — velocity-gated gravity (finalized tuning)
-- Exhaustive velocity bands, deepest-first.
--
-- Signal model (settled during Phase 1, diagnostics removed):
--   jump start   : OnJumpDelegate BP binding on BP_PlayerBase_C. Fires
--                  exactly once per executed player jump, so no grounded
--                  guard is needed.
--   jump release : JumpKey.Poll() edge. Character:Jump / StopJumping and
--                  PalCMC:Jump do not cross ProcessEvent for the player,
--                  and pawn.bPressedJump is consumed before we can read
--                  it — polling is the only working release signal.
-- =========================================================================

local JumpVel                  = 900
local LaunchMultiplier         = 1.275
local TargetGravity            = 1.8
local TargetGravityExtreme     = 4
local VanillaGravity           = 2.6   -- original game vanilla is 1.6
local LowGravity               = 1.4
local NegativeThreshold        = -150  -- uu/s
local NegativeThresholdExtreme = -450
local PositiveThreshold        = 20
local CutMultiplier            = 0.69   -- rising Vz scale applied on release (nice)


local M = { name = "jump" }
local JumpKey = require("jumpkey")

local jumpInitiated = false
local launchInitiated = false

local DEBUG_JUMP = false

local function jdbg(fmt, ...)
    if DEBUG_JUMP then print(string.format("[PalFeel:jump] " .. fmt .. "\n", ...)) end
end

-- Declaration only: main.lua reads M.Hooks at load and registers each
-- entry via RegisterHook in its retry loop.
M.Hooks = {
    -- PRIMARY jump-start signal.
    { name = "OnJumpDelegate (BP bound)",
        path = "/Game/Pal/Blueprint/Character/Base/BP_PlayerBase.BP_PlayerBase_C:"
        .. "BndEvt__BP_PlayerBase_CharacterMovement_K2Node_ComponentBoundEvent_2_OnJumpDelegate__DelegateSignature",
        callback = function(Context)
            jumpInitiated = true
            jdbg("jump initiated (delegate)")
        end },    
        { name = "JumpSpotLarge:OnLaunchCharacter",
            path = "/Game/Pal/Blueprint/LevelObject/BP_LevelGimmickJumpSpotLarge.BP_LevelGimmickJumpSpotLarge_C:OnLaunchCharacter",
            post = function()
                jdbg("LAUNCH JUMP BIG")
                launchInitiated = true
            end },
        { name = "JumpSpotSmall:OnLaunchCharacter",
            path = "/Game/Pal/Blueprint/LevelObject/BP_LevelGimmickJumpSpotSmall.BP_LevelGimmickJumpSpotSmall_C:OnLaunchCharacter",
            post = function()
                jdbg("LAUNCH JUMP SMALL")
                launchInitiated = true
            end },
}
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    cmc.GravityScale  = VanillaGravity   -- clean slate on (re)spawn
    cmc.JumpZVelocity = JumpVel
    jumpInitiated     = false            -- a respawn mid-air must not inherit it
end

function M.OnTick(dt, pawn, cmc)
    local _, _, released = JumpKey.Poll()   -- unconditional, first

    local mode = cmc.MovementMode
    if mode ~= 3 then       -- NOT Move_FALLING
        cmc.GravityScale = VanillaGravity
        return
    end

    local vz = cmc.Velocity.Z

    -- Adjust launch pads against higher gravity
    if launchInitiated then
        cmc.Velocity.Z = cmc.Velocity.Z * LaunchMultiplier
        launchInitiated = false
    end

    -- Jump cut: only for jumps we started from the ground.
    if jumpInitiated and released and vz > 0 then
        cmc.Velocity.Z = vz * CutMultiplier
        vz = cmc.Velocity.Z
        jdbg("jump cut -> Vz=%.0f", vz)
    end

    -- Distinct velocity sections, checked deepest-first so exactly one
    -- band applies per tick (gravity is a pure function of Vz).
    if vz <= NegativeThresholdExtreme then
        cmc.GravityScale = TargetGravityExtreme   -- full falling acceleration
    elseif vz <= NegativeThreshold then
        cmc.GravityScale = TargetGravity          -- build-up after the peak
    elseif vz < PositiveThreshold then
        cmc.GravityScale = LowGravity             -- peak twilight
    else
        cmc.GravityScale = VanillaGravity         -- fast rise
    end

    if vz < 0 and jumpInitiated then
        jumpInitiated = false
    end
end


NotifyOnNewObject("/Script/Pal.PalLevelGimmickJumpSpot", function(obj)
    print("[PalFeel] jumpspot: " .. obj:GetFullName() .. "\n")
end)

return M
