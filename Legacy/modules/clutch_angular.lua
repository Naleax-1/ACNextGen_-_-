---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- clutch_angular.lua
-- Prototype-02 / Engine <-> Clutch Angular Constraint
--
-- Design basis: ACNextGen Prototype-01 development report.
-- Prototype-02 introduces a virtual gearbox-input angular state and
-- computes clutch torque from relative angular velocity. It does not
-- overwrite Assetto Corsa physics directly.
--============================================================

local M = {}

M.params = {
    capacityNm = 520.0,
    engagementTau = 0.035,
    omegaTau = 0.020,
    stiffnessNmPerRadS = 115.0,
    dampingNmPerRadS = 8.0,
    slipScaleRadS = 18.0,
    maxReactionNm = 900.0,
    minDt = 0.0005,
    maxDt = 0.050,
    exportInterval = 0.10,
    drivenWheelCount = 2,
    usePrototypeGearbox = true,
    prototypeGearboxInputOmegaKey = "ngp_gearbox_p3_input_omega",
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    engineOmega = 0.0,
    gearboxInputOmega = 0.0,
    relativeOmega = 0.0,
    relativeOmegaRate = 0.0,
    clutchInput = 1.0,
    clutchEngagement = 1.0,
    clutchCapacityNm = M.params.capacityNm,
    transmittedTorqueNm = 0.0,
    reactionTorqueNm = 0.0,
    slipPowerW = 0.0,
    gear = 0,
    gearRatio = 0.0,
    finalRatio = 4.10,
    wheelOmega = 0.0,
    linkedWheelOmega = false,
    exportTimer = 0.0,
}

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n then return fallback or 0.0 end
    return n
end

local function clamp(v, a, b)
    v = num(v, a)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function abs(v)
    v = num(v, 0.0)
    return v < 0.0 and -v or v
end

local function safeField(obj, key, fallback)
    if not obj then return fallback end
    local ok, value = pcall(function() return obj[key] end)
    if ok and value ~= nil then return value end
    return fallback
end

local function safeLoadRaw(key)
    if not ac or not ac.load then return nil end
    local ok, value = pcall(function() return ac.load(key) end)
    if ok then return value end
    return nil
end

local function safeLoadNumber(key, fallback)
    local value = safeLoadRaw(key)
    local n = tonumber(value)
    if n ~= nil and n == n then return n end
    return fallback
end

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, value) end)
end

local function safeStoreString(key, value)
    safeStore(key, tostring(value or ""))
end

local function lowPass(current, target, tau, dt)
    current = num(current, 0.0)
    target = num(target, 0.0)
    tau = math.max(num(tau, 0.01), 0.0001)
    dt = math.max(num(dt, 0.001), 0.0001)
    local a = clamp(dt / (tau + dt), 0.0, 1.0)
    return current + (target - current) * a
end

local function sign(v)
    return v < 0.0 and -1.0 or 1.0
end

local function readGearRatio(gear)
    if abs(gear) <= 0.0 then return 0.0 end
    local key = "ngp_drive_gear_ratio_" .. tostring(math.floor(gear))
    local ratio = safeLoadNumber(key, nil)
    if ratio ~= nil and abs(ratio) > 0.0001 then return ratio end
    local ratioAbs = safeLoadNumber("ngp_gear_ratio_" .. tostring(math.floor(gear)), nil)
    if ratioAbs ~= nil and abs(ratioAbs) > 0.0001 then return ratioAbs end
    return 0.0
end

local function readFinalRatio()
    return math.max(abs(safeLoadNumber("ngp_drive_final_ratio", state.finalRatio)), 0.001)
end

local function readDrivenWheelOmega(car)
    local sum = 0.0
    local count = 0
    local wheels = car and safeField(car, "wheels", nil)

    if wheels then
        for i = 2, 3 do
            local wheel = wheels[i]
            if wheel then
                local omega = num(safeField(wheel, "angularSpeed", nil), nil)
                if omega ~= nil then
                    sum = sum + omega
                    count = count + 1
                end
            end
        end
    end

    if count == 0 then
        local a = safeLoadNumber("ngp_wheel_omega_2", nil)
        local b = safeLoadNumber("ngp_wheel_omega_3", nil)
        if a ~= nil then sum = sum + a; count = count + 1 end
        if b ~= nil then sum = sum + b; count = count + 1 end
    end

    if count == 0 then
        return state.wheelOmega or 0.0, false
    end

    return sum / count, true
end

