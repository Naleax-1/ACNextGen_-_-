---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- differential_angular.lua
-- Prototype-05 / Differential Angular Reaction
--
-- Design basis: ACNextGen Prototype development report.
-- P05 sits between the P04 driveline state and the rear wheel pair.
-- It models the differential's angular state and torque allocation
-- without directly overwriting Assetto Corsa wheel physics.
--
-- IMPORTANT:
--   This is deliberately a bridge/physical observer at this stage.
--   The existing diff_lsd.lua remains the authority for LSD lock
--   configuration and its measured/estimated lock state.
--============================================================

local M = {}

M.params = {
    halfShaftInertiaKgM2 = 0.018,
    differentialInertiaKgM2 = 0.012,
    shaftStiffnessNmPerRad = 260.0,
    shaftDampingNmPerRadS = 6.0,
    wheelSyncTau = 0.035,
    torqueTau = 0.025,
    reactionTau = 0.040,

    openSplit = 0.50,
    maxInputTorqueNm = 12000.0,
    maxLockTorqueNm = 5000.0,
    maxReactionTorqueNm = 12000.0,

    lockUse = 0.90,
    lockTorqueFloorNm = 0.0,
    coastLockScale = 0.85,

    minDt = 0.0005,
    maxDt = 0.050,
    debugStoreInterval = 0.10,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,

    inputOmega = 0.0,
    carrierOmega = 0.0,
    omegaL = 0.0,
    omegaR = 0.0,
    omegaLState = 0.0,
    omegaRState = 0.0,
    omegaDiff = 0.0,
    omegaDiffFiltered = 0.0,

    inputTorqueNm = 0.0,
    transmittedTorqueNm = 0.0,
    openTorqueLNm = 0.0,
    openTorqueRNm = 0.0,
    lockTorqueNm = 0.0,
    lockCorrectionNm = 0.0,
    wheelTorqueLNm = 0.0,
    wheelTorqueRNm = 0.0,

    reactionTorqueNm = 0.0,
    wheelReactionNm = 0.0,
    carrierReactionNm = 0.0,
    torqueImbalanceNm = 0.0,

    lockRatio = 0.0,
    lockTarget = 0.0,
    lockSource = "NONE",
    mode = "COAST",
    signedTorque = 0.0,

    linkedP04 = false,
    linkedLSD = false,
    linkedWheels = false,
    exportTimer = 0.0,
}

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

local function abs(v)
    v = num(v, 0.0)
    return v < 0.0 and -v or v
end

local function sign(v)
    v = num(v, 0.0)
    if v > 0.000001 then return 1.0 end
    if v < -0.000001 then return -1.0 end
    return 0.0
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
    local n = tonumber(safeLoadRaw(key))
    if n ~= nil and n == n then return n end
    return fallback
end

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, value) end)
end

local function lowPass(current, target, tau, dt)
    tau = math.max(num(tau, 0.01), 0.0001)
    dt = math.max(num(dt, 0.001), 0.0001)
    local a = clamp(dt / (tau + dt), 0.0, 1.0)
    return num(current, 0.0) + (num(target, 0.0) - num(current, 0.0)) * a
end

local function readRearWheelOmega(car)
    local wheels = car and safeField(car, "wheels", nil)
    if not wheels then return nil, nil end

    local wl = wheels[2]
    local wr = wheels[3]
    local ol = wl and tonumber(safeField(wl, "angularSpeed", nil)) or nil
    local orr = wr and tonumber(safeField(wr, "angularSpeed", nil)) or nil

    if ol == nil then ol = safeLoadNumber("ngp_lsd_omega_l", nil) end
    if orr == nil then orr = safeLoadNumber("ngp_lsd_omega_r", nil) end
    if ol == nil or orr == nil then return nil, nil end

    return ol, orr
end

