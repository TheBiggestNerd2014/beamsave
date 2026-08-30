-- BeamSave GE extension for BeamNG.drive 0.39
-- Save and restore vehicle scenes. A bad save must never crash the game.

local M = {}

local FORMAT_VERSION = 1
local BEAMNG_TARGET = "0.39"
local ROOT_DIR = "beamSave"
local SAVE_DIR = "beamSave/saves"
local SETTINGS_PATH = "beamSave/settings.json"
local PENDING_PATH = "beamSave/pendingLoad.json"
local COLLECT_TIMEOUT = 5.0
local SPAWN_GAP = 0.18
local POST_SPAWN_DELAY = 0.55
local PLACE_AGAIN_DELAY = 0.45
local MAP_READY_DELAY = 2.5
local VLUA_EXT = "beamSave_vehicleState"

local DEFAULT_SETTINGS = {
  vehicleLoadMode = "replace",
  autoSwitchMap = true,
  confirmBeforeDeleting = true,
  restoreVelocity = true,
  restoreMechanicalState = true,
  restoreDamage = false,
  restoreLights = true,
  savePlayerVehicle = true,
  saveAllVehicles = true,
  saveAIVehicles = false
}

local settings = {}
local busy = nil
local collectJob = nil
local loadJob = nil
local pendingResume = nil

local function logI(msg)
  log("I", "BeamSave", tostring(msg))
end

local function logW(msg)
  log("W", "BeamSave", tostring(msg))
end

local function logE(msg)
  log("E", "BeamSave", tostring(msg))
end

local function sendUI(payload)
  local ok, err = pcall(function()
    guihooks.trigger("BeamSaveUI", payload)
  end)
  if not ok then
    logE("Failed to send UI event: " .. tostring(err))
  end
end

local function setBusy(state, phase, message)
  busy = state
  sendUI({
    type = "busy",
    busy = state ~= nil,
    phase = phase or state,
    message = message
  })
end

local function notify(level, message, extra)
  local payload = extra or {}
  payload.type = "status"
  payload.level = level
  payload.message = message
  sendUI(payload)
  if level == "error" then
    logE(message)
  elseif level == "warning" then
    logW(message)
  else
    logI(message)
  end
end

local function progress(current, total, message)
  sendUI({
    type = "progress",
    current = current or 0,
    total = total or 0,
    message = message or ""
  })
end

