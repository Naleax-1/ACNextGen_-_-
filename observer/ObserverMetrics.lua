-- ACNextGen ObserverMetrics
-- Monitoring counters only. Never performs physics calculations.

local M = {}

function M.new()
    return {
        engineTick = 0,
        lastStateTick = 0,
        stateAge = 0,
        updateCount = 0,
        errorCount = 0,
        observerTime = 0,
        lastUpdate = 0,
    }
end

return M
