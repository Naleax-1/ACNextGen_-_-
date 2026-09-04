---@diagnostic disable: undefined-global
-- ACNextGen R1 / Engineering 50% foundation
local APP_NAME='ACNextGen'; local VERSION='NGP-R1 50% Engineering Foundation'
local ROOT='assettocorsa/apps/lua/ACNextGen'
local Core=require('ACNextGen.Core_ngp')
local Engine=require('ACNextGen.Engine.Engine')
local Send=require('ACNextGen.Send.Physics')
local app={initialized=false,core=nil,engine=nil,send=nil,lastError='',status='BOOT'}
local MODULES={'Engine_Core.json','Engine_Turbo.json','Engine_Thermal.json','Engine_Damage.json','Engine_Output.json','Tyre_Force.json','Suspension_Heave.json','Chassis_Output.json'}
local function log(s) if ac and ac.log then pcall(ac.log,'['..APP_NAME..'] '..tostring(s)) end end
local function inputSnapshot()
 local car=ac and ac.getCar and ac.getCar(0) or nil
 local rpm=car and tonumber(car.rpm) or 0
 local throttle=car and tonumber(car.gas) or 0
 local coolant=car and tonumber(car.waterTemperature) or 90
 local health=1
 return {['engine.rpm']=rpm,['driver.throttle']=throttle,['engine.coolant_c']=coolant,['engine.health']=health,['vehicle.wheel_load']=1000,['vehicle.slip']=0.05}
end
function script.update(dt)
 if not app.initialized then
  local ok,engine=pcall(Engine.new,ROOT,MODULES)
  if not ok or not engine or engine.error then app.status='ERROR'; app.lastError=tostring(engine and engine.error or engine); log(app.lastError); return end
  app.engine=engine; app.core=Core.new(); app.core:setEngine(engine); app.send=Send.new(); app.initialized=true; app.status='RUNNING'; log(VERSION..' initialized')
 end
 local ok,e=pcall(function() app.core:begin(dt,inputSnapshot()); local out=app.core:update(); if not out then error('ENGINE:'..tostring(e)) end; app.send:update(out) end)
 if not ok then app.status='ERROR'; app.lastError=tostring(e); log('Runtime error: '..app.lastError) end
end
function windowMain()
 if ui and ui.text then
  ui.text('ACNextGen '..VERSION)
  ui.text('Status: '..tostring(app.status))
  if app.lastError ~= '' then ui.text('Error: '..tostring(app.lastError)) end
  if app.core then ui.text('Frame: '..tostring(app.core.frame)); ui.text('Time: '..string.format('%.3f',app.core.time)) end
 end
end

function script.draw()
 if ui and ui.beginWindow then
  ui.beginWindow(APP_NAME,ui.WindowFlags and ui.WindowFlags.NoCollapse or 0)
  ui.text('ACNextGen '..VERSION)
  ui.text('Status: '..app.status)
  if app.lastError~='' then ui.text('Error: '..app.lastError) end
  if app.core then ui.text('Frame: '..tostring(app.core.frame)); ui.text('Time: '..string.format('%.3f',app.core.time)) end
  ui.endWindow()
 end
end
function script.shutdown() app.initialized=false; app.status='STOPPED'; log('shutdown') end
return app
