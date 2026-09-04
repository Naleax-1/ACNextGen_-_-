local Output=require('ACNextGen.Send.Output')
local M={}
function M.new() return setmetatable({last={}}, {__index=M}) end
function M:update(engineOutput) self.last=Output.build(engineOutput or {}); return self.last end
function M:applyMock() return self.last end
return M
