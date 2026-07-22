-- =========================================================================
-- TheCameraIsAPal subsystem: holsterframe — BOTW framing while holstered
--
-- Holster truth is read from the game itself (main.lua derives
-- sig.holstered from LoadoutSelectorComponent.currentItemSlotIndex < 0),
-- which is the exact property the HelpfulHolster mod uses as its own
-- ground truth — the two mods cannot disagree, and this also reacts to
-- holstering done through the native weapon palette.
--
-- Vanilla SocketOffset is (0,0,0): the camera is already centered at the
-- offset level, so the BOTW effect here is pull-back plus a slight raise.
-- The rig supplies the ease in both directions; this subsystem only states
-- the target while the state holds and goes silent when it does not.
-- =========================================================================

local Rig = require("rig")

local CFG = {
    ARM_SCALE = 1.20,                    -- 400 -> 480 uu pulled back
    SOCK      = { x = 0, y = 0, z = 15 },-- slight raise for the BOTW framing
    FOV_ADD   = 0,                       -- deg; try -2 for a mild tele feel
}

local M = { name = "holsterframe" }

function M.OnCached(ctx) end

function M.OnTick(dt, ctx, sig)
    if sig.holstered then
        Rig.Add{ armScale = CFG.ARM_SCALE, sock = CFG.SOCK, fovAdd = CFG.FOV_ADD }
    end
end

return M
