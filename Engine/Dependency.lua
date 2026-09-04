local M={}
function M.resolve(registry)
 local indeg={}; local out={}
 for id,_ in pairs(registry) do indeg[id]=0; out[id]={} end
 for id,s in pairs(registry) do for _,dep in ipairs(s.dependencies or {}) do if not registry[dep] then return nil,'DEPENDENCY_MISSING:'..dep..' <- '..id end; indeg[id]=indeg[id]+1; out[dep][#out[dep]+1]=id end end
 local q={}; for id,d in pairs(indeg) do if d==0 then q[#q+1]=id end end
 table.sort(q); local order={}
 while #q>0 do local id=table.remove(q,1); order[#order+1]=id; for _,nextId in ipairs(out[id]) do indeg[nextId]=indeg[nextId]-1; if indeg[nextId]==0 then q[#q+1]=nextId end end; table.sort(q) end
 if #order~=(function() local c=0; for _ in pairs(registry) do c=c+1 end; return c end)() then return nil,'DEPENDENCY_CYCLE' end
 return order
end
return M
