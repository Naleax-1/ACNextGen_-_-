local Loader=require('ACNextGen.Engine.Loader')
local Validator=require('ACNextGen.Engine.Validator')
local Dependency=require('ACNextGen.Engine.Dependency')
local Scheduler=require('ACNextGen.Engine.Scheduler')
local State=require('ACNextGen.Engine.State')
local Evaluator=require('ACNextGen.Engine.Evaluator')
local Observer=require('ACNextGen.Engine.Observer')
local OutputBridge=require('ACNextGen.Engine.OutputBridge')

local M={}
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end

function M.new(base,files)
    local self=setmetatable({
        loader=Loader.new(base), registry={}, catalog={}, order={}, scheduler=nil,
        state=State.new(), observer=Observer.new(), bridge=OutputBridge.new(),
        lastOutputs={}, lastError=nil,
        stats={ticks=0,errors=0}
    }, {__index=M})

    local ok,e=self.loader:loadDir(base..'/Module',files)
    if not ok then
        self.lastError=e; self.error=e
        self.observer:reportEngineError('MODULE_LOAD_ERROR', e)
        return self
    end

    self.registry=self.loader.registry
    self.catalog=self.loader.catalog
    self.bridge:subscribe(self.observer)

    ok,e=Validator.registry(self.registry)
    if not ok then
        self.lastError=e; self.error=e
        self.observer:reportEngineError('MODULE_VALIDATION_ERROR', e)
        return self
    end

    self.order,e=Dependency.resolve(self.registry)
    if not self.order then
        self.lastError=e; self.error=e
        self.observer:reportEngineError('DEPENDENCY_ERROR', e)
        return self
    end

    self.scheduler=Scheduler.new(self.order)
    for id,s in pairs(self.registry) do
        self.state:initModule(id,s)
        self.observer:reportModule(id,'WAITING',nil)
    end

    self.observer:setStatus('WAITING_ENGINE')
    return self
end

function M:connectObserver(target)
    if not target or type(target.capture)~='function' then
        return false,'OUTPUT_OBSERVER_INVALID'
    end
    return self.bridge:subscribe(target)
end

function M:disconnectObserver(target)
    return self.bridge:unsubscribe(target)
end

-- Formal read-only Engine -> Observer interface.
function M:getObserverState()
    return self.observer:getObserverState()
end

function M:tick(inputs)
    if self.error then
        self.stats.errors=self.stats.errors+1
        self.observer:reportEngineError('ENGINE_NOT_READY', self.error)
        return nil,self.error
    end

    self.stats.ticks=self.stats.ticks+1
    self.observer:beginTick(self.stats.ticks)

    local outputs={}
    local ok,e=self.scheduler:each(function(id)
        local spec=self.registry[id]
        local start=os.clock()
        local r=Evaluator.run(spec,inputs or {},outputs,self.state:get(id))

        for name,v in pairs(r) do
            if not finite(v) then
                self.observer:reportModule(id,'ERROR','OUTPUT_INVALID:'..id..':'..name)
                return false,'OUTPUT_INVALID:'..id..':'..name
            end
            local lim=spec.limits and spec.limits[name]
            if lim and (v<lim[1] or v>lim[2]) then
                self.observer:reportModule(id,'ERROR','OUTPUT_LIMIT:'..id..':'..name)
                return false,'OUTPUT_LIMIT:'..id..':'..name
            end
        end

        outputs[id]=r
        local elapsed=os.clock()-start
        local pushed,pushErr=self.bridge:publish(id,r,elapsed,self.stats.ticks)
        if not pushed then
            self.observer:reportModule(id,'ERROR',pushErr)
            return false,pushErr
        end
        self.observer:reportModule(id,'ONLINE',nil)
        return true
    end)

    if not ok then
        self.stats.errors=self.stats.errors+1
        self.lastError=e
        self.observer:endTick(self.stats.ticks,false,e)
        return nil,e
    end

    self.lastOutputs=outputs
    self.lastError=nil
    self.observer:endTick(self.stats.ticks,true,nil)
    return outputs
end

function M:diagnostics()
    return {
        bridge=self.bridge:stats(),
        observer=self.observer:diagnostics(),
        module_count=(function() local n=0; for _ in pairs(self.registry) do n=n+1 end; return n end)(),
        catalog_count=(function() local n=0; for _ in pairs(self.catalog) do n=n+1 end; return n end)(),
        order=self.order,
        stats=self.stats,
        lastError=self.lastError
    }
end

return M
