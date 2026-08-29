<template>
  <div class="beamsave-app">
    <div class="bs-header">
      <div class="bs-title">BeamSave</div>
      <div class="bs-tabs">
        <button type="button" class="bs-tab" :class="{ active: tab === 'save' }" @click="setTab('save')">Save</button>
        <button type="button" class="bs-tab" :class="{ active: tab === 'load' }" @click="setTab('load')">Load</button>
        <button type="button" class="bs-tab" :class="{ active: tab === 'settings' }" @click="setTab('settings')">Settings</button>
      </div>
    </div>

    <div class="bs-body">
      <div v-if="tab === 'save'" class="bs-panel">
        <label class="bs-label" for="bs-save-name">Save name</label>
        <input
          id="bs-save-name"
          class="bs-input"
          type="text"
          maxlength="64"
          v-model="saveName"
          :disabled="busy"
          placeholder="e.g. Downtown Drag"
          @focus="setTyping(true)"
          @blur="setTyping(false)"
          @keydown.stop
          @keyup.stop
          @keypress.stop
        />
        <p class="bs-hint">Letters, numbers, spaces, dashes, and underscores only.</p>
        <button type="button" class="bs-btn bs-btn-primary" :disabled="busy || !saveName" @click="save">Save current scene</button>
      </div>

      <div v-if="tab === 'load'" class="bs-panel">
        <div class="bs-row-actions">
          <button type="button" class="bs-btn bs-btn-ghost" :disabled="busy" @click="refresh">Refresh</button>
          <span class="bs-muted">{{ saves.length }} save{{ saves.length === 1 ? '' : 's' }}</span>
        </div>
        <div v-if="!saves.length" class="bs-empty">No .bngsave files found.</div>
        <div class="bs-save-list">
          <div v-for="s in saves" :key="s.path || s.saveName" class="bs-save-card" :class="{ corrupt: s.corrupt }">
            <div class="bs-save-main">
              <div class="bs-save-name">{{ s.saveName }}</div>
              <div class="bs-save-meta">
                <span>{{ s.levelId }}</span>
                <span>{{ s.vehicleCount }} veh</span>
                <span v-if="s.createdAt">{{ formatDate(s.createdAt) }}</span>
                <span v-if="s.corrupt" class="bs-bad">corrupt</span>
              </div>
            </div>
            <div class="bs-save-actions">
              <button type="button" class="bs-btn bs-btn-small" :disabled="busy || s.corrupt" @click="load(s)">Load</button>
              <button type="button" class="bs-btn bs-btn-small bs-btn-danger" :disabled="busy" @click="askDelete(s)">Delete</button>
            </div>
          </div>
        </div>
      </div>

      <div v-if="tab === 'settings'" class="bs-panel bs-settings">
        <div class="bs-setting">
          <div class="bs-setting-text">
            <div class="bs-setting-name">Vehicle Load Mode</div>
            <div class="bs-setting-desc">Replace deletes current vehicles. Add keeps them and spawns the save alongside.</div>
          </div>
          <div class="bs-mode">
            <button type="button" class="bs-mode-btn" :class="{ active: settings.vehicleLoadMode === 'replace' }" @click="setLoadMode('replace')">Replace Current Vehicles</button>
            <button type="button" class="bs-mode-btn" :class="{ active: settings.vehicleLoadMode === 'add' }" @click="setLoadMode('add')">Add to Current Vehicles</button>
          </div>
        </div>
        <label v-for="item in toggles" :key="item.key" class="bs-toggle">
          <input type="checkbox" v-model="settings[item.key]" @change="saveSettings" />
          <span class="bs-toggle-text">
            <span class="bs-setting-name">{{ item.name }}</span>
            <span class="bs-setting-desc">{{ item.desc }}</span>
          </span>
        </label>
      </div>
    </div>

    <div v-if="busy || progress.message" class="bs-progress">
      <div class="bs-progress-label">{{ progress.message || (busy ? 'Working...' : '') }}</div>
      <div v-if="progress.total" class="bs-progress-track">
        <div class="bs-progress-bar" :style="{ width: progressPct + '%' }"></div>
      </div>
    </div>

    <div v-if="status.message" class="bs-status" :class="status.level">{{ status.message }}</div>

    <div v-if="confirm.kind" class="bs-modal">
      <div class="bs-modal-card">
        <div class="bs-modal-title">{{ confirm.title }}</div>
        <div class="bs-modal-text">{{ confirm.text }}</div>
        <div class="bs-modal-actions">
          <button type="button" class="bs-btn bs-btn-ghost" @click="cancelConfirm">Cancel</button>
          <button type="button" class="bs-btn" :class="confirm.danger ? 'bs-btn-danger' : 'bs-btn-primary'" @click="acceptConfirm">{{ confirm.ok }}</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'

