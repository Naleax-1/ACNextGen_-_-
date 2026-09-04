---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- engine_thermal.lua
-- Prototype-09 / Virtual Engine Thermal State
--
-- Assetto Corsa does not expose a complete coolant/oil temperature
-- model to this architecture. P09 therefore creates internal,
-- non-invasive thermal states rather than pretending AC has values
-- that it does not provide.
--
-- Thermal chain:
--   combustion / losses -> engine heat -> coolant/oil/turbo thermal mass
--   -> airflow cooling -> thermal stress -> conservative torque derate
--
-- This module never writes AC coolant/oil temperatures and never
-- damages the car directly. It only publishes virtual states.
--============================================================

local M = {}

M.params = {
    ambientC = 25.0,
    coolantInitC = 25.0,
    oilInitC = 25.0,
    turboInitC = 25.0,

    coolantCapacity = 18500.0,
    oilCapacity = 11500.0,
    turboCapacity = 4200.0,

    combustionHeatFraction = 0.24,
    frictionHeatFraction = 0.70,
    pumpingHeatFraction = 0.45,
    accessoryHeatFraction = 0.35,
    turboHeatFraction = 0.18,

    coolantTransfer = 0.62,
    oilTransfer = 0.34,
    turboTransfer = 0.50,

    coolantRadiatorBase = 0.055,
    coolantRadiatorSpeed = 0.010,
    oilCoolingBase = 0.020,
    oilCoolingSpeed = 0.005,
    turboCoolingBase = 0.014,
    turboCoolingSpeed = 0.004,

    warmupAmbientGain = 0.18,
    normalCoolantC = 92.0,
    normalOilC = 105.0,
    normalTurboC = 135.0,

    coolantDerateStart = 118.0,
    coolantDerateFull = 145.0,
    oilDerateStart = 128.0,
    oilDerateFull = 165.0,
    turboDerateStart = 175.0,
    turboDerateFull = 235.0,

    maxDerate = 0.22,
    hysteresis = 0.015,
    maxTempC = 320.0,

    minDt = 0.01,
    maxDt = 0.20,
    storeInterval = 0.25,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    coolantC = 25.0,
    oilC = 25.0,
    turboC = 25.0,
    ambientC = 25.0,
    speedKmh = 0.0,
    throttle = 0.0,
    rpm = 0.0,
    heatInput = 0.0,
    coolantHeat = 0.0,
    oilHeat = 0.0,
    turboHeat = 0.0,
    coolantDerate = 0.0,
    oilDerate = 0.0,
    turboDerate = 0.0,
    torqueMultiplier = 1.0,
    thermalStress = 0.0,
    updateTimer = 999.0,
}

M.state = state
M.debug = state

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback or 0.0 end
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

local function safeLoad(key, fallback)
    if not ac or not ac.load then return fallback end
    local ok, value = pcall(function() return ac.load(key) end)
    if ok and value ~= nil then return num(value, fallback) end
    return fallback
end

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, value) end)
end

local function safeStoreString(key, value)
    safeStore(key, tostring(value or ""))
end

local function approach(current, target, rate, dt)
    local a = 1.0 - math.exp(-math.max(rate, 0.0) * dt)
    return current + (target - current) * a
end

local function rangeStress(value, startValue, fullValue)
    if value <= startValue then return 0.0 end
    return clamp((value - startValue) / math.max(fullValue - startValue, 0.001), 0.0, 1.0)
end

local function getAmbient(car)
    -- Prefer values exposed by the environment if available; otherwise
    -- remain explicit that this is a virtual ambient estimate.
    local candidates = {
        safeField(car, "ambientTemperature", nil),
        safeField(car, "ambientTemp", nil),
    }
    for i = 1, #candidates do
        local n = tonumber(candidates[i])
        if n then return clamp(n, -20.0, 60.0) end
    end
    return M.params.ambientC
end

local function exportState()
    safeStore("ngp_engine_thermal_coolant_c", state.coolantC)
    safeStore("ngp_engine_thermal_oil_c", state.oilC)
    safeStore("ngp_engine_thermal_turbo_c", state.turboC)
    safeStore("ngp_engine_thermal_ambient_c", state.ambientC)
    safeStore("ngp_engine_thermal_heat_input", state.heatInput)
    safeStore("ngp_engine_thermal_coolant_heat", state.coolantHeat)
    safeStore("ngp_engine_thermal_oil_heat", state.oilHeat)
    safeStore("ngp_engine_thermal_turbo_heat", state.turboHeat)
    safeStore("ngp_engine_thermal_coolant_derate", state.coolantDerate)
    safeStore("ngp_engine_thermal_oil_derate", state.oilDerate)
    safeStore("ngp_engine_thermal_turbo_derate", state.turboDerate)
    safeStore("ngp_engine_thermal_torque_multiplier", state.torqueMultiplier)
    safeStore("ngp_engine_thermal_stress", state.thermalStress)
    safeStore("ngp_engine_thermal_rpm", state.rpm)
    safeStore("ngp_engine_thermal_speed_kmh", state.speedKmh)
    safeStore("ngp_engine_thermal_throttle", state.throttle)
    safeStoreString("ngp_engine_thermal_status", state.status)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
    state.coolantC = M.params.coolantInitC
    state.oilC = M.params.oilInitC
    state.turboC = M.params.turboInitC
    state.ambientC = M.params.ambientC
    state.torqueMultiplier = 1.0
    state.updateTimer = 999.0
    exportState()
