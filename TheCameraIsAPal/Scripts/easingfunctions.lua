--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\-- EASING FUNCTIONS  (https://easings.net) --////////////////////////////////////-- 

--author: TheTr3y
--date = 2025-05-19
--  SUMMARY:
--      Helper functions I have made to return values based on well known math equations used in high production software to make things feel smooth and buttery.
--      They work by passing in a starting value, ending value, and ratio value of how far along you are in your desired total time to complete the journey. 
--      The intended use is to call them in an updating/looping function which passes in a value of (current travel time / total desired travel time) in the last parameter "t".    
--      They are sectioned by Ease category (In, Out, InOut), and ordered from most linear(top) to least linear(bottom) i.e.[quad, cubic, circ, quart, quint, expo].


local EasingOptions = {}

-- Local helper strictly for Bounce calculations
local function BounceCalc(t)
    if t < (1 / 2.75) then
        return 7.5625 * t * t
    elseif t < (2 / 2.75) then
        t = t - (1.5 / 2.75)
        return 7.5625 * t * t + 0.75
    elseif t < (2.5 / 2.75) then
        t = t - (2.25 / 2.75)
        return 7.5625 * t * t + 0.9375
    else
        t = t - (2.625 / 2.75)
        return 7.5625 * t * t + 0.984375
    end
end

-- Linear --
function EasingOptions.EaseLinear(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * t
end

-- EaseIn's --
function EasingOptions.EaseInSine(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * (1 - math.cos(t * (math.pi / 2)))
end

function EasingOptions.EaseInQuad(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * t * t
end

function EasingOptions.EaseInCubic(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * t * t * t
end

function EasingOptions.EaseInQuart(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * t * t * t * t
end

function EasingOptions.EaseInQuint(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * t * t * t * t * t
end

function EasingOptions.EaseInExpo(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 0 then return from end
    local change = to - from
    return from + change * math.pow(2, 10 * (t - 1))
end

function EasingOptions.EaseInCirc(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from - change * (math.sqrt(1 - t * t) - 1)
end

function EasingOptions.EaseInBack(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    local s = 1.70158
    return from + change * t * t * ((s + 1) * t - s)
end

function EasingOptions.EaseInElastic(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 0 then return from end
    if t == 1 then return to end
    local change = to - from
    local p = 0.3
    local s = p / 4
    t = t - 1
    return from - change * (math.pow(2, 10 * t) * math.sin((t - s) * (2 * math.pi) / p))
end

function EasingOptions.EaseInBounce(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * (1 - BounceCalc(1 - t))
end

-- EaseOut's --
function EasingOptions.EaseOutSine(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * math.sin(t * (math.pi / 2))
end

function EasingOptions.EaseOutQuad(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from - change * t * (t - 2)
end

function EasingOptions.EaseOutCubic(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    t = t - 1
    return from + change * (t * t * t + 1)
end

function EasingOptions.EaseOutQuart(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    t = t - 1
    return from - change * (t * t * t * t - 1)
end

function EasingOptions.EaseOutQuint(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    t = t - 1
    return from + change * (t * t * t * t * t + 1)
end

function EasingOptions.EaseOutExpo(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 1 then return to end
    local change = to - from
    return from + change * (1 - math.pow(2, -10 * t))
end

function EasingOptions.EaseOutCirc(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * math.sqrt(1 - (t - 1)^2)
end

function EasingOptions.EaseOutBack(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    local s = 1.70158
    t = t - 1
    return from + change * (t * t * ((s + 1) * t + s) + 1)
end

function EasingOptions.EaseOutElastic(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 0 then return from end
    if t == 1 then return to end
    local change = to - from
    local p = 0.3
    local s = p / 4
    return from + change * (math.pow(2, -10 * t) * math.sin((t - s) * (2 * math.pi) / p) + 1)
end

function EasingOptions.EaseOutBounce(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from + change * BounceCalc(t)
end

-- EaseInOut's --
function EasingOptions.EaseInOutSine(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    return from - change / 2 * (math.cos(math.pi * t) - 1)
end

function EasingOptions.EaseInOutQuad(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    if t < 0.5 then
        return from + change * 2 * t * t
    else
        return from - change * (t * (t - 2) - 0.5)
    end
end

function EasingOptions.EaseInOutCubic(from, to, t)
    t = math.max(0, math.min(1, t))
    if t < 0.5 then
        return from + (to - from) * 4 * t * t * t
    else
        local f = ((2 * t) - 2)
        return from + (to - from) * (0.5 * f * f * f + 1)
    end
end

function EasingOptions.EaseInOutQuart(from, to, t)
    t = math.max(0, math.min(1, t))
    if t < 0.5 then
        return from + (to - from) * 8 * t * t * t * t
    else
        local f = ((2 * t) - 2)
        return from + (to - from) * (0.5 * f * f * f * f + 1)
    end
end

function EasingOptions.EaseInOutQuint(from, to, t)
    t = math.max(0, math.min(1, t))
    if t < 0.5 then
        return from + (to - from) * 16 * t * t * t * t * t
    else
        local f = ((2 * t) - 2)
        return from + (to - from) * (0.5 * f * f * f * f * f + 1)
    end
end

function EasingOptions.EaseInOutExpo(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 0 then return from end
    if t == 1 then return to end
    if t < 0.5 then
        return from + (to - from) * 0.5 * (math.pow(2, 20 * t - 10))
    else
        return from + (to - from) * (1 - 0.5 * (math.pow(2, -20 * t + 10)))
    end
end

function EasingOptions.EaseInOutCirc(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    t = t * 2
    if t < 1 then
        return from - change / 2 * (math.sqrt(1 - t * t) - 1)
    else
        t = t - 2
        return from + change / 2 * (math.sqrt(1 - t * t) + 1)
    end
end

function EasingOptions.EaseInOutBack(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    local s = 1.70158 * 1.525
    t = t * 2
    if t < 1 then
        return from + change / 2 * (t * t * ((s + 1) * t - s))
    else
        t = t - 2
        return from + change / 2 * (t * t * ((s + 1) * t + s) + 2)
    end
end

function EasingOptions.EaseInOutElastic(from, to, t)
    t = math.max(0, math.min(1, t))
    if t == 0 then return from end
    if t == 1 then return to end
    local change = to - from
    local p = 0.3 * 1.5
    local s = p / 4
    t = t * 2 - 1
    if t < 0 then
        return from - change * 0.5 * (math.pow(2, 10 * t) * math.sin((t - s) * (2 * math.pi) / p))
    else
        return from + change * (math.pow(2, -10 * t) * math.sin((t - s) * (2 * math.pi) / p) * 0.5 + 1)
    end
end

function EasingOptions.EaseInOutBounce(from, to, t)
    t = math.max(0, math.min(1, t))
    local change = to - from
    if t < 0.5 then
        return from + change * (1 - BounceCalc(1 - 2 * t)) * 0.5
    else
        return from + change * (BounceCalc(2 * t - 1) * 0.5 + 0.5)
    end
end

return EasingOptions
