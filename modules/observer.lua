---@diagnostic disable: undefined-global

-- ACNextGen Observer UI compatibility adapter.
-- Presentation only. It consumes Engine.getObserverState() through a provider.

local ObserverUI = require('ACNextGen.observer.ObserverUI')
local M = {}
local provider = nil

function M.bindEngineObserver(observer)
    if observer and type(observer.getObserverState) == 'function' then
        provider = function() return observer:getObserverState() end
        return true
    end
    provider = nil
    return false
end

function M.bindObserverProvider(fn)
    if type(fn) ~= 'function' then
        provider=nil
        return false
    end
    provider=fn
    return ObserverUI.bind(fn)
end

function M.setEngineDiagnostics(diag, err)
    -- Retained for compatibility; UI state comes only from the Observer snapshot.
end

function M.init()
    if ac and ac.log then
        pcall(function() ac.log('[ACNextGen] Observer display layer loaded') end)
    end
end

function M.update(dt, car, runtime)
    if provider then
        ObserverUI.bind(provider)
    end
    return ObserverUI.update(dt)
end

function M.drawUI(runtime, modules)
    ObserverUI.draw()
end

return M
