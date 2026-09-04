---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- turbo_prototype.lua
-- Prototype-08 / Generic Turbocharger Physical Model
--
-- Design intent:
--   Exhaust energy -> turbine -> shaft inertia -> compressor -> boost
--   -> engine torque multiplier.
--
-- This is deliberately architecture-agnostic. It can operate as a
-- conservative virtual turbo when a car exposes boost/configuration data,
-- while naturally collapsing to 1.0 torque multiplier on NA cars.
-- It does not overwrite AC boost or engine RPM.
--============================================================

local M = {}

M.params = {
    defaultEnabled = false,
    defaultMaxBoostBar = 0.85,
    defaultSpoolRpm = 3600.0,
    defaultFullBoostRpm = 5200.0,
    defaultSpoolTau = 0.28,
    defaultResponseTau = 0.08,
    defaultCompressorEfficiency = 0.72,
    defaultTurbineEfficiency = 0.68,
    defaultInertia = 0.0035,
    defaultWastegateStartBar = 0.72,
    defaultWastegateGain = 2.8,
    defaultBoostTorqueGain = 0.72,
    defaultThrottleLag = 0.035,
    defaultExhaustEnergyGain = 1.0,
    defaultAmbientBar = 1.01325,
    minBoostBar = 0.0,
    maxBoostBar = 2.50,
    maxTurboOmega = 180000.0,
    minDt = 0.0005,
    maxDt = 0.050,
}

