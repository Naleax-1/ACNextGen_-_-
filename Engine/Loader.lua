local JSON=require('ACNextGen.Engine.JSON')
local M={}
local function read(path) local f,e=io.open(path,'r'); if not f then return nil,e end; local s=f:read('*a'); f:close(); return s end
function M.new(base) return setmetatable({base=base or '',registry={},catalog={}}, {__index=M}) end
function M:loadFile(path)
 local s,e=read(path); if not s then return nil,'FILE_NOT_FOUND:'..tostring(e) end
 local ok,obj=pcall(JSON.decode,s); if not ok then return nil,'JSON_DECODE_ERROR:'..tostring(obj) end
 if not obj.metadata or not obj.metadata.id then return nil,'MODULE_INVALID:missing metadata.id' end
 self.catalog[obj.metadata.id]=obj
 if obj.metadata.enabled==false then return obj end
 if self.registry[obj.metadata.id] then return nil,'MODULE_DUPLICATE:'..obj.metadata.id end
 self.registry[obj.metadata.id]=obj; return obj
end
function M:loadDir(dir, files)
 for _,name in ipairs(files or {}) do local obj,e=self:loadFile(dir..'/'..name); if not obj then return false,e end end
 return true
end
return M
