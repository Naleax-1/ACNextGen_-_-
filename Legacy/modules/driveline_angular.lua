---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- driveline_angular.lua
-- Prototype-04 / Driveline Angular State
--
-- Design basis: ACNextGen Prototype development report.
-- P04 places an explicit torsional shaft state between the P03
-- gearbox output and the existing drivetrain/windup observers.
-- It is an observer/bridge only: no direct AC physics overwrite.
--============================================================

local M = {}

M.params = {
    shaftInertiaKgM2 = 0.060,
    shaftStiffnessNmPerRad = 420.0,
    shaftDampingNmPerRadS = 10.0,
    shaftLossNmPerRadS = 0.08,

    backlashRad = 0.010,
    backlashEngageGain = 12.0,
    backlashReleaseGain = 7.0,
    backlashShockGain = 0.18,

    wheelAnchorTau = 0.060,
    torqueFilterTau = 0.025,
    reactionFilterTau = 0.030,

    efficiency = 0.985,
    maxTwistRad = 0.75,
    maxOmega = 2500.0,
    maxTorque = 12000.0,

    minDt = 0.0005,
    maxDt = 0.050,
    exportInterval = 0.10,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,

    inputOmega = 0.0,
    outputOmega = 0.0,
    inputOmegaRate = 0.0,
    outputOmegaRate = 0.0,

    twistRad = 0.0,
    twistRate = 0.0,
    torsionTorqueNm = 0.0,
    dampingTorqueNm = 0.0,
    shaftTorqueNm = 0.0,
    loadTorqueNm = 0.0,
    reactionTorqueNm = 0.0,
    transmittedTorqueNm = 0.0,

    wheelOmega = 0.0,
    gearboxOutputOmega = 0.0,
    gearboxOutputTorqueNm = 0.0,
    drivetrainLoadTorqueNm = 0.0,

    backlash = 0.0,
    backlashShock = 0.0,
    engaged = true,
    linkedGearbox = false,
    linkedDrivetrain = false,
    linkedWheels = false,

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
    local wheels = car and safeField(car, "wheels", nil)
    local sum, count = 0.0, 0
    if wheels then
        for i = 0, 3 do
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
        local rearL = safeLoadNumber("ngp_wheel_omega_2", nil)
        local rearR = safeLoadNumber("ngp_wheel_omega_3", nil)
        if rearL ~= nil then sum = sum + rearL; count = count + 1 end
        if rearR ~= nil then sum = sum + rearR; count = count + 1 end
    end
    if count == 0 then return state.wheelOmega, false end
    return sum / count, true
end

local function exportState()
    safeStore("ngp_driveline_p4_input_omega", state.inputOmega)
    safeStore("ngp_driveline_p4_output_omega", state.outputOmega)
    safeStore("ngp_driveline_p4_input_omega_rate", state.inputOmegaRate)
    safeStore("ngp_driveline_p4_output_omega_rate", state.outputOmegaRate)
    safeStore("ngp_driveline_p4_twist_rad", state.twistRad)
    safeStore("ngp_driveline_p4_twist_rate", state.twistRate)
    safeStore("ngp_driveline_p4_torsion_torque_nm", state.torsionTorqueNm)
    safeStore("ngp_driveline_p4_damping_torque_nm", state.dampingTorqueNm)
    safeStore("ngp_driveline_p4_shaft_torque_nm", state.shaftTorqueNm)
    safeStore("ngp_driveline_p4_load_torque_nm", state.loadTorqueNm)
    safeStore("ngp_driveline_p4_reaction_torque_nm", state.reactionTorqueNm)
    safeStore("ngp_driveline_p4_transmitted_torque_nm", state.transmittedTorqueNm)
    safeStore("ngp_driveline_p4_wheel_omega", state.wheelOmega)
    safeStore("ngp_driveline_p4_gearbox_output_omega", state.gearboxOutputOmega)
    safeStore("ngp_driveline_p4_gearbox_output_torque_nm", state.gearboxOutputTorqueNm)
    safeStore("ngp_driveline_p4_drivetrain_load_torque_nm", state.drivetrainLoadTorqueNm)
    safeStore("ngp_driveline_p4_backlash", state.backlash)
    safeStore("ngp_driveline_p4_backlash_shock", state.backlashShock)
    safeStore("ngp_driveline_p4_engaged", state.engaged and 1 or 0)
    safeStore("ngp_driveline_p4_link_gearbox", state.linkedGearbox and 1 or 0)
    safeStore("ngp_driveline_p4_link_drivetrain", state.linkedDrivetrain and 1 or 0)
    safeStore("ngp_driveline_p4_link_wheels", state.linkedWheels and 1 or 0)
    safeStore("ngp_driveline_p4_update_count", state.updateCount)
    safeStoreString("ngp_driveline_p4_status", state.status)

    -- Bridge keys for the next stage and for the existing observer stack.
    safeStore("ngp_driveline_reaction_torque_nm", state.reactionTorqueNm)
    safeStore("ngp_driveline_transmitted_torque_nm", state.transmittedTorqueNm)
    safeStore("ngp_driveline_torsion_torque_nm", state.torsionTorqueNm)
    safeStore("ngp_driveline_angular_twist", state.twistRad)
    safeStore("ngp_driveline_angular_velocity", state.outputOmega)
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

    local gearboxOmega = safeLoadNumber("ngp_gearbox_p3_output_omega", state.outputOmega)
    local gearboxTorque = safeLoadNumber("ngp_gearbox_p3_output_torque_nm", 0.0)
    local drivetrainLoad = safeLoadNumber("ngp_drivetrain_diff_input_torque_nm", 0.0)
    if abs(drivetrainLoad) <= 0.0001 then
        drivetrainLoad = safeLoadNumber("ngp_diff_input_torque_nm", 0.0)
    end

    local wheelOmega, wheelLinked = readWheelOmega(car)
    state.linkedGearbox = safeLoadRaw("ngp_gearbox_p3_output_omega") ~= nil
    state.linkedDrivetrain = safeLoadRaw("ngp_drivetrain_diff_input_torque_nm") ~= nil
    state.linkedWheels = wheelLinked

    state.gearboxOutputOmega = clamp(gearboxOmega, -M.params.maxOmega, M.params.maxOmega)
    state.gearboxOutputTorqueNm = clamp(gearboxTorque, -M.params.maxTorque, M.params.maxTorque)
    state.drivetrainLoadTorqueNm = clamp(drivetrainLoad, -M.params.maxTorque, M.params.maxTorque)
    state.wheelOmega = clamp(wheelOmega, -M.params.maxOmega, M.params.maxOmega)

    local prevInput = state.inputOmega
    local prevOutput = state.outputOmega

    -- P04 input is the explicit P03 gearbox output shaft state.
    state.inputOmega = lowPass(state.inputOmega, state.gearboxOutputOmega, 0.018, dt)

    -- The output shaft is a dynamic state, not a direct copy of wheel speed.
    -- Wheel speed is only a weak anchor so the shaft can accumulate/release twist.
    local wheelAnchor = state.outputOmega
    if wheelLinked then
        wheelAnchor = lowPass(state.outputOmega, state.wheelOmega, M.params.wheelAnchorTau, dt)
    end

    state.outputOmega = lowPass(state.outputOmega, wheelAnchor, 0.020, dt)

    local prevTwist = state.twistRad
    state.twistRad = clamp(state.inputOmega - state.outputOmega, -M.params.maxTwistRad, M.params.maxTwistRad)
    state.twistRate = (state.twistRad - prevTwist) / math.max(dt, M.params.minDt)

    local insideLash = abs(state.twistRad) <= M.params.backlashRad
    if insideLash then
        state.backlash = lowPass(state.backlash, 1.0, 0.035, dt)
        state.engaged = false
    else
        local target = clamp((abs(state.twistRad) - M.params.backlashRad) /
            math.max(M.params.backlashRad, 0.0001), 0.0, 1.0)
        state.backlash = lowPass(state.backlash, 1.0 - target, 0.025, dt)
        state.engaged = true
    end

    local engage = 1.0 - clamp(state.backlash, 0.0, 1.0)
    local torsion = M.params.shaftStiffnessNmPerRad * state.twistRad * engage
    local damping = M.params.shaftDampingNmPerRadS * state.twistRate * engage
    local loss = M.params.shaftLossNmPerRadS * state.outputOmega

    state.torsionTorqueNm = clamp(torsion, -M.params.maxTorque, M.params.maxTorque)
    state.dampingTorqueNm = clamp(damping, -M.params.maxTorque, M.params.maxTorque)

    -- The wheel-side load opposes the shaft. P04 does not inject this torque
    -- into AC; it exposes the reaction needed by P03/P05 closed-loop stages.
    local reaction = state.torsionTorqueNm + state.dampingTorqueNm
    local loadReaction = state.drivetrainLoadTorqueNm * (1.0 - M.params.efficiency)
    reaction = reaction + loadReaction
    state.reactionTorqueNm = clamp(lowPass(state.reactionTorqueNm, reaction, M.params.reactionFilterTau, dt),
        -M.params.maxTorque, M.params.maxTorque)

    local driveTorque = state.gearboxOutputTorqueNm * M.params.efficiency
    if state.engaged then
        driveTorque = driveTorque - state.reactionTorqueNm
    else
        driveTorque = 0.0
    end
    state.transmittedTorqueNm = clamp(lowPass(state.transmittedTorqueNm, driveTorque,
        M.params.torqueFilterTau, dt), -M.params.maxTorque, M.params.maxTorque)
    state.shaftTorqueNm = state.transmittedTorqueNm
    state.loadTorqueNm = state.drivetrainLoadTorqueNm

    -- P04's output angular state receives a small inertial response from the
    -- transmitted torque. This is deliberately conservative until P05 closes
    -- the wheel-side reaction loop.
    local accel = (state.transmittedTorqueNm - state.drivetrainLoadTorqueNm - loss) /
        math.max(M.params.shaftInertiaKgM2, 0.001)
    state.outputOmega = clamp(state.outputOmega + accel * dt, -M.params.maxOmega, M.params.maxOmega)

    state.inputOmegaRate = clamp((state.inputOmega - prevInput) / math.max(dt, M.params.minDt), -10000.0, 10000.0)
    state.outputOmegaRate = clamp((state.outputOmega - prevOutput) / math.max(dt, M.params.minDt), -10000.0, 10000.0)

    local twistCrossed = (prevTwist > M.params.backlashRad and state.twistRad < -M.params.backlashRad)
        or (prevTwist < -M.params.backlashRad and state.twistRad > M.params.backlashRad)
    if twistCrossed then
        state.backlashShock = math.min(1.0, state.backlashShock + M.params.backlashShockGain)
    end
    state.backlashShock = math.max(0.0, state.backlashShock - dt * 5.0)

    state.status = "RUNNING"
    state.exportTimer = state.exportTimer + dt
    if state.exportTimer >= M.params.exportInterval then
        state.exportTimer = 0.0
    end
    exportState()
end

function M.getReactionTorque() return state.reactionTorqueNm or 0.0 end
function M.getTransmittedTorque() return state.transmittedTorqueNm or 0.0 end
function M.getTwist() return state.twistRad or 0.0 end
function M.getOutputOmega() return state.outputOmega or 0.0 end
function M.getState() return state end

return M
