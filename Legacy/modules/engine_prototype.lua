---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- engine_prototype.lua
-- Prototype-01 / Engine Physical Model
--
-- Design basis: ACNextGen Prototype-01 development report.
-- This module does NOT write car.rpm. It maintains a virtual engine
-- angular state and hands a torque signal to drivetrain.lua through
-- ac.store().
--============================================================

local M = {}

M.params = {
    authority = 0.35,

    inertiaDefault = 0.120,
    minimumRpm = 980.0,
    fallbackLimiter = 7250.0,

    throttleTau = 0.045,
    rpmSyncTau = 0.75,

    -- Conservative Prototype-01 loss model. These are implementation
    -- assumptions, not values claimed by the supplied design report.
    frictionTorqueNm = 14.0,
    frictionRpmGainNm = 0.0020,
    pumpingTorqueNm = 22.0,
    pumpingRpmGainNm = 0.0040,
    accessoryTorqueNm = 4.0,
    engineBrakeGain = 1.0,

    limiterStart = 0.985,
    limiterFullCut = 1.015,
    limiterCutTorque = 0.85,

    minDt = 0.0005,
    maxDt = 0.050,
    exportInterval = 0.10,
    waveformEnabled = true,
    waveformKey = "ngp_engine_p7_torque_multiplier",
    waveformDefault = 1.0,
    turboEnabled = true,
    turboKey = "ngp_engine_p8_torque_multiplier",
    turboDefault = 1.0,
}

