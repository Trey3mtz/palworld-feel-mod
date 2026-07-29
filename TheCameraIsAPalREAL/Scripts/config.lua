-- =========================================================================
-- TheCameraIsAPal: config — the single runtime-tunable data table
--
-- THIS FILE IS PURE DATA. No require(), no logic, no UObject access.
-- That is what makes it safe to re-read from disk while the game runs.
--
-- ITERATION LOOP:
--   1. edit a number below and save (game stays running)
--   2. press F10 in game
--   3. main.lua drops package.loaded["config"], re-requires this file, and
--      fans the fresh sub-tables out to every module's M.RefreshConfig
--
-- A syntax error here is caught, logged, and IGNORED — the previously good
-- config stays live and the game does not die. Fix and press F10 again.
--
-- Keys:  F10 reload config   F11 master on/off   F9 dump state
--
-- Sub-table names under `subsystems` MUST match each module's M.name.
-- =========================================================================

return {

-- ==== 1. logging =========================================================
-- `enabled=false` kills every log line in the mod, including the hot path.
-- Per-channel flags below only matter while enabled is true. Keep `rig` and
-- `signals` off unless you are actively debugging: they print at 1 Hz and
-- on every state transition respectively.
log = {
    enabled  = true,
    channels = {
        rig      = false,   -- 1 Hz channel win/stomp telemetry
        signals  = false,   -- probe's [E] transition spam
        framing  = true,
        ticksrc  = true,
    },
},

-- ==== 2. feature switches ================================================
-- Flip any of these and press F10. A disabled subsystem is skipped in the
-- dispatch loop entirely (no tick cost) and is told to release whatever it
-- was holding, so disabling is visually immediate and complete.
enabled = {
    framing  = true,
    sprintfx = true,
    fallfx   = true,
    probe    = false,   -- dev recon: [E] transition logging + vanilla dump
    xray     = false,   -- one-shot reflection dump; turn on to map Channel A
},

-- ==== 3. tick source =====================================================
-- Which UFunction drives our per-frame update. This is the frame-ordering
-- experiment: our writes land wherever this hook sits relative to the game's
-- own camera update, and that ordering is the whole jitter question.
--
--   controller_bp  BP_PalPlayerController_C:ReceiveTick        (original)
--   manager_bp     BP_PalPlayerCameraManager_C:ReceiveTick     (closer to eval)
--   manager_bp_upd PlayerCameraManager:BlueprintUpdateCamera   (inside eval)
--
-- Start on controller_bp (known-good). Try the others and watch the F9 dump:
-- a source that fires INSIDE camera evaluation should drive Channel C stomps
-- to ~0. If a source never fires, ticksource logs it and falls back.
tick = {
    source    = "controller_bp",
    fallback  = "controller_bp",
    telemetry = true,      -- log hook install/fire status
    dtClamp   = 0.1,       -- s; ignore absurd dt after a hitch or load screen
},

-- ==== 4. rig: write channels =============================================
-- Channel routing. See rig.lua's header for why these three exist.
--   "A" source params  — write what the game interpolates FROM. Uncontested,
--                        but latched: the game only re-reads the bank on a
--                        locomotion-state transition.
--   "B" shake pipeline — applied inside camera evaluation. Uncontested, but
--                        can only carry one-shot impulses with the game's own
--                        shake class; it cannot carry an arbitrary curve.
--   "C" output write   — TargetArmLength / SocketOffset / FieldOfView.
--                        Immediate, but the game writes these too during
--                        state interp / slide / glide. See contention below.
rig = {
    channels = {
        framing = "A+C",   -- bank for transitions, glide for immediate effect
        jitter  = "C",     -- B cannot carry a per-frame curve; see header
        fov     = "C",     -- no FOV source param found yet — run xray
        impulse = "B",
    },

    -- CONTENTION POLICY (this is the jitter fix).
    -- The old rig kept writing while the game was also writing, so the value
    -- alternated between ours and theirs every frame — that alternation IS
    -- the jitter (measured: it overwrote the game on 60/60 contested frames).
    -- Now the rig detects the game's write, hands the channel back, and
    -- watches. It returns only once the value has held still for
    -- `quietFrames` — proof the game has finished its interpolation, which a
    -- fixed countdown cannot know. `authorityRate` blends our contribution
    -- out and back in so neither handover is a visible pop.
    contention = {
        quietFrames   = 6,      -- stable frames before we take the channel back
        releaseRate   = 30.0,   -- 1/s fade-OUT of our contribution (fast: get
                                --      out of the way in ~9 frames)
        resumeRate    = 6.0,    -- 1/s fade-IN when the game lets go (gentle)
        -- "is this still the value we wrote?" — tolerant.
        epsArm        = 0.5,    -- uu
        epsFov        = 0.25,   -- deg
        epsSock       = 0.5,    -- uu, max per-axis
        -- "has the game stopped moving it at all?" — strict, and deliberately
        -- much smaller. A slow interpolation still counts as the game driving.
        quietEps      = 0.05,   -- uu
    },

    -- Smoothing of the additive (Channel C) effect state, in OFFSET space.
    smooth = {
        armTime  = 0.45,   -- s   SmoothDamp time for armScale
        fovTime  = 0.30,   -- s
        sockRate = 6.0,    -- 1/s ExpApproach rate for framing offsets
    },

    -- Below these magnitudes the rig writes NOTHING and the game keeps full
    -- ownership. Raise if you see idle micro-corrections.
    neutral = { scale = 0.002, fov = 0.05, sock = 0.1 },
},

-- ==== 5. framing =========================================================
-- Holster-driven camera framing. Replaces the old statecam + holsterframe.
framing = {
    -- Holstered: BOTW-ish — centered, pulled back, slightly high.
    holstered = { arm = 500, offset = { x = 10, y = 0,  z = 50 } },
    -- Drawn: vanilla-like over-the-shoulder, a little further back.
    drawn     = { arm = 360, offset = { x = 80, y = 60, z = 60 } },

    -- The immediate glide after a holster transition. Duration-based so it
    -- can use a real easing curve rather than an exponential chase.
    -- Contention is NOT handled here — the rig owns that (rig.contention).
    glide = {
        duration = 0.45,             -- s
        easing   = "EaseOutCubic",   -- any name from easingfunctions.lua
    },

    -- Which state-bank fields Channel A writes. Confirmed present on
    -- PalShooterSpringArmComponent. Run xray (enabled.xray = true) to find
    -- more; add them here and press F10 — no code change needed.
    bank = {
        "Walk", "HipShoot", "Air", "AirHipShoot",
    },

    -- Spring-arm lag. Re-asserted at `reassertHz` because the game restores
    -- its own values on some state changes.
    lag = {
        enable     = true,
        speed      = 9,        -- lower = more float. 6 heavy, 12 subtle
        maxDist    = 150,
        rotation   = false,    -- delays look input; off by default
        rotSpeed   = 15,
        reassertHz = 1.0,
    },

    speedBlur = true,
},

-- ==== 6. sprintfx ========================================================
-- Roadie-run footstep bob. Phase-driven, not noise, so cadence tracks speed.
sprintfx = {
    fovAdd   = 7.0,     -- deg at full intensity

    bobVert  = 12.0,    -- uu vertical dip amplitude
    bobLat   = 7.0,     -- uu lateral sway amplitude
    bobSharp = 0.62,    -- < 1 = punchier vertical

    stepLo   = 2.3,     -- Hz footfall cadence at speedLo
    stepHi   = 3.0,     -- Hz cadence at speedHi

    roughY   = 2.5,     -- uu Perlin garnish so it never reads as a metronome
    roughZ   = 2.0,
    roughHz  = 3.7,

    speedLo  = 420,     -- uu/s (above the 350 walk cap)
    speedHi  = 600,
    minInt   = 0.4,
    rampIn   = 3.0,     -- 1/s
    rampOut  = 5.0,

    footfallImpulse = true,
    impulseScale    = 0.12,   -- Channel B rotational jolt per footfall
},

-- ==== 7. fallfx ==========================================================
-- Vertical-dominant heave while falling + one hard jolt on touchdown.
fallfx = {
    vzStart   = 200,     -- uu/s downward before any effect
    vzMax     = 1400,    -- uu/s downward at full intensity
    fovMax    = 12.0,    -- deg at full intensity

    heaveZ    = 34.0,    -- uu dominant vertical heave
    heaveHz   = 2.2,
    heaveSharp = 0.7,

    turbX     = 8.0,     -- uu fBm turbulence (garnish only)
    turbY     = 10.0,
    turbZ     = 12.0,
    turbHz    = 4.5,
    octaves   = 3,

    minInt    = 0.15,
    rampIn    = 6.0,     -- 1/s
    rampOut   = 10.0,    -- fast decay on landing

    landImpulse = true,
    landMinInt  = 0.20,  -- minimum peak intensity to fire the landing jolt
    landScale   = 1.0,   -- shake scale = landScale * peak intensity
},

-- ==== 8. signals =========================================================
-- Thresholds for the derived per-tick state main.lua hands to subsystems.
signals = {
    -- Sprint is SPEED-based on purpose: the bRequestSprint flag never fired
    -- across multiple capture sessions and its pcall silently disabled every
    -- sprint effect. Grounded speed over the walk cap cannot fail silently.
    sprintMinSpeed  = 420,   -- uu/s; above walk cap 350, below sprint 610
    headingMinSpeed = 60,    -- uu/s; below this heading is nil
    camInputDeadzone = 0.05, -- look-axis magnitude regarded as "no input"
},

-- ==== 9. probe (dev) =====================================================
probe = {
    dumpOnCache = true,   -- vanilla value dump on each (re)spawn
    logSignals  = true,   -- [E] transition lines (also needs log.channels.signals)
},

}
