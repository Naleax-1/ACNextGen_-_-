local M={}
function M.new() return setmetatable({modules={}}, {__index=M}) end
function M:initModule(id,spec)
 local s={}
 for name,def in pairs(spec.state or {}) do s[name]=def.default or 0 end
 self.modules[id]=s
end
function M:get(id) return self.modules[id] or {} end
function M:set(id,name,value) if self.modules[id] then self.modules[id][name]=value end end
return M