local state = {
    status = "INIT",
    updateCount = 0,
    carId = "",

    rawRpm = 0.0,
    virtualRpm = 0.0,
    virtualOmega = 0.0,
    inertia = M.params.inertiaDefault,

    driverThrottle = 0.0,
    filteredThrottle = 0.0,

    baseCombustionTorqueNm = 0.0,
    frictionTorqueNm = 0.0,
    pumpingTorqueNm = 0.0,
    accessoryTorqueNm = 0.0,
    engineBrakeTorqueNm = 0.0,
    limiterTorqueNm = 0.0,
    netTorqueNm = 0.0,
    clutchReactionTorqueNm = 0.0,
    combustionWaveformMultiplier = 1.0,
    turboTorqueMultiplier = 1.0,
    thermalTorqueMultiplier = 1.0,

    redlineRpm = M.params.fallbackLimiter,
    minimumRpm = M.params.minimumRpm,
    peakTorqueNm = 0.0,

    powerLut = {},
    powerLutLoaded = false,
    powerLutName = "power.lut",
    configLoaded = false,
    configPath = "",
    lutPath = "",

    exportTimer = 0.0,
    initialized = false,
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

local function safeStore(key, value)
    if not ac or not ac.store then return end
    pcall(function() ac.store(key, value) end)
end

local function safeStoreString(key, value)
    safeStore(key, tostring(value or ""))
end

local function safeLoad(key, fallback)
    if not ac or not ac.load then return fallback end
    local ok, value = pcall(function() return ac.load(key) end)
    if ok and value ~= nil then return value end
    return fallback
end

local function safeLoadNumber(key, fallback)
    local value = safeLoad(key, fallback)
    local number = tonumber(value)
    if number ~= nil then return number end
    return fallback
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

local function trim(value)
    local s = tostring(value or "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function stripComment(value)
    local s = tostring(value or "")
    local p1 = s:find(";", 1, true)
    local p2 = s:find("#", 1, true)
    local p
    if p1 and p2 then p = math.min(p1, p2) else p = p1 or p2 end
    if p then s = s:sub(1, p - 1) end
    return trim(s)
end

local function parseIni(text)
    local ini = {}
    local section = ""
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

local function iniString(ini, section, key, defaultValue)
    section = tostring(section or ""):upper()
    key = tostring(key or ""):upper()
    if ini and ini[section] and ini[section][key] ~= nil then
        return tostring(ini[section][key])
    end
    return defaultValue
end

local function iniNumber(ini, section, key, defaultValue)
    local value = iniString(ini, section, key, nil)
    local n = tonumber(value)
    if n == nil then return defaultValue end
    return n
end

local function safeCarConfig(section, key, defaultValue)
    if not ac or not ac.getCarConfig then return defaultValue end
    local ok, value = pcall(function()
        return ac.getCarConfig(0, section, key, defaultValue)
    end)
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

local function buildCarPathCandidates(carId, relativePath)
    local candidates = {}
    if carId == "" then return candidates end

    if ac and ac.FolderID then
        local contentCars = safeGetFolder(ac.FolderID.ContentCars)
        if contentCars then
            candidates[#candidates + 1] = joinPath(joinPath(contentCars, carId), relativePath)
        end

        local root = safeGetFolder(ac.FolderID.Root or ac.FolderID.AC or ac.FolderID.AssettoCorsa)
        if root then
            candidates[#candidates + 1] = joinPath(joinPath(joinPath(joinPath(root, "content"), "cars"), carId), relativePath)
        end
    end

    candidates[#candidates + 1] = joinPath(joinPath("content/cars", carId), relativePath)
    candidates[#candidates + 1] = joinPath(joinPath("../content/cars", carId), relativePath)
    candidates[#candidates + 1] = joinPath(joinPath("../../content/cars", carId), relativePath)
    candidates[#candidates + 1] = joinPath(joinPath("../../../content/cars", carId), relativePath)

    return candidates
end

local function readFirstExisting(candidates)
    for i = 1, #candidates do
        local text = readTextFile(candidates[i])
        if text and text ~= "" then return text, candidates[i] end
    end
    return nil, ""
end

local function parsePowerLut(fileText)
    local points = {}
    if not fileText then return points end

    for line in tostring(fileText):gmatch("[^\r\n]+") do
        local clean = stripComment(line):gsub("|", " "):gsub(",", " ")
        local rpm, torque = clean:match("([%-%d%.]+)%s+([%-%d%.]+)")
        rpm = tonumber(rpm)
        torque = tonumber(torque)
        if rpm and torque then
            points[#points + 1] = { rpm = rpm, torque = torque }
        end
    end

    table.sort(points, function(a, b) return a.rpm < b.rpm end)
    return points
end

local function interpolatePowerLut(points, rpm)
    if not points or #points == 0 then return 0.0 end
    rpm = num(rpm, 0.0)

    if rpm <= points[1].rpm then return points[1].torque end
    local last = points[#points]
    if rpm >= last.rpm then return last.torque end

    for i = 1, #points - 1 do
        local a = points[i]
        local b = points[i + 1]
        if rpm >= a.rpm and rpm <= b.rpm then
            local span = math.max(b.rpm - a.rpm, 1.0)
            local t = clamp((rpm - a.rpm) / span, 0.0, 1.0)
            return a.torque + (b.torque - a.torque) * t
        end
    end

    return last.torque
end

local function loadConfig()
    local carId = getCarId()
    state.carId = carId
    state.configLoaded = false
    state.configPath = ""
    state.lutPath = ""
    state.powerLut = {}
    state.powerLutLoaded = false
    state.powerLutName = "power.lut"
    state.inertia = M.params.inertiaDefault
    state.redlineRpm = M.params.fallbackLimiter
    state.minimumRpm = M.params.minimumRpm
    state.peakTorqueNm = 0.0

    if carId == "" then
        state.configLoaded = true
        return
    end

    local engineText, enginePath = readFirstExisting(buildCarPathCandidates(carId, "data/engine.ini"))
    if engineText then
        local ini = parseIni(engineText)
        state.configPath = enginePath
        state.inertia = math.max(iniNumber(ini, "ENGINE_DATA", "INERTIA", state.inertia), 0.001)
        state.redlineRpm = math.max(
            iniNumber(ini, "ENGINE_DATA", "LIMITER", iniNumber(ini, "HEADER", "LIMITER", state.redlineRpm)),
            1000.0
        )
        state.minimumRpm = math.max(iniNumber(ini, "ENGINE_DATA", "MINIMUM", state.minimumRpm), 100.0)
        state.powerLutName = iniString(ini, "HEADER", "POWER_CURVE", state.powerLutName)
        state.peakTorqueNm = math.max(iniNumber(ini, "ENGINE_DATA", "MAX_TORQUE", 0.0), 0.0)
    end

    local lutText, lutPath = readFirstExisting(buildCarPathCandidates(carId, "data/" .. state.powerLutName))
    if not lutText and state.powerLutName ~= "power.lut" then
        lutText, lutPath = readFirstExisting(buildCarPathCandidates(carId, "data/power.lut"))
    end

    if lutText then
        state.powerLut = parsePowerLut(lutText)
        state.lutPath = lutPath
        state.powerLutLoaded = #state.powerLut > 0

        if state.powerLutLoaded then
            for i = 1, #state.powerLut do
                state.peakTorqueNm = math.max(state.peakTorqueNm, state.powerLut[i].torque)
            end
        end
    end

    state.configLoaded = true
end

local function lowPass(current, target, dt, tau)
    if tau <= 0.0 then return target end
    local a = clamp(dt / (tau + dt), 0.0, 1.0)
    return current + (target - current) * a
end

local function syncVirtualRpm(rawRpm, dt)
    if state.virtualRpm <= 0.0 then
        state.virtualRpm = rawRpm
        state.virtualOmega = rawRpm * (2.0 * math.pi / 60.0)
        return
    end

    local sync = clamp(dt / (M.params.rpmSyncTau + dt), 0.0, 1.0)
    local targetOmega = rawRpm * (2.0 * math.pi / 60.0)
    state.virtualOmega = state.virtualOmega + (targetOmega - state.virtualOmega) * sync
    state.virtualRpm = state.virtualOmega * 60.0 / (2.0 * math.pi)
end

local function calculateLosses(rpm, throttle, gear)
    local rpmAbs = abs(rpm)
    local rpmK = clamp(rpmAbs / 1000.0, 0.0, 12.0)

    state.frictionTorqueNm = M.params.frictionTorqueNm + M.params.frictionRpmGainNm * rpmAbs
    state.accessoryTorqueNm = M.params.accessoryTorqueNm

    -- Pumping loss grows toward closed throttle and with engine speed.
    local closedThrottle = 1.0 - clamp(throttle, 0.0, 1.0)
    state.pumpingTorqueNm = M.params.pumpingTorqueNm * (0.20 + 0.80 * closedThrottle) * (0.35 + 0.65 * rpmK / 8.0)
    state.pumpingTorqueNm = clamp(state.pumpingTorqueNm, 0.0, M.params.pumpingTorqueNm * 1.50)

    local inGear = abs(gear) > 0
    state.engineBrakeTorqueNm = 0.0
    if inGear and closedThrottle > 0.0 then
        state.engineBrakeTorqueNm = (state.frictionTorqueNm + state.pumpingTorqueNm) * M.params.engineBrakeGain * closedThrottle
    end
end

local function calculateLimiter(rpm)
    local ratio = rpm / math.max(state.redlineRpm, 1000.0)
    if ratio <= M.params.limiterStart then return 0.0 end

    local t = clamp((ratio - M.params.limiterStart) / math.max(M.params.limiterFullCut - M.params.limiterStart, 0.001), 0.0, 1.0)
    return t * M.params.limiterCutTorque
end

local function calculateTorque(dt, gear)
    local rpm = math.max(state.virtualRpm, 0.0)
    local throttle = clamp(state.filteredThrottle, 0.0, 1.0)

    local combustion = 0.0
    if state.powerLutLoaded then
        combustion = interpolatePowerLut(state.powerLut, rpm)
    end

    state.combustionWaveformMultiplier = M.params.waveformDefault
    if M.params.waveformEnabled then
        state.combustionWaveformMultiplier = clamp(
            safeLoadNumber(M.params.waveformKey, M.params.waveformDefault),
            0.50,
            1.50
        )
    end

    state.turboTorqueMultiplier = M.params.turboDefault
    if M.params.turboEnabled then
        state.turboTorqueMultiplier = clamp(
            safeLoadNumber(M.params.turboKey, M.params.turboDefault),
            1.0,
            3.0
        )
    end

    state.thermalTorqueMultiplier = clamp(
        safeLoadNumber("ngp_engine_thermal_torque_multiplier", 1.0),
        0.78,
        1.0
    )

    state.baseCombustionTorqueNm = combustion * throttle * state.combustionWaveformMultiplier * state.turboTorqueMultiplier * state.thermalTorqueMultiplier
    calculateLosses(rpm, throttle, gear)

    state.limiterTorqueNm = 0.0
    local limiterCut = calculateLimiter(rpm)
    if limiterCut > 0.0 then
        state.limiterTorqueNm = state.baseCombustionTorqueNm * limiterCut
    end

    local losses = state.frictionTorqueNm + state.pumpingTorqueNm + state.accessoryTorqueNm
    local net = state.baseCombustionTorqueNm - losses - state.limiterTorqueNm

    -- When the engine is off throttle and in gear, preserve the explicit
    -- engine-braking component for diagnostics; it is not added twice.
    if throttle <= 0.001 and abs(gear) > 0 then
        net = -state.engineBrakeTorqueNm - state.accessoryTorqueNm
    end

    return net
end

local function updateVirtualEngine(dt, gear)
    local netTorque = calculateTorque(dt, gear)
    local angularAcceleration = netTorque / math.max(state.inertia, 0.001)

    state.virtualOmega = state.virtualOmega + angularAcceleration * dt
    local minOmega = state.minimumRpm * (2.0 * math.pi / 60.0)
    if state.virtualOmega < minOmega then state.virtualOmega = minOmega end

    local rpm = state.virtualOmega * 60.0 / (2.0 * math.pi)

    -- Do not replace AC RPM. Synchronize the virtual state slowly so an
    -- unstable early prototype cannot run away indefinitely.
    local rawRpm = math.max(state.rawRpm, 0.0)
    if rawRpm > 0.0 then
        local sync = clamp(dt / (M.params.rpmSyncTau + dt), 0.0, 1.0)
        rpm = rpm + (rawRpm - rpm) * sync
        state.virtualOmega = rpm * (2.0 * math.pi / 60.0)
    end

    state.virtualRpm = rpm
    local clutchReaction = safeLoadNumber("ngp_clutch_p2_reaction_torque_nm", 0.0)
    local reactionAuthority = clamp(safeLoadNumber("ngp_engine_proto_authority", M.params.authority), 0.0, 1.0)
    local appliedReaction = clutchReaction * reactionAuthority
    state.clutchReactionTorqueNm = appliedReaction
    netTorque = netTorque - appliedReaction

    state.netTorqueNm = netTorque
end

local function exportState()
    safeStore("ngp_engine_proto_authority", M.params.authority)
    safeStore("ngp_engine_proto_output_torque_nm", state.netTorqueNm or 0.0)
    safeStore("ngp_engine_proto_base_combustion_torque_nm", state.baseCombustionTorqueNm or 0.0)
    safeStore("ngp_engine_proto_waveform_multiplier", state.combustionWaveformMultiplier or 1.0)
    safeStore("ngp_engine_proto_turbo_multiplier", state.turboTorqueMultiplier or 1.0)
    safeStore("ngp_engine_proto_thermal_multiplier", state.thermalTorqueMultiplier or 1.0)
    safeStore("ngp_engine_proto_damage_multiplier", state.damageTorqueMultiplier or 1.0)
    safeStore("ngp_engine_proto_friction_torque_nm", state.frictionTorqueNm or 0.0)
    safeStore("ngp_engine_proto_pumping_torque_nm", state.pumpingTorqueNm or 0.0)
    safeStore("ngp_engine_proto_accessory_torque_nm", state.accessoryTorqueNm or 0.0)
    safeStore("ngp_engine_proto_engine_brake_torque_nm", state.engineBrakeTorqueNm or 0.0)
    safeStore("ngp_engine_proto_clutch_reaction_torque_nm", state.clutchReactionTorqueNm or 0.0)
    safeStore("ngp_engine_proto_limiter_torque_nm", state.limiterTorqueNm or 0.0)
    safeStore("ngp_engine_proto_rpm", state.virtualRpm or 0.0)
    safeStore("ngp_engine_proto_omega", state.virtualOmega or 0.0)
    safeStore("ngp_engine_proto_inertia", state.inertia or M.params.inertiaDefault)
    safeStore("ngp_engine_proto_throttle", state.filteredThrottle or 0.0)
    safeStore("ngp_engine_proto_raw_rpm", state.rawRpm or 0.0)
    safeStore("ngp_engine_proto_peak_torque_nm", state.peakTorqueNm or 0.0)
    safeStore("ngp_engine_proto_redline_rpm", state.redlineRpm or M.params.fallbackLimiter)
    safeStore("ngp_engine_proto_update_count", state.updateCount or 0)
    safeStoreString("ngp_engine_proto_status", state.status)
    safeStoreString("ngp_engine_proto_config_path", state.configPath)
    safeStoreString("ngp_engine_proto_lut_path", state.lutPath)
    safeStoreString("ngp_engine_proto_car_id", state.carId)
end

function M.init()
    state.initialized = true
    state.status = "INIT"
    state.updateCount = 0
    loadConfig()

    state.virtualRpm = math.max(state.minimumRpm, 0.0)
    state.virtualOmega = state.virtualRpm * (2.0 * math.pi / 60.0)

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
    state.rawRpm = math.max(num(safeField(car, "rpm", 0.0), 0.0), 0.0)
    state.driverThrottle = clamp(num(safeField(car, "gas", 0.0), 0.0), 0.0, 1.0)
    local gear = math.floor(num(safeField(car, "gear", 0), 0))

    if state.virtualRpm <= 0.0 then
        syncVirtualRpm(state.rawRpm, dt)
    end

    state.filteredThrottle = lowPass(state.filteredThrottle, state.driverThrottle, dt, M.params.throttleTau)
    updateVirtualEngine(dt, gear)

    -- Drivetrain is scheduled immediately after this module at 60 Hz, so
    -- publish the prototype torque every update. This avoids a startup
    -- frame using a stale ac.store() value.
    exportState()

    state.status = "RUNNING"
end

function M.getTorqueNm()
    return state.netTorqueNm or 0.0
end

function M.getVirtualRpm()
    return state.virtualRpm or 0.0
end

function M.getAuthority()
    return M.params.authority
end

function M.getState()
    return state
end

return M
