---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- wheel_tire_reaction.lua
-- Prototype-06 / Wheel-Tire Reaction
--
-- Design basis: ACNextGen Prototype development report.
-- P06 closes the first useful mechanical reaction path from the
-- tire contact patch back toward the driveline.
--
-- This module is intentionally OBSERVER/BRIDGE ONLY:
--   Tire longitudinal force -> wheel reaction torque
--   Wheel angular speed -> rotational power / slip diagnostics
--   Reaction torque -> P05 Differential / future P04 Driveline
--
-- It does NOT overwrite Assetto Corsa wheel physics.
--============================================================

local M = {}

M.params = {
    drivenWheelFL = false,
    drivenWheelFR = false,
    drivenWheelRL = true,
    drivenWheelRR = true,

    defaultRadiusM = 0.32,
    minRadiusM = 0.10,
    maxRadiusM = 0.60,

    forceTau = 0.018,
    reactionTau = 0.030,
    omegaTau = 0.020,

    maxReactionTorqueNm = 12000.0,
    maxForceN = 30000.0,
    minDt = 0.0005,
    maxDt = 0.050,

    debugStoreInterval = 0.10,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,

    wheel = {},
    drivenCount = 0,

    frontReactionNm = 0.0,
    rearReactionNm = 0.0,
    totalReactionNm = 0.0,
    rearSignedReactionNm = 0.0,
    rearPowerW = 0.0,

    linkedTireForce = false,
    linkedWheelAPI = false,
    linkedP05 = false,
    exportTimer = 0.0,
}

for i = 0, 3 do
    state.wheel[i] = {
        index = i,
        driven = false,
        radiusM = M.params.defaultRadiusM,
        omega = 0.0,
        omegaState = 0.0,
        longitudinalForceN = 0.0,
        forceStateN = 0.0,
        reactionTorqueNm = 0.0,
        signedReactionTorqueNm = 0.0,
        tractionTorqueNm = 0.0,
        rotationalPowerW = 0.0,
        slipPowerW = 0.0,
        status = "INIT",
    }
end

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

local function getWheel(car, index)
    local wheels = car and safeField(car, "wheels", nil)
    if not wheels then return nil end
    return wheels[index]
end

local function readWheelRadius(wheel)
    local r = safeField(wheel, "tyreRadius", nil)
    if r == nil then r = safeField(wheel, "tireRadius", nil) end
    r = tonumber(r)
    if r == nil or r <= 0.0 then r = M.params.defaultRadiusM end
    return clamp(r, M.params.minRadiusM, M.params.maxRadiusM)
end

local function readWheelOmega(wheel, index)
    local omega = safeField(wheel, "angularSpeed", nil)
    if omega == nil then
        omega = safeLoadNumber("ngp_diff_p5_omega_" .. (index == 2 and "l" or index == 3 and "r" or "x"), nil)
    end
    return tonumber(omega)
end

local function readLongitudinalForce(index)
    local f = safeLoadNumber("ngp_tire_force_longitudinal_" .. index, nil)
    if f == nil then f = safeLoadNumber("ngp_tire_force_long_" .. index, nil) end
    return tonumber(f)
end

local function isDriven(index)
    if index == 0 then return M.params.drivenWheelFL end
    if index == 1 then return M.params.drivenWheelFR end
    if index == 2 then return M.params.drivenWheelRL end
    if index == 3 then return M.params.drivenWheelRR end
    return false
end

local function exportWheel(index, w)
    local suffix = tostring(index)
    safeStore("ngp_wheel_p6_radius_m_" .. suffix, w.radiusM)
    safeStore("ngp_wheel_p6_omega_" .. suffix, w.omegaState)
    safeStore("ngp_wheel_p6_longitudinal_force_n_" .. suffix, w.forceStateN)
    safeStore("ngp_wheel_p6_reaction_torque_nm_" .. suffix, w.signedReactionTorqueNm)
    safeStore("ngp_wheel_p6_reaction_abs_nm_" .. suffix, w.reactionTorqueNm)
    safeStore("ngp_wheel_p6_traction_torque_nm_" .. suffix, w.tractionTorqueNm)
    safeStore("ngp_wheel_p6_rotational_power_w_" .. suffix, w.rotationalPowerW)
    safeStore("ngp_wheel_p6_slip_power_w_" .. suffix, w.slipPowerW)
    safeStore("ngp_wheel_p6_driven_" .. suffix, w.driven and 1 or 0)
end