local function exportState()
    safeStore("ngp_diff_p5_input_omega", state.inputOmega)
    safeStore("ngp_diff_p5_carrier_omega", state.carrierOmega)
    safeStore("ngp_diff_p5_omega_l", state.omegaLState)
    safeStore("ngp_diff_p5_omega_r", state.omegaRState)
    safeStore("ngp_diff_p5_omega_diff", state.omegaDiff)
    safeStore("ngp_diff_p5_omega_diff_filtered", state.omegaDiffFiltered)

    safeStore("ngp_diff_p5_input_torque_nm", state.inputTorqueNm)
    safeStore("ngp_diff_p5_transmitted_torque_nm", state.transmittedTorqueNm)
    safeStore("ngp_diff_p5_open_torque_l_nm", state.openTorqueLNm)
    safeStore("ngp_diff_p5_open_torque_r_nm", state.openTorqueRNm)
    safeStore("ngp_diff_p5_lock_torque_nm", state.lockTorqueNm)
    safeStore("ngp_diff_p5_lock_correction_nm", state.lockCorrectionNm)
    safeStore("ngp_diff_p5_wheel_torque_l_nm", state.wheelTorqueLNm)
    safeStore("ngp_diff_p5_wheel_torque_r_nm", state.wheelTorqueRNm)

    safeStore("ngp_diff_p5_reaction_torque_nm", state.reactionTorqueNm)
    safeStore("ngp_diff_p5_wheel_reaction_nm", state.wheelReactionNm)
    safeStore("ngp_diff_p5_carrier_reaction_nm", state.carrierReactionNm)
    safeStore("ngp_diff_p5_torque_imbalance_nm", state.torqueImbalanceNm)

    safeStore("ngp_diff_p5_lock_ratio", state.lockRatio)
    safeStore("ngp_diff_p5_lock_target", state.lockTarget)
    safeStore("ngp_diff_p5_signed_torque", state.signedTorque)
    safeStore("ngp_diff_p5_link_p04", state.linkedP04 and 1 or 0)
    safeStore("ngp_diff_p5_link_lsd", state.linkedLSD and 1 or 0)
    safeStore("ngp_diff_p5_link_wheels", state.linkedWheels and 1 or 0)
    safeStore("ngp_diff_p5_status", state.status)
    safeStore("ngp_diff_p5_mode", state.mode)
    safeStore("ngp_diff_p5_lock_source", state.lockSource)
    safeStore("ngp_diff_p5_update_count", state.updateCount)
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

    local p04Omega = safeLoadNumber("ngp_driveline_p4_output_omega", state.carrierOmega)
    local p04Torque = safeLoadNumber("ngp_driveline_p4_transmitted_torque_nm", 0.0)
    local p04Reaction = safeLoadNumber("ngp_driveline_p4_reaction_torque_nm", 0.0)

    local lsdLock = safeLoadNumber("ngp_lsd_lock", nil)
    local lsdLockTorque = safeLoadNumber("ngp_lsd_lock_torque_nm", nil)
    local lsdDiff = safeLoadNumber("ngp_lsd_sdiff_filtered", nil)
    if lsdDiff == nil then lsdDiff = safeLoadNumber("ngp_lsd_sdiff", 0.0) end

    local ol, orr = readRearWheelOmega(car)
    state.linkedP04 = safeLoadRaw("ngp_driveline_p4_output_omega") ~= nil
    state.linkedLSD = lsdLock ~= nil or lsdLockTorque ~= nil
    state.linkedWheels = ol ~= nil and orr ~= nil

    if ol == nil or orr == nil then
        ol = state.omegaLState
        orr = state.omegaRState
    end

    state.inputOmega = clamp(p04Omega, -2500.0, 2500.0)
    state.transmittedTorqueNm = clamp(p04Torque, -M.params.maxInputTorqueNm, M.params.maxInputTorqueNm)
    state.omegaL = clamp(num(ol, 0.0), -2500.0, 2500.0)
    state.omegaR = clamp(num(orr, 0.0), -2500.0, 2500.0)

    state.omegaLState = lowPass(state.omegaLState, state.omegaL, M.params.wheelSyncTau, dt)
    state.omegaRState = lowPass(state.omegaRState, state.omegaR, M.params.wheelSyncTau, dt)
    state.omegaDiff = state.omegaLState - state.omegaRState
    state.omegaDiffFiltered = lowPass(state.omegaDiffFiltered, state.omegaDiff, 0.045, dt)

    state.carrierOmega = lowPass(state.carrierOmega,
        (state.omegaLState + state.omegaRState) * 0.5,
        0.025, dt)

    state.lockRatio = clamp(num(lsdLock, 0.0), 0.0, 1.0)
    state.lockTarget = state.lockRatio
    state.lockSource = lsdLock ~= nil and "LSD" or "DEFAULT"

    local input = state.transmittedTorqueNm
    state.signedTorque = sign(input)
    state.mode = input >= 0.0 and "POWER" or "COAST"

    local split = clamp(M.params.openSplit, 0.0, 1.0)
    state.openTorqueLNm = input * split
    state.openTorqueRNm = input * (1.0 - split)

    -- Prefer the physical lock torque capacity already computed by diff_lsd.lua.
    -- If it is unavailable, derive a conservative capacity from lock ratio.
    local lockCapacity = num(lsdLockTorque, 0.0)
    if lockCapacity <= M.params.lockTorqueFloorNm then
        lockCapacity = abs(input) * state.lockRatio * M.params.lockUse
    else
        lockCapacity = lockCapacity * M.params.lockUse
    end

    if state.mode == "COAST" then
        lockCapacity = lockCapacity * M.params.coastLockScale
    end

    lockCapacity = clamp(lockCapacity, 0.0, math.min(M.params.maxLockTorqueNm, abs(input) * 0.5))

    -- A positive omega difference means the left wheel is faster.
    -- The differential transfers torque toward the slower side.
    local correction = -sign(state.omegaDiffFiltered) * lockCapacity
    correction = correction * state.signedTorque
    state.lockTorqueNm = lockCapacity
    state.lockCorrectionNm = correction

    state.wheelTorqueLNm = state.openTorqueLNm + correction
    state.wheelTorqueRNm = state.openTorqueRNm - correction

    -- The carrier reaction is the sum of the two wheel torque paths.
    -- P04 reaction remains part of the upstream closed-loop estimate.
    local wheelSum = state.wheelTorqueLNm + state.wheelTorqueRNm
    state.carrierReactionNm = lowPass(state.carrierReactionNm,
        wheelSum - input,
        M.params.reactionTau, dt)

    -- Approximate wheel-side resistance from the differential's own measured
    -- locking demand. This is an exported reaction signal for P06.
    local measuredLockResistance = safeLoadNumber("ngp_lsd_resist_torque_nm", 0.0)
    local p06Reaction = safeLoadNumber("ngp_wheel_p6_reaction_rear_nm", nil)
    local wheelResistance = abs(measuredLockResistance)
    if p06Reaction ~= nil then
        wheelResistance = wheelResistance + abs(p06Reaction)
    end
    wheelResistance = wheelResistance + abs(p04Reaction) * 0.0
    if wheelResistance > M.params.maxReactionTorqueNm then
        wheelResistance = M.params.maxReactionTorqueNm
    end
    state.wheelReactionNm = lowPass(state.wheelReactionNm,
        wheelResistance,
        M.params.reactionTau, dt)

    state.reactionTorqueNm = clamp(
        lowPass(state.reactionTorqueNm,
            state.carrierReactionNm + state.wheelReactionNm,
            M.params.reactionTau, dt),
        -M.params.maxReactionTorqueNm,
        M.params.maxReactionTorqueNm)

    state.torqueImbalanceNm = state.wheelTorqueLNm - state.wheelTorqueRNm
    state.status = (state.linkedP04 and state.linkedLSD and state.linkedWheels) and "RUNNING" or "PARTIAL LINK"

    state.exportTimer = state.exportTimer + dt
    if state.exportTimer >= M.params.debugStoreInterval then
        state.exportTimer = 0.0
    end

    -- Bridge keys for P06 / future reaction loop.
    safeStore("ngp_diff_reaction_torque_nm", state.reactionTorqueNm)
    safeStore("ngp_diff_wheel_torque_l_nm", state.wheelTorqueLNm)
    safeStore("ngp_diff_wheel_torque_r_nm", state.wheelTorqueRNm)
    safeStore("ngp_diff_carrier_omega", state.carrierOmega)
    safeStore("ngp_diff_wheel_omega_l", state.omegaLState)
    safeStore("ngp_diff_wheel_omega_r", state.omegaRState)

    exportState()
end

function M.getReactionTorque() return state.reactionTorqueNm or 0.0 end
function M.getWheelTorqueL() return state.wheelTorqueLNm or 0.0 end
function M.getWheelTorqueR() return state.wheelTorqueRNm or 0.0 end
function M.getLockRatio() return state.lockRatio or 0.0 end
function M.getState() return state end

return M
