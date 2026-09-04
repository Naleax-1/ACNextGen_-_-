local M={}
local function n(v) v=tonumber(v); if not v or v~=v or v==math.huge or v==-math.huge then return 0 end return v end
function M.eval(node,ctx)
 if type(node)~='table' then return 0 end
 local op=node.op
 if op=='constant' then return n(node.value)
 elseif op=='input' then return n(ctx.inputs[node.name])
 elseif op=='parameter' then return n(ctx.parameters[node.name])
 elseif op=='state' then return n(ctx.state[node.name])
 elseif op=='dependency' then return n(ctx.deps[node.module] and ctx.deps[node.module][node.output])
 elseif op=='abs' then return math.abs(M.eval(node.args[1],ctx)) end
 local a={}; for i,x in ipairs(node.args or {}) do a[i]=M.eval(x,ctx) end
 if op=='add' then local r=0; for _,v in ipairs(a) do r=r+v end; return r end
 if op=='subtract' then return (a[1] or 0)-(a[2] or 0) end
 if op=='multiply' then local r=1; for _,v in ipairs(a) do r=r*v end; return r end
 if op=='divide' then if math.abs(a[2] or 0)<1e-9 then return 0 end; return a[1]/a[2] end
 if op=='max' then return math.max(table.unpack(a)) end
 if op=='min' then return math.min(table.unpack(a)) end
 if op=='clamp' then return math.max(a[2],math.min(a[3],a[1])) end
 return 0
end
function M.run(spec,inputs,deps,state)
 local ctx={inputs=inputs or {},parameters=spec.parameters or {},deps=deps or {},state=state or {}}
 local results={}; for name,node in pairs((spec.formula or {}).outputs or {}) do results[name]=M.eval(node,ctx) end
 return results
end
return M
