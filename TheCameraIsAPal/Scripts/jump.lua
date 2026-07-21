-- =========================================================================
-- PalFeel subsystem: jump — velocity-gated gravity (finalized tuning)
-- Exhaustive velocity bands, deepest-first (intent-corrected per review).
-- =========================================================================

local JumpVel                  = 900
local TargetGravity            = 1.8
local TargetGravityExtreme     = 4
local VanillaGravity           = 2.6   -- original game vanilla is 1.6
local LowGravity               = 1.4
local NegativeThreshold        = -150  -- uu/s
local NegativeThresholdExtreme = -450
local PositiveThreshold        = 20

local M = { name = "jump" }
local JumpKey = require("jumpkey")
local myCmcName, myCmc = nil, nil
local myPawnName = nil
local jumpInitiated = false
local prevPressed = nil
local DEBUG_JUMP = true

local function jdbg(fmt, ...)
    if DEBUG_JUMP then print(string.format("[PalFeel:jump] " .. fmt .. "\n", ...)) end
end

local otherFires = 0

-- Declaration only: main.lua reads M.Hooks at load and registers each
-- entry via RegisterHook in its retry loop.
M.Hooks = {
    -- PRIMARY jump-start signal: the delegate binding proven to fire
    -- exactly once per executed player jump. Fires only when a jump
    -- actually happened, so "a jump I initiated" needs no grounded guard.
    { name = "OnJumpDelegate (BP bound)",
        path = "/Game/Pal/Blueprint/Character/Base/BP_PlayerBase.BP_PlayerBase_C:"
        .. "BndEvt__BP_PlayerBase_CharacterMovement_K2Node_ComponentBoundEvent_2_OnJumpDelegate__DelegateSignature",
        callback = function(Context)
            jumpInitiated = true
            jdbg("jump initiated (delegate)")
        end },

    -- DIAGNOSTIC ONLY: PalCMC:Jump registered but never fired for the
    -- player (input path appears to call the C++ method directly). This
    -- distinguishes "live for Pals but not the player" from "never
    -- invoked via ProcessEvent at all". Remove once answered.
    { name = "PalCMC:Jump (diagnostic)",
        path = "/Script/Pal.PalCharacterMovementComponent:Jump",
        callback = function(Context)
            local ok, obj = pcall(function() return Context:get() end)
            if not ok or not obj then return end
            local okN, n = pcall(function() return obj:GetFullName() end)
            if okN and myCmcName and n == myCmcName then
                jdbg("[diag] PalCMC:Jump fired for the PLAYER")
            elseif otherFires < 5 then
                otherFires = otherFires + 1
                jdbg("[diag] PalCMC:Jump fired for other: %s%s",
                    okN and n or "?", otherFires == 5 and " (further suppressed)" or "")
            end
        end },

    -- DIAGNOSTIC: release-path test. bPressedJump transitions prove the
    -- input binding drives Jump()/StopJumping(); a release binding fires
    -- unconditionally, so if StopJumping crosses ProcessEvent it marks
    -- your release even during a real jump (where the flag is consumed).
    -- Both firing => event-driven release solved. Both silent => pure
    -- C++ binding; fallback is polling IsInputKeyDown. Remove once known.
    { name = "Character:StopJumping (diagnostic)",
        path = "/Script/Engine.Character:StopJumping",
        callback = function(Context)
            local ok, obj = pcall(function() return Context:get() end)
            if ok and obj and myPawnName then
                local okN, n = pcall(function() return obj:GetFullName() end)
                if okN and n ~= myPawnName then return end
            end
            local vz = "?"
            if myCmc and myCmc:IsValid() then
                local okV, v = pcall(function() return myCmc.Velocity.Z end)
                if okV then vz = string.format("%.0f", v) end
            end
            jdbg("[diag] StopJumping fired (Vz=%s)", vz)
        end },
    { name = "Character:Jump (diagnostic)",
        path = "/Script/Engine.Character:Jump",
        callback = function(Context)
            local ok, obj = pcall(function() return Context:get() end)
            if ok and obj and myPawnName then
                local okN, n = pcall(function() return obj:GetFullName() end)
                if okN and n ~= myPawnName then return end
            end
            jdbg("[diag] Character:Jump fired")
        end },
}
-- =========================================================================

function M.OnPlayerCached(pawn, cmc)
    cmc.GravityScale  = VanillaGravity   -- clean slate on (re)spawn
    cmc.JumpZVelocity = JumpVel
    myCmcName, myCmc = cmc:GetFullName(), cmc   -- for the hook filters
    myPawnName = pawn:GetFullName()
end



function M.OnTick(dt, pawn, cmc)
    local down, pressed, released = JumpKey.Poll()  -- unconditional, first
    -- 'released' is your jump-cut trigger; gate it with your own
    -- jumpInitiated flag as planned.
    local mode = cmc.MovementMode

    if mode ~= 3 then       -- NOT Move_FALLING
        cmc.GravityScale = VanillaGravity
        return
    end

    local vz = cmc.Velocity.Z

    -- DIAGNOSTIC: does bPressedJump track your button? Edge-logged only.
    -- If these lines follow your press/release, your release signal is
    -- prevPressed == true and pressed == false. Remove once answered.
    local okP, pressed = pcall(function() return pawn.bPressedJump end)
    if okP and pressed ~= prevPressed then
        jdbg("[diag] bPressedJump -> %s (Vz=%.0f)", tostring(pressed), vz)
        prevPressed = pressed
    end



    -- (jump-cut logic goes here: jumpInitiated is true only for jumps you
    --  started from the ground; clear it after applying a cut.)
    if jumpInitiated and released and vz > 0 then
        cmc.Velocity.Z = (cmc.Velocity.Z * 0.6)
        vz = cmc.Velocity.Z
        jdbg("[diag] jump cut!")
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

    if cmc.Velocity.Z < 0 and jumpInitiated then
        jumpInitiated = false
    end
end

return M