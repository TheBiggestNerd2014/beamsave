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

local function deviceIsGearbox(device)
  if type(device) ~= "table" then
    return false
  end
  local kind = string.lower(tostring(device.type or ""))
  local name = string.lower(tostring(device.name or ""))
  if kind:find("gearbox", 1, true) or kind:find("dct", 1, true) or kind:find("cvt", 1, true) then
    return true
  end
  if name == "gearbox" or name:find("gearbox", 1, true) then
    return true
  end
  return false
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
  -- Some layouts do not register the device under the literal name "gearbox".
  if powertrain and powertrain.getDevices then
    local devices = safe(function()
      return powertrain.getDevices()
    end)
    if type(devices) == "table" then
      for _, device in pairs(devices) do
        if deviceIsGearbox(device) then
          return device
        end
      end
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
  if controller and type(controller.mainController) == "table" then
    local main = controller.mainController
    if type(main.shiftToGearIndex) == "function" or type(main.setGearboxMode) == "function" then
      return main
    end
  end
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

local function vehicleTag(d)
  local idText = "id ?"
  if obj then
    local id = nil
    if obj.getID then
      id = safe(function()
        return obj:getID()
      end)
    end
    if id == nil and obj.getId then
      id = safe(function()
        return obj:getId()
      end)
    end
    if id ~= nil then
      idText = "id " .. tostring(id)
    end
  end
  if type(d) == "table" and type(d.model) == "string" and d.model ~= "" then
    return d.model .. " " .. idText
  end
  return idText
end

local function gearboxLabel()
  local box = getGearbox()
  if not box then
    return "no gearbox"
  end
  if type(box.type) == "string" and box.type ~= "" then
    return box.type
  end
  if type(box.name) == "string" and box.name ~= "" then
    return box.name
  end
  return "gearbox"
end

