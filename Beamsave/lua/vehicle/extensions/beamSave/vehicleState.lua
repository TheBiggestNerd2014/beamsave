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

local function automaticModesOf(vc)
  if not vc then
    return nil
  end
  local modes = vc.automaticModes
  if type(modes) ~= "string" and type(vc.gearboxHandling) == "table" then
    modes = vc.gearboxHandling.automaticModes
  end
  if type(modes) ~= "string" and type(vc.automaticHandling) == "table" then
    modes = vc.automaticHandling.automaticModes
  end
  if type(modes) == "string" and modes ~= "" then
    return modes
  end
  return nil
end

local function collectTransmission()
  local out = {}
  local ev = electrics and electrics.values
  if ev then
    out.gear = ev.gear
    -- Physical ratio. Reverse is negative, neutral is 0. Not the PRND lever.
    out.gearIndex = ev.gearIndex
    out.gear_A = ev.gear_A
    out.gearboxBehavior = ev.gearboxMode or ev.gearboxBehavior
    out.parkingbrake = ev.parkingbrake
  end
  local box = getGearbox()
  if box then
    if box.gearIndex ~= nil then
      out.gearIndex = box.gearIndex
    end
    out.gearMode = box.mode
  end
  local vc = getVehicleController()
  if vc then
    if vc.gearboxBehavior ~= nil then
      out.gearboxBehavior = vc.gearboxBehavior
    end
    if type(vc.getGearName) == "function" then
      local name = safe(function()
        return vc.getGearName()
      end)
      if type(name) == "string" and name ~= "" then
        out.gear = name
      end
    end
    -- getGearPosition returns (0-1 lever ratio, 1-based mode index).
    -- The ratio must not be passed to shiftToGearIndex.
    if type(vc.getGearPosition) == "function" then
      local ratio, modeIndex
      pcall(function()
        ratio, modeIndex = vc.getGearPosition()
      end)
      modeIndex = tonumber(modeIndex)
      if modeIndex and modeIndex >= 1 then
        out.shifterModeIndex = modeIndex
      end
      if out.gear_A == nil and type(ratio) == "number" then
        out.gear_A = ratio
      end
    end
    local modes = automaticModesOf(vc)
    if modes then
      out.automaticModes = modes
    end
  end
  if out.automaticModes ~= nil or out.gear_A ~= nil then
    out.transmissionType = "automatic"
  else
    out.transmissionType = "manual"
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
    data.shifterModeIndex = trans.shifterModeIndex
    data.automaticModes = trans.automaticModes
    data.transmissionType = trans.transmissionType
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

-- Automatic shiftToGearIndex does not take a position in the "PRNDS21M" string.
-- It takes the H-shifter index from shiftLogic-automaticGearbox:
--   -1 R, 0 N, 1 P, 2 D, 3 S, 4 low-2, 5 low-1, 6 manual.
-- Arcade mode's shiftToGearIndex only switches to realistic, so the lever
-- has to be applied after that switch. Sport "S3" is lever S. "M3" is manual
-- mode locked in 3rd and has to be walked after entering M.
local H_SHIFTER_INDEX = {
  R = -1,
  N = 0,
  P = 1,
  D = 2,
  S = 3,
  ["2"] = 4,
  ["1"] = 5,
  M = 6
}

local function rawGearName()
  local vc = getVehicleController()
  if vc and type(vc.getGearName) == "function" then
    local name = safe(function()
      return vc.getGearName()
    end)
    if type(name) == "string" and name ~= "" then
      return string.upper(name)
    end
  end
  local ev = electrics and electrics.values
  if ev and ev.gear ~= nil then
    local s = string.upper(tostring(ev.gear))
    if s ~= "" then
      return s
    end
  end
  return nil
end

local function leverTarget(d)
  if type(d) ~= "table" or d.gear == nil then
    return nil
  end
  local s = string.upper(tostring(d.gear)):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  if s == "PARK" then return "P" end
  if s == "REV" or s == "REVERSE" then return "R" end
  if s == "NEUTRAL" then return "N" end
  if s == "DRIVE" then return "D" end
  local manualGear = s:match("^M(%d+)$")
  if manualGear then
    return "M" .. manualGear
  end
  local sportOrDrive = s:match("^([DS])%d+$")
  if sportOrDrive then
    return sportOrDrive
  end
  return s
end

local function leverMatches(current, target)
  if not current or not target then
    return false
  end
  if current == target then
    return true
  end
  if target == "S" and current:match("^S%d+$") then
    return true
  end
  if target == "D" and current:match("^D%d+$") then
    return true
  end
  if target == "M" and current:match("^M%d*$") then
    return true
  end
  return false
