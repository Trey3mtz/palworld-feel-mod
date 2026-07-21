-- =========================================================================
-- PalFeel module: camutil — math core for the camera subsystem
--
-- Dump-independent (no UObject access). Final code; safe to ship as-is.
--   Noise1D / FBm      : deterministic Perlin-style gradient noise, ~[-1, 1]
--   ExpApproach        : frame-rate independent exponential ease toward target
--   SmoothDamp         : critically damped spring (Unity semantics)
--   AngleDeltaDeg      : shortest signed angular difference in degrees
--   MapClamped         : linear remap with output clamping
-- =========================================================================

local M = {}

-- ---------------------------- Perlin noise -------------------------------

local perm = {}
do
    -- Deterministic permutation table (fixed seed => repeatable feel tuning).
    math.randomseed(0x5EED)
    local p = {}
    for i = 0, 255 do p[i] = i end
    for i = 255, 1, -1 do
        local j = math.random(0, i)
        p[i], p[j] = p[j], p[i]
    end
    for i = 0, 511 do perm[i] = p[i % 256] end
end

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end

local function grad(hash, x)
    local h = hash % 16
    local g = 1 + (h % 8)              -- gradient magnitude 1..8
    if h >= 8 then g = -g end
    return g * x
end

--- 1D Perlin gradient noise. Output approx [-1, 1]. Period 256.
--- Use distinct large offsets per channel (e.g. +137.7, +291.3) so the
--- X/Y/Z shake axes decorrelate while sharing one time base.
function M.Noise1D(x)
    local xf0 = math.floor(x)
    local xi  = xf0 % 256
    local xf  = x - xf0
    local u   = fade(xf)
    local a   = grad(perm[xi],     xf)
    local b   = grad(perm[xi + 1], xf - 1)
    return (a + u * (b - a)) * 0.25    -- normalize toward [-1, 1]
end

--- Fractal (octaved) noise. Richer motion than a single octave; use for
--- the falling shake. octaves 2-3 is plenty at camera rates.
function M.FBm(x, octaves, lacunarity, gain)
    octaves    = octaves or 3
    lacunarity = lacunarity or 2.0
    gain       = gain or 0.5
    local amp, freq, sum, norm = 1.0, 1.0, 0.0, 0.0
    for _ = 1, octaves do
        sum  = sum + amp * M.Noise1D(x * freq)
        norm = norm + amp
        amp  = amp * gain
        freq = freq * lacunarity
    end
    return sum / norm
end

-- ---------------------------- smoothing ----------------------------------

--- Exponential approach: moves `current` toward `target` at `rate` (1/s),
--- identical feel at any frame rate. rate ~= 1/time-constant.
function M.ExpApproach(current, target, rate, dt)
    local t = 1 - math.exp(-rate * dt)
    return current + (target - current) * t
end

--- Critically damped spring (Unity SmoothDamp port).
--- Returns newValue, newVelocity. Keep the velocity between calls.
--- smoothTime ~ time to cover most of the distance; maxSpeed optional.
function M.SmoothDamp(current, target, velocity, smoothTime, dt, maxSpeed)
    smoothTime = math.max(0.0001, smoothTime)
    local omega = 2.0 / smoothTime
    local x     = omega * dt
    local e     = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)

    local change     = current - target
    local originalTo = target

    if maxSpeed then
        local maxChange = maxSpeed * smoothTime
        if change >  maxChange then change =  maxChange end
        if change < -maxChange then change = -maxChange end
    end
    target = current - change

    local temp   = (velocity + omega * change) * dt
    velocity     = (velocity - omega * temp) * e
    local output = target + (change + temp) * e

    -- Prevent overshoot past the true target.
    if ((originalTo - current) > 0) == (output > originalTo) then
        output   = originalTo
        velocity = (output - originalTo) / dt
    end
    return output, velocity
end

-- ---------------------------- angles / remap -----------------------------

--- Shortest signed delta from `fromDeg` to `toDeg`, in (-180, 180].
function M.AngleDeltaDeg(fromDeg, toDeg)
    local d = (toDeg - fromDeg) % 360
    if d > 180 then d = d - 360 end
    return d
end

--- Heading (deg, world yaw) of a 2D velocity. Returns nil below minSpeed.
function M.VelocityHeadingDeg(vx, vy, minSpeed)
    local s = math.sqrt(vx * vx + vy * vy)
    if s < (minSpeed or 1) then return nil end
    return math.deg(math.atan(vy, vx))
end

--- Remap v from [inA, inB] to [outA, outB], clamped to the output range.
function M.MapClamped(v, inA, inB, outA, outB)
    if inA == inB then return outA end
    local t = (v - inA) / (inB - inA)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return outA + (outB - outA) * t
end

return M
