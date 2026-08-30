-- BeamSave vehicle Lua extension.
-- Collects and restores per-vehicle state that only exists in the vehicle VM.
-- Every read/write is guarded so missing modules never break a vehicle.

local M = {}

local function safe(fn)
  local ok, result = pcall(fn)
  if ok then
    return result
  end
  return nil
end

local function getGearbox()
  if gearbox then
    return gearbox
  end
  if powertrain and powertrain.getDevice then
    local device = safe(function()
      return powertrain.getDevice("gearbox")
    end)
    if device then
      return device
    end
  end
  return nil
end

local function tableVec(v)
  if not v then return nil end
  local x = tonumber(v.x or v[1] or v["1"])
  local y = tonumber(v.y or v[2] or v["2"])
  local z = tonumber(v.z or v[3] or v["3"])
  local w = tonumber(v.w or v[4] or v["4"])
  if not x or not y or not z then return nil end
  local out = { x = x, y = y, z = z }
  if w ~= nil then
    out.w = w
  end
  return out
end

local function collectFuel()
  local fuel = {}
  if not energyStorage then
    return fuel
  end
  local storages = safe(function()
    return energyStorage.getStorages()
  end)
  if type(storages) ~= "table" then
    return fuel
  end
  for name, storage in pairs(storages) do
    if type(storage) == "table" then
      fuel[name] = tonumber(storage.remainingRatio)
    end
  end
  return fuel
end

local function collectElectrics()
  local out = {}
  if not (electrics and electrics.values) then
    return out
  end
  local v = electrics.values
  out.engineRunning = v.engineRunning
  if out.engineRunning == nil then
    out.engineRunning = v.running
  end
  out.rpm = v.rpmTacho or v.rpm
  out.watertemp = v.watertemp
  out.oiltemp = v.oiltemp
  out.lights = v.lights
  out.gear = v.gear
  out.throttle = v.throttle
  out.brake = v.brake
  out.ignitionLevel = v.ignitionLevel
  if out.ignitionLevel == nil and v.ignition ~= nil then
    out.ignitionLevel = v.ignition and 2 or 0
  end
  return out
end

local function collectMotion()
  local out = {}
  if not obj then
    return out
  end
  out.pos = safe(function()
    if obj.getPosition then
      return tableVec(obj:getPosition())
    end
    return nil
  end)
  if not out.pos then
    out.pos = safe(function()
      if obj.getRefNodePosition then
        return tableVec(obj:getRefNodePosition())
      end
      return nil
    end)
  end
  out.dir = safe(function()
    if obj.getDirectionVector then
      return tableVec(obj:getDirectionVector())
    end
    return nil
  end)
  out.up = safe(function()
    if obj.getDirectionVectorUp then
      return tableVec(obj:getDirectionVectorUp())
    end
    return nil
  end)
  out.rot = safe(function()
    if obj.getDirectionVector and obj.getDirectionVectorUp and quatFromDir then
      local q = quatFromDir(-vec3(obj:getDirectionVector()), obj:getDirectionVectorUp())
      if q then
        return { x = tonumber(q.x) or 0, y = tonumber(q.y) or 0, z = tonumber(q.z) or 0, w = tonumber(q.w) or 1 }
      end
    end
    return nil
  end)
  out.vel = safe(function()
    if obj.getVelocity then
      return tableVec(obj:getVelocity())
    end
    return nil
  end)
  out.angVel = safe(function()
    if obj.getAngularVelocity then
      return tableVec(obj:getAngularVelocity())
    end
    if obj.getRefNodeAngularVelocity then
      return tableVec(obj:getRefNodeAngularVelocity())
    end
    return nil
  end)
  return out
end

local function vehicleId()
  if obj and obj.getID then
    return tonumber(obj:getID())
  end
  if objectId then
    return tonumber(objectId)
  end
  return 0
end

function M.collect()
  local ok, err = pcall(function()
    local data = {}
    data.fuel = collectFuel()

    local ev = collectElectrics()
    data.engineRunning = ev.engineRunning
    data.rpm = ev.rpm
    data.watertemp = ev.watertemp
    data.oiltemp = ev.oiltemp
    data.lights = ev.lights
    data.gear = ev.gear
    data.throttle = ev.throttle
    data.brake = ev.brake
    data.ignitionLevel = ev.ignitionLevel

    local box = getGearbox()
    if box then
      data.gearIndex = box.gearIndex
      data.gearMode = box.mode
    end

    local motion = collectMotion()
    data.pos = motion.pos
    data.dir = motion.dir
    data.up = motion.up
    data.rot = motion.rot
    data.vel = motion.vel
    data.angVel = motion.angVel

    local payload = serialize(data)
    obj:queueGameEngineLua(
      string.format("if extensions.beamSave_core then extensions.beamSave_core.onVehicleDataCollected(%s, %s) end", tostring(vehicleId()), payload)
    )
  end)
  if not ok then
    log("W", "BeamSave", "vehicle collect failed: " .. tostring(err))
    pcall(function()
      obj:queueGameEngineLua(
        string.format("if extensions.beamSave_core then extensions.beamSave_core.onVehicleDataCollected(%s, {}) end", tostring(vehicleId()))
      )
    end)
  end
