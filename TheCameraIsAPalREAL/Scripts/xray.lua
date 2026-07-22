-- =========================================================================
-- TheCameraIsAPal subsystem: xray — runtime reflection of camera classes
--
-- The game's native camera code rewrites TargetArmLength / SocketOffset per
-- frame from its OWN parameters. Those source parameters live in the
-- Pal-layer members of PalShooterSpringArmComponent,
-- PalCharacterCameraComponent, and PalPlayerCameraManager -- none of which
-- are covered by the base-engine MDK. Instead of requiring a CXX dump,
-- this subsystem walks each object's class hierarchy with ForEachProperty
-- and prints every property name, type, and live value, stopping once the
-- hierarchy reaches engine classes (already known from the MDK).
--
-- Runs once per session on first cache. Output is grep-able:
--   grep "TheCameraIsAPal:xray" UE4SS.log
-- Look for members whose value matches the vanilla numbers (400, 70) or
-- whose names suggest per-state distance/offset/interp control; those are
-- the candidates for a contention-free write channel.
-- =========================================================================

local M = { name = "xray" }

local dumped = false

local function dbg(fmt, ...)
    print(string.format("[TheCameraIsAPal:xray] " .. fmt .. "\n", ...))
end

local function PropName(prop)
    local ok, s = pcall(function() return prop:GetFName():ToString() end)
    if ok and s then return s end
    ok, s = pcall(function() return tostring(prop:GetFName()) end)
    if ok and s then return s end
    ok, s = pcall(function() return prop:GetFullName() end)
    if ok and s then return s:match("([%w_]+)$") or s end
    return "<unnamed>"
end

local function PropType(prop)
    local ok, s = pcall(function() return prop:GetClass():GetFName():ToString() end)
    if ok and s then return s end
    ok, s = pcall(function() return prop:GetFullName() end)
    if ok and s then return s:match("^(%S+)") or "?" end
    return "?"
end

local function FormatValue(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "<read err>" end
    local t = type(v)
    if t == "number" then return string.format("%.6g", v) end
    if t == "boolean" or t == "nil" then return tostring(v) end
    if t == "string" then return v end
    local s
    ok, s = pcall(function()
        return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
    end)
    if ok then return s end
    ok, s = pcall(function()
        return string.format("(P=%.1f Y=%.1f R=%.1f)", v.Pitch, v.Yaw, v.Roll)
    end)
    if ok then return s end
    ok, s = pcall(function()
        return string.format("(%.2f, %.2f)", v.X, v.Y)
    end)
    if ok then return s end
    ok, s = pcall(function() return v:GetFullName() end)
    if ok then return s end
    return "<struct/unhandled>"
end

local function IsEngineLayer(fullName)
    return fullName:find("/Script/Engine")
        or fullName:find("/Script/CoreUObject")
        or fullName:find("/Script/GameplayCameras")
        or fullName:find("/Script/CinematicCamera")
end

local function DumpLayers(obj, label)
    if obj == nil then
        dbg("== %s: nil ==", label)
        return
    end
    local okC, cls = pcall(function() return obj:GetClass() end)
    if not okC or cls == nil then
        dbg("== %s: GetClass failed ==", label)
        return
    end

    local struct = cls
    local depth = 0
    while struct and depth < 12 do
        depth = depth + 1
        local full = "?"
        pcall(function() full = struct:GetFullName() end)
        if IsEngineLayer(full) then
            dbg("== %s: reached engine layer (%s), stopping ==", label, full)
            break
        end

        dbg("== %s :: %s ==", label, full)
        local count = 0
        local okF = pcall(function()
            struct:ForEachProperty(function(prop)
                count = count + 1
                local n = PropName(prop)
                dbg("  %-42s %-22s = %s", n, PropType(prop), FormatValue(obj, n))
            end)
        end)
        if not okF then
            dbg("  ForEachProperty unsupported on this UE4SS build; a CXX dump of %s is needed instead", full)
            break
        end
        if count == 0 then dbg("  (no own properties at this layer)") end

        local nextStruct = nil
        pcall(function() nextStruct = struct:GetSuperStruct() end)
        if nextStruct == nil then break end
        local validNext = false
        pcall(function() validNext = nextStruct:IsValid() end)
        if not validNext then break end
        struct = nextStruct
    end
end

function M.OnCached(ctx)
    if dumped then return end
    dumped = true

    dbg("======== camera class xray (once per session) ========")
    DumpLayers(ctx.arm, "CameraBoom")
    DumpLayers(ctx.cam, "FollowCamera")

    local pcm = nil
    pcall(function() pcm = ctx.pc.PlayerCameraManager end)
    DumpLayers(pcm, "CameraManager")
    dbg("======== xray complete ========")
end

function M.OnTick(dt, ctx, sig) end

return M