const tab = ref('save')
const saveName = ref('')
const busy = ref(false)
const saves = ref([])
const settings = reactive({
  vehicleLoadMode: 'replace',
  autoSwitchMap: true,
  confirmBeforeDeleting: true,
  restoreVelocity: true,
  restoreMechanicalState: true,
  restoreDamage: false,
  restoreLights: true,
  savePlayerVehicle: true,
  saveAllVehicles: true,
  saveAIVehicles: false
})
const status = reactive({ level: 'info', message: '' })
const progress = reactive({ current: 0, total: 0, message: '' })
const confirm = reactive({ kind: null, title: '', text: '', ok: 'OK', danger: false, saveName: '', savePath: '', save: null })

const toggles = [
  { key: 'autoSwitchMap', name: 'Automatically Switch Maps', desc: 'Load the saved map before restoring vehicles.' },
  { key: 'confirmBeforeDeleting', name: 'Confirm Before Deleting Vehicles', desc: 'Ask before replace mode removes the current scene.' },
  { key: 'restoreVelocity', name: 'Restore Vehicle Velocity', desc: 'Reapply linear and angular velocity when possible.' },
  { key: 'restoreMechanicalState', name: 'Restore Mechanical State', desc: 'Fuel, ignition, and gear where BeamNG exposes setters.' },
  { key: 'restoreDamage', name: 'Restore Damage / Deformation', desc: 'Experimental beamstate. Can crash some vehicles with advanced couplers.' },
  { key: 'restoreLights', name: 'Restore Lights / Vehicle State', desc: 'Restore the lights bitmask when a setter is available.' },
  { key: 'savePlayerVehicle', name: 'Save Player Vehicle', desc: 'Include the vehicle you are currently driving.' },
  { key: 'saveAllVehicles', name: 'Save All Vehicles', desc: 'Include other player-spawned vehicles. Parked / simplified traffic is never saved.' },
  { key: 'saveAIVehicles', name: 'Save AI / Traffic Vehicles', desc: 'Include driving traffic and other AI vehicles. Parked / simplified cars are still skipped.' }
]

const progressPct = computed(() => {
  if (!progress.total) return 0
  return Math.max(0, Math.min(100, (progress.current / progress.total) * 100))
})

function luaArg(arg) {
  if (typeof arg === 'string') return JSON.stringify(arg)
  if (typeof arg === 'number' || typeof arg === 'boolean') return String(arg)
  return JSON.stringify(JSON.stringify(arg))
}

function engineApi() {
  if (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) return bngApi
  if (typeof window !== 'undefined' && window.bngApi && window.bngApi.engineLua) return window.bngApi
  return null
}

function callLua(fnName, args, callback) {
  const luaArgs = (args || []).map(luaArg).join(',')
  // Do not "return" the Lua result. JSON from getSavesJson/listSaves is not
  // valid Lua, and engineLua will throw "unexpected symbol" on the colons.
  const cmd = 'if not extensions.beamSave_core then extensions.load("beamSave_core") end; extensions.beamSave_core.' + fnName + '(' + luaArgs + ')'
  const api = engineApi()
  if (!api) return
  if (typeof callback === 'function') {
    api.engineLua(cmd, callback)
  } else {
    api.engineLua(cmd)
  }
}

function applySaves(res) {
  let list = res
  if (typeof res === 'string') {
    try {
      list = JSON.parse(res)
    } catch (err) {
      list = []
    }
  }
  if (list && list.saves) list = list.saves
  if (!Array.isArray(list)) list = []
  saves.value = list
  status.level = list.length ? 'success' : 'info'
  status.message = list.length
    ? ('Found ' + list.length + ' save' + (list.length === 1 ? '' : 's') + '.')
    : 'No .bngsave files found.'
}

function formatDate(iso) {
  if (!iso) return ''
  return String(iso).replace('T', ' ').replace(/:\d\d$/, '')
}

function setTyping(on) {
  const flag = on ? 'true' : 'false'
  const cmds = [
    'if setCEFTyping then setCEFTyping(' + flag + ') end',
    'if setCEFFocus then setCEFFocus(' + flag + ') end',
    'if core_input_bindings and core_input_bindings.setEnabled then core_input_bindings.setEnabled(' + (on ? 'false' : 'true') + ') end'
  ]
  const api = (typeof bngApi !== 'undefined' && bngApi) || (typeof window !== 'undefined' && window.bngApi)
  cmds.forEach(cmd => {
    try {
      if (api && api.engineLua) api.engineLua(cmd)
    } catch (err) {}
  })
}

