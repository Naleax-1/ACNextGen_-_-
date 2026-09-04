local M={}
function M.new(order) return setmetatable({order=order or {}},{__index=M}) end
function M:each(fn) for _,id in ipairs(self.order) do local ok,e=fn(id); if ok==false then return false,e end end return true end
return M
