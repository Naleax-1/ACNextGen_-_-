-- ACNextGen ObserverUI
-- Presentation only. Reads Observer snapshots; never accesses Engine modules.

local M = {}

local provider = nil
local lastSnapshot = nil
local uiAccumulator = 0
local UI_INTERVAL = 0.10

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

local function kv(label, value)
    ui.text(string.format("%-22s : %s", label, tostring(value)))
end

local function refreshSnapshot(dt)
    uiAccumulator = uiAccumulator + (tonumber(dt) or 0)
    if not lastSnapshot or uiAccumulator >= UI_INTERVAL then
        uiAccumulator = 0
        if provider then
            local ok, snapshot = pcall(provider)
            if ok and snapshot then
                lastSnapshot = snapshot
            end
        end
    end
    return lastSnapshot
end

function M.bind(providerFunction)
    if type(providerFunction) ~= 'function' then
        provider = nil
        return false
    end
    provider = providerFunction
    return true
end

function M.draw(snapshot)
    snapshot = snapshot or lastSnapshot
    ui.text("=== ACNextGen OBSERVER ===")
    ui.text("READ-ONLY ENGINE DIAGNOSTICS")
    ui.separator()

    if not snapshot then
        kv("OBSERVER", "WAITING_ENGINE")
        return
    end

    kv("ENGINE", snapshot.status == 'RUNNING' and "ONLINE" or tostring(snapshot.status or "OFFLINE"))
    kv("STATE", snapshot.tick and snapshot.tick > 0 and "UPDATED" or "STALE")
    kv("TICK", num(snapshot.tick, 0))
    kv("AGE", num(snapshot.stateAge, 0))
    kv("ERROR", snapshot.error and snapshot.error.active and (snapshot.error.code or "ACTIVE") or "NONE")

    ui.separator()
    ui.text("MODULES")

    local modules = snapshot.modules or {}
    local ids = {}
    for id in pairs(modules) do ids[#ids + 1] = id end
    table.sort(ids)

    if #ids == 0 then
        ui.text("  WAITING FOR ENGINE")
    else
        for i = 1, #ids do
            local m = modules[ids[i]]
            ui.text(string.format("%-22s : %s", ids[i], tostring(m.status or "UNKNOWN")))
        end
    end

    if snapshot.error and snapshot.error.active then
        ui.separator()
        ui.text("ENGINE ERROR")
        ui.text(tostring(snapshot.error.message or snapshot.error.code or "UNKNOWN"))
    end
end

function M.update(dt)
    return refreshSnapshot(dt)
end

return M
