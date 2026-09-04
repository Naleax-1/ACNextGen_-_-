local M={}
function M.new() return setmetatable({time=0,dt=0,frame=0,input={},output={},engine=nil},{__index=M}) end
function M:begin(dt,input) self.dt=dt or 0; self.time=self.time+self.dt; self.frame=self.frame+1; self.input=input or {} end
function M:setEngine(engine) self.engine=engine end
function M:update() if not self.engine then return nil,'ENGINE_MISSING' end; local out,e=self.engine:tick(self.input); if not out then return nil,e end; self.output=out; return out end
return M