local function copySettings(src)
  local out = {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    if src[k] ~= nil then
      out[k] = src[k]
    else
      out[k] = v
    end
  end
  if out.vehicleLoadMode ~= "add" then
    out.vehicleLoadMode = "replace"
  end
  return out
end

local function ensureDirs()
  pcall(function()
    if FS and FS.directoryCreate then
      if not FS:directoryExists(ROOT_DIR) then
        FS:directoryCreate(ROOT_DIR)
      end
      if not FS:directoryExists(SAVE_DIR) then
        FS:directoryCreate(SAVE_DIR)
      end
    end
  end)
end

local function loadSettings()
  ensureDirs()
  local data = nil
  pcall(function()
    data = jsonReadFile(SETTINGS_PATH)
  end)
  settings = copySettings(type(data) == "table" and data or {})
end

local function persistSettings()
  ensureDirs()
  local ok = pcall(function()
    jsonWriteFile(SETTINGS_PATH, settings, true)
  end)
  if not ok then
    logE("Could not write settings file")
  end
end

local function sanitizeName(raw)
  local name = tostring(raw or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("[^%w%s%-%_]", "")
  name = name:gsub("%.%.", "")
  name = name:gsub("%s+", " ")
  if #name > 64 then
    name = name:sub(1, 64):gsub("%s+$", "")
  end
  return name
end

local function saveFilePath(name)
  return SAVE_DIR .. "/" .. name .. ".bngsave"
end

local function normalizePath(p)
  return tostring(p or ""):gsub("\\", "/")
end

local function canonicalSavePath(p)
  p = normalizePath(p):gsub("^/+", "")
  if p:find("%.%.", 1, true) then return nil end
  local name = p:match("([^/]+)%.[Bb][Nn][Gg][Ss][Aa][Vv][Ee]$")
  if not name or name == "" or name:find("[/\\]") then
    return nil
  end
  -- Accept any absolute/VFS path that is clearly our save file.
  if p:lower():find("beamsave/saves/", 1, true) or not p:find("/", 1, true) then
    return SAVE_DIR .. "/" .. name .. ".bngsave"
  end
  return nil
end

local function isSafeSavePath(p)
  return canonicalSavePath(p) ~= nil
end

local function fileExists(p)
  local exists = false
  pcall(function()
    if FS and FS.fileExists then
      exists = FS:fileExists(p)
    end
  end)
  if exists then return true end
  local data = nil
  pcall(function()
    data = jsonReadFile(p)
  end)
  return data ~= nil
end

local function removeFile(p)
  pcall(function()
    if FS and FS.removeFile then
      FS:removeFile(p)
    elseif deleteFile then
      deleteFile(p)
    end
  end)
end

local function numField(t, i, named)
  if type(t) ~= "table" then return nil end
  return tonumber(t[named] or t[i] or t[tostring(i)])
end

-- Named xyz/xyzw tables survive BeamNG jsonReadFile; raw arrays often come
-- back with string keys ("1","2") so pos[1] is nil and spawn falls back to a line.
local function asXyz(v)
  if v == nil then return nil end
  local x, y, z, w
  if type(v) == "table" then
    x = numField(v, 1, "x")
    y = numField(v, 2, "y")
    z = numField(v, 3, "z")
    w = numField(v, 4, "w")
  else
    x = tonumber(v.x)
    y = tonumber(v.y)
    z = tonumber(v.z)
    if v.w ~= nil then
      w = tonumber(v.w)
    end
  end
  if not x or not y or not z then return nil end
  if x ~= x or y ~= y or z ~= z then return nil end
  local out = { x = x, y = y, z = z }
  if w ~= nil then
    out.w = w
  end
  return out
end

local function vecToTable(v)
  return asXyz(v)
end

local function toVec3(t)
  local v = asXyz(t)
  if not v then return nil end
  return vec3(v.x, v.y, v.z)
end

local function toQuat(t)
  local v = asXyz(t)
  if not v then return quat(0, 0, 0, 1) end
  return quat(v.x, v.y, v.z, v.w or 1)
end

local function isValidTransform(pos, rot)
  local p = asXyz(pos)
  if not p then return false end
  if math.abs(p.x) > 1e7 or math.abs(p.y) > 1e7 or math.abs(p.z) > 1e7 then return false end
  if rot ~= nil and type(rot) ~= "table" and type(rot) ~= "userdata" then
    return false
  end
  return true
end

-- Copy numbers immediately. BeamNG reuses vec3 userdata, so keeping the
-- object would make every vehicle share the last position read.
local function copyWorldPos(raw, y, z)
  if raw == nil then return nil end
  if type(raw) == "number" and type(y) == "number" then
    local x = raw
    if x ~= x or y ~= y then return nil end
    z = tonumber(z) or 0
    return { x = x, y = y, z = z }
  end
  local x, yy, zz
  pcall(function()
    x = tonumber(raw.x)
    yy = tonumber(raw.y)
    zz = tonumber(raw.z)
  end)
  if x and yy and zz and x == x and yy == yy and zz == zz then
    return { x = x, y = yy, z = zz }
  end
  return asXyz(raw)
end

local function readVehiclePos(veh)
  local pos = nil
  pcall(function()
    if veh.getPositionXYZ then
      local x, y, z = veh:getPositionXYZ()
      pos = copyWorldPos(x, y, z)
    end
  end)
  if pos then return pos end
  pcall(function()
    if veh.getPosition then
      pos = copyWorldPos(veh:getPosition())
    end
  end)
  if pos then return pos end
  pcall(function()
    if veh.getPos then
      pos = copyWorldPos(veh:getPos())
    end
  end)
  return pos
end

local function getLevelId()
  local id = nil
  pcall(function()
    if getCurrentLevelIdentifier then
      id = getCurrentLevelIdentifier()
    end
  end)
  if type(id) == "string" and id ~= "" then
    return id
  end
  local missionFile = ""
  pcall(function()
    if getMissionFilename then
      missionFile = getMissionFilename() or ""
    end
  end)
  missionFile = normalizePath(missionFile)
  if missionFile == "" then return nil end
  local level = missionFile:match("^/levels/([^/]+)/")
  return level
end

local function getLevelPath()
  local missionFile = ""
  pcall(function()
    if getMissionFilename then
      missionFile = getMissionFilename() or ""
    end
  end)
  missionFile = normalizePath(missionFile)
  if missionFile ~= "" then
    return missionFile
  end
  local id = getLevelId()
  if id then
    return "/levels/" .. id .. "/main.level.json"
  end
  return nil
end

local function levelExists(levelId, levelPath)
  local candidates = {}
  if type(levelPath) == "string" and levelPath ~= "" then
    candidates[#candidates + 1] = levelPath
  end
  if type(levelId) == "string" and levelId ~= "" then
    candidates[#candidates + 1] = "/levels/" .. levelId .. "/main.level.json"
    candidates[#candidates + 1] = "/levels/" .. levelId .. "/info.json"
  end
  for _, p in ipairs(candidates) do
    local ok = false
    pcall(function()
      if FS and FS.fileExists then
        ok = FS:fileExists(p)
      end
    end)
    if ok then return true end
  end
  local listed = false
  pcall(function()
    if core_levels and core_levels.getList then
      local list = core_levels.getList()
      if type(list) == "table" then
        for _, info in pairs(list) do
          local name = type(info) == "table" and (info.levelName or info.name or info.misFilePath) or info
          if type(name) == "string" and (name == levelId or name:find(levelId, 1, true)) then
            listed = true
          end
        end
      end
    end
  end)
  return listed
end

local function eachVehicle(fn)
  local seen = {}
  local function consider(vid, veh)
    vid = tonumber(vid)
    if not vid or not veh or seen[vid] then return end
    seen[vid] = true
    fn(vid, veh)
  end

  pcall(function()
    if activeVehiclesIterator then
      for vid, veh in activeVehiclesIterator() do
        consider(vid, veh)
      end
    end
  end)
  pcall(function()
    if getAllVehicles then
      local list = getAllVehicles()
      if type(list) == "table" then
        for _, veh in pairs(list) do
          if veh and veh.getID then
            consider(veh:getID(), veh)
          end
        end
      end
    end
  end)
  pcall(function()
    if map and map.objects then
      for id, _ in pairs(map.objects) do
        local veh = nil
        pcall(function()
          veh = be:getObjectByID(id)
        end)
        if veh then
          consider(id, veh)
        end
      end
    end
  end)
  pcall(function()
    if be and be.getObjectCount and be.getObject then
      for i = 0, be:getObjectCount() do
        local veh = be:getObject(i)
        if veh and veh.getID then
          local className = nil
          pcall(function()
            if veh.getClassName then
              className = veh:getClassName()
            end
          end)
          if className == "BeamNGVehicle" or veh.JBeam or veh.getJBeamFilename then
            consider(veh:getID(), veh)
          end
        end
      end
    end
  end)
  pcall(function()
    if not scenetree or not scenetree.findClassObjects then return end
    local names = scenetree.findClassObjects("BeamNGVehicle")
    if not names then return end
    for _, name in ipairs(names) do
      local veh = scenetree.findObject(name)
      if veh and veh.getID then
        consider(veh:getID(), veh)
      end
    end
  end)
end

local function getPlayerId()
  local id = nil
  pcall(function()
    local veh = be:getPlayerVehicle(0)
    if veh and veh.getID then
      id = veh:getID()
    end
  end)
  return id
end

local function vehicleName(veh)
  local name = ""
  pcall(function()
    if veh and veh.getName then
      name = veh:getName() or ""
    end
  end)
  return string.lower(tostring(name))
end

local function looksParkedOrSimplified(text)
  text = string.lower(tostring(text or ""))
  if text == "" then return false end
  -- Only the simplified-traffic family. "Park" as a gear, or a car sitting
  -- in a lot, must not match.
  return text:find("simple_traffic", 1, true)
    or text:find("simpletraffic", 1, true)
    or text:find("simplified_traffic", 1, true)
end

local function asColor(v)
  local named = asXyz(v)
  if named then
    return { named.x, named.y, named.z, named.w or 1 }
  end
  if type(v) ~= "table" then return nil end
  local r = tonumber(v.r or v[1] or v["1"])
  local g = tonumber(v.g or v[2] or v["2"])
  local b = tonumber(v.b or v[3] or v["3"])
  local a = tonumber(v.a or v[4] or v["4"] or 1)
  if not r or not g or not b then return nil end
  return { r, g, b, a or 1 }
end

local function getModel(veh)
  local model = nil
  pcall(function()
    if veh.getJBeamFilename then
      model = veh:getJBeamFilename()
    end
  end)
  if (not model or model == "") and veh.JBeam then
    model = veh.JBeam
  end
  if (not model or model == "") and veh.jbeam then
    model = veh.jbeam
  end
  if (not model or model == "") then
    pcall(function()
      if veh.getID and core_vehicle_manager and core_vehicle_manager.getVehicleData then
        local vd = core_vehicle_manager.getVehicleData(veh:getID())
        if type(vd) == "table" then
          model = vd.jbeam or vd.mainPartName or vd.model
        end
      end
    end)
  end
  if type(model) == "string" then
    model = model:gsub("\\", "/"):gsub("^vehicles/", ""):gsub("/.*$", "")
  end
  return model
end

local function getConfigPath(veh)
  local cfg = veh.partConfig
  if type(cfg) ~= "string" or cfg == "" then
    pcall(function()
      cfg = veh:getField("partConfig", "")
    end)
  end
  if type(cfg) == "string" and cfg ~= "" then
    return cfg
  end
  return nil
end

local parkedIdCache = nil

local function addParkedIds(set, t)
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do
    local id = nil
    if type(v) == "number" then
      id = v
    elseif type(k) == "number" then
      id = k
    elseif tonumber(k) then
      id = tonumber(k)
    elseif type(v) == "table" then
      id = tonumber(v.id or v.vehId or v.gameVehicleID)
    end
    if id then
      set[id] = true
    end
  end
end

local function refreshParkedIds()
  local set = {}
  pcall(function()
    if not gameplay_parking then return end
    if gameplay_parking.getParkedCarsList then
      addParkedIds(set, gameplay_parking.getParkedCarsList())
    end
    if gameplay_parking.getParkedCars then
      addParkedIds(set, gameplay_parking.getParkedCars())
    end
    if gameplay_parking.getParkedCarsData then
      addParkedIds(set, gameplay_parking.getParkedCarsData())
    end
    if gameplay_parking.getParkedVehicles then
      addParkedIds(set, gameplay_parking.getParkedVehicles())
    end
  end)
  parkedIdCache = set
  return set
end

local function trafficInfo(vehId)
  local info = nil
  pcall(function()
    if gameplay_traffic and gameplay_traffic.getTrafficData then
      local data = gameplay_traffic.getTrafficData()
      if type(data) == "table" then
        info = data[vehId]
      end
    end
  end)
  return info
end

-- Only skip simplified-traffic props. Engine off / gear Park is normal state.
local function isParkedOrSimplified(veh, vehId)
  if looksParkedOrSimplified(getModel(veh)) or looksParkedOrSimplified(getConfigPath(veh)) then
    return true
  end
  local partName = nil
  pcall(function()
    if core_vehicle_manager and core_vehicle_manager.getVehicleData then
      local vd = core_vehicle_manager.getVehicleData(vehId)
      if type(vd) == "table" then
        partName = vd.mainPartName or vd.model or vd.jbeam
      end
    end
  end)
  if looksParkedOrSimplified(partName) then
    return true
  end
  local info = trafficInfo(vehId)
  if type(info) == "table" and (info.simplified or info.isSimplified or info.simpleVeh or info.simpleVehicle) then
    return true
  end
  return false
end

local function isAIVehicle(veh, vehId)
  local info = trafficInfo(vehId)
  if type(info) == "table" and (info.isTraffic == true or info.isAI == true) then
    return true
  end
  local name = vehicleName(veh)
  if name:find("traffic", 1, true) or name:find("ai_", 1, true) then
    return true
  end
  return false
end

local function shouldSkipLoadVehicle(data)
  if type(data) ~= "table" then return true end
  if data.isParked or data.isSimplified then return true end
  if looksParkedOrSimplified(data.model)
    or looksParkedOrSimplified(data.configPath)
    or looksParkedOrSimplified(data.objectName) then
    return true
  end
  return false
end

local function shouldSaveVehicle(veh, vehId, playerId)
  local isPlayer = playerId ~= nil and vehId == playerId
  if (not isPlayer) and isParkedOrSimplified(veh, vehId) then
    return false
  end
  local isAI = isAIVehicle(veh, vehId)
  if isPlayer then
    return settings.savePlayerVehicle == true
  end
  if isAI then
    return settings.saveAIVehicles == true
  end
  return settings.saveAllVehicles == true
end

local function isNonZeroDir(t)
  t = asXyz(t)
  if not t then return false end
  return (t.x * t.x + t.y * t.y + t.z * t.z) > 1e-8
end

-- setPositionRotation expects the quat from quatFromDir(forward, up).
-- veh:getRotation() in GE stays at the spawn heading and is not usable.
local function quatFromDirUp(dir, up)
  dir = asXyz(dir)
  up = asXyz(up)
  if not isNonZeroDir(dir) or not isNonZeroDir(up) or not quatFromDir then
    return nil
  end
  local ok, q = pcall(function()
    local d = vec3(dir.x, dir.y, dir.z)
    local u = vec3(up.x, up.y, up.z)
    if d.normalized then
      d = d:normalized()
    end
    if u.normalized then
      u = u:normalized()
    end
    -- BeamNG vehicle forward is -Y. quatFromDir expects that back-axis
    -- direction, so pass -forward (same pairing BeamMP uses).
    return quatFromDir(-d, u)
  end)
  if ok and q then
    return {
      x = tonumber(q.x) or 0,
      y = tonumber(q.y) or 0,
      z = tonumber(q.z) or 0,
      w = tonumber(q.w) or 1
    }
  end
  return nil
end

local function readDirectionPair(veh)
  local dir, up = nil, nil
  pcall(function()
    if veh.getDirectionVector then
      dir = copyWorldPos(veh:getDirectionVector())
    end
    if veh.getDirectionVectorUp then
      up = copyWorldPos(veh:getDirectionVectorUp())
    end
  end)
  if (not isNonZeroDir(dir) or not isNonZeroDir(up)) and veh.getID then
    pcall(function()
      local vdata = map and map.objects and map.objects[veh:getID()]
      if type(vdata) ~= "table" then return end
      if not isNonZeroDir(dir) and vdata.dirVec then
        dir = copyWorldPos(vdata.dirVec)
      end
      if not isNonZeroDir(up) and (vdata.dirVecUp or vdata.upVec) then
        up = copyWorldPos(vdata.dirVecUp or vdata.upVec)
      end
    end)
  end
  if not isNonZeroDir(dir) then dir = nil end
  if not isNonZeroDir(up) then up = nil end
  return dir, up
end

local function getRotationTable(veh)
  local dir, up = readDirectionPair(veh)
  local rot = quatFromDirUp(dir, up)
  if rot then
    return rot, dir, up
  end
  return { x = 0, y = 0, z = 0, w = 1 }, dir, up
end

local function collectGEState(veh, vehId, index, playerId)
  local pos = readVehiclePos(veh)
  local vel = nil
  pcall(function()
    vel = asXyz(veh:getVelocity())
  end)
  local color, color2 = nil, nil
  pcall(function() color = asXyz(veh.color) end)
  pcall(function() color2 = asXyz(veh.color2) end)
  local model = getModel(veh)
  local configPath = getConfigPath(veh)
  local parked = isParkedOrSimplified(veh, vehId)
  if not pos then
    logW("Could not read position for vehicle " .. tostring(vehId) .. " (" .. tostring(model) .. ")")
  end
  local rot, dir, up = getRotationTable(veh)
  return {
    index = index,
    vehId = vehId,
    objectName = vehicleName(veh),
    isPlayerVehicle = playerId ~= nil and vehId == playerId,
    isAI = isAIVehicle(veh, vehId),
    isParked = parked,
    isSimplified = parked or looksParkedOrSimplified(model) or looksParkedOrSimplified(configPath),
    model = model,
    configPath = configPath,
    color = color,
    color2 = color2,
    pos = pos,
    rot = rot,
    dir = dir,
    up = up,
    vel = vel,
    hasBeamstate = false,
    beamstateFile = nil
  }
end

local function queueVehicleLua(veh, command)
  local ok, err = pcall(function()
    veh:queueLuaCommand(command)
  end)
  if not ok then
    logW("queueLuaCommand failed: " .. tostring(err))
    return false
  end
  return true
end

local function loadVluaAndRun(veh, call)
  -- Concatenate instead of string.format so serialized restore tables cannot
  -- inject % format tokens.
  local cmd = 'pcall(function() extensions.load("' .. VLUA_EXT .. '") if extensions.'
    .. VLUA_EXT .. ' then extensions.' .. VLUA_EXT .. '.' .. call .. ' end end)'
  return queueVehicleLua(veh, cmd)
end

local function beamstatePath(saveName, index)
  return SAVE_DIR .. "/" .. saveName .. "_beam" .. tostring(index) .. ".json"
end

local function sendSettings()
  sendUI({ type = "settings", settings = settings })
end

local function readSaveMeta(path)
  local data = nil
  local ok = pcall(function()
    data = jsonReadFile(path)
  end)
  local name = path:match("([^/]+)%.bngsave$") or "Unknown"
  if not ok or type(data) ~= "table" then
    return {
      path = path,
      saveName = name,
      levelId = "?",
      vehicleCount = 0,
      createdAt = "",
      corrupt = true
    }
  end
  return {
    path = path,
    saveName = data.saveName or name,
    levelId = data.levelId or "?",
    vehicleCount = tonumber(data.vehicleCount) or (data.vehicles and #data.vehicles) or 0,
    createdAt = data.createdAt or "",
    beamSaveVersion = data.beamSaveVersion,
    corrupt = false
  }
end

local function collectFindResults(res, into)
  if type(res) ~= "table" then return end
  for k, v in pairs(res) do
    local f = nil
    if type(v) == "string" then
      f = v
    elseif type(k) == "string" then
      f = k
    end
    if f then
      into[#into + 1] = f
    end
  end
end

local function rawFind(dir, pattern)
  local found = {}
  pcall(function()
    if FS and FS.findFiles then
      collectFindResults(FS:findFiles(dir, pattern, -1, true, false), found)
    end
  end)
  pcall(function()
    if FS and FS.findFiles then
      collectFindResults(FS:findFiles(dir, pattern, -1, true, true), found)
    end
  end)
  pcall(function()
    if FS and FS.findFiles then
      collectFindResults(FS:findFiles(dir, pattern, 0, true, false), found)
    end
  end)
  return found
end

local function listSaveFiles()
  ensureDirs()
  local raw = {}
  local dirs = {
    SAVE_DIR, SAVE_DIR .. "/", "/" .. SAVE_DIR, "/" .. SAVE_DIR .. "/",
    ROOT_DIR, ROOT_DIR .. "/", "/" .. ROOT_DIR, "/" .. ROOT_DIR .. "/"
  }
  local patterns = { "*.bngsave", "*.BNGSAVE", "*" }
  for _, dir in ipairs(dirs) do
    for _, pattern in ipairs(patterns) do
      for _, f in ipairs(rawFind(dir, pattern)) do
        raw[#raw + 1] = f
      end
    end
  end

  -- Index written on each successful save, in case findFiles misses user files.
  pcall(function()
    local idx = jsonReadFile(SAVE_DIR .. "/index.json")
    if type(idx) == "table" and type(idx.files) == "table" then
      for _, name in ipairs(idx.files) do
        if type(name) == "string" then
          raw[#raw + 1] = SAVE_DIR .. "/" .. name
        end
      end
    end
  end)

  local seen = {}
  local saves = {}
  for _, f in ipairs(raw) do
    local path = canonicalSavePath(f)
    if path and not seen[path] then
      seen[path] = true
      saves[#saves + 1] = readSaveMeta(path)
    end
  end
  table.sort(saves, function(a, b)
    return tostring(a.createdAt or "") > tostring(b.createdAt or "")
  end)
  logI("Listed " .. tostring(#saves) .. " save(s) from " .. tostring(#raw) .. " candidate file(s)")
  pcall(function()
    local names = {}
    for _, s in ipairs(saves) do
      local n = tostring(s.path or ""):match("([^/]+%.bngsave)$")
      if n then names[#names + 1] = n end
    end
    jsonWriteFile(SAVE_DIR .. "/index.json", { files = names }, true)
  end)
  return saves
end

local function rememberIndexedSave(saveName)
  pcall(function()
    local files = {}
    local seen = {}
    local idx = jsonReadFile(SAVE_DIR .. "/index.json")
    if type(idx) == "table" and type(idx.files) == "table" then
      for _, name in ipairs(idx.files) do
        if type(name) == "string" and not seen[name] then
          seen[name] = true
          files[#files + 1] = name
        end
      end
    end
    local entry = saveName .. ".bngsave"
    if not seen[entry] then
      files[#files + 1] = entry
    end
    jsonWriteFile(SAVE_DIR .. "/index.json", { files = files }, true)
  end)
end

local function forgetIndexedSave(savePath)
  pcall(function()
    local drop = (canonicalSavePath(savePath) or ""):match("([^/]+%.bngsave)$")
    local idx = jsonReadFile(SAVE_DIR .. "/index.json")
    if type(idx) ~= "table" or type(idx.files) ~= "table" then return end
    local files = {}
    for _, name in ipairs(idx.files) do
      if name ~= drop then
        files[#files + 1] = name
      end
    end
    jsonWriteFile(SAVE_DIR .. "/index.json", { files = files }, true)
  end)
end

local function sendSaveList()
  local saves = listSaveFiles()
  sendUI({ type = "saves", saves = saves })
  return saves
end

local function companionFiles(savePath)
  local base = normalizePath(savePath):gsub("%.bngsave$", "")
  local prefix = base:match("([^/]+)$") or ""
  local found = {}
  pcall(function()
    if FS and FS.findFiles then
      found = FS:findFiles(SAVE_DIR, prefix .. "_beam*.json", -1, true, false) or {}
    end
  end)
  local out = {}
  for _, f in ipairs(found) do
    f = normalizePath(f)
    if not f:find("/", 1, true) then
      f = SAVE_DIR .. "/" .. f
    end
    if f:sub(1, #SAVE_DIR + 1) == SAVE_DIR .. "/" and not f:find("%.%.", 1, true) then
      out[#out + 1] = f
    end
  end
  return out
end

local function finishSaveWrite()
  if not collectJob then return end
  local job = collectJob
  collectJob = nil

  local vehicles = {}
  for _, item in ipairs(job.order) do
    local data = job.collected[item]
    if data and data.model and data.model ~= "" then
      if data.isParked or data.isSimplified or looksParkedOrSimplified(data.model) or looksParkedOrSimplified(data.configPath) then
        logI("Omitting parked/simplified vehicle from save: " .. tostring(data.model))
      else
        data.vehId = nil
        data.pos = asXyz(data.pos)
        data.dir = asXyz(data.dir)
        data.up = asXyz(data.up)
        data.rot = quatFromDirUp(data.dir, data.up) or asXyz(data.rot) or { x = 0, y = 0, z = 0, w = 1 }
        data.vel = asXyz(data.vel)
        data.angVel = asXyz(data.angVel)
        if data.pos then
          logI(string.format("Saved %s pos=(%.3f, %.3f, %.3f)", tostring(data.model), data.pos.x, data.pos.y, data.pos.z))
        else
          logW("No position collected for " .. tostring(data.model) .. "; load will use the default spawn line")
        end
        vehicles[#vehicles + 1] = data
      end
    end
  end

  local payload = {
    beamSaveVersion = FORMAT_VERSION,
    beamNGVersion = BEAMNG_TARGET,
    saveName = job.saveName,
    levelId = job.levelId,
    levelPath = job.levelPath,
    createdAt = os.date("!%Y-%m-%dT%H:%M:%S"),
    vehicleCount = #vehicles,
    vehicles = vehicles
  }

  local path = saveFilePath(job.saveName)
  local wrote = false
  local err = nil
  wrote, err = pcall(function()
    jsonWriteFile(path, payload, true)
  end)
  setBusy(nil)
  if not wrote then
    notify("error", "Could not write save file: " .. tostring(err))
    return
  end
  if not fileExists(path) then
    notify("error", "Save file was not created. Check that BeamSave can write to the user-data folder.")
    return
  end
  rememberIndexedSave(job.saveName)
  notify("success", string.format("Saved \"%s\" (%d vehicle%s).", job.saveName, #vehicles, #vehicles == 1 and "" or "s"), {
    saveName = job.saveName,
    vehicleCount = #vehicles
  })
  sendSaveList()
end

local function mergeVluaData(dest, src)
  if type(dest) ~= "table" or type(src) ~= "table" then return end
  dest.fuel = src.fuel
  dest.engineRunning = src.engineRunning
  dest.rpm = src.rpm
  dest.watertemp = src.watertemp
  dest.oiltemp = src.oiltemp
  dest.lights = src.lights
  dest.gear = src.gear
  dest.gearIndex = src.gearIndex
  dest.gearMode = src.gearMode
  dest.throttle = src.throttle
  dest.brake = src.brake
  dest.ignitionLevel = src.ignitionLevel
  if src.angVel then
    dest.angVel = asXyz(src.angVel) or src.angVel
  end
  if src.vel then
    dest.vel = asXyz(src.vel) or src.vel
  end
  -- VLUA obj:getPosition() is the live world ref-node. GE getPosition() can
  -- still be the original spawn point on the road after the vehicle has moved.
  local vluaPos = asXyz(src.pos)
  if vluaPos then
    dest.pos = vluaPos
  end
  -- Prefer live facing vectors. obj:getRotation() is a different convention
  -- from setPositionRotation and will point the vehicle the wrong way.
  if src.dir then
    dest.dir = asXyz(src.dir) or dest.dir
  end
  if src.up then
    dest.up = asXyz(src.up) or dest.up
  end
  dest.rot = quatFromDirUp(dest.dir, dest.up) or dest.rot
end

local function deleteVehicle(veh)
  if not veh then return end
  local ok = pcall(function()
    veh:delete()
  end)
  if ok then return end
  pcall(function()
    if be.deleteObject then
      be:deleteObject(veh:getID())
    end
  end)
end

local function deleteCurrentVehicles()
  local list = {}
  eachVehicle(function(_, veh)
    list[#list + 1] = veh
  end)
  for _, veh in ipairs(list) do
    pcall(deleteVehicle, veh)
  end
  logI("Deleted " .. tostring(#list) .. " current vehicle(s) before replace load")
end

local function enterVehicle(veh)
  pcall(function()
    if be.enterVehicle then
      be:enterVehicle(0, veh)
    end
  end)
end

-- Absolute world teleport. Never use setClusterPosRelRot / safeTeleport:
-- those are relative or they snap to the road.
local function applyWorldTransform(veh, data)
  if not veh or not data then return false end
  local p = asXyz(data.pos)
  if not p then
    logW("No world position for " .. tostring(data.model) .. ", leaving spawn pose")
    return false
  end
  local r = quatFromDirUp(data.dir, data.up) or asXyz(data.rot) or { x = 0, y = 0, z = 0, w = 1 }
  local placed = false
  pcall(function()
    veh:setPositionRotation(p.x, p.y, p.z, r.x, r.y, r.z, r.w or 1)
    placed = true
  end)
  if not placed then
    pcall(function()
      if veh.setPosRot then
        veh:setPosRot(p.x, p.y, p.z, r.x, r.y, r.z, r.w or 1)
        placed = true
      end
    end)
  end
  if not placed then
    pcall(function()
      veh:setPosition(vec3(p.x, p.y, p.z))
      placed = true
    end)
  end
  if placed then
    logI(string.format(
      "Placed %s at world (%.3f, %.3f, %.3f) rot=(%.3f, %.3f, %.3f, %.3f)",
      tostring(data.model), p.x, p.y, p.z, r.x, r.y, r.z, r.w or 1
    ))
  end
  return placed
end

local function queueVehicleRestore(veh, data)
  if not veh or not data then return end
  local restore = {
    fuel = data.fuel,
    engineRunning = data.engineRunning,
    rpm = data.rpm,
    watertemp = data.watertemp,
    oiltemp = data.oiltemp,
    lights = data.lights,
    gear = data.gear,
    gearIndex = data.gearIndex,
    gearMode = data.gearMode,
    throttle = data.throttle,
    brake = data.brake,
    ignitionLevel = data.ignitionLevel,
    vel = settings.restoreVelocity and data.vel or nil,
    angVel = settings.restoreVelocity and data.angVel or nil,
    restoreVelocity = settings.restoreVelocity == true,
    restoreMechanicalState = settings.restoreMechanicalState == true,
    restoreLights = settings.restoreLights == true
  }
  local serialized = nil
  pcall(function()
    serialized = serialize(restore)
  end)
  if serialized then
    loadVluaAndRun(veh, "restore(" .. serialized .. ")")
  else
    logW("Could not serialize restore payload for " .. tostring(data.model))
  end
end

local function applyPostSpawn(veh, data)
  if not veh or not data then return end
  applyWorldTransform(veh, data)
  queueVehicleRestore(veh, data)

  if settings.restoreDamage and data.hasBeamstate and data.beamstateFile then
    local bp = normalizePath(data.beamstateFile)
    if bp:sub(1, #SAVE_DIR + 1) == SAVE_DIR .. "/" and not bp:find("%.%.", 1, true) and fileExists(bp) then
      queueVehicleLua(veh, string.format('pcall(function() if beamstate then beamstate.load(%q) end end)', bp))
    else
      logW("Skipping beamstate for " .. tostring(data.model) .. ": file missing or unsafe")
    end
  end
end

local function snapshotVehicleIds()
  local ids = {}
  eachVehicle(function(id, _)
    ids[id] = true
  end)
  return ids
end

local function findNewVehicle(oldIds)
  local found = nil
  eachVehicle(function(id, veh)
    if not oldIds[id] then
      found = veh
    end
  end)
  return found
end

local function spawnOne(data)
  if type(data) ~= "table" or type(data.model) ~= "string" or data.model == "" then
    return nil, "missing model"
  end
  if not core_vehicles or not core_vehicles.spawnNewVehicle then
    return nil, "spawn API unavailable"
  end

  local opts = {
    autoEnterVehicle = false,
    cling = false,
    safeSpawn = false
  }
  if type(data.configPath) == "string" and data.configPath ~= "" then
    opts.config = data.configPath
  end
  -- Do not pass pos/rot here. spawnNewVehicle runs setSafePosition, which
  -- snaps to the road and offsets behind the current vehicle.
  local color = asColor(data.color)
  if color then
    opts.color = color
  end
  local color2 = asColor(data.color2)
  if color2 then
    opts.color2 = color2
  end

  local veh = nil
  local ok, result = pcall(function()
    return core_vehicles.spawnNewVehicle(data.model, opts)
  end)
  if ok and result then
    veh = result
  end
  if not veh then
    ok, result = pcall(function()
      return core_vehicles.spawnNewVehicle(data.model, { config = opts.config, color = opts.color, color2 = opts.color2 })
    end)
    if ok then
      veh = result
    end
  end
  if not veh then
    return nil, "spawn failed (missing vehicle mod or config?)"
  end
  return veh, nil
end

local function finishLoad()
  if not loadJob then return end
  local job = loadJob
  loadJob = nil
  setBusy(nil)
  local okCount = #job.succeeded
  local failCount = #job.failed
  local msg = string.format("Restored %d of %d vehicle%s.", okCount, job.total, job.total == 1 and "" or "s")
  if failCount > 0 then
    local names = {}
    for i, f in ipairs(job.failed) do
      if i <= 4 then
        names[#names + 1] = f.model or ("#" .. tostring(i))
      end
    end
    msg = msg .. " Failed: " .. table.concat(names, ", ")
    if failCount > 4 then
      msg = msg .. string.format(" and %d more", failCount - 4)
    end
    notify("warning", msg, { restored = okCount, failed = failCount })
  else
    notify("success", msg, { restored = okCount, failed = 0 })
  end
end

local function stepLoadJob()
  if not loadJob then return end
  local job = loadJob
  if job.phase == "waitDelete" then
    return
  end
  if job.phase == "spawn" then
    job.index = job.index + 1
    if job.index > #job.vehicles then
      job.phase = "done"
      finishLoad()
      return
    end
    local data = job.vehicles[job.index]
    progress(job.index, job.total, string.format("Spawning %s (%d/%d)...", tostring(data.model or "vehicle"), job.index, job.total))
    job.oldIds = snapshotVehicleIds()
    local veh, err = spawnOne(data)
    job.pendingData = data
    if veh then
      job.pendingVeh = veh
      job.phase = "settle"
      job.timer = POST_SPAWN_DELAY
      return
    end
    -- spawnNewVehicle is asynchronous in some 0.39 paths; wait for a new ID.
    job.pendingVeh = nil
    job.spawnErr = err
    job.phase = "waitSpawn"
    job.timer = 0.05
    job.spawnWait = 2.5
    return
  end
  if job.phase == "waitSpawn" then
    local veh = findNewVehicle(job.oldIds or {})
    if veh then
      job.pendingVeh = veh
      job.phase = "settle"
      job.timer = POST_SPAWN_DELAY
      return
    end
    if job.spawnWait <= 0 then
      local data = job.pendingData
      logW("Could not spawn " .. tostring(data and data.model) .. ": " .. tostring(job.spawnErr or "timed out waiting for vehicle"))
      job.failed[#job.failed + 1] = { model = data and data.model, reason = job.spawnErr or "spawn timeout" }
      job.pendingData = nil
      job.phase = "spawn"
      job.timer = SPAWN_GAP
    else
      job.timer = 0.05
    end
    return
  end
  if job.phase == "settle" then
    local veh = job.pendingVeh
    local data = job.pendingData
    local ok = pcall(applyPostSpawn, veh, data)
    if not ok then
      logW("Post-spawn restore failed for " .. tostring(data and data.model))
      job.failed[#job.failed + 1] = { model = data and data.model, reason = "restore failed" }
      job.pendingVeh = nil
      job.pendingData = nil
      job.phase = "spawn"
      job.timer = SPAWN_GAP
      return
    end
    job.phase = "reseat"
    job.timer = PLACE_AGAIN_DELAY
    return
  end
  if job.phase == "reseat" then
    local veh = job.pendingVeh
    local data = job.pendingData
    job.pendingVeh = nil
    job.pendingData = nil
    pcall(applyWorldTransform, veh, data)
    -- Teleport resets ignition to spawn default (usually running). Re-apply last.
    pcall(queueVehicleRestore, veh, data)
    job.succeeded[#job.succeeded + 1] = data and data.model
    if data and data.isPlayerVehicle then
      enterVehicle(veh)
    end
    job.phase = "spawn"
    job.timer = SPAWN_GAP
  end
end

local function startSpawnQueue(saveData)
  local vehicles = {}
  for _, v in ipairs(saveData.vehicles or {}) do
    if shouldSkipLoadVehicle(v) then
      logI("Skipping parked/simplified vehicle: " .. tostring(v.model or v.objectName or "?"))
    else
      v.pos = asXyz(v.pos)
      v.dir = asXyz(v.dir)
      v.up = asXyz(v.up)
      v.rot = quatFromDirUp(v.dir, v.up) or asXyz(v.rot)
      v.vel = asXyz(v.vel)
      v.angVel = asXyz(v.angVel)
      vehicles[#vehicles + 1] = v
    end
  end
  loadJob = {
    phase = "spawn",
    vehicles = vehicles,
    index = 0,
    total = #vehicles,
    timer = 0.05,
    succeeded = {},
    failed = {},
    pendingVeh = nil,
    pendingData = nil
  }
  if loadJob.total == 0 then
    finishLoad()
    return
  end
  progress(0, loadJob.total, "Preparing to spawn vehicles...")
end

local function validateSave(data)
  if type(data) ~= "table" then
    return nil, "Save file is not valid JSON"
  end
  local ver = tonumber(data.beamSaveVersion)
  if not ver then
    return nil, "Save is missing beamSaveVersion"
  end
  if ver > FORMAT_VERSION then
    return nil, string.format("Unsupported save version %s (this BeamSave reads v%s)", tostring(ver), tostring(FORMAT_VERSION))
  end
  if type(data.vehicles) ~= "table" then
    return nil, "Save is missing vehicle data"
  end
  if not data.levelId or data.levelId == "" then
    logW("Save has no levelId; map switching will be skipped")
  end
  return data, nil
end

local function beginRestore(saveData)
  if settings.vehicleLoadMode == "replace" then
    deleteCurrentVehicles()
  end
  startSpawnQueue(saveData)
end

local function loadValidatedSave(saveData, skipMapCheck)
  setBusy("load", "load", "Loading save...")
  progress(0, 1, "Reading save...")

  local currentLevel = getLevelId()
  local savedLevel = saveData.levelId
  if not skipMapCheck and savedLevel and currentLevel and savedLevel ~= currentLevel then
    if settings.autoSwitchMap then
      if not levelExists(savedLevel, saveData.levelPath) then
        setBusy(nil)
        notify("error", "Saved map \"" .. tostring(savedLevel) .. "\" is not installed.")
        return
      end
      local levelPath = saveData.levelPath
      if type(levelPath) ~= "string" or levelPath == "" then
        levelPath = "/levels/" .. savedLevel .. "/main.level.json"
      end
      ensureDirs()
      local pending = { savePath = saveFilePath(saveData.saveName), confirmed = true }
      -- Prefer the path we actually loaded from if present
      if saveData._path then
        pending.savePath = saveData._path
      end
      local wrote = pcall(function()
        jsonWriteFile(PENDING_PATH, pending, true)
      end)
      if not wrote then
        setBusy(nil)
        notify("error", "Could not write pending load file before switching maps.")
        return
      end
      notify("info", "Switching to map \"" .. savedLevel .. "\"...")
      local started = pcall(function()
        core_levels.startLevel(levelPath)
      end)
      if not started then
        removeFile(PENDING_PATH)
        setBusy(nil)
        notify("error", "BeamNG could not start level " .. tostring(levelPath))
        return
      end
      return
    else
      setBusy(nil)
      notify("warning", string.format("Save is for map \"%s\" but you are on \"%s\". Enable Automatically Switch Maps, or load that map first.", tostring(savedLevel), tostring(currentLevel)))
      return
    end
  end

  beginRestore(saveData)
end

-- Public API ---------------------------------------------------------------

function M.requestUIState()
  local ok, err = pcall(function()
    sendSettings()
    sendSaveList()
    sendUI({ type = "busy", busy = busy ~= nil, phase = busy })
  end)
  if not ok then
    logE("requestUIState failed: " .. tostring(err))
  end
end

function M.getSettings()
  sendSettings()
end

function M.updateSettings(jsonStr)
  local ok, err = pcall(function()
    local data = jsonStr
    if type(jsonStr) == "string" then
      data = jsonDecode(jsonStr)
    end
    if type(data) ~= "table" then
      notify("error", "Invalid settings payload")
      return
    end
    settings = copySettings(data)
    persistSettings()
    sendSettings()
    logI("Settings updated")
  end)
  if not ok then
    logE("updateSettings failed: " .. tostring(err))
    notify("error", "Could not update settings")
  end
end

function M.listSaves()
  local ok, err = pcall(sendSaveList)
  if not ok then
    logE("listSaves failed: " .. tostring(err))
    notify("error", "Could not list saves")
  end
end

-- Kept for older UI builds. Do not return JSON: engineLua treats a returned
-- string as Lua source, and JSON "key":value is a syntax error.
function M.getSavesJson()
  local ok, err = pcall(sendSaveList)
  if not ok then
    logE("getSavesJson failed: " .. tostring(err))
  end
end

function M.saveScene(saveName, overwrite)
  local ok, err = pcall(function()
    if busy then
      notify("warning", "BeamSave is already busy.")
      return
    end
    if not getLevelId() then
      notify("error", "No map is loaded. Enter a level before saving.")
      return
    end

    local name = sanitizeName(saveName)
    if name == "" then
      notify("error", "Enter a save name. Use letters, numbers, spaces, dashes, or underscores.")
      return
    end
    if name ~= tostring(saveName or ""):gsub("^%s+", ""):gsub("%s+$", "") then
      logW("Save name sanitized from \"" .. tostring(saveName) .. "\" to \"" .. name .. "\"")
    end

    ensureDirs()
    local path = saveFilePath(name)
    if fileExists(path) and not overwrite then
      sendUI({ type = "confirmOverwrite", saveName = name })
      return
    end

    local playerId = getPlayerId()
    refreshParkedIds()
    local order = {}
    local collected = {}
    local pending = {}
    local index = 0
    local seen = 0
    local skipped = 0

    eachVehicle(function(vehId, veh)
      pcall(function()
        if veh.getActive and veh.setActive and veh:getActive() == false then
          veh:setActive(true)
        end
      end)
      seen = seen + 1
      if shouldSaveVehicle(veh, vehId, playerId) then
        index = index + 1
        local ge = collectGEState(veh, vehId, index - 1, playerId)
        if not ge.model or ge.model == "" then
          skipped = skipped + 1
          logW("Skipping vehicle " .. tostring(vehId) .. ": could not read model")
        else
          if settings.restoreDamage then
            local bp = beamstatePath(name, ge.index)
            ge.beamstateFile = bp
            ge.hasBeamstate = true
            queueVehicleLua(veh, string.format('pcall(function() if beamstate then beamstate.save(%q) end end)', bp))
          end
          collected[vehId] = ge
          order[#order + 1] = vehId
          pending[vehId] = true
          local queued = loadVluaAndRun(veh, "collect()")
          if not queued then
            pending[vehId] = nil
          end
        end
      else
        skipped = skipped + 1
        logI(string.format(
          "Not saving vehicle %s (%s) player=%s parked/simplified=%s ai=%s",
          tostring(vehId),
          tostring(getModel(veh) or "?"),
          tostring(playerId ~= nil and vehId == playerId),
          tostring(isParkedOrSimplified(veh, vehId)),
          tostring(isAIVehicle(veh, vehId))
        ))
      end
    end)
    logI(string.format("Found %d vehicle(s) in the scene; saving %d, skipped %d", seen, #order, skipped))

    collectJob = {
      saveName = name,
      levelId = getLevelId(),
      levelPath = getLevelPath(),
      collected = collected,
      pending = pending,
      order = order,
      timeout = COLLECT_TIMEOUT
    }

    setBusy("save", "save", "Collecting vehicle state...")
    if #order == 0 then
      finishSaveWrite()
      return
    end
    progress(0, #order, string.format("Collecting state from %d vehicle%s...", #order, #order == 1 and "" or "s"))
  end)
  if not ok then
    collectJob = nil
    setBusy(nil)
    logE("saveScene failed: " .. tostring(err))
    notify("error", "Save failed unexpectedly. See the log for [BeamSave] details.")
  end
end

function M.onVehicleDataCollected(vehId, data)
  local ok, err = pcall(function()
    if not collectJob then return end
    vehId = tonumber(vehId)
    if not vehId then return end
    if type(data) == "string" then
      local decoded = nil
      pcall(function() decoded = jsonDecode(data) end)
      data = decoded
    end
    if collectJob.collected[vehId] and type(data) == "table" then
      mergeVluaData(collectJob.collected[vehId], data)
    end
    collectJob.pending[vehId] = nil
    local remaining = 0
    for _ in pairs(collectJob.pending) do
      remaining = remaining + 1
    end
    local total = #collectJob.order
    progress(total - remaining, total, string.format("Collected %d/%d vehicles...", total - remaining, total))
    if remaining == 0 then
      finishSaveWrite()
    end
  end)
  if not ok then
    logE("onVehicleDataCollected failed: " .. tostring(err))
  end
end

function M.loadSave(savePath, confirmed)
  local ok, err = pcall(function()
    if busy then
      notify("warning", "BeamSave is already busy.")
      return
    end
    savePath = canonicalSavePath(savePath)
    if not savePath then
      notify("error", "Refusing to load a file outside the BeamSave folder.")
      return
    end
    if not getLevelId() then
      notify("error", "No map is loaded.")
      return
    end

    local data = nil
    local readOk = pcall(function()
      data = jsonReadFile(savePath)
    end)
    if not readOk then
      notify("error", "Could not read save file.")
      return
    end
    local saveData, verr = validateSave(data)
    if not saveData then
      notify("error", verr or "Invalid save")
      return
    end
    saveData._path = savePath
    if type(saveData.saveName) ~= "string" or saveData.saveName == "" then
      saveData.saveName = savePath:match("([^/]+)%.bngsave$") or "save"
    end

    if settings.vehicleLoadMode == "replace" and settings.confirmBeforeDeleting and not confirmed then
      sendUI({ type = "confirmDeleteVehicles", savePath = savePath })
      return
    end

    loadValidatedSave(saveData, false)
  end)
  if not ok then
    loadJob = nil
    setBusy(nil)
    logE("loadSave failed: " .. tostring(err))
    notify("error", "Load failed unexpectedly. See the log for [BeamSave] details.")
  end
end

function M.deleteSave(savePath)
  local ok, err = pcall(function()
    savePath = canonicalSavePath(savePath)
    if not savePath then
      notify("error", "Refusing to delete a file outside the BeamSave folder.")
      return
    end
    if not fileExists(savePath) then
      notify("warning", "Save file was already gone.")
      forgetIndexedSave(savePath)
      sendSaveList()
      return
    end
    for _, extra in ipairs(companionFiles(savePath)) do
      removeFile(extra)
    end
    removeFile(savePath)
    forgetIndexedSave(savePath)
    notify("success", "Deleted save.")
    sendSaveList()
  end)
  if not ok then
    logE("deleteSave failed: " .. tostring(err))
    notify("error", "Could not delete save.")
  end
end

function M.onExtensionLoaded()
  local ok, err = pcall(function()
    loadSettings()
    ensureDirs()
    logI("Loaded (target BeamNG.drive " .. BEAMNG_TARGET .. ")")
  end)
  if not ok then
    logE("onExtensionLoaded failed: " .. tostring(err))
  end
end

local function tryResumePendingLoad()
  if loadJob or pendingResume then return end
  local data = nil
  pcall(function()
    data = jsonReadFile(PENDING_PATH)
  end)
  if type(data) ~= "table" or type(data.savePath) ~= "string" then
    return
  end
  removeFile(PENDING_PATH)
  pendingResume = {
    savePath = data.savePath,
    timer = MAP_READY_DELAY
  }
  setBusy("load", "load", "Map loaded, waiting to restore vehicles...")
  notify("info", "Map loaded. Restoring vehicles...")
end

function M.onClientStartMission()
  pcall(tryResumePendingLoad)
end

function M.onClientPostStartMission()
  pcall(tryResumePendingLoad)
end

function M.onWorldReadyToPlay()
  pcall(tryResumePendingLoad)
end

function M.onLevelLoaded()
  pcall(tryResumePendingLoad)
end

function M.onVehicleSpawned(vehId)
  pcall(function()
    if not loadJob or loadJob.phase ~= "waitSpawn" or not vehId then
      return
    end
    local veh = be:getObjectByID(vehId)
    if veh then
      loadJob.pendingVeh = veh
      loadJob.phase = "settle"
      loadJob.timer = POST_SPAWN_DELAY
    end
  end)
end

function M.onUpdate(dt)
  dt = tonumber(dt) or 0
  if collectJob then
    collectJob.timeout = collectJob.timeout - dt
    if collectJob.timeout <= 0 then
      logW("Vehicle state collection timed out; writing save with available data")
      finishSaveWrite()
    end
  end

  if pendingResume then
    pendingResume.timer = pendingResume.timer - dt
    if pendingResume.timer <= 0 then
      local path = pendingResume.savePath
      pendingResume = nil
      local data = nil
      pcall(function()
        data = jsonReadFile(path)
      end)
      local saveData, verr = validateSave(data)
      if not saveData then
        setBusy(nil)
        notify("error", verr or "Pending save is invalid")
      else
        saveData._path = path
        loadValidatedSave(saveData, true)
      end
    end
  end

  if loadJob then
    if loadJob.phase == "waitSpawn" then
      loadJob.spawnWait = (loadJob.spawnWait or 0) - dt
    end
    loadJob.timer = (loadJob.timer or 0) - dt
    if loadJob.timer <= 0 then
      local ok, err = pcall(stepLoadJob)
      if not ok then
        logE("Load step failed: " .. tostring(err))
        if loadJob then
          loadJob.failed[#loadJob.failed + 1] = { model = "unknown", reason = tostring(err) }
          loadJob.phase = "spawn"
          loadJob.timer = SPAWN_GAP
          loadJob.pendingVeh = nil
          loadJob.pendingData = nil
        end
      end
    end
  end
end

return M
