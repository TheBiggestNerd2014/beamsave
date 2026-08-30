# BeamSave 1.2.0

Save and restore the current vehicle scene in **BeamNG.drive 0.39** through an in-game HUD app.

Saves use a versioned `.bngsave` file stored in BeamNG **user data**, not the game install folder.

## Install

1. Copy `BeamSave_1.2.0_BeamNG_0.39.zip` into:

   `%LOCALAPPDATA%\BeamNG.drive\0.39\mods`

   If an older BeamSave zip is already there, replace it, then disable and re-enable the mod so BeamNG remounts the files.

2. Enable **BeamSave** in the in-game Mod Manager.
3. Open the HUD Apps layout editor (Pause menu → System / HUD Apps).
4. Add **BeamSave** to your layout. It is a Vue HUD app for 0.39 (`app.vue` + `app.json`).

## Use

The app has three tabs.

### Save Game

- Enter a save name (letters, numbers, spaces, dashes, underscores).
- Click **Save current scene**.
- Unsafe characters and path traversal (`..`, slashes) are stripped. Names are limited to 64 characters.
- If that name already exists, BeamSave asks before overwriting.

### Load Game

- Lists `.bngsave` files from the BeamSave folder only.
- Each row shows save name, map, vehicle count, and date/time.
- **Load** restores the scene. **Delete** removes that save and its companion beamstate files.
- **Refresh** re-reads the folder.
- Corrupt saves are listed but cannot be loaded.

### Settings

Settings are written to `beamSave/settings.json` in user data.

| Setting | Default | What it does |
|---|---|---|
| Vehicle Load Mode | Replace Current Vehicles | **Replace** deletes current vehicles, then loads the save. **Add** keeps current vehicles and spawns the save next to them. |
| Automatically Switch Maps | On | If the save is for another map, BeamSave starts that level, waits for it to finish loading, then restores vehicles. |
| Confirm Before Deleting Vehicles | On | In Replace mode, ask before deleting the current scene. |
| Restore Vehicle Velocity | On | Reapply linear and angular velocity when a setter exists. **Runtime testing required** — if the API is missing, vehicles spawn at rest. |
| Restore Mechanical State | On | Restore fuel, ignition/engine running, and gear where setters exist. RPM and temperatures are saved but not forced. |
| Restore Damage / Deformation | Off | Uses BeamNG `beamstate`. Experimental. Can crash some vehicles with advanced couplers (for example some Scintilla / Covet setups). |
| Restore Lights / Vehicle State | On | Restore the lights bitmask when a setter exists. |
| Save Player Vehicle | On | Include the vehicle you are driving. |
| Save All Vehicles | On | Include other player-spawned vehicles. Parked / simplified traffic is never saved. |
| Save AI / Traffic Vehicles | Off | Include driving traffic / AI vehicles. Parked / simplified cars are still skipped. |

## Where files go

All BeamSave files stay under the user-data folder:

```
%LOCALAPPDATA%\BeamNG.drive\0.39\beamSave\
  settings.json
  pendingLoad.json          (temporary, only while switching maps)
  saves\
    MySave.bngsave
    MySave_beam0.json       (optional beamstate, only if damage restore is enabled)
```

BeamSave will not read or write files outside `beamSave/saves` for save data.

## `.bngsave` format (v1)

JSON with:

- `beamSaveVersion` (currently `1`)
- `beamNGVersion`
- `saveName`, `levelId`, `levelPath`, `createdAt`, `vehicleCount`
- `vehicles[]`: model, config path, colors, position, rotation, velocity, angular velocity, fuel, engine/gear/lights/temperatures, and optional beamstate filename

Future BeamSave versions can migrate older v1 files. Newer unknown versions are rejected instead of being half-loaded.

## What restores reliably

These use documented BeamNG 0.39 GE / vehicle APIs:

- Map / level
- Vehicle model and configuration
- Paint colors (primary and secondary)
- Exact position and rotation. **Re-save** older scenes: those files often stored positions in a form BeamNG could not reload, so every car spawned in a default line.
- Fuel remaining ratio per named tank
- Engine running / ignition level (`vehicleController.setEngineIgnition` plus `electrics.setIgnitionLevel` when present)

## What is best-effort

These are saved when readable, then restored only if a setter exists. Failures are logged and skipped:

- Linear and angular velocity (`obj:setVelocity` / `setAngularVelocity`, or a cluster-velocity fallback)
- Gear index / mode
- Lights bitmask
- Throttle and brake values (saved; live input is not replayed)
- Engine RPM, water temperature, oil temperature (saved; not independently forced)
- Doors / hood / trunk and deformation (only through optional `beamstate`)

## What is not supported

Parked and simplified traffic cars are never saved or restored.

These are skipped on purpose so a load cannot take down the session:

- Full mid-air node-level physics without beamstate
- AI path / route memory
- Trailer coupler relationships across a reload
- Invented internal C++ state that mods cannot access

A missing vehicle mod, missing config, missing map, corrupt file, or failed spawn aborts only that vehicle (or that operation), never the game.

## Logging

Look in the BeamNG log for lines tagged **BeamSave**:

```
[BeamSave] Saved "Downtown Drag" (2 vehicles).
```

## Testing checklist

- One vehicle, same map
- Several vehicles and mixed configs
- Modded vehicles, with the mod installed and with it missing
- Position and rotation
- Damaged vehicles with Restore Damage on and off
- Fuel and engine running state
- Different maps, and a save whose map is not installed
- Corrupt / unsupported-version saves
- Replace mode and Add mode
- Large scenes (10+ vehicles) — watch the progress bar
- Unsafe save names (`../`, slashes)
- Duplicate save names

## Packaging

The zip is a normal BeamNG overlay:

```
lua/ge/extensions/beamSave/core.lua
lua/vehicle/extensions/beamSave/vehicleState.lua
scripts/beamSave/modScript.lua
ui/modules/apps/BeamSave/app.js
ui/modules/apps/BeamSave/app.json
ui/modules/apps/BeamSave/app.html
ui/modules/apps/BeamSave/app.css
ui/modules/apps/BeamSave/app.png
README.md
```

Target version: **BeamNG.drive 0.39**.
