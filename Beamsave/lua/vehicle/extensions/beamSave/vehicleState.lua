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

local function getVehicleController()
  if controller and controller.getController then
    local vc = safe(function()
      return controller.getController("vehicleController")
    end)
    if vc then
      return vc
    end
  end
  if controller and controller.mainController then
    return controller.mainController
  end
  return nil
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
  out.gearIndex = v.gearIndex
  out.gear_A = v.gear_A
  out.gearboxBehavior = v.gearboxMode or v.gearboxBehavior
  out.parkingbrake = v.parkingbrake
  out.throttle = v.throttle
  out.brake = v.brake
  out.ignitionLevel = v.ignitionLevel
  if out.ignitionLevel == nil and v.ignition ~= nil then
    out.ignitionLevel = v.ignition and 2 or 0
  end
  return out
end

local function collectTransmission()
  local out = {}
  local ev = electrics and electrics.values
  if ev then
    out.gear = ev.gear
    out.gearIndex = ev.gearIndex
    out.gear_A = ev.gear_A
    out.gearboxBehavior = ev.gearboxMode or ev.gearboxBehavior
    out.parkingbrake = ev.parkingbrake
  end
  local vc = getVehicleController()
  if vc then
    if vc.gearboxBehavior ~= nil then
      out.gearboxBehavior = vc.gearboxBehavior
    end
    if vc.gearIndex ~= nil then
      out.gearIndex = vc.gearIndex
    end
    if type(vc.getGearName) == "function" then
      local name = safe(function()
        return vc.getGearName()
      end)
      if type(name) == "string" and name ~= "" then
        out.gear = name
      end
    end
    if type(vc.getGearPosition) == "function" then
      local pos = safe(function()
        return vc.getGearPosition()
      end)
      if type(pos) == "number" then
        out.shifterIndex = pos
      elseif type(pos) == "table" then
        out.shifterIndex = tonumber(pos[1] or pos.x or pos.index)
      end
    end
  end
  local box = getGearbox()
  if box then
    if out.gearIndex == nil then
      out.gearIndex = box.gearIndex
    end
    out.gearMode = box.mode
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
    data.throttle = ev.throttle
    data.brake = ev.brake
    data.ignitionLevel = ev.ignitionLevel

    local trans = collectTransmission()
    data.gear = trans.gear
    data.gearIndex = trans.gearIndex
    data.gearMode = trans.gearMode
    data.gearboxBehavior = trans.gearboxBehavior
    data.gear_A = trans.gear_A
    data.shifterIndex = trans.shifterIndex
    data.parkingbrake = trans.parkingbrake

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

local function normalizeGearName(g)
  if g == nil then
    return nil
  end
  local s = string.upper(tostring(g)):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  if s == "PARK" then return "P" end
  if s == "REV" or s == "REVERSE" then return "R" end
  if s == "NEUTRAL" then return "N" end
  if s == "DRIVE" then return "D" end
  -- Arcade/auto display like S3 or M2 is the shifter letter, not the ratio.
  local letter = s:match("^([PRNDSM])%-?%d+$")
  if letter == "S" or letter == "M" or letter == "D" then
    return letter
  end
  if s == "P" or s == "R" or s == "N" or s == "D" or s == "S" or s == "M" then
    return s
  end
  return s
end

local function currentGearName()
  local ev = electrics and electrics.values
  if ev and ev.gear ~= nil then
    return normalizeGearName(ev.gear)
  end
  local vc = getVehicleController()
  if vc and type(vc.getGearName) == "function" then
    return normalizeGearName(safe(function()
      return vc.getGearName()
    end))
  end
  return nil
end

local function applyParkingBrake(value)
  if value == nil then
    return
  end
  local amount = tonumber(value)
  if amount == nil then
    amount = (value == true or tostring(value) == "1") and 1 or 0
  end
  amount = math.max(0, math.min(1, amount))
  pcall(function()
    if input and input.event then
      input.event("parkingbrake", amount, 1)
    elseif electrics and electrics.values then
      electrics.values.parkingbrake = amount
    end
  end)
end

local function restoreGear(d)
  local vc = getVehicleController()
  local targetName = normalizeGearName(d.gear)
  local wantPark = targetName == "P"
  local index = tonumber(d.shifterIndex)
  if index == nil then
    index = tonumber(d.gearIndex)
  end

  if vc and d.gearboxBehavior ~= nil and type(vc.setGearboxMode) == "function" then
    pcall(function()
      vc.setGearboxMode(d.gearboxBehavior)
    end)
  end

  if vc and type(vc.shiftToGearIndex) == "function" and index ~= nil then
    pcall(function()
      vc.shiftToGearIndex(index)
    end)
  elseif vc and type(vc.shiftToGearIndex) == "function" and targetName == "R" then
    pcall(function()
      vc.shiftToGearIndex(-1)
    end)
  elseif vc and type(vc.shiftToGearIndex) == "function" and targetName == "N" then
    pcall(function()
      vc.shiftToGearIndex(0)
    end)
  end

  -- Automatics expose P/R/N/D as a lever. One notch per call; onUpdate retries
  -- finish the walk after each shift is applied.
  if vc and targetName and (targetName == "P" or targetName == "R" or targetName == "N" or targetName == "D" or targetName == "S" or targetName == "M") then
    local now = currentGearName()
    if now ~= targetName then
      local order = { P = 1, R = 2, N = 3, D = 4, S = 5, M = 6 }
      local from = order[now or ""]
      local to = order[targetName]
      if from and to and to > from and type(vc.shiftUp) == "function" then
        pcall(function()
          vc.shiftUp()
        end)
      elseif from and to and to < from and type(vc.shiftDown) == "function" then
        pcall(function()
          vc.shiftDown()
        end)
      end
    end
  end

  if wantPark and vc and type(vc.setFreeze) == "function" then
    pcall(function()
      vc.setFreeze(true)
    end)
  end

  -- Keep the old assignment as a last-ditch fallback for unusual gearboxes.
  local box = getGearbox()
  if box then
    pcall(function()
      if d.gearMode ~= nil and box.mode ~= nil then
        box.mode = d.gearMode
      end
      if index ~= nil and box.setGearIndex then
        box:setGearIndex(index)
      elseif index ~= nil and box.gearIndex ~= nil then
        box.gearIndex = index
      end
    end)
  end

  if d.parkingbrake ~= nil then
    applyParkingBrake(d.parkingbrake)
  elseif wantPark then
    applyParkingBrake(1)
  end
end

local pendingRestore = nil

local function scheduleGearRetry(data)
  pendingRestore = {
    data = data,
    tries = 6,
    wait = 0.12
  }
end

function M.onUpdate(dt)
  if not pendingRestore then
    return
  end
  pendingRestore.wait = pendingRestore.wait - (tonumber(dt) or 0)
  if pendingRestore.wait > 0 then
    return
  end
  pendingRestore.tries = pendingRestore.tries - 1
  pendingRestore.wait = 0.2
  pcall(restoreGear, pendingRestore.data)
  if pendingRestore.tries <= 0 then
    pendingRestore = nil
  end
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
      -- Ignition and the post-teleport reseat reset PRND. Retry after spawn settles.
      if data.gear ~= nil or data.gearIndex ~= nil or data.shifterIndex ~= nil then
        scheduleGearRetry(data)
      end
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