local function behaviorText(vc)
  local bits = {}
  if vc and vc.gearboxBehavior ~= nil then
    bits[#bits + 1] = "vc=" .. tostring(vc.gearboxBehavior)
  end
  local ev = electrics and electrics.values
  if ev then
    if ev.gearboxMode ~= nil then
      bits[#bits + 1] = "electrics=" .. tostring(ev.gearboxMode)
    elseif ev.gearboxBehavior ~= nil then
      bits[#bits + 1] = "electrics=" .. tostring(ev.gearboxBehavior)
    end
  end
  if #bits == 0 then
    return "unread"
  end
  return table.concat(bits, " ")
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

local function gearboxTypeName(box)
  if type(box) == "table" and type(box.type) == "string" and box.type ~= "" then
    return box.type
  end
  return nil
end

-- Classification comes from the powertrain device. gear_A and getGearPosition
-- are not safe: manuals also return a number there, and treating that as an
-- automatic made 1st gear restore through the H-shifter (index 5 = 5th).
local function classifyGearbox(box, modes)
  local kind = string.lower(gearboxTypeName(box) or "")
  if kind:find("manual", 1, true) or kind:find("sequential", 1, true) then
    return "manual"
  end
  if kind:find("automatic", 1, true) or kind:find("dct", 1, true) or kind:find("cvt", 1, true) then
    return "automatic"
  end
  if type(modes) == "string" and modes ~= "" then
    local upper = string.upper(modes)
    if upper:find("D", 1, true) or upper:find("P", 1, true) then
      return "automatic"
    end
  end
  if kind ~= "" then
    return "manual"
  end
  return nil
end

-- Split the cluster text into a PRND lever. A bare number is the current
-- ratio (3rd, 4th), not the lever. BeamNG's automatic shiftToGearIndex
-- turns an unknown index into Neutral, so a ratio must never be sent there.
local function parseLever(gear, modes, gearMode, gearIndex)
  local s = string.upper(tostring(gear or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "PARK" or s == "P" then return "P" end
  if s == "REV" or s == "REVERSE" or s == "R" then return "R" end
  if s == "NEUTRAL" or s == "N" then return "N" end
  if s == "DRIVE" or s == "D" then return "D" end
  if s == "SPORT" or s == "S" then return "S" end
  local manualGear = s:match("^M(%d+)$")
  if manualGear then return "M" .. manualGear end
  local prefixed = s:match("^([DS])%d+$")
  if prefixed then return prefixed end

  local mode = string.lower(tostring(gearMode or ""))
  local index = tonumber(gearIndex)
  if mode == "park" then return "P" end
  if mode == "neutral" then return "N" end
  if mode == "reverse" or (index and index < 0) then return "R" end
  if (s == "1" or s == "2") and type(modes) == "string" and string.find(string.upper(modes), s, 1, true) then
    if s == "1" and index == 1 then return "1" end
    if s == "2" and index and index >= 1 and index <= 2 then return "2" end
  end
  if tonumber(s) or mode == "drive" then
    return "D"
  end
  if s ~= "" then
    return s
  end
  return nil
end

local function looksLikeLeverText(gear, modes)
  local s = string.upper(tostring(gear or ""))
  if s == "P" or s == "R" or s == "N" or s == "D" or s == "S" then return true end
  if s == "PARK" or s == "REVERSE" or s == "NEUTRAL" or s == "DRIVE" then return true end
  if s:match("^M%d+$") or s:match("^[DS]%d+$") then return true end
  if (s == "1" or s == "2") and type(modes) == "string" and string.find(string.upper(modes), s, 1, true) then
    return true
  end
  return false
end

local function collectTransmission()
  local out = {}
  local ev = electrics and electrics.values
  local displayGear = nil
  if ev then
    displayGear = ev.gear
    out.gear = ev.gear
    out.gearIndex = ev.gearIndex
    out.gearboxBehavior = ev.gearboxMode or ev.gearboxBehavior
    out.parkingbrake = ev.parkingbrake
    -- Keep the real electrics value only. Do not invent gear_A from
    -- getGearPosition; that number exists on manuals too.
    if ev.gear_A ~= nil then
      out.gear_A = ev.gear_A
    end
  end
  local box = getGearbox()
  out.gearboxType = gearboxTypeName(box)
  if box then
    if box.gearIndex ~= nil then
      out.gearIndex = box.gearIndex
    end
    out.gearMode = box.mode
  end
  local vc = getVehicleController()
  local modes = automaticModesOf(vc)
  if modes then
    out.automaticModes = modes
  end
  if vc and vc.gearboxBehavior ~= nil then
    out.gearboxBehavior = vc.gearboxBehavior
  end
  local officialGear = nil
  if vc and type(vc.getGearName) == "function" then
    officialGear = safe(function()
      return vc.getGearName()
    end)
    if type(officialGear) ~= "string" or officialGear == "" then
      officialGear = nil
    end
  end
  if looksLikeLeverText(officialGear, modes) then
    out.gear = officialGear
  elseif looksLikeLeverText(displayGear, modes) then
    out.gear = displayGear
  elseif officialGear then
    out.gear = officialGear
  end

  local class = classifyGearbox(box, modes)
  if class == nil then
    class = "manual"
  end
  out.transmissionType = class
  if class == "manual" then
    local raw = string.upper(tostring(out.gear or ""))
    local fromName = tonumber(raw)
    if raw == "R" or raw == "REVERSE" or raw == "REV" then
      fromName = -1
    elseif raw == "N" or raw == "NEUTRAL" then
      fromName = 0
    end
    if fromName ~= nil then
      out.gearIndex = fromName
    end
    out.lever = nil
    out.gear_A = nil
  else
    out.lever = parseLever(out.gear, modes, out.gearMode, out.gearIndex)
    if vc and type(vc.getGearPosition) == "function" then
      local ratio, modeIndex
      pcall(function()
        ratio, modeIndex = vc.getGearPosition()
      end)
      ratio = tonumber(ratio)
      modeIndex = tonumber(modeIndex)
      -- (0-1 lever ratio, 1-based mode index). Anything else is not a lever index.
      if modeIndex and modeIndex >= 1 and ratio and ratio >= 0 and ratio <= 1 then
        out.shifterModeIndex = modeIndex
      end
    end
  end
  log("I", "BeamSave", string.format(
    "Transmission save %s (%s) gear=%s lever=%s index=%s mode=%s behavior=%s %s",
    tostring(out.transmissionType),
    tostring(out.gearboxType),
    tostring(out.gear),
    tostring(out.lever),
    tostring(out.gearIndex),
    tostring(out.gearMode),
    tostring(out.gearboxBehavior),
    vehicleTag()
  ))
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
    data.gearboxType = trans.gearboxType
    data.lever = trans.lever
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

-- H-shifter indexes from shiftLogic-automaticGearbox. An index that is not a
-- real mode on that car is forced to Neutral, so 1 and 2 are intentionally
-- absent: those are manual gear numbers, and the automatic map uses 5 for "1".
-- Low ranges are stepped with shiftUp/shiftDown instead.
--   -1 R, 0 N, 1 P, 2 D, 3 S, 6 M
local H_SHIFTER_INDEX = {
  R = -1,
  N = 0,
  P = 1,
  D = 2,
  S = 3,
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
  if type(d) ~= "table" then
    return nil
  end
  if type(d.lever) == "string" and d.lever ~= "" then
    return string.upper(d.lever)
  end
  return parseLever(d.gear, d.automaticModes, d.gearMode, d.gearIndex)
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
  if target:match("^M%d+$") and current == target then
    return true
  end
  -- A bare ratio only counts when the gearbox itself has left neutral/park.
  -- Spawn can show a number while the lever is still N.
  if target == "D" and tonumber(current) and tonumber(current) > 0 then
    local box = getGearbox()
    if box and (box.mode == "neutral" or box.mode == "park") then
      return false
    end
    return true
  end
  if target == "R" and tonumber(current) and tonumber(current) < 0 then
    local box = getGearbox()
    if box and (box.mode == "neutral" or box.mode == "park") then
      return false
    end
    return true
  end
  return false
end

local function isAutomatic(d)
  local live = classifyGearbox(getGearbox(), automaticModesOf(getVehicleController()))
  if live == "automatic" then
    return true
  end
  if live == "manual" then
    return false
  end
  if type(d) ~= "table" then
    return false
  end
  if type(d.gearboxType) == "string" then
    local saved = classifyGearbox({ type = d.gearboxType }, d.automaticModes)
    if saved ~= nil then
      return saved == "automatic"
    end
  end
  if type(d.lever) == "string" and d.lever ~= "" then
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
  local raw = string.upper(tostring(d.gear or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "R" or raw == "REVERSE" or raw == "REV" then
    return -1
  end
  if raw == "N" or raw == "NEUTRAL" then
    return 0
  end
  local fromName = tonumber(raw)
  if fromName ~= nil then
    return fromName
  end
  return tonumber(d.gearIndex)
end

local function restoreManualGear(d, vc)
  local index = manualGearIndex(d)
  if index == nil then
    if not d._logged then
      d._logged = true
      log("I", "BeamSave", "No manual gear stored (" .. vehicleTag(d) .. ", " .. gearboxLabel() .. ", saved gear " .. tostring(d.gear) .. ")")
    end
    return true
  end
  local nowIndex = electrics and electrics.values and electrics.values.gearIndex
  if not d._logged then
    d._logged = true
    log("I", "BeamSave", "Restoring manual gear " .. tostring(index) .. " (now " .. tostring(rawGearName() or nowIndex) .. ", saved gear " .. tostring(d.gear) .. ", " .. gearboxLabel() .. ", " .. vehicleTag(d) .. ")")
  end
  if not d._manualReady then
    if d.gearboxBehavior ~= nil and vc and type(vc.setGearboxMode) == "function" then
      pcall(function()
        vc.setGearboxMode(d.gearboxBehavior)
      end)
    end
    d._manualReady = true
  end
  local before = electrics and electrics.values and electrics.values.gearIndex
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
  local after = electrics and electrics.values and electrics.values.gearIndex
  d._shiftLogs = d._shiftLogs or 0
  if d._shiftLogs < 4 and (not d._shiftLogged or after ~= d._lastShiftAfter) then
    d._shiftLogs = d._shiftLogs + 1
    d._shiftLogged = true
    d._lastShiftAfter = after
    log("I", "BeamSave", "Manual shift " .. vehicleTag(d) .. " " .. tostring(before) .. " -> " .. tostring(after) .. " target " .. tostring(index))
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

-- Arcade shiftToGearIndex only switches into realistic and leaves the default
-- mode, which is Neutral. Ask for realistic once, then shift on that same
-- call and again from updateGFX. Do not wait until the behavior field reads
-- back: on 0.40 that field is often missing, and the old wait never shifted.
-- Manual gear numbers are not passed through this map.
local function restoreAutomaticGear(d, vc)
  local target = leverTarget(d)
  if not target then
    if not d._logged then
      d._logged = true
      log("I", "BeamSave", "No automatic lever stored (" .. vehicleTag(d) .. ", " .. gearboxLabel() .. ", saved gear " .. tostring(d.gear) .. ")")
    end
    return false
  end
  if not d._logged then
    d._logged = true
    log("I", "BeamSave", "Restoring automatic lever to " .. target .. " (now " .. tostring(rawGearName()) .. ", saved gear " .. tostring(d.gear) .. ", " .. gearboxLabel() .. ", behavior " .. behaviorText(vc) .. ", " .. vehicleTag(d) .. ")")
  end
  if transmissionReached(d, target, vc) then
    d._leverHeld = true
    return true
  end

  if not d._askedRealistic then
    if vc and type(vc.setGearboxMode) == "function" then
      pcall(function()
        vc.setGearboxMode("realistic")
      end)
    end
    d._askedRealistic = true
  end

  local hIndex = nil
  if target:match("^M%d+$") then
    hIndex = H_SHIFTER_INDEX.M
  else
    hIndex = H_SHIFTER_INDEX[target]
  end
  if hIndex ~= nil and (d._hMisses or 0) < 4 and vc and type(vc.shiftToGearIndex) == "function" then
    local before = rawGearName()
    pcall(function()
      vc.shiftToGearIndex(hIndex)
    end)
    local after = rawGearName()
    d._shiftLogs = d._shiftLogs or 0
    if d._shiftLogs < 4 and (not d._shiftLogged or after ~= d._lastShiftAfter) then
      d._shiftLogs = d._shiftLogs + 1
      d._shiftLogged = true
      d._lastShiftAfter = after
      log("I", "BeamSave", "Automatic shift " .. vehicleTag(d) .. " " .. tostring(before) .. " -> " .. tostring(after) .. " via shiftToGearIndex(" .. tostring(hIndex) .. "), behavior " .. behaviorText(vc))
    end
    if transmissionReached(d, target, vc) then
      d._leverHeld = true
      return true
    end
    if after == "N" and target ~= "N" then
      d._hMisses = (d._hMisses or 0) + 1
    elseif after == before then
      d._hMisses = (d._hMisses or 0) + 1
    end
    return false
  end

  local beforeWalk = rawGearName()
  stepLever(vc, walkDirection(beforeWalk, target, modesFor(vc, d)))
  local afterWalk = rawGearName()
  if not d._walkLogged then
    d._walkLogged = true
    log("I", "BeamSave", "Automatic step " .. vehicleTag(d) .. " " .. tostring(beforeWalk) .. " -> " .. tostring(afterWalk) .. " toward " .. target .. ", behavior " .. behaviorText(vc))
  end
  if transmissionReached(d, target, vc) then
    d._leverHeld = true
    return true
  end
  return false
end

local function restoreGear(d)
  local vc = getVehicleController()
  if getGearbox() == nil and vc == nil then
    if not d._waitLogged then
      d._waitLogged = true
      log("I", "BeamSave", "Transmission restore waiting, no gearbox or controller yet (" .. vehicleTag(d) .. ")")
    end
    return false
  end
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
  -- Leave the gearbox in realistic. Arcade's shiftToGearIndex does not move
  -- the lever, and putting arcade back on after a successful shift drops it
  -- to the spawn default, Neutral.
end

local pendingRestore = nil

local function scheduleGearRetry(data)
  local auto = isAutomatic(data)
  pendingRestore = {
    data = data,
    tries = auto and 30 or 16,
    wait = 0
  }
end

local gearTickWait = 0

-- Vehicle Lua calls updateGFX (and sometimes update). onUpdate is the game-engine
-- hook, so a restore that only waited there never ran a second time: the lever
-- stayed on the spawn default and manuals never logged a shift.
local function tickPendingGear(dt)
  if not pendingRestore then
    return
  end
  gearTickWait = gearTickWait - (tonumber(dt) or 0)
  if gearTickWait > 0 then
    return
  end
  gearTickWait = 0.05
  pendingRestore.wait = pendingRestore.wait - (tonumber(dt) or 0)
  if pendingRestore.wait > 0 then
    return
  end
  pendingRestore.tries = pendingRestore.tries - 1
  local data = pendingRestore.data
  local auto = isAutomatic(data)
  pendingRestore.wait = auto and 0.15 or 0.1
  local done = false
  local ok, result = pcall(restoreGear, data)
  if ok then
    done = result == true
  end
  if done then
    pcall(finishTransmission, data)
    pendingRestore = nil
  elseif pendingRestore.tries <= 0 then
    log("W", "BeamSave", "Transmission did not reach " .. tostring(leverTarget(data) or data.gear) .. " (now " .. tostring(rawGearName()) .. ", " .. vehicleTag(data) .. ", behavior " .. behaviorText(getVehicleController()) .. ", " .. gearboxLabel() .. ")")
    if data.parkingbrake ~= nil then
      applyParkingBrake(data.parkingbrake)
    end
    pendingRestore = nil
  end
end

function M.updateGFX(dt)
  tickPendingGear(dt)
end

function M.update(dt)
  tickPendingGear(dt)
end

function M.onUpdate(dt)
  tickPendingGear(dt)
end

function M.tickTransmission()
  tickPendingGear(0.2)
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
      local reached = restoreGear(data)
      if reached then
        finishTransmission(data)
      elseif data.gear ~= nil or data.lever ~= nil or data.gearIndex ~= nil or data.gearboxType ~= nil or data.shifterModeIndex ~= nil or data.automaticModes ~= nil or data.transmissionType ~= nil then
        -- Ignition and the post-teleport reseat reset the shifter. Retry from updateGFX.
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