local function exportState()
    for i = 0, 3 do exportWheel(i, state.wheel[i]) end

    safeStore("ngp_wheel_p6_reaction_front_nm", state.frontReactionNm)
    safeStore("ngp_wheel_p6_reaction_rear_nm", state.rearReactionNm)
    safeStore("ngp_wheel_p6_reaction_total_nm", state.totalReactionNm)
    safeStore("ngp_wheel_p6_reaction_rear_signed_nm", state.rearSignedReactionNm)
    safeStore("ngp_wheel_p6_rear_power_w", state.rearPowerW)
    safeStore("ngp_wheel_p6_driven_count", state.drivenCount)

    safeStore("ngp_wheel_p6_link_tire_force", state.linkedTireForce and 1 or 0)
    safeStore("ngp_wheel_p6_link_wheel_api", state.linkedWheelAPI and 1 or 0)
    safeStore("ngp_wheel_p6_link_p05", state.linkedP05 and 1 or 0)
    safeStore("ngp_wheel_p6_status", state.status)
    safeStore("ngp_wheel_p6_update_count", state.updateCount)
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
    state.frontReactionNm = 0.0
    state.rearReactionNm = 0.0
    state.rearSignedReactionNm = 0.0
    state.rearPowerW = 0.0
    state.totalReactionNm = 0.0
    state.drivenCount = 0

    state.linkedTireForce = false
    state.linkedWheelAPI = false
    state.linkedP05 = safeLoadRaw("ngp_diff_p5_wheel_torque_l_nm") ~= nil

    for i = 0, 3 do
        local w = state.wheel[i]
        local wheel = getWheel(car, i)
        local radius = readWheelRadius(wheel)
        local omega = readWheelOmega(wheel, i)
        local force = readLongitudinalForce(i)

        if wheel ~= nil then state.linkedWheelAPI = true end
        if force ~= nil then state.linkedTireForce = true end

        w.driven = isDriven(i)
        if w.driven then state.drivenCount = state.drivenCount + 1 end
        w.radiusM = radius

        if omega == nil then omega = w.omegaState end
        if force == nil then force = 0.0 end

        omega = clamp(omega, -2500.0, 2500.0)
        force = clamp(force, -M.params.maxForceN, M.params.maxForceN)

        w.omega = omega
        w.omegaState = lowPass(w.omegaState, omega, M.params.omegaTau, dt)
        w.longitudinalForceN = force
        w.forceStateN = lowPass(w.forceStateN, force, M.params.forceTau, dt)

        -- Tire longitudinal force is the contact-patch force.  The
        -- corresponding signed wheel reaction is force * radius with the
        -- opposite sign convention to the drive torque.
        local signedReaction = -w.forceStateN * w.radiusM
        signedReaction = clamp(signedReaction, -M.params.maxReactionTorqueNm, M.params.maxReactionTorqueNm)

        w.signedReactionTorqueNm = lowPass(
            w.signedReactionTorqueNm,
            signedReaction,
            M.params.reactionTau,
            dt
        )
        w.reactionTorqueNm = abs(w.signedReactionTorqueNm)

        w.tractionTorqueNm = clamp(
            safeLoadNumber("ngp_tire_force_drive_torque_nm_" .. i, 0.0),
            -M.params.maxReactionTorqueNm,
            M.params.maxReactionTorqueNm
        )

        w.rotationalPowerW = w.signedReactionTorqueNm * w.omegaState
        w.slipPowerW = abs(w.forceStateN) * abs(w.omegaState * w.radiusM)

        if i <= 1 then
            state.frontReactionNm = state.frontReactionNm + w.signedReactionTorqueNm
        else
            state.rearReactionNm = state.rearReactionNm + w.reactionTorqueNm
            state.rearSignedReactionNm = state.rearSignedReactionNm + w.signedReactionTorqueNm
            state.rearPowerW = state.rearPowerW + w.rotationalPowerW
        end

        state.totalReactionNm = state.totalReactionNm + w.signedReactionTorqueNm
        w.status = (force ~= nil and wheel ~= nil) and "LINKED" or "PARTIAL"
    end

    -- P05 consumes the magnitude of the rear tire reaction as an upstream
    -- load estimate.  The signed value remains available for the future
    -- fully closed rotational loop.
    safeStore("ngp_wheel_p6_reaction_rear_nm", state.rearReactionNm)
    safeStore("ngp_wheel_p6_reaction_rear_signed_nm", state.rearSignedReactionNm)
    safeStore("ngp_wheel_p6_reaction_total_nm", state.totalReactionNm)

    if state.linkedWheelAPI and state.linkedTireForce then
        state.status = "RUNNING"
    elseif state.linkedWheelAPI or state.linkedTireForce then
        state.status = "PARTIAL LINK"
    else
        state.status = "WAITING FOR TIRE FORCE"
    end

    state.exportTimer = state.exportTimer + dt
    if state.exportTimer >= M.params.debugStoreInterval then
        state.exportTimer = 0.0
    end

    exportState()
end

function M.getRearReactionTorque() return state.rearReactionNm or 0.0 end
function M.getRearSignedReactionTorque() return state.rearSignedReactionNm or 0.0 end
function M.getTotalReactionTorque() return state.totalReactionNm or 0.0 end
function M.getState() return state end

return M
