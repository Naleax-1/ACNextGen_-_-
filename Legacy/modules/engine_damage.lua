---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- engine_damage.lua
-- Prototype-10 / Progressive Engine Damage
--
-- P10 is deliberately not a BeamNG clone. It borrows the useful
-- architectural idea of component-local state, progressive damage,
-- thermal interaction and a distinct "engine disabled" state, while
-- remaining non-invasive to Assetto Corsa.
--
-- AC does not expose the complete set of oil pressure, coolant flow,
-- bearing, rod, piston and water-ingestion signals needed for a literal
-- internal-engine damage model. P10 therefore estimates those states from
-- observable/prototyped signals and exposes them as virtual health states.
--============================================================

local M = {}

M.params = {
    minDt = 0.02,
    maxDt = 0.20,
    storeInterval = 0.25,

    -- Health is 1.0 -> healthy, 0.0 -> failed.
    initialHealth = 1.0,

    -- Persistent wear/damage rates. These are intentionally conservative.
    heatDamageGain = 0.0000018,
    oilHeatDamageGain = 0.0000010,
    turboHeatDamageGain = 0.00000055,
    overrevDamageGain = 0.0000028,
    overspeedGraceRpm = 250.0,
    loadDamageGain = 0.00000015,

    -- Recovery is only allowed for transient stress, not true damage.
    stressRecoveryRate = 0.22,

    -- Progressive thresholds.
    warningHealth = 0.82,
    derateStartHealth = 0.65,
    severeHealth = 0.35,
    failureHealth = 0.08,

    maxTorqueDerate = 0.55,
    severeTorqueDerate = 0.82,

    -- Mechanical event estimates.
    redlineMarginRpm = 250.0,
    stallRecoveryRpm = 500.0,
    maxStress = 1.0,

    -- Turbo-bearing / shaft protection estimate.
    turboOverspeedRpm = 150000.0,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,

    engineHealth = 1.0,
    rotatingAssemblyHealth = 1.0,
    lubricationHealth = 1.0,
    thermalHealth = 1.0,
    turboHealth = 1.0,

    thermalStress = 0.0,
    overrevStress = 0.0,
    lubricationStress = 0.0,
    loadStress = 0.0,

    torqueMultiplier = 1.0,
    disabled = false,
    warning = false,

    rpm = 0.0,
    redline = 0.0,
    engineLoad = 0.0,
    coolantC = 25.0,
    oilC = 25.0,
    turboC = 25.0,
    turboRpm = 0.0,
    netTorqueNm = 0.0,
    reactionTorqueNm = 0.0,

    lastDamageRate = 0.0,
    lastDamageSource = "NONE",
    cumulativeDamage = 0.0,
    updateTimer = 999.0,
}

M.state = state
M.debug = state

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

local function min4(a, b, c, d)
    return math.min(num(a, 1.0), num(b, 1.0), num(c, 1.0), num(d, 1.0))
end