function setLoadMode(mode) {
  settings.vehicleLoadMode = mode
  saveSettings()
}

function setTab(next) {
  if (tab.value === 'save' && next !== 'save') setTyping(false)
  tab.value = next
  if (next === 'load') refresh()
  if (next === 'settings') callLua('getSettings')
}

function save() {
  if (busy.value || !saveName.value) return
  callLua('saveScene', [saveName.value, false])
}

function refresh() {
  status.level = 'info'
  status.message = 'Refreshing save list...'
  callLua('listSaves')
}

function load(s) {
  if (!s || s.corrupt || busy.value) return
  callLua('loadSave', [s.path, false])
}

function askDelete(s) {
  Object.assign(confirm, {
    kind: 'deleteSave',
    title: 'Delete save?',
    text: 'Delete "' + s.saveName + '" and any beamstate files next to it? This cannot be undone.',
    ok: 'Delete',
    danger: true,
    save: s
  })
}

function saveSettings() {
  callLua('updateSettings', [{ ...settings }])
}

function cancelConfirm() {
  confirm.kind = null
}

function acceptConfirm() {
  const kind = confirm.kind
  const name = confirm.saveName
  const path = confirm.savePath
  const saveItem = confirm.save
  confirm.kind = null
  if (kind === 'overwrite') callLua('saveScene', [name, true])
  else if (kind === 'deleteVehicles') callLua('loadSave', [path, true])
  else if (kind === 'deleteSave' && saveItem) callLua('deleteSave', [saveItem.path])
}

function handleEvent(data) {
  if (!data || !data.type) return
  if (data.type === 'status') {
    status.level = data.level || 'info'
    status.message = data.message || ''
  } else if (data.type === 'saves') {
    const list = Array.isArray(data.saves) ? data.saves : []
    saves.value = list
    status.level = list.length ? 'success' : 'info'
    status.message = list.length
      ? ('Found ' + list.length + ' save' + (list.length === 1 ? '' : 's') + '.')
      : 'No .bngsave files found.'
  } else if (data.type === 'settings' && data.settings) {
    Object.keys(data.settings).forEach(key => {
      settings[key] = data.settings[key]
    })
  } else if (data.type === 'busy') {
    busy.value = !!data.busy
    if (!data.busy) {
      progress.current = 0
      progress.total = 0
      progress.message = ''
    } else if (data.message) {
      progress.message = data.message
    }
  } else if (data.type === 'progress') {
    progress.current = data.current || 0
    progress.total = data.total || 0
    progress.message = data.message || ''
  } else if (data.type === 'confirmOverwrite') {
    Object.assign(confirm, {
      kind: 'overwrite',
      title: 'Overwrite save?',
      text: 'A save named "' + data.saveName + '" already exists. Replace it?',
      ok: 'Overwrite',
      danger: true,
      saveName: data.saveName
    })
  } else if (data.type === 'confirmDeleteVehicles') {
    Object.assign(confirm, {
      kind: 'deleteVehicles',
      title: 'Replace current vehicles?',
      text: 'This will delete the vehicles currently in the scene, then load the save.',
      ok: 'Replace and load',
      danger: true,
      savePath: data.savePath
    })
  }
}

function onUiEvent(a, b) {
  const data = (a && a.type) ? a : (b && b.type) ? b : a
  handleEvent(data)
}

let unbind = null

onMounted(async () => {
  callLua('requestUIState')
  const offs = []
  try {
    const game = (typeof $game !== 'undefined' && $game) || (typeof window !== 'undefined' && window.$game)
    if (game && game.events && game.events.on) {
      game.events.on('BeamSaveUI', onUiEvent)
      offs.push(() => game.events.off && game.events.off('BeamSaveUI', onUiEvent))
    }
  } catch (err) {
    console.warn('[BeamSave] $game event bind failed', err)
  }
  try {
    const mod = await import('@/services/events')
    if (mod && mod.useEvents) {
      const events = mod.useEvents()
      events.on('BeamSaveUI', onUiEvent)
      offs.push(() => events.off && events.off('BeamSaveUI', onUiEvent))
    }
  } catch (err) {
    console.warn('[BeamSave] useEvents bind skipped', err)
  }
  unbind = () => offs.forEach(fn => fn())
})

onUnmounted(() => {
  setTyping(false)
  if (unbind) unbind()
})
</script>

