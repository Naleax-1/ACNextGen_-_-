-- ACNextGen OutputBridge
-- One-way Engine result transport. No physics writes, no JSON access, no UI.

local M = {}

function M.new()
    return setmetatable({
        subscribers = {},
        published = 0,
        rejected = 0,
        subscriberErrors = 0,
    }, { __index = M })
end

function M:subscribe(target)
    if not target or type(target.capture) ~= 'function' then
        return false, 'OUTPUT_SUBSCRIBER_INVALID'
    end
    for i = 1, #self.subscribers do
        if self.subscribers[i] == target then return true end
    end
    self.subscribers[#self.subscribers + 1] = target
    return true
end

function M:unsubscribe(target)
    for i=#self.subscribers,1,-1 do
        if self.subscribers[i] == target then
            table.remove(self.subscribers,i)
            return true
        end
    end
    return false
end

function M:publish(id, outputs, elapsed, frame)
    if not id or type(outputs) ~= 'table' then
        self.rejected=self.rejected+1
        return false,'OUTPUT_INVALID'
    end

    self.published=self.published+1

    for i=1,#self.subscribers do
        local target=self.subscribers[i]
        local ok,err=pcall(function()
            target:capture(id,outputs,elapsed,frame)
        end)
        if not ok then
            self.subscriberErrors=self.subscriberErrors+1
            return false,'OUTPUT_SUBSCRIBER_ERROR:'..tostring(err)
        end
    end
    return true
end

function M:stats()
    return {
        published=self.published,
        rejected=self.rejected,
        subscribers=#self.subscribers,
        subscriberErrors=self.subscriberErrors,
    }
end

return M
