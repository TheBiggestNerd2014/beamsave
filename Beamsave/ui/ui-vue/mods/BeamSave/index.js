// BeamNG.drive 0.39 Vue mod entry. HUD apps are discovered from app.json
// plus a Vue SFC. Named export matches vanilla modules/apps/index.js style.

export { default as beamSave } from './apps/beamSave/app.vue'

function tryRegisterHudApp(api, component) {
  if (!api || !component) return
  const payload = {
    name: 'BeamSave',
    appName: 'BeamSave',
    directive: 'beamSaveApp',
    component,
    vue: true
  }
  const fns = [
    api.registerHudApp,
    api.addHudApp,
    api.registerApp,
    api.hudApps && api.hudApps.register,
    api.apps && api.apps.register
  ]
  for (const fn of fns) {
    if (typeof fn === 'function') {
      try {
        fn.call(api.hudApps || api.apps || api, payload)
        return
      } catch (err) {
        console.warn('[BeamSave] HUD register attempt failed', err)
      }
    }
  }
}

export async function onLoad(api) {
  try {
    const mod = await import('./apps/beamSave/app.vue')
    tryRegisterHudApp(api, mod && mod.default)
  } catch (err) {
    console.warn('[BeamSave] Vue HUD onLoad skipped', err)
  }
}

export function onUnload() {}

export default { onLoad, onUnload }