local function updateGearboxInputOmega(dt, car, gear, gearRatio)
    local wheelOmega, linked = readDrivenWheelOmega(car)
    state.wheelOmega = wheelOmega
    state.linkedWheelOmega = linked

    if abs(gear) <= 0.0 or abs(gearRatio) <= 0.0001 then
        state.gearboxInputOmega = lowPass(state.gearboxInputOmega, 0.0, 0.080, dt)
        return
    end

    if M.params.usePrototypeGearbox then
        local p3 = safeLoadNumber(M.params.prototypeGearboxInputOmegaKey, nil)
        if p3 ~= nil and abs(p3) < M.params.maxReactionNm * 10.0 then
            state.gearboxInputOmega = lowPass(state.gearboxInputOmega, p3, M.params.omegaTau, dt)
            return
        end
    end

    local target = wheelOmega * gearRatio * state.finalRatio
    state.gearboxInputOmega = lowPass(state.gearboxInputOmega, target, M.params.omegaTau, dt)
end

local function calculateClutchTorque(dt)
    local delta = state.engineOmega - state.gearboxInputOmega
    local rate = (delta - state.relativeOmega) / math.max(dt, 0.0005)
    state.relativeOmegaRate = clamp(rate, -10000.0, 10000.0)
    state.relativeOmega = lowPass(state.relativeOmega, delta, 0.012, dt)

    local engagement = clamp(state.clutchEngagement, 0.0, 1.0)
    local capacity = M.params.capacityNm * engagement
    state.clutchCapacityNm = capacity

    if capacity <= 0.001 or abs(state.gear) <= 0.0 then
        state.transmittedTorqueNm = 0.0
        state.reactionTorqueNm = 0.0
        state.slipPowerW = 0.0
        return
    end

    -- A bounded spring/damper clutch law. The torque opposes relative
    -- angular motion and saturates at the available friction capacity.
    local raw = M.params.stiffnessNmPerRadS * state.relativeOmega
        + M.params.dampingNmPerRadS * state.relativeOmegaRate
    local smooth = math.tanh(raw / math.max(M.params.slipScaleRadS, 0.001))
    local transmitted = capacity * smooth

    transmitted = clamp(transmitted, -M.params.maxReactionNm, M.params.maxReactionNm)
    state.transmittedTorqueNm = transmitted
    state.reactionTorqueNm = -transmitted
    state.slipPowerW = abs(transmitted * state.relativeOmega)
end

local function exportState()
    safeStore("ngp_clutch_p2_transmitted_torque_nm", state.transmittedTorqueNm or 0.0)
    safeStore("ngp_clutch_p2_reaction_torque_nm", state.reactionTorqueNm or 0.0)
    safeStore("ngp_clutch_p2_capacity_nm", state.clutchCapacityNm or 0.0)
    safeStore("ngp_clutch_p2_engine_omega", state.engineOmega or 0.0)
    safeStore("ngp_clutch_p2_gearbox_input_omega", state.gearboxInputOmega or 0.0)
    safeStore("ngp_clutch_p2_relative_omega", state.relativeOmega or 0.0)
    safeStore("ngp_clutch_p2_relative_omega_rate", state.relativeOmegaRate or 0.0)
    safeStore("ngp_clutch_p2_slip_power_w", state.slipPowerW or 0.0)
    safeStore("ngp_clutch_p2_engagement", state.clutchEngagement or 0.0)
    safeStore("ngp_clutch_p2_wheel_omega", state.wheelOmega or 0.0)
    safeStore("ngp_clutch_p2_gear_ratio", state.gearRatio or 0.0)
    safeStore("ngp_clutch_p2_final_ratio", state.finalRatio or 0.0)
    safeStore("ngp_clutch_p2_linked_wheel_omega", state.linkedWheelOmega and 1 or 0)
    safeStore("ngp_clutch_p2_update_count", state.updateCount or 0)
    safeStoreString("ngp_clutch_p2_status", state.status)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
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
    state.engineOmega = safeLoadNumber("ngp_engine_proto_omega", num(safeField(car, "rpm", 0.0), 0.0) * 2.0 * math.pi / 60.0)
    state.clutchInput = clamp(num(safeField(car, "clutch", 1.0), 1.0), 0.0, 1.0)
    state.clutchEngagement = lowPass(state.clutchEngagement, state.clutchInput, M.params.engagementTau, dt)
    state.gear = math.floor(num(safeField(car, "gear", 0), 0))
    state.gearRatio = readGearRatio(state.gear)
    state.finalRatio = readFinalRatio()

    updateGearboxInputOmega(dt, car, state.gear, state.gearRatio)
    calculateClutchTorque(dt)

    state.status = "RUNNING"
    exportState()
end

function M.getTransmittedTorqueNm()
    return state.transmittedTorqueNm or 0.0
end

function M.getReactionTorqueNm()
    return state.reactionTorqueNm or 0.0
end

function M.getGearboxInputOmega()
    return state.gearboxInputOmega or 0.0
end

function M.getState()
    return state
end

return M