end

local function isAutomatic(d)
  if type(d) ~= "table" then
    return false
  end
  if d.transmissionType == "automatic" then
    return true
  end
  if d.transmissionType == "manual" then
    return false
  end
  if type(d.automaticModes) == "string" and d.automaticModes ~= "" then
    return true
  end
  if d.gear_A ~= nil then
    return true
  end
  local raw = string.upper(tostring(d.gear or ""))
  if raw == "P" or raw == "D" or raw == "S" or raw == "PARK" or raw == "DRIVE" then
    return true
  end
  if raw:match("^M%d+$") or raw:match("^S%d+$") or raw:match("^D%d+$") then
    return true
  end
  return false
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

local function modesFor(vc, d)
  local live = automaticModesOf(vc)
  if live then
    return string.upper(live)
  end
  if type(d and d.automaticModes) == "string" and d.automaticModes ~= "" then
    return string.upper(d.automaticModes)
  end
  return nil
end

local function currentModeIndex(vc)
  if not (vc and type(vc.getGearPosition) == "function") then
    return nil
  end
  local ratio, modeIndex
  pcall(function()
    ratio, modeIndex = vc.getGearPosition()
  end)
  modeIndex = tonumber(modeIndex)
  if modeIndex and modeIndex >= 1 then
    return modeIndex
  end
  return nil
end

local function inRealistic(vc)
  local behavior = nil
  if vc and type(vc.gearboxBehavior) == "string" then
    behavior = vc.gearboxBehavior
  else
    local ev = electrics and electrics.values
    if ev then
      behavior = ev.gearboxMode or ev.gearboxBehavior
    end
  end
  return behavior == "realistic" or behavior == "realisticManual" or behavior == "manual"
end

local function modeOrderKey(name, modes)
  if not name or name == "" then
    return nil
  end
  local manualGear = name:match("^M(%d+)$")
  if manualGear then
    local mPos = 80
    if type(modes) == "string" then
      local found = string.find(modes, "M", 1, true)
      if found then
        mPos = found
      end
    end
    return mPos * 100 + tonumber(manualGear)
  end
  local base = name
  if name:match("^S%d+$") then
    base = "S"
  elseif name:match("^D%d+$") then
    base = "D"
  end
  if type(modes) == "string" then
    local pos = string.find(modes, base, 1, true)
    if pos then
      return pos * 100
    end
  end
  local fallback = {
    P = 100, R = 200, N = 300, D = 400, S = 500,
    ["2"] = 600, ["1"] = 700, L = 750, M = 800
  }
  return fallback[base]
end

local function walkDirection(current, target, modes)
  local fromKey = modeOrderKey(current, modes)
  local toKey = modeOrderKey(target, modes)
  if not fromKey or not toKey or fromKey == toKey then
    return 0
  end
  if toKey > fromKey then
    return 1
  end
  return -1
end

local function gearIndexMatches(index)
  if index == nil or not (electrics and electrics.values) then
    return false
  end
  local live = tonumber(electrics.values.gearIndex)
  return live ~= nil and live == index
end

local function manualGearIndex(d)
  local index = tonumber(d.gearIndex)
  if index ~= nil then
    return index
  end
  local raw = string.upper(tostring(d.gear or ""))
  if raw == "R" or raw == "REVERSE" or raw == "REV" then
    return -1
  end
  if raw == "N" or raw == "NEUTRAL" then
    return 0
  end
  return tonumber(raw)
end

local function restoreManualGear(d, vc)
  local index = manualGearIndex(d)
  if index == nil then
    return true
  end
  if not d._manualReady then
    if d.gearboxBehavior ~= nil and vc and type(vc.setGearboxMode) == "function" then
      pcall(function()
        vc.setGearboxMode(d.gearboxBehavior)
      end)
    end
    d._manualReady = true
    return false
  end
  if vc and type(vc.shiftToGearIndex) == "function" then
    pcall(function()
      vc.shiftToGearIndex(index)
    end)
  else
    local box = getGearbox()
    if box then
      pcall(function()
        if box.setGearIndex then
          box:setGearIndex(index)
        elseif box.gearIndex ~= nil then
          box.gearIndex = index
        end
      end)
    end
  end
  return gearIndexMatches(index)
end

local function transmissionReached(d, target, vc)
  if target and leverMatches(rawGearName(), target) then
    return true
  end
  if not target then
    local savedIndex = tonumber(d.shifterModeIndex)
    local liveIndex = currentModeIndex(vc)
    if savedIndex and liveIndex and savedIndex == liveIndex then
      return true
    end
  end
  return false
end

