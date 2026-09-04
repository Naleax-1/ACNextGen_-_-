---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- engine_combustion_waveform.lua
-- Prototype-07 / Generic 4-Stroke Combustion Pulsation
--
-- The supplied development report describes P07 as a 4-cylinder
-- waveform prototype. This implementation deliberately does NOT
-- hard-code the architecture: cylinder count is read from the car
-- data when available and falls back to 4. The waveform therefore
-- remains useful for 3/4/5/6/8/10/12-cylinder engines as well.
--
-- This is a smooth aggregate crank-torque pulsation model, not a
-- claim to reconstruct an OEM firing order. It is intentionally
-- conservative and acts as a multiplier on the existing LUT torque.
--============================================================

local M = {}

M.params = {
    defaultCylinders = 4,
    minCylinders = 1,
    maxCylinders = 16,

    -- Four-stroke aggregate firing events per crank revolution = N/2.
    -- A harmonic representation is used rather than a hard-coded firing order.
    baseStrength = 0.065,
    secondHarmonicStrength = 0.018,
    thirdHarmonicStrength = 0.008,

    -- Avoid torque going negative solely because of waveform modulation.
    minimumMultiplier = 0.82,
    maximumMultiplier = 1.18,

    -- Small damping prevents discontinuities when the car is stopped.
    phaseSpeedFloorRpm = 20.0,
    phaseTau = 0.030,
    exportInterval = 0.10,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    cylinders = 4,
    strokes = 4,
    rpm = 0.0,
    omega = 0.0,
    phase = 0.0,
    multiplier = 1.0,
    normalizedPulse = 0.0,
    fundamental = 0.0,
    second = 0.0,
    third = 0.0,
    configSource = "default",
    exportTimer = 0.0,
}

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0.0
    end
    return n
end

local function clamp(v, a, b)
    v = num(v, a)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function safeField(obj, key, fallback)
    if not obj then return fallback end
    local ok, value = pcall(function() return obj[key] end)
    if ok and value ~= nil then return value end
    return fallback
end

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, value) end)
end

local function safeStoreString(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, tostring(value or "")) end)
end

local function safeGetCarConfig(section, key, defaultValue)
    if not ac or not ac.getCarConfig then return defaultValue end
    local ok, value = pcall(function()
        return ac.getCarConfig(0, section, key, defaultValue)
    end)
    if ok and value ~= nil then return value end
    return defaultValue
end

local function getCylinderCount()
    -- Support common custom/config keys without assuming one exact source.
    local candidates = {
        { "ENGINE_DATA", "CYLINDERS" },
        { "ENGINE_DATA", "CYLINDER_COUNT" },
        { "HEADER", "CYLINDERS" },
        { "HEADER", "CYLINDER_COUNT" },
    }

    for i = 1, #candidates do
        local section, key = candidates[i][1], candidates[i][2]
        local raw = safeGetCarConfig(section, key, nil)
        local n = tonumber(raw)
        if n and n >= M.params.minCylinders and n <= M.params.maxCylinders then
            return math.floor(n), section .. ":" .. key
        end
    end

    return M.params.defaultCylinders, "default"
end

local function exportState()
    safeStore("ngp_engine_p7_cylinders", state.cylinders)
    safeStore("ngp_engine_p7_strokes", state.strokes)
    safeStore("ngp_engine_p7_rpm", state.rpm)
    safeStore("ngp_engine_p7_omega", state.omega)
    safeStore("ngp_engine_p7_phase_rad", state.phase)
    safeStore("ngp_engine_p7_multiplier", state.multiplier)
    safeStore("ngp_engine_p7_normalized_pulse", state.normalizedPulse)
    safeStore("ngp_engine_p7_fundamental", state.fundamental)
    safeStore("ngp_engine_p7_second", state.second)
    safeStore("ngp_engine_p7_third", state.third)
    safeStore("ngp_engine_p7_status", state.status)
    safeStoreString("ngp_engine_p7_config_source", state.configSource)
    safeStore("ngp_engine_p7_update_count", state.updateCount)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
    state.cylinders, state.configSource = getCylinderCount()
    state.phase = 0.0
    state.multiplier = 1.0
    exportState()
end

function M.update(dt, car, runtime)
    if not state.initialized then M.init() end

    dt = clamp(dt, 0.0005, 0.100)
    if not car then
        state.status = "NO CAR"
        exportState()
        return
    end

    state.updateCount = state.updateCount + 1

    local rpm = math.max(num(safeField(car, "rpm", 0.0), 0.0), 0.0)
    local omega = rpm * (2.0 * math.pi / 60.0)
    state.rpm = rpm
    state.omega = omega

    -- Re-read very infrequently in case a runtime/car configuration changes.
    if state.updateCount % 300 == 0 then
        state.cylinders, state.configSource = getCylinderCount()
    end

    -- Four-stroke: N firing events occur over 720 degrees.
    -- The aggregate periodicity is therefore N/2 cycles per crank revolution.
    local harmonic = math.max(state.cylinders * 0.5, 0.5)

    if rpm > M.params.phaseSpeedFloorRpm then
        state.phase = state.phase + omega * dt * harmonic
        state.phase = state.phase % (2.0 * math.pi)
    end

    -- Phase-shifted harmonics produce a smooth but non-sinusoidal pulse shape.
    state.fundamental = math.sin(state.phase)
    state.second = math.sin(2.0 * state.phase + 0.35)
    state.third = math.sin(3.0 * state.phase - 0.20)

    local pulse =
        M.params.baseStrength * state.fundamental +
        M.params.secondHarmonicStrength * state.second +
        M.params.thirdHarmonicStrength * state.third

    state.normalizedPulse = pulse
    state.multiplier = clamp(1.0 + pulse, M.params.minimumMultiplier, M.params.maximumMultiplier)

    -- Publish a multiplicative modifier. Engine Prototype consumes this on
    -- the next update, keeping the dependency one-directional and stable.
    safeStore("ngp_engine_p7_torque_multiplier", state.multiplier)
    safeStore("ngp_engine_p7_cylinder_count", state.cylinders)

    state.status = "RUNNING"
    state.exportTimer = state.exportTimer + dt
    if state.exportTimer >= M.params.exportInterval then
        state.exportTimer = 0.0
        exportState()
    end
end

function M.getTorqueMultiplier()
    return state.multiplier or 1.0
end

function M.getCylinderCount()
    return state.cylinders or M.params.defaultCylinders
end

function M.getState()
    return state
end

return M
