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

local CommonState = require("commonstate")

local JumpVel                  = 1050
local LaunchMultiplier         = 1.27 -- This value perfectly counter's increased gravity back to vanilla launch feel
local TargetGravity            = 1.8
local TargetGravityExtreme     = 3.8
local VanillaGravity           = 2.6   -- original game vanilla is 1.6
local LowGravity               = 1.5
local NegativeThreshold        = -150  -- uu/s
local NegativeThresholdExtreme = -450
local PositiveThreshold        = 75
local CutMultiplier            = 0.65   -- rising Vz scale applied on release (nice)
local JumpCutOn                = true  -- Turns the feature for jump cutting on/off

local M = { name = "jump" }
local JumpKey = require("jumpkey")

local jumpInitiated = false
local DEBUG_PRINT = false

local function jdbg(fmt, ...)
    if DEBUG_PRINT then print(string.format("[PalFeel:jump] " .. fmt .. "\n", ...)) end
end

M.Hooks = {
    { name = "OnJumpDelegate (BP bound)",
        path = "/Game/Pal/Blueprint/Character/Base/BP_PlayerBase.BP_PlayerBase_C:"
        .. "BndEvt__BP_PlayerBase_CharacterMovement_K2Node_ComponentBoundEvent_2_OnJumpDelegate__DelegateSignature",
        callback = function(Context)
            jumpInitiated = true
            jdbg("jump initiated (delegate)")
        end }
}

M.Notifications = {
    { name = "JumpSpot",
        class = "/Script/Pal.PalLevelGimmickJumpSpot",
        callback = function(obj)
            -- Strict pointer validation before memory access
            if obj and obj:IsValid() then
                local v = obj.JumpZVelocity
                if v then
                    obj.JumpZVelocity = v * LaunchMultiplier
                    jdbg("jumpspot Z %.0f -> %.0f", v, obj.JumpZVelocity)
                end
            end
        end },
}
-- =========================================================================
function M.OnPlayerCached(pawn, cmc)
    if not cmc or not cmc:IsValid() then return end
    cmc.GravityScale  = VanillaGravity   
    cmc.JumpZVelocity = JumpVel
    jumpInitiated     = false            
end

function M.OnTick(dt, pawn, cmc)
    -- CRITICAL: Unshielded execution requires manual pointer validation
    if not cmc or not cmc:IsValid() then return end

    local down, pressed, released = JumpKey.Poll()   
    if CommonState.ClimbHasPriority then return end  

    local mode = cmc.MovementMode
    M.KeyDown     = down
    M.KeyPressed  = pressed
    M.KeyReleased = released
    
    if mode ~= 3 then       
        cmc.GravityScale = VanillaGravity
        return
    end

    local vz = cmc.Velocity.Z

    if JumpCutOn and jumpInitiated and released and vz > 0 then
        vz = vz * CutMultiplier
        cmc.Velocity.Z = vz
        jumpInitiated = false
        released = false
        jdbg("Jump CUT!")
    end

    if vz <= NegativeThresholdExtreme then
        cmc.GravityScale = TargetGravityExtreme   
    elseif vz <= NegativeThreshold then
        cmc.GravityScale = TargetGravity          
    elseif vz < PositiveThreshold then
        cmc.GravityScale = LowGravity             
    else
        cmc.GravityScale = TargetGravityExtreme   
    end

    if vz < -0.01 and jumpInitiated then
        jumpInitiated = false
    end
end

return M