local function exportState()
    safeStore("ngp_engine_damage_health", state.engineHealth)
    safeStore("ngp_engine_damage_rotating_health", state.rotatingAssemblyHealth)
    safeStore("ngp_engine_damage_lubrication_health", state.lubricationHealth)
    safeStore("ngp_engine_damage_thermal_health", state.thermalHealth)
    safeStore("ngp_engine_damage_turbo_health", state.turboHealth)
    safeStore("ngp_engine_damage_thermal_stress", state.thermalStress)
    safeStore("ngp_engine_damage_overrev_stress", state.overrevStress)
    safeStore("ngp_engine_damage_lubrication_stress", state.lubricationStress)
    safeStore("ngp_engine_damage_load_stress", state.loadStress)
    safeStore("ngp_engine_damage_torque_multiplier", state.torqueMultiplier)
    safeStore("ngp_engine_damage_disabled", state.disabled and 1 or 0)
    safeStore("ngp_engine_damage_warning", state.warning and 1 or 0)
    safeStore("ngp_engine_damage_rpm", state.rpm)
    safeStore("ngp_engine_damage_redline", state.redline)
    safeStore("ngp_engine_damage_engine_load", state.engineLoad)
    safeStore("ngp_engine_damage_coolant_c", state.coolantC)
    safeStore("ngp_engine_damage_oil_c", state.oilC)
    safeStore("ngp_engine_damage_turbo_c", state.turboC)
    safeStore("ngp_engine_damage_turbo_rpm", state.turboRpm)
    safeStore("ngp_engine_damage_net_torque_nm", state.netTorqueNm)
    safeStore("ngp_engine_damage_reaction_torque_nm", state.reactionTorqueNm)
    safeStore("ngp_engine_damage_rate", state.lastDamageRate)
    safeStore("ngp_engine_damage_cumulative", state.cumulativeDamage)
    safeStoreString("ngp_engine_damage_source", state.lastDamageSource)
    safeStoreString("ngp_engine_damage_status", state.status)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
    state.engineHealth = M.params.initialHealth
    state.rotatingAssemblyHealth = M.params.initialHealth
    state.lubricationHealth = M.params.initialHealth
    state.thermalHealth = M.params.initialHealth
    state.turboHealth = M.params.initialHealth
    state.thermalStress = 0.0
    state.overrevStress = 0.0
    state.lubricationStress = 0.0
    state.loadStress = 0.0
    state.torqueMultiplier = 1.0
    state.disabled = false
    state.warning = false
    state.lastDamageRate = 0.0
    state.lastDamageSource = "NONE"
    state.cumulativeDamage = 0.0
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
    state.redline = math.max(safeLoad("ngp_engine_proto_redline_rpm", safeField(car, "limiterRPM", 7000.0)), 1000.0)

    local gas = clamp(num(safeField(car, "gas", 0.0), 0.0), 0.0, 1.0)
    local brake = clamp(num(safeField(car, "brake", 0.0), 0.0), 0.0, 1.0)
    local torque = math.abs(safeLoad("ngp_engine_proto_output_torque_nm", 0.0))
    local baseTorque = math.max(math.abs(safeLoad("ngp_engine_proto_base_combustion_torque_nm", 0.0)), 1.0)
    state.netTorqueNm = torque
    state.reactionTorqueNm = math.abs(safeLoad("ngp_engine_proto_clutch_reaction_torque_nm", 0.0))
    state.engineLoad = clamp(torque / baseTorque, 0.0, 1.5)

    state.coolantC = safeLoad("ngp_engine_thermal_coolant_c", 25.0)
    state.oilC = safeLoad("ngp_engine_thermal_oil_c", 25.0)
    state.turboC = safeLoad("ngp_engine_thermal_turbo_c", 25.0)
    state.turboRpm = safeLoad("ngp_turbo_shaft_rpm", 0.0)

    local thermalStress = clamp(safeLoad("ngp_engine_thermal_stress", 0.0), 0.0, 1.0)
    local oilHeatStress = clamp((state.oilC - 120.0) / 65.0, 0.0, 1.0)
    local coolantStress = clamp((state.coolantC - 105.0) / 55.0, 0.0, 1.0)
    local turboStress = clamp((state.turboC - 160.0) / 90.0, 0.0, 1.0)

    local rpmExcess = math.max(state.rpm - (state.redline + M.params.redlineMarginRpm), 0.0)
    local rpmSpan = math.max(state.redline * 0.18, 500.0)
    state.overrevStress = clamp(rpmExcess / rpmSpan, 0.0, 1.0)

    -- AC cannot directly expose oil pressure/starvation here. Instead use
    -- high lateral/longitudinal load proxies only if available, otherwise
    -- preserve lubrication health rather than inventing starvation events.
    local gLat = math.abs(safeLoad("ngp_lateral_g", 0.0))
    local gLong = math.abs(safeLoad("ngp_longitudinal_g", 0.0))
    local oilStarvationProxy = clamp(math.max(gLat - 1.6, 0.0) / 1.4, 0.0, 1.0)
    local brakingProxy = clamp(math.max(gLong - 1.8, 0.0) / 1.6, 0.0, 1.0) * brake
    state.lubricationStress = math.max(oilHeatStress * 0.55, oilStarvationProxy * 0.70, brakingProxy * 0.35)
    state.thermalStress = math.max(thermalStress, coolantStress * 0.55, oilHeatStress * 0.70)
    state.loadStress = clamp(state.engineLoad * gas, 0.0, 1.0)

    local rotatingDamage = state.overrevStress * rpmSpan * M.params.overrevDamageGain * dt
    local thermalDamage = state.thermalStress * M.params.heatDamageGain * math.max(state.coolantC - 90.0, 0.0) * dt
    local oilDamage = state.lubricationStress * M.params.oilHeatDamageGain * math.max(state.oilC - 105.0, 0.0) * dt
    local turboDamage = turboStress * M.params.turboHeatDamageGain * math.max(state.turboC - 150.0, 0.0) * dt
    local loadDamage = state.loadStress * state.overrevStress * M.params.loadDamageGain * 100000.0 * dt

    local damageRate = rotatingDamage + thermalDamage + oilDamage + turboDamage + loadDamage
    state.lastDamageRate = damageRate

    if damageRate > 0.0 then
        local source = "LOAD"
        if state.overrevStress > 0.05 then source = "OVERREV"
        elseif state.lubricationStress > 0.35 then source = "LUBRICATION"
        elseif state.thermalStress > 0.35 then source = "THERMAL"
        elseif turboStress > 0.35 then source = "TURBO"
        end
        state.lastDamageSource = source
        state.cumulativeDamage = state.cumulativeDamage + damageRate
    else
        state.lastDamageSource = "NONE"
    end

    state.rotatingAssemblyHealth = clamp(state.rotatingAssemblyHealth - rotatingDamage, 0.0, 1.0)
    state.thermalHealth = clamp(state.thermalHealth - thermalDamage, 0.0, 1.0)
    state.lubricationHealth = clamp(state.lubricationHealth - oilDamage, 0.0, 1.0)
    state.turboHealth = clamp(state.turboHealth - turboDamage, 0.0, 1.0)

    state.engineHealth = min4(
        state.rotatingAssemblyHealth,
        state.thermalHealth,
        state.lubricationHealth,
        state.turboHealth
    )

    state.warning = state.engineHealth <= M.params.warningHealth

    local derate = 0.0
    if state.engineHealth < M.params.derateStartHealth then
        derate = clamp(
            (M.params.derateStartHealth - state.engineHealth)
            / math.max(M.params.derateStartHealth - M.params.failureHealth, 0.01),
            0.0, 1.0
        ) * M.params.maxTorqueDerate
    end

    if state.engineHealth < M.params.severeHealth then
        local severe = clamp((M.params.severeHealth - state.engineHealth) / M.params.severeHealth, 0.0, 1.0)
        derate = math.max(derate, severe * M.params.severeTorqueDerate)
    end

    -- Immediate protection from extreme over-rev is distinct from permanent damage.
    if state.overrevStress > 0.80 then
        derate = math.max(derate, 0.75 * state.overrevStress)
    end

    state.disabled = state.engineHealth <= M.params.failureHealth
    if state.disabled then
        derate = 1.0
        state.status = "ENGINE FAILED"
    elseif state.engineHealth < M.params.severeHealth then
        state.status = "SEVERE DAMAGE"
    elseif state.warning then
        state.status = "WARNING"
    else
        state.status = "RUNNING"
    end

    state.torqueMultiplier = clamp(1.0 - derate, 0.0, 1.0)

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
