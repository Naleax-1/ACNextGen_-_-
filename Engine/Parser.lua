local M={}
function M.validateFormula(node)
 if type(node)~='table' then return false,'FORMULA_INVALID' end
 if node.outputs then for _,v in pairs(node.outputs) do local ok,e=M.validateFormula(v); if not ok then return false,e end end; return true end
 if node.op=='constant' or node.op=='input' or node.op=='parameter' or node.op=='dependency' then return true end
 local ops={add=true,subtract=true,multiply=true,divide=true,max=true,min=true,clamp=true,abs=true}
 if not ops[node.op] then return false,'FORMULA_OP_UNSUPPORTED:'..tostring(node.op) end
 if not node.args or type(node.args)~='table' then return false,'FORMULA_ARGS_MISSING' end
 for _,a in ipairs(node.args) do local ok,e=M.validateFormula(a); if not ok then return false,e end end
 return true
end
function M.parse(module)
 if type(module)~='table' then return nil,'MODULE_NOT_OBJECT' end
 local required={'metadata','inputs','parameters','state','formula','conditions','outputs','dependencies','limits'}
 for _,k in ipairs(required) do if module[k]==nil then return nil,'MISSING_FIELD:'..k end end
 local ok,e=M.validateFormula(module.formula); if not ok then return nil,e end
 return module
end
return M
