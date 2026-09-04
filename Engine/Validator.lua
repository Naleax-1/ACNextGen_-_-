local Parser=require('ACNextGen.Engine.Parser')
local M={}
function M.module(spec)
 local ok,e=Parser.parse(spec); if not ok then return false,e end
 if not spec.metadata.id or spec.metadata.id=='' then return false,'ID_MISSING' end
 for name,lim in pairs(spec.limits or {}) do if type(lim)~='table' or #lim~=2 then return false,'LIMIT_INVALID:'..name end end
 return true
end
function M.registry(registry)
 local seen={}; for id,s in pairs(registry) do if seen[id] then return false,'MODULE_DUPLICATE:'..id end; seen[id]=true; local ok,e=M.module(s); if not ok then return false,id..':'..e end end; return true end
return M