end

function M.update(dt, car, runtime)
    if not state.initialized then M.init() end
    dt = clamp(dt, M.params.minDt, M.params.maxDt)
    if not car then
        state.status = "NO CAR"
        exportState()
        return
    end

    state.updateCount = state.updateCount + 1
    state.rpm = math.max(num(safeField(car, "rpm", 0.0), 0.0), 0.0)
    state.throttle = clamp(num(safeField(car, "gas", 0.0), 0.0), 0.0, 1.0)
    state.speedKmh = math.max(num(safeField(car, "speedKmh", safeField(car, "speed", 0.0)), 0.0), 0.0)
    state.ambientC = getAmbient(car)

    local engineTorque = math.abs(safeLoad("ngp_engine_proto_base_combustion_torque_nm", 0.0))
    local friction = math.abs(safeLoad("ngp_engine_proto_friction_torque_nm", 0.0))
    local pumping = math.abs(safeLoad("ngp_engine_proto_pumping_torque_nm", 0.0))
    local accessory = math.abs(safeLoad("ngp_engine_proto_accessory_torque_nm", 0.0))
    local turboTorque = math.abs(safeLoad("ngp_turbo_turbine_torque_nm", 0.0))

    local omega = state.rpm * 2.0 * math.pi / 60.0
    local mechanicalPower = math.abs(engineTorque * omega)
    local heat = mechanicalPower * M.params.combustionHeatFraction
        + friction * omega * M.params.frictionHeatFraction
        + pumping * omega * M.params.pumpingHeatFraction
        + accessory * omega * M.params.accessoryHeatFraction
        + turboTorque * omega * M.params.turboHeatFraction

    state.heatInput = heat

    -- The values are normalized heat-energy rates rather than pretending
    -- to be exact SI coolant/oil thermodynamics. This keeps P09 stable
    -- while still giving the simulation useful thermal memory.
    local coolantInput = heat * M.params.coolantTransfer
    local oilInput = heat * M.params.oilTransfer
    local turboInput = heat * M.params.turboTransfer

    local speedFactor = clamp(state.speedKmh / 180.0, 0.0, 1.0)
    local loadFactor = clamp(0.15 + state.throttle * 0.85, 0.15, 1.0)

    local coolantCooling = M.params.coolantRadiatorBase + M.params.coolantRadiatorSpeed * speedFactor
    local oilCooling = M.params.oilCoolingBase + M.params.oilCoolingSpeed * speedFactor
    local turboCooling = M.params.turboCoolingBase + M.params.turboCoolingSpeed * speedFactor

    local coolantTarget = state.ambientC + coolantInput / math.max(M.params.coolantCapacity, 1.0) * 120.0
    local oilTarget = state.ambientC + oilInput / math.max(M.params.oilCapacity, 1.0) * 140.0
    local turboTarget = state.ambientC + turboInput / math.max(M.params.turboCapacity, 1.0) * 180.0

    coolantTarget = math.max(coolantTarget, state.ambientC + 5.0 * loadFactor)
    oilTarget = math.max(oilTarget, state.ambientC + 8.0 * loadFactor)
    turboTarget = math.max(turboTarget, state.ambientC + 10.0 * loadFactor)

    local coolantRate = 0.35 + coolantCooling * 1.5
    local oilRate = 0.22 + oilCooling * 1.2
    local turboRate = 0.28 + turboCooling * 1.3

    state.coolantC = approach(state.coolantC, coolantTarget, coolantRate, dt)
    state.oilC = approach(state.oilC, oilTarget, oilRate, dt)
    state.turboC = approach(state.turboC, turboTarget, turboRate, dt)

    -- Explicit ambient pull gives a plausible warm-up/cool-down memory
    -- without requiring an AC-native coolant temperature signal.
    local ambientPull = M.params.warmupAmbientGain * dt
    state.coolantC = state.coolantC + (state.ambientC - state.coolantC) * ambientPull * (1.0 - 0.35 * speedFactor)
    state.oilC = state.oilC + (state.ambientC - state.oilC) * ambientPull * 0.75
    state.turboC = state.turboC + (state.ambientC - state.turboC) * ambientPull * 0.45

    state.coolantC = clamp(state.coolantC, state.ambientC, M.params.maxTempC)
    state.oilC = clamp(state.oilC, state.ambientC, M.params.maxTempC)
    state.turboC = clamp(state.turboC, state.ambientC, M.params.maxTempC)

    state.coolantDerate = rangeStress(state.coolantC, M.params.coolantDerateStart, M.params.coolantDerateFull)
    state.oilDerate = rangeStress(state.oilC, M.params.oilDerateStart, M.params.oilDerateFull)
    state.turboDerate = rangeStress(state.turboC, M.params.turboDerateStart, M.params.turboDerateFull)

    local weightedStress = clamp(
        state.coolantDerate * 0.40 + state.oilDerate * 0.40 + state.turboDerate * 0.20,
        0.0, 1.0
    )
    state.thermalStress = weightedStress
    state.torqueMultiplier = clamp(1.0 - M.params.maxDerate * weightedStress, 1.0 - M.params.maxDerate, 1.0)

    state.status = "RUNNING"
    state.updateTimer = state.updateTimer + dt
    if state.updateTimer >= M.params.storeInterval then
        state.updateTimer = 0.0
        exportState()
    end
end

function M.getTorqueMultiplier()
    return state.torqueMultiplier or 1.0
end

function M.getState()
    return state
end

return M
