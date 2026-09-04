local M={}
function M.sanitize(value,fallback) value=tonumber(value); if not value or value~=value or value==math.huge or value==-math.huge then return fallback or 0 end return value end
function M.build(engineOutput)
 return {engine_torque_nm=M.sanitize(engineOutput.ENGINE_OUTPUT and engineOutput.ENGINE_OUTPUT.torque_nm,0), tyre_force=M.sanitize(engineOutput.TYRE_FORCE and engineOutput.TYRE_FORCE.longitudinal_force,0), chassis_load=M.sanitize(engineOutput.CHASSIS_OUTPUT and engineOutput.CHASSIS_OUTPUT.chassis_load,0)}
end
return M
