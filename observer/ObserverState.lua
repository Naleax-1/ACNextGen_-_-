-- ACNextGen ObserverState
-- Read-only presentation snapshot. No physics calculation.

local M = {}

function M.new()
    return {
        engineAlive = false,
        ready = false,
        engineTick = 0,
        stateAge = 0,
        lastUpdate = 0,
        updateCount = 0,
        observerUpdateTime = 0,
        engineError = false,
        lastError = nil,
        moduleCount = 0,
        modules = {},
        state = {},
        result = {},
    }
end

return M
