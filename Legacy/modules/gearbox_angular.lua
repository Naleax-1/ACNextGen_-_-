---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- gearbox_angular.lua
-- Prototype-03 / Gearbox Angular State
--
-- Design basis: ACNextGen Prototype development report.
-- P03 gives the gearbox an explicit input/output angular state
-- between the P02 clutch and the existing driveline observer.
-- It is intentionally non-invasive: Assetto Corsa's own gear/rpm
-- state is not overwritten.
--============================================================

local M = {}

M.params = {
    inputInertiaKgM2 = 0.085,
    outputInertiaKgM2 = 0.045,
    shaftStiffnessNmPerRad = 1500.0,
    shaftDampingNmPerRadS = 35.0,
    inputDampingNmPerRadS = 0.35,
    outputDampingNmPerRadS = 0.20,
    neutralFreewheelDamping = 0.08,
    torqueLoss = 0.015,
    shiftBlendTau = 0.045,
    omegaTau = 0.020,
    maxOmega = 2500.0,
    maxTorque = 6000.0,
    maxDt = 0.050,
    minDt = 0.0005,
    exportInterval = 0.10,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    gear = 0,
    prevGear = 0,
    gearRatio = 0.0,
    finalRatio = 4.10,
    inputOmega = 0.0,
    outputOmega = 0.0,
    inputOmegaRate = 0.0,
    outputOmegaRate = 0.0,
    constraintError = 0.0,
    constraintTorqueNm = 0.0,
    inputTorqueNm = 0.0,
    outputTorqueNm = 0.0,
    loadTorqueNm = 0.0,
    clutchTorqueNm = 0.0,
    shiftBlend = 1.0,
    shiftShock = 0.0,
    wheelOmega = 0.0,
    wheelLinked = false,
    gearboxLinked = false,
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
    tau = math.max(num(tau, 0.01), 0.0001)
    dt = math.max(num(dt, 0.001), 0.0001)
    local a = clamp(dt / (tau + dt), 0.0, 1.0)
    return num(current, 0.0) + (num(target, 0.0) - num(current, 0.0)) * a
end

local function readWheelOmega(car)
    local sum, count = 0.0, 0
    local wheels = car and safeField(car, "wheels", nil)
    if wheels then
        for i = 2, 3 do
            local wheel = wheels[i]
            if wheel then
                local omega = tonumber(safeField(wheel, "angularSpeed", nil))
                if omega ~= nil and omega == omega then
                    sum = sum + omega
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then
        for _, key in ipairs({"ngp_wheel_omega_2", "ngp_wheel_omega_3"}) do
            local omega = safeLoadNumber(key, nil)
            if omega ~= nil then sum = sum + omega; count = count + 1 end
        end
    end
    if count == 0 then return state.wheelOmega, false end
    return sum / count, true
end

local function readRatios(car, gear)
    local ratio = safeLoadNumber("ngp_drive_gear_ratio", 0.0)
    local final = safeLoadNumber("ngp_drive_final_ratio", state.finalRatio)

    if abs(ratio) <= 0.0001 and abs(gear) > 0 then
        ratio = safeLoadNumber("ngp_gear_ratio_" .. tostring(math.floor(gear)), 0.0)
    end

    if abs(ratio) <= 0.0001 and car then
        local ok, cfg = pcall(function() return ac.getCarConfig() end)
        if ok and cfg then
            local gears = safeField(cfg, "GEARS", nil)
            if gears then
                local key = "GEAR_" .. tostring(math.floor(gear))
                ratio = tonumber(safeField(gears, key, 0.0)) or 0.0
                final = tonumber(safeField(gears, "FINAL", final)) or final
            end
        end
    end

    return num(ratio, 0.0), math.max(abs(num(final, state.finalRatio)), 0.001)
end

local function exportState()
    safeStore("ngp_gearbox_p3_input_omega", state.inputOmega)
    safeStore("ngp_gearbox_p3_output_omega", state.outputOmega)
    safeStore("ngp_gearbox_p3_input_omega_rate", state.inputOmegaRate)
    safeStore("ngp_gearbox_p3_output_omega_rate", state.outputOmegaRate)
    safeStore("ngp_gearbox_p3_constraint_error", state.constraintError)
    safeStore("ngp_gearbox_p3_constraint_torque_nm", state.constraintTorqueNm)
    safeStore("ngp_gearbox_p3_input_torque_nm", state.inputTorqueNm)
    safeStore("ngp_gearbox_p3_output_torque_nm", state.outputTorqueNm)
    safeStore("ngp_gearbox_p3_load_torque_nm", state.loadTorqueNm)
    safeStore("ngp_gearbox_p3_clutch_torque_nm", state.clutchTorqueNm)
    safeStore("ngp_gearbox_p3_gear", state.gear)
    safeStore("ngp_gearbox_p3_gear_ratio", state.gearRatio)
    safeStore("ngp_gearbox_p3_final_ratio", state.finalRatio)
    safeStore("ngp_gearbox_p3_shift_blend", state.shiftBlend)
    safeStore("ngp_gearbox_p3_shift_shock", state.shiftShock)
    safeStore("ngp_gearbox_p3_wheel_omega", state.wheelOmega)
    safeStore("ngp_gearbox_p3_linked_wheel", state.wheelLinked and 1 or 0)
    safeStore("ngp_gearbox_p3_linked_drivetrain", state.gearboxLinked and 1 or 0)
    safeStore("ngp_gearbox_p3_update_count", state.updateCount)
    safeStoreString("ngp_gearbox_p3_status", state.status)
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

    local gear = math.floor(num(safeField(car, "gear", safeLoadNumber("ngp_drive_gear", 0)), 0))
    local ratio, finalRatio = readRatios(car, gear)
    state.prevGear = state.gear
    state.gear = gear
    state.gearRatio = ratio
    state.finalRatio = finalRatio

    if gear ~= state.prevGear then
        state.shiftBlend = 0.0
        state.shiftShock = 1.0
    else
        state.shiftBlend = lowPass(state.shiftBlend, 1.0, M.params.shiftBlendTau, dt)
        state.shiftShock = math.max(0.0, state.shiftShock - dt * 7.0)
    end

    local wheelOmega, wheelLinked = readWheelOmega(car)
    state.wheelOmega = wheelOmega
    state.wheelLinked = wheelLinked

    local clutchNm = safeLoadNumber("ngp_clutch_p2_transmitted_torque_nm", 0.0)
    local diffNm = safeLoadNumber("ngp_drivetrain_diff_input_torque_nm", 0.0)
    state.clutchTorqueNm = clamp(clutchNm, -M.params.maxTorque, M.params.maxTorque)

    -- The existing drivetrain's diff-input torque is downstream of the
    -- gearbox. Reflect it through the final drive to obtain an estimated
    -- gearbox-output load. This remains an observer/bridge, not an AC
    -- physics overwrite.
    local outputLoad = 0.0
    if abs(finalRatio) > 0.001 then
        outputLoad = diffNm / finalRatio
    end
    state.loadTorqueNm = clamp(outputLoad, -M.params.maxTorque, M.params.maxTorque)
    state.gearboxLinked = safeLoadNumber("ngp_drivetrain_update_count", 0.0) > 0.0

    local prevInput = state.inputOmega
    local prevOutput = state.outputOmega

    if abs(ratio) <= 0.0001 then
        -- Neutral: input shaft is free of the wheel-side gear constraint.
        -- Output shaft follows the observed driven-wheel speed.
        state.outputOmega = lowPass(state.outputOmega, wheelOmega, M.params.omegaTau, dt)
        local accel = (state.clutchTorqueNm - M.params.neutralFreewheelDamping * state.inputOmega)
            / math.max(M.params.inputInertiaKgM2, 0.001)
        state.inputOmega = clamp(state.inputOmega + accel * dt, -M.params.maxOmega, M.params.maxOmega)
        state.constraintTorqueNm = 0.0
        state.outputTorqueNm = 0.0
    else
        -- Gear constraint: input omega ~= output omega * gear ratio.
        -- A compliant shaft transfers torque rather than teleporting either
        -- angular state to the other.
        local ratioAbs = math.max(abs(ratio), 0.001)
        local error = state.inputOmega - state.outputOmega * ratio
        local relRate = ((state.inputOmega - prevInput) - (state.outputOmega - prevOutput) * ratio)
            / math.max(dt, M.params.minDt)
        state.constraintError = clamp(error, -M.params.maxOmega, M.params.maxOmega)

        local spring = M.params.shaftStiffnessNmPerRad * state.constraintError
        local damper = M.params.shaftDampingNmPerRadS * clamp(relRate, -1000.0, 1000.0)
        local constraint = clamp((spring + damper) * state.shiftBlend,
            -M.params.maxTorque, M.params.maxTorque)

        state.constraintTorqueNm = constraint

        local inputLoss = state.inputOmega * M.params.inputDampingNmPerRadS
        local outputLoss = state.outputOmega * M.params.outputDampingNmPerRadS
        local inputAccel = (state.clutchTorqueNm - constraint - inputLoss) /
            math.max(M.params.inputInertiaKgM2, 0.001)
        local outputAccel = (constraint / ratio - state.loadTorqueNm - outputLoss) /
            math.max(M.params.outputInertiaKgM2, 0.001)

        state.inputOmega = clamp(state.inputOmega + inputAccel * dt, -M.params.maxOmega, M.params.maxOmega)
        state.outputOmega = clamp(state.outputOmega + outputAccel * dt, -M.params.maxOmega, M.params.maxOmega)

        -- The wheel observation provides a weak positional anchor. It avoids
        -- indefinite drift when the existing drivetrain is not yet exporting
        -- a reaction torque, while keeping the gearbox state dynamic.
        if wheelLinked then
            state.outputOmega = lowPass(state.outputOmega, wheelOmega, 0.085, dt)
        end

        state.outputTorqueNm = clamp(constraint / ratioAbs, -M.params.maxTorque, M.params.maxTorque)
    end

    state.inputOmegaRate = clamp((state.inputOmega - prevInput) / math.max(dt, M.params.minDt), -10000.0, 10000.0)
    state.outputOmegaRate = clamp((state.outputOmega - prevOutput) / math.max(dt, M.params.minDt), -10000.0, 10000.0)

    if state.updateCount == 1 then
        local engineOmega = safeLoadNumber("ngp_engine_proto_omega", num(safeField(car, "rpm", 0.0), 0.0) * 2.0 * math.pi / 60.0)
        state.inputOmega = engineOmega
        if wheelLinked then state.outputOmega = wheelOmega end
    end

    state.status = "RUNNING"
    exportState()
end

function M.getInputOmega() return state.inputOmega or 0.0 end
function M.getOutputOmega() return state.outputOmega or 0.0 end
function M.getOutputTorqueNm() return state.outputTorqueNm or 0.0 end
function M.getState() return state end

return M