end

local function restoreFuel(fuel)
  if type(fuel) ~= "table" or not energyStorage then
    return
  end
  for name, ratio in pairs(fuel) do
    ratio = tonumber(ratio)
    if ratio then
      ratio = math.max(0, math.min(1, ratio))
      pcall(function()
        local storage = energyStorage.getStorage(name)
        if storage and storage.setRemainingRatio then
          storage:setRemainingRatio(ratio)
        elseif storage then
          storage.remainingRatio = ratio
          if storage.energyCapacity then
            storage.storedEnergy = storage.energyCapacity * ratio
          end
        end
      end)
    end
  end
end

local function isEngineOn(v)
  if v == nil or v == false then return false end
  if v == true then return true end
  local n = tonumber(v)
  if n ~= nil then return n > 0.5 end
  local s = string.lower(tostring(v))
  if s == "false" or s == "off" or s == "nil" then return false end
  return s ~= "" and s ~= "0"
end

local function restoreIgnition(d)
  if d.engineRunning == nil and d.ignitionLevel == nil then
    return
  end
  local running = nil
  if d.engineRunning ~= nil then
    running = isEngineOn(d.engineRunning)
  end
  local level = tonumber(d.ignitionLevel)
  if level == nil then
    level = running and 2 or 0
  end
  if running == nil then
    running = level >= 2
  end
  -- Spawn always starts the engine. vehicleController.setEngineIgnition is
  -- what actually keeps it off; setIgnitionLevel alone gets overwritten.
  pcall(function()
    if controller and controller.getController then
      local vc = controller.getController("vehicleController")
      if vc and vc.setEngineIgnition then
        vc.setEngineIgnition(running)
      end
    end
  end)
  pcall(function()
    if electrics and electrics.setIgnitionLevel then
      electrics.setIgnitionLevel(running and math.max(level, 2) or math.min(level, 1))
    elseif electrics and electrics.values then
      electrics.values.ignitionLevel = running and 2 or 0
      electrics.values.engineRunning = running
      electrics.values.ignition = running
    end
  end)
  if not running then
    pcall(function()
      if powertrain and powertrain.getDevice then
        local eng = powertrain.getDevice("mainEngine")
        if eng and eng.setIgnition then
          eng:setIgnition(0)
        end
      end
    end)
  end
end

local function restoreLights(lights)
  if lights == nil then
    return
  end
  pcall(function()
    if electrics and electrics.setLightsState then
      electrics.setLightsState(lights)
    elseif electrics and electrics.values then
      electrics.values.lights = lights
    end
  end)
end

local function restoreGear(d)
  local box = getGearbox()
  if not box then
    return
  end
  pcall(function()
    if d.gearMode ~= nil and box.mode ~= nil then
      box.mode = d.gearMode
    end
    if d.gearIndex ~= nil and box.gearIndex ~= nil then
      box.gearIndex = d.gearIndex
    end
  end)
end

local function restoreVelocity(d)
  if not obj then
    return
  end
  if type(d.vel) == "table" then
    local vx = tonumber(d.vel[1] or d.vel.x)
    local vy = tonumber(d.vel[2] or d.vel.y)
    local vz = tonumber(d.vel[3] or d.vel.z)
    if vx and vy and vz then
      local applied = false
      pcall(function()
        if obj.setVelocity then
          obj:setVelocity(vx, vy, vz)
          applied = true
        end
      end)
      if not applied then
        pcall(function()
          if obj.applyClusterVelocityScaleAdd and obj.getRefNodeId then
            obj:applyClusterVelocityScaleAdd(obj:getRefNodeId(), 1, vx, vy, vz)
          end
        end)
      end
    end
  end
  if type(d.angVel) == "table" then
    local ax = tonumber(d.angVel[1] or d.angVel.x)
    local ay = tonumber(d.angVel[2] or d.angVel.y)
    local az = tonumber(d.angVel[3] or d.angVel.z)
    if ax and ay and az then
      pcall(function()
        if obj.setAngularVelocity then
          obj:setAngularVelocity(ax, ay, az)
        end
      end)
    end
  end
end

function M.restore(data)
  local ok, err = pcall(function()
    if type(data) == "string" then
      data = jsonDecode(data)
    end
    if type(data) ~= "table" then
      return
    end
    if data.restoreMechanicalState ~= false then
      restoreFuel(data.fuel)
      restoreIgnition(data)
      restoreGear(data)
    end
    if data.restoreLights then
      restoreLights(data.lights)
    end
    if data.restoreVelocity then
      restoreVelocity(data)
    end
  end)
  if not ok then
    log("W", "BeamSave", "vehicle restore failed: " .. tostring(err))
  end
end

return M