local state = {
    initialized = false,
    status = "INIT",
    updateCount = 0,
    carId = "",
    enabled = false,
    configSource = "default-disabled",
    turboFile = "",

    rpm = 0.0,
    throttle = 0.0,
    boostBar = 0.0,
    manifoldPressureBar = 1.01325,
    targetBoostBar = 0.0,
    wastegate = 0.0,
    spool = 0.0,
    shaftOmega = 0.0,
    shaftRpm = 0.0,
    compressorEfficiency = 0.72,
    turbineEfficiency = 0.68,
    turbineTorqueNm = 0.0,
    compressorTorqueNm = 0.0,
    shaftNetTorqueNm = 0.0,
    boostTorqueMultiplier = 1.0,
    lagState = 0.0,
    measuredBoostBar = 0.0,
    measuredBoostValid = false,

    maxBoostBar = 0.85,
    spoolRpm = 3600.0,
    fullBoostRpm = 5200.0,
    spoolTau = 0.28,
    responseTau = 0.08,
    inertia = 0.0035,
    wastegateStartBar = 0.72,
    wastegateGain = 2.8,
    boostTorqueGain = 0.72,
    throttleLag = 0.035,
    ambientBar = 1.01325,
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
    safeStore(key, tostring(value or ""))
end

local function safeGetCarConfig(section, key, defaultValue)
    if not ac or not ac.getCarConfig then return defaultValue end
    local ok, value = pcall(function() return ac.getCarConfig(0, section, key, defaultValue) end)
    if ok and value ~= nil then return value end
    return defaultValue
end

local function safeGetFolder(folderId)
    if not ac or not ac.getFolder or folderId == nil then return nil end
    local ok, value = pcall(function() return ac.getFolder(folderId) end)
    if ok and value ~= nil then return tostring(value) end
    return nil
end

local function joinPath(a, b)
    if not a or a == "" then return tostring(b or "") end
    local s = tostring(a):gsub("\\", "/")
    if s:sub(-1) == "/" then return s .. tostring(b or "") end
    return s .. "/" .. tostring(b or "")
end

local function getCarId()
    if ac and ac.getCarID then
        local ok, value = pcall(function() return ac.getCarID(0) end)
        if ok and value ~= nil then
            local id = tostring(value):gsub("\\", "/")
            return id:match("([^/]+)$") or id
        end
    end
    return ""
end

local function readTextFile(path)
    if not io or not io.open or not path or path == "" then return nil end
    local ok, content = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if ok then return content end
    return nil
end

local function trim(v)
    local s = tostring(v or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function stripComment(v)
    local s = tostring(v or "")
    local p1, p2 = s:find(";", 1, true), s:find("#", 1, true)
    local p
    if p1 and p2 then p = math.min(p1, p2) else p = p1 or p2 end
    if p then s = s:sub(1, p - 1) end
    return trim(s)
end

local function parseIni(text)
    local ini, section = {}, ""
    if not text then return ini end
    for line in tostring(text):gmatch("[^\r\n]+") do
        local clean = stripComment(line)
        if clean ~= "" then
            local sec = clean:match("^%[([^%]]+)%]$")
            if sec then
                section = trim(sec):upper()
                ini[section] = ini[section] or {}
            else
                local key, value = clean:match("^([^=]+)=(.*)$")
                if key and value and section ~= "" then
                    ini[section] = ini[section] or {}
                    ini[section][trim(key):upper()] = trim(value)
                end
            end
        end
    end
    return ini
end

local function iniNumber(ini, section, key, fallback)
    section, key = tostring(section):upper(), tostring(key):upper()
    local value = ini and ini[section] and ini[section][key]
    local n = tonumber(value)
    return n or fallback
end

local function safePathCandidates(carId)
    local out = {}
    if carId == "" then return out end
    if ac and ac.FolderID then
        local cars = safeGetFolder(ac.FolderID.ContentCars)
        if cars then out[#out + 1] = joinPath(joinPath(cars, carId), "data/turbo.ini") end
        local root = safeGetFolder(ac.FolderID.Root or ac.FolderID.AC or ac.FolderID.AssettoCorsa)
        if root then out[#out + 1] = joinPath(joinPath(joinPath(joinPath(root, "content"), "cars"), carId), "data/turbo.ini") end
    end
    out[#out + 1] = joinPath(joinPath("content/cars", carId), "data/turbo.ini")
    out[#out + 1] = joinPath(joinPath("../content/cars", carId), "data/turbo.ini")
    out[#out + 1] = joinPath(joinPath("../../content/cars", carId), "data/turbo.ini")
    return out
end

local function loadConfig()
    state.carId = getCarId()
    state.enabled = M.params.defaultEnabled
    state.configSource = M.params.defaultEnabled and "default-enabled" or "default-disabled"
    state.turboFile = ""
    state.maxBoostBar = M.params.defaultMaxBoostBar
    state.spoolRpm = M.params.defaultSpoolRpm
    state.fullBoostRpm = M.params.defaultFullBoostRpm
    state.spoolTau = M.params.defaultSpoolTau
    state.responseTau = M.params.defaultResponseTau
    state.inertia = M.params.defaultInertia
    state.wastegateStartBar = M.params.defaultWastegateStartBar
    state.wastegateGain = M.params.defaultWastegateGain
    state.boostTorqueGain = M.params.defaultBoostTorqueGain
    state.compressorEfficiency = M.params.defaultCompressorEfficiency
    state.turbineEfficiency = M.params.defaultTurbineEfficiency
    state.ambientBar = M.params.defaultAmbientBar

    -- Prefer an explicit turbo.ini if the car provides one.
    local candidates = safePathCandidates(state.carId)
    for i = 1, #candidates do
        local text = readTextFile(candidates[i])
        if text and text ~= "" then
            local ini = parseIni(text)
            local sec = ini.TURBO or ini.TURBOCHARGER or ini.TURBO_DATA or {}
            state.maxBoostBar = clamp(iniNumber(ini, "TURBO", "MAX_BOOST", iniNumber(ini, "TURBO_DATA", "MAX_BOOST", state.maxBoostBar)), 0.0, M.params.maxBoostBar)
            state.spoolRpm = math.max(iniNumber(ini, "TURBO", "REFERENCE_RPM", iniNumber(ini, "TURBO_DATA", "REFERENCE_RPM", state.spoolRpm)), 500.0)
            state.fullBoostRpm = math.max(iniNumber(ini, "TURBO", "FULL_BOOST_RPM", state.fullBoostRpm), state.spoolRpm + 100.0)
            state.spoolTau = math.max(iniNumber(ini, "TURBO", "LAG_DN", state.spoolTau), 0.01)
            state.responseTau = math.max(iniNumber(ini, "TURBO", "LAG_UP", state.responseTau), 0.01)
            state.wastegateStartBar = clamp(iniNumber(ini, "TURBO", "WASTEGATE_START", state.wastegateStartBar), 0.0, state.maxBoostBar)
            state.compressorEfficiency = clamp(iniNumber(ini, "TURBO", "COMPRESSOR_EFFICIENCY", state.compressorEfficiency), 0.20, 1.0)
            state.turbineEfficiency = clamp(iniNumber(ini, "TURBO", "TURBINE_EFFICIENCY", state.turbineEfficiency), 0.20, 1.0)
            state.inertia = math.max(iniNumber(ini, "TURBO", "INERTIA", state.inertia), 0.0001)
            state.enabled = true
            state.configSource = "turbo.ini"
            state.turboFile = candidates[i]
            return
        end
    end

    -- A live AC/CSP turbo signal is enough to enable the observer model.
    -- We do not assume a turbo exists merely because the key is absent.
    state.configSource = "runtime-detect"
end

local function readMeasuredBoost(car)
    local keys = { "turboBoost", "turbo_boost", "boost", "boostPressure" }
    for i = 1, #keys do
        local v = tonumber(safeField(car, keys[i], nil))
        if v ~= nil then
            -- Heuristic: values above 3 are usually kPa-like or mbar-like;
            -- values in the 0..3 range are treated as bar gauge.
            if v > 30.0 then v = v / 100.0 end
            if v > 3.0 then v = v / 100.0 end
            return clamp(v, -0.20, M.params.maxBoostBar), true
        end
    end
    return 0.0, false
end

local function lowPass(current, target, dt, tau)
    local a = clamp(dt / (math.max(tau, 0.0001) + dt), 0.0, 1.0)
    return current + (target - current) * a
end

local function updateVirtualTurbo(dt, car)
    local rpm = math.max(num(safeField(car, "rpm", 0.0), 0.0), 0.0)
    local throttle = clamp(num(safeField(car, "gas", 0.0), 0.0), 0.0, 1.0)
    state.rpm = rpm
    state.throttle = throttle

    local measured, valid = readMeasuredBoost(car)
    state.measuredBoostBar = measured
    state.measuredBoostValid = valid

    -- If the runtime explicitly reports boost, use it as an observation, not
    -- as a command. It keeps the virtual state close to the car while leaving
    -- the model responsible for the lag/spool behavior.
    if valid then
        state.enabled = true
        state.configSource = "runtime-boost"
    end

    if not state.enabled then
        state.boostBar = 0.0
        state.targetBoostBar = 0.0
        state.spool = 0.0
        state.wastegate = 0.0
        state.shaftOmega = 0.0
        state.shaftRpm = 0.0
        state.turbineTorqueNm = 0.0
        state.compressorTorqueNm = 0.0
        state.shaftNetTorqueNm = 0.0
        state.boostTorqueMultiplier = 1.0
        state.status = "NA/IDLE"
        return
    end

    local rpmSpan = math.max(state.fullBoostRpm - state.spoolRpm, 500.0)
    local rpmSpool = clamp((rpm - state.spoolRpm) / rpmSpan, 0.0, 1.0)
    local exhaustDemand = clamp(throttle * (0.25 + 0.75 * rpmSpool), 0.0, 1.0)

    -- Target boost is constrained by a simple wastegate model.
    local rawTarget = state.maxBoostBar * exhaustDemand
    local preGate = clamp((rawTarget - state.wastegateStartBar) * state.wastegateGain, 0.0, 1.0)
    state.wastegate = preGate
    rawTarget = rawTarget * (1.0 - 0.85 * state.wastegate)
    state.targetBoostBar = clamp(rawTarget, 0.0, state.maxBoostBar)

    -- Shaft dynamics: turbine energy accelerates the turbo; compressor demand
    -- opposes it. The constants are normalized so the state remains stable at
    -- game-scale timesteps rather than pretending to be a CFD model.
    local turbineDemand = exhaustDemand * (0.35 + 0.65 * rpmSpool) * state.turbineEfficiency
    local compressorDemand = clamp(state.boostBar / math.max(state.maxBoostBar, 0.05), 0.0, 1.0) * (0.35 + 0.65 * throttle) / math.max(state.compressorEfficiency, 0.2)

    state.turbineTorqueNm = turbineDemand * 0.045
    state.compressorTorqueNm = compressorDemand * 0.038
    state.shaftNetTorqueNm = state.turbineTorqueNm - state.compressorTorqueNm
    state.shaftOmega = clamp(state.shaftOmega + (state.shaftNetTorqueNm / math.max(state.inertia, 0.0001)) * dt, 0.0, M.params.maxTurboOmega)
    state.shaftRpm = state.shaftOmega * 60.0 / (2.0 * math.pi)

    local shaftSpool = clamp(state.shaftOmega / 90000.0, 0.0, 1.0)
    state.spool = lowPass(state.spool, math.max(rpmSpool, shaftSpool), dt, state.spoolTau)

    local dynamicTarget = state.targetBoostBar * state.spool
    if valid then
        dynamicTarget = lowPass(dynamicTarget, math.max(measured, 0.0), dt, state.responseTau)
    end
    state.boostBar = lowPass(state.boostBar, dynamicTarget, dt, state.responseTau)
    state.boostBar = clamp(state.boostBar, 0.0, state.maxBoostBar)
    state.manifoldPressureBar = state.ambientBar + state.boostBar

    -- Translate gauge boost into a torque multiplier. This is intentionally
    -- sub-linear: more boost adds torque, but does not create infinite torque.
    local pressureRatio = state.manifoldPressureBar / math.max(state.ambientBar, 0.5)
    local boostGain = clamp((pressureRatio - 1.0) * state.boostTorqueGain, 0.0, 2.0)
    state.boostTorqueMultiplier = 1.0 + boostGain
    state.boostTorqueMultiplier = clamp(state.boostTorqueMultiplier, 1.0, 1.0 + 2.0 * state.boostTorqueGain)
    state.status = "RUNNING"
end

local function exportState()
    safeStore("ngp_engine_p8_enabled", state.enabled and 1 or 0)
    safeStore("ngp_engine_p8_boost_bar", state.boostBar)
    safeStore("ngp_engine_p8_target_boost_bar", state.targetBoostBar)
    safeStore("ngp_engine_p8_manifold_pressure_bar", state.manifoldPressureBar)
    safeStore("ngp_engine_p8_shaft_rpm", state.shaftRpm)
    safeStore("ngp_engine_p8_shaft_omega", state.shaftOmega)
    safeStore("ngp_engine_p8_spool", state.spool)
    safeStore("ngp_engine_p8_wastegate", state.wastegate)
    safeStore("ngp_engine_p8_turbine_torque_nm", state.turbineTorqueNm)
    safeStore("ngp_engine_p8_compressor_torque_nm", state.compressorTorqueNm)
    safeStore("ngp_engine_p8_shaft_net_torque_nm", state.shaftNetTorqueNm)
    safeStore("ngp_engine_p8_torque_multiplier", state.boostTorqueMultiplier)
    safeStore("ngp_engine_p8_measured_boost_bar", state.measuredBoostBar)
    safeStore("ngp_engine_p8_measured_boost_valid", state.measuredBoostValid and 1 or 0)
    safeStore("ngp_engine_p8_max_boost_bar", state.maxBoostBar)
    safeStore("ngp_engine_p8_inertia", state.inertia)
    safeStore("ngp_engine_p8_update_count", state.updateCount)
    safeStoreString("ngp_engine_p8_status", state.status)
    safeStoreString("ngp_engine_p8_config_source", state.configSource)
    safeStoreString("ngp_engine_p8_turbo_file", state.turboFile)
end

function M.init()
    state.initialized = true
    state.updateCount = 0
    loadConfig()
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
    updateVirtualTurbo(dt, car)
    exportState()
end

function M.getTorqueMultiplier()
    return state.boostTorqueMultiplier or 1.0
end

function M.getState()
    return state
end

return M
