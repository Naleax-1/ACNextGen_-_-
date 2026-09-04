-- ACNextGen Production Observer
-- OBS-ENGINE-01
-- Read-only diagnostic observer. The Engine remains Source of Truth.
-- This object never calculates or writes physics.

local ObserverState = require('ACNextGen.observer.ObserverState')
local ObserverMetrics = require('ACNextGen.observer.ObserverMetrics')

local M = {}

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function copyScalarTable(src, dst)
    dst = dst or {}
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src or {}) do
        if finite(v) or type(v) == 'string' or type(v) == 'boolean' or v == nil then
            dst[k] = v
        end
    end
    return dst
end

local function clearTable(t)
    for k in pairs(t) do t[k] = nil end
end

function M.new()
    return setmetatable({
        enabled = true,
        status = 'OFFLINE',
        state = ObserverState.new(),
        metrics = ObserverMetrics.new(),

        -- Reused storage: avoids per-tick table churn.
        moduleOutputs = {},
        moduleStatus = {},
        moduleErrors = {},
        moduleTimes = {},

        error = {
            active = false,
            code = nil,
            message = nil,
        },

        heartbeat = 0,
        lastTick = 0,
        stateChanged = false,
        captureCount = 0,
        invalidCount = 0,
        lastModule = nil,

        -- UI snapshot is generated only when requested.
        snapshotCache = nil,
        snapshotTick = -1,
    }, { __index = M })
end

function M:setStatus(status)
    self.status = status or 'OFFLINE'
end

function M:beginTick(tick)
    if not self.enabled then return end
    self.stateChanged = false
    self.metrics.updateCount = self.metrics.updateCount + 1
    self.lastUpdate = os.clock()
    self.heartbeat = tonumber(tick) or (self.heartbeat + 1)
end

function M:capture(id, outputs, elapsed, frame)
    if not self.enabled or not id then return false end

    local target = self.moduleOutputs[id]
    if not target then
        target = {}
        self.moduleOutputs[id] = target
    end

    clearTable(target)
    for name, value in pairs(outputs or {}) do
        if finite(value) then
            target[name] = value
        else
            self.invalidCount = self.invalidCount + 1
        end
    end

    self.moduleStatus[id] = 'ONLINE'
    self.moduleErrors[id] = nil
    self.moduleTimes[id] = finite(elapsed) and elapsed or 0
    self.lastModule = id
    self.captureCount = self.captureCount + 1
    self.lastTick = tonumber(frame) or self.lastTick
    self.stateChanged = true
    self.metrics.engineTick = self.lastTick
    self.metrics.lastStateTick = self.lastTick
    self.metrics.stateAge = 0
    return true
end

function M:reportModule(id, status, err)
    if not id then return end
    self.moduleStatus[id] = status or 'UNKNOWN'
    self.moduleErrors[id] = err
end

function M:endTick(tick, ok, err)
    if not self.enabled then return end
    local t = tonumber(tick) or self.lastTick

    if t ~= self.lastTick then
        self.stateChanged = true
        self.metrics.stateAge = 0
    elseif not self.stateChanged then
        self.metrics.stateAge = self.metrics.stateAge + 1
    end

    self.lastTick = t
    self.metrics.engineTick = t
    self.metrics.lastStateTick = t
    self.state = self.state
    self.error.active = not ok
    self.error.code = err and tostring(err):match('^[^:]+') or nil
    self.error.message = err and tostring(err) or nil
    self.status = ok and 'RUNNING' or 'ERROR'
    self.state.engineAlive = ok
    self.state.ready = ok
    self.state.engineTick = t
    self.state.stateAge = self.metrics.stateAge
    self.state.lastUpdate = self.lastUpdate
    self.state.updateCount = self.metrics.updateCount
    self.state.engineError = self.error.active
    self.state.lastError = self.error.message
end

function M:reportEngineError(code, message)
    self.error.active = true
    self.error.code = code
    self.error.message = message
    self.state.engineError = true
    self.state.lastError = message
    self.status = 'ERROR'
    self.metrics.errorCount = self.metrics.errorCount + 1
end

function M:getObserverState()
    -- This is a presentation snapshot, not the Engine internal State.
    local s = {
        alive = self.state.engineAlive,
        ready = self.state.ready,
        tick = self.lastTick,
        stateAge = self.metrics.stateAge,
        status = self.status,
        state = {
            engineAlive = self.state.engineAlive,
            ready = self.state.ready,
            tick = self.lastTick,
            stateAge = self.metrics.stateAge,
        },
        result = {},
        error = {
            active = self.error.active,
            code = self.error.code,
            message = self.error.message,
        },
        modules = {},
        metrics = {
            updateCount = self.metrics.updateCount,
            lastStateTick = self.metrics.lastStateTick,
            stateAge = self.metrics.stateAge,
            observerTime = self.lastUpdate,
            errorCount = self.metrics.errorCount,
        },
    }

    for id, outputs in pairs(self.moduleOutputs) do
        s.result[id] = copyScalarTable(outputs)
        s.modules[id] = {
            status = self.moduleStatus[id] or 'UNKNOWN',
            executionTime = self.moduleTimes[id] or 0,
            error = self.moduleErrors[id],
        }
    end

    return s
end

-- Compatibility methods for the R2 transport/UI.
function M:snapshot()
    return self:getObserverState().result
end

function M:get(id)
    local s = self:getObserverState()
    return s.result[id]
end

function M:clear()
    clearTable(self.moduleOutputs)
    clearTable(self.moduleStatus)
    clearTable(self.moduleErrors)
    clearTable(self.moduleTimes)
    self.lastTick = 0
    self.heartbeat = 0
    self.status = 'OFFLINE'
end

function M:diagnostics()
    local n = 0
    for _ in pairs(self.moduleOutputs) do n = n + 1 end
    return {
        modules = n,
        captures = self.captureCount,
        invalid = self.invalidCount,
        frame = self.lastTick,
        lastModule = self.lastModule,
        status = self.status,
        heartbeat = self.heartbeat,
        stateAge = self.metrics.stateAge,
        updateCount = self.metrics.updateCount,
        error = self.error,
    }
end

return M
