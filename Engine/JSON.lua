local M={}
local function err(s,p) error('JSON decode error at '..tostring(p)..': '..s,0) end
function M.decode(s)
 local i=1; local n=#s
 local function ws() while i<=n and s:sub(i,i):match('%s') do i=i+1 end end
 local parse
 local function str()
  local q=i; i=i+1; local out={}
  while i<=n do local c=s:sub(i,i)
   if c=='"' then i=i+1; return table.concat(out) end
   if c=='\\' then i=i+1; local e=s:sub(i,i); local map={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
    if map[e] then out[#out+1]=map[e]; i=i+1 elseif e=='u' then local h=s:sub(i+1,i+4); if not h:match('^%x%x%x%x$') then err('bad unicode',i) end; out[#out+1]='?'; i=i+5 else err('bad escape',i) end
   else out[#out+1]=c; i=i+1 end
  end
  err('unterminated string',q)
 end
 local function num()
  local a=i; local tok=s:match('^-?%d+%.?%d*[eE]?[+-]?%d*',i); if not tok or tok=='' then err('bad number',i) end; i=i+#tok; return tonumber(tok)
 end
 local function arr()
  i=i+1; ws(); local t={}; if s:sub(i,i)==']' then i=i+1; return t end
  while true do t[#t+1]=parse(); ws(); local c=s:sub(i,i); if c==']' then i=i+1; return t elseif c==',' then i=i+1; ws() else err('expected , or ]',i) end end
 end
 local function obj()
  i=i+1; ws(); local t={}; if s:sub(i,i)=='}' then i=i+1; return t end
  while true do ws(); if s:sub(i,i)~='"' then err('expected key',i) end; local k=str(); ws(); if s:sub(i,i)~=':' then err('expected :',i) end; i=i+1; ws(); t[k]=parse(); ws(); local c=s:sub(i,i); if c=='}' then i=i+1; return t elseif c==',' then i=i+1 else err('expected , or }',i) end end
 end
 function parse()
  ws(); local c=s:sub(i,i)
  if c=='"' then return str() elseif c=='{' then return obj() elseif c=='[' then return arr() elseif c=='-' or c:match('%d') then return num() elseif s:sub(i,i+3)=='true' then i=i+4; return true elseif s:sub(i,i+4)=='false' then i=i+5; return false elseif s:sub(i,i+3)=='null' then i=i+4; return nil else err('unexpected token',i) end
 end
 local v=parse(); ws(); if i<=n then err('trailing data',i) end; return v
end
return M