<style scoped>
.beamsave-app { position: relative; display: flex; flex-direction: column; width: 100%; height: 100%; box-sizing: border-box; color: #e8eaed; background: rgba(14, 16, 20, 0.92); border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 6px; font-family: "Segoe UI", Tahoma, sans-serif; font-size: 12px; line-height: 1.35; overflow: hidden; }
.bs-header { padding: 8px 10px 0; flex: 0 0 auto; }
.bs-title { font-size: 14px; font-weight: 700; letter-spacing: 0.04em; color: #ffb347; margin-bottom: 6px; }
.bs-tabs { display: flex; gap: 4px; }
.bs-tab { flex: 1; border: 0; background: rgba(255, 255, 255, 0.06); color: #c5cad3; padding: 6px 4px; border-radius: 4px 4px 0 0; cursor: pointer; }
.bs-tab.active { background: rgba(255, 179, 71, 0.18); color: #fff; box-shadow: inset 0 -2px 0 #ffb347; }
.bs-body { flex: 1 1 auto; min-height: 0; overflow: auto; padding: 10px; }
.bs-panel { display: flex; flex-direction: column; gap: 8px; }
.bs-label, .bs-setting-name { display: block; font-weight: 600; color: #fff; }
.bs-input { width: 100%; box-sizing: border-box; border: 1px solid rgba(255, 255, 255, 0.12); background: rgba(0, 0, 0, 0.35); color: #fff; border-radius: 4px; padding: 7px 8px; }
.bs-hint, .bs-setting-desc, .bs-muted, .bs-save-meta { color: #9aa3b2; font-size: 11px; }
.bs-setting-desc { display: block; margin-top: 2px; line-height: 1.35; }
.bs-toggle-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.bs-mode { display: flex; flex-direction: column; gap: 4px; }
.bs-mode-btn { width: 100%; text-align: left; border: 1px solid rgba(255, 255, 255, 0.12); background: rgba(0, 0, 0, 0.35); color: #c5cad3; border-radius: 4px; padding: 7px 8px; cursor: pointer; }
.bs-mode-btn.active { background: rgba(255, 179, 71, 0.18); color: #fff; border-color: #ffb347; }
.bs-btn { border: 0; border-radius: 4px; padding: 7px 10px; background: #3d4554; color: #fff; cursor: pointer; }
.bs-btn:disabled { opacity: 0.45; cursor: default; }
.bs-btn-primary { background: #c67a1a; }
.bs-btn-ghost { background: rgba(255, 255, 255, 0.08); }
.bs-btn-danger { background: #8b2e2e; }
.bs-btn-small { padding: 4px 7px; font-size: 11px; }
.bs-row-actions { display: flex; align-items: center; justify-content: space-between; }
.bs-save-list { display: flex; flex-direction: column; gap: 6px; }
.bs-save-card { display: flex; gap: 8px; justify-content: space-between; align-items: flex-start; padding: 7px 8px; background: rgba(255, 255, 255, 0.04); border: 1px solid rgba(255, 255, 255, 0.06); border-radius: 4px; }
.bs-save-card.corrupt { border-color: rgba(255, 80, 80, 0.35); }
.bs-save-name { font-weight: 600; }
.bs-save-meta { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 2px; }
.bs-save-actions { display: flex; flex-direction: column; gap: 4px; }
.bs-bad { color: #ff8080; }
.bs-empty { color: #9aa3b2; text-align: center; padding: 18px 8px; }
.bs-settings { gap: 10px; }
.bs-setting, .bs-toggle { display: flex; gap: 8px; align-items: flex-start; }
.bs-setting { flex-direction: column; }
.bs-toggle input { margin-top: 3px; }
.bs-progress, .bs-status { flex: 0 0 auto; padding: 6px 10px; font-size: 11px; }
.bs-progress { background: rgba(255, 179, 71, 0.08); border-top: 1px solid rgba(255, 179, 71, 0.2); }
.bs-progress-track { height: 4px; margin-top: 4px; background: rgba(255, 255, 255, 0.1); border-radius: 2px; overflow: hidden; }
.bs-progress-bar { height: 100%; background: #ffb347; }
.bs-status { border-top: 1px solid rgba(255, 255, 255, 0.08); }
.bs-status.success { color: #8ee0a8; }
.bs-status.warning { color: #ffd27a; }
.bs-status.error { color: #ff8d8d; }
.bs-status.info { color: #c5cad3; }
.bs-modal { position: absolute; inset: 0; background: rgba(0, 0, 0, 0.55); display: flex; align-items: center; justify-content: center; padding: 12px; }
.bs-modal-card { width: 100%; background: #1b1f27; border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 6px; padding: 12px; }
.bs-modal-title { font-weight: 700; margin-bottom: 6px; }
.bs-modal-text { color: #c5cad3; margin-bottom: 10px; }
.bs-modal-actions { display: flex; justify-content: flex-end; gap: 6px; }
</style>
