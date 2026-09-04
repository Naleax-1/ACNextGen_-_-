---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- engine_system.lua
-- V1.2.0 / Simplified Vehicle Engine Gateway
--
-- This is the small integration layer for the vehicle-side engine path.
-- It does not replace the existing engine modules and does not write
-- Assetto Corsa physics directly. It only collects their published
-- state into one stable, read-only engine output contract for the
-- drivetrain and Observer.
--
-- Order:
--   combustion waveform / turbo
--        -> engine prototype
--        -> thermal
--        -> damage
--        -> engine system gateway
--        -> drivetrain
--============================================================

local M = {}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    rpm = 0.0,
    throttle = 0.0,
    baseTorqueNm = 0.0,
    netTorqueNm = 0.0,
    torqueMultiplier = 1.0,
    thermalMultiplier = 1.0,
    damageMultiplier = 1.0,
    turboMultiplier = 1.0,
    waveformMultiplier = 1.0,
    coolantC = 25.0,
    oilC = 25.0,
    turboC = 25.0,
    engineHealth = 1.0,
    turboHealth = 1.0,
    warning = false,
    disabled = false,
    redlineRpm = 7200.0,
    authority = 0.0,
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

local function safeLoad(key, fallback)
    if not ac or not ac.load then return fallback end
    local ok, value = pcall(ac.load, key)
    if ok and value ~= nil then return value end
    return fallback
end

local function readNumber(key, fallback)
    return num(safeLoad(key, fallback), fallback)
end

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(ac.store, key, value)
end

local function safeStoreString(key, value)
    safeStore(key, tostring(value or ""))
end

local function finiteOr(v, fallback)
    v = num(v, fallback)
    if v ~= v or v == math.huge or v == -math.huge then
        return fallback
    end
    return v
end

local function exportState()
    safeStore("ngp_engine_system_rpm", state.rpm)
    safeStore("ngp_engine_system_throttle", state.throttle)
    safeStore("ngp_engine_system_base_torque_nm", state.baseTorqueNm)
    safeStore("ngp_engine_system_output_torque_nm", state.netTorqueNm)
    safeStore("ngp_engine_system_torque_multiplier", state.torqueMultiplier)
    safeStore("ngp_engine_system_thermal_multiplier", state.thermalMultiplier)
    safeStore("ngp_engine_system_damage_multiplier", state.damageMultiplier)
    safeStore("ngp_engine_system_turbo_multiplier", state.turboMultiplier)
    safeStore("ngp_engine_system_waveform_multiplier", state.waveformMultiplier)
    safeStore("ngp_engine_system_coolant_c", state.coolantC)
    safeStore("ngp_engine_system_oil_c", state.oilC)
    safeStore("ngp_engine_system_turbo_c", state.turboC)
    safeStore("ngp_engine_system_health", state.engineHealth)
    safeStore("ngp_engine_system_turbo_health", state.turboHealth)
    safeStore("ngp_engine_system_warning", state.warning and 1 or 0)
    safeStore("ngp_engine_system_disabled", state.disabled and 1 or 0)
    safeStore("ngp_engine_system_redline_rpm", state.redlineRpm)
    safeStore("ngp_engine_system_authority", state.authority)
    safeStore("ngp_engine_system_update_count", state.updateCount)
    safeStoreString("ngp_engine_system_status", state.status)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
    exportState()
end

function M.update(dt, car, runtime)
    if not state.initialized then M.init() end

    state.updateCount = state.updateCount + 1

    state.rpm = math.max(readNumber("ngp_engine_proto_rpm", car and car.rpm or 0.0), 0.0)
    state.throttle = clamp(readNumber("ngp_engine_proto_throttle", car and car.gas or 0.0), 0.0, 1.0)

    state.baseTorqueNm = finiteOr(readNumber("ngp_engine_proto_base_combustion_torque_nm", 0.0), 0.0)
    state.netTorqueNm = finiteOr(readNumber("ngp_engine_proto_output_torque_nm", 0.0), 0.0)

    state.waveformMultiplier = clamp(readNumber("ngp_engine_p7_torque_multiplier", 1.0), 0.0, 2.0)
    state.turboMultiplier = clamp(readNumber("ngp_engine_p8_torque_multiplier", 1.0), 0.0, 2.0)
    state.thermalMultiplier = clamp(readNumber("ngp_engine_thermal_torque_multiplier", 1.0), 0.0, 1.0)
    state.damageMultiplier = clamp(readNumber("ngp_engine_damage_torque_multiplier", 1.0), 0.0, 1.0)

    state.torqueMultiplier = clamp(
        state.waveformMultiplier *
        state.turboMultiplier *
        state.thermalMultiplier *
        state.damageMultiplier,
        0.0,
        2.0
    )

    state.coolantC = finiteOr(readNumber("ngp_engine_thermal_coolant_c", 25.0), 25.0)
    state.oilC = finiteOr(readNumber("ngp_engine_thermal_oil_c", 25.0), 25.0)
    state.turboC = finiteOr(readNumber("ngp_engine_thermal_turbo_c", 25.0), 25.0)
    state.engineHealth = clamp(readNumber("ngp_engine_damage_health", 1.0), 0.0, 1.0)
    state.turboHealth = clamp(readNumber("ngp_engine_damage_turbo_health", 1.0), 0.0, 1.0)
    state.warning = readNumber("ngp_engine_damage_warning", 0.0) > 0.5
    state.disabled = readNumber("ngp_engine_damage_disabled", 0.0) > 0.5
    state.redlineRpm = math.max(readNumber("ngp_engine_proto_redline_rpm", 7200.0), 1000.0)
    state.authority = clamp(readNumber("ngp_engine_proto_authority", 0.0), 0.0, 1.0)

    -- The gateway never invents a second torque path. The authoritative
    -- torque remains the engine prototype output; this module only exposes
    -- a consolidated state and validity gate.
    if state.disabled then
        state.status = "ENGINE DISABLED"
    elseif state.warning then
        state.status = "WARNING"
    elseif not car then
        state.status = "NO CAR"
    else
        state.status = "RUNNING"
    end

    state.netTorqueNm = finiteOr(state.netTorqueNm, 0.0)
    exportState()
end

function M.getTorqueNm()
    return state.netTorqueNm or 0.0
end

function M.getState()
    return state
end

return M