local function stepLever(vc, dir)
  if not vc or dir == 0 then
    return
  end
  if dir > 0 and type(vc.shiftUp) == "function" then
    pcall(function()
      vc.shiftUp()
    end)
  elseif dir < 0 and type(vc.shiftDown) == "function" then
    pcall(function()
      vc.shiftDown()
    end)
  end
end

-- Apply the automatic lever only after realistic mode is active. Arcade's
-- shiftToGearIndex does not move the lever.
local function restoreAutomaticGear(d, vc)
  local target = leverTarget(d)
  if not target and tonumber(d.shifterModeIndex) == nil then
    return false
  end
  if not d._logged then
    d._logged = true
    log("I", "BeamSave", "Restoring automatic lever to " .. tostring(target or d.shifterModeIndex) .. " (now " .. tostring(rawGearName()) .. ")")
  end
  -- Arcade can keep Drive. Park, reverse, neutral, sport, low, and manual
  -- mode only stick after the realistic lever is selected.
  local arcadeDrive = d.gearboxBehavior == "arcade" and target == "D"
  if transmissionReached(d, target, vc) and (arcadeDrive or inRealistic(vc) or d._leverHeld) then
    d._leverHeld = true
    return true
  end

  if not inRealistic(vc) then
    if not d._askedRealistic and vc and type(vc.setGearboxMode) == "function" then
      pcall(function()
        vc.setGearboxMode("realistic")
      end)
      d._askedRealistic = true
      return false
    end
    if not d._realisticWait then
      d._realisticWait = true
      return false
    end
  end

  if not d._hShifted and vc and type(vc.shiftToGearIndex) == "function" then
    local base = target
    if target and target:match("^M%d+$") then
      base = "M"
    end
    local hIndex = base and H_SHIFTER_INDEX[base] or nil
    if hIndex == nil then
      d._hShifted = true
    else
      local before = rawGearName()
      pcall(function()
        vc.shiftToGearIndex(hIndex)
      end)
      local after = rawGearName()
      local changed = after ~= before
      if changed or inRealistic(vc) then
        d._hShifted = true
      end
      if transmissionReached(d, target, vc) and (changed or arcadeDrive or inRealistic(vc)) then
        d._leverHeld = true
        return true
      end
      return false
    end
  end

  local savedIndex = tonumber(d.shifterModeIndex)
  local liveIndex = currentModeIndex(vc)
  if savedIndex and liveIndex and savedIndex ~= liveIndex then
    if liveIndex < savedIndex then
      stepLever(vc, 1)
    else
      stepLever(vc, -1)
    end
    if transmissionReached(d, target, vc) then
      d._leverHeld = true
    end
    return d._leverHeld == true
  end

  stepLever(vc, walkDirection(rawGearName(), target, modesFor(vc, d)))
  if transmissionReached(d, target, vc) then
    d._leverHeld = true
    return true
  end
  return false
end

local function restoreGear(d)
  local vc = getVehicleController()
  if isAutomatic(d) then
    return restoreAutomaticGear(d, vc)
  end
  return restoreManualGear(d, vc)
end

local function finishTransmission(d)
  if d._finished then
    return
  end
  d._finished = true
  if d.parkingbrake ~= nil then
    applyParkingBrake(d.parkingbrake)
  end
  if isAutomatic(d) and d.gearboxBehavior == "arcade" and leverTarget(d) == "D" then
    local vc = getVehicleController()
    if vc and type(vc.setGearboxMode) == "function" then
      pcall(function()
        vc.setGearboxMode("arcade")
      end)
    end
  end
end

local pendingRestore = nil

local function scheduleGearRetry(data)
  local auto = isAutomatic(data)
  pendingRestore = {
    data = data,
    tries = auto and 24 or 10,
    wait = auto and 0.4 or 0.2
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
  local data = pendingRestore.data
  local auto = isAutomatic(data)
  pendingRestore.wait = auto and 0.3 or 0.2
  local done = false
  local ok, result = pcall(restoreGear, data)
  if ok then
    done = result == true
  end
  if done then
    pcall(finishTransmission, data)
    pendingRestore = nil
  elseif pendingRestore.tries <= 0 then
    log("W", "BeamSave", "Transmission did not reach " .. tostring(leverTarget(data) or data.gear) .. " (now " .. tostring(rawGearName()) .. ")")
    if data.parkingbrake ~= nil then
      applyParkingBrake(data.parkingbrake)
    end
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
      -- Ignition and the post-teleport reseat reset the shifter. Retry after spawn settles.
      if data.gear ~= nil or data.gearIndex ~= nil or data.shifterModeIndex ~= nil or data.automaticModes ~= nil then
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
