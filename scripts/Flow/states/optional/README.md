# Optional states: WallRun

**WallRun** is kept out of the default build: it needs its own continuous side-scan raycast
(`core/optional/sensor_ext.lua`'s `updateWallRun`) that doesn't fit
through the shared detection rays the other states use. Pulling it out was purely a performance call, not a
functionality one.

Currently: not required anywhere, not registered, zero runtime cost.

## To bring WallRun back

1. **main.lua**
   - `local WallRunState = require('states/optional/wall_run')`
   - Add it to `REGISTERED_STATES`
   - Alongside `SensorExt.updateLedgeHang(...)`, add:
     `SensorExt.updateWallRun(dt, InputManager.intents, EngineSync.data)`
     (or just call `SensorExt.update(...)` to run both passes at once)
   - Worth checking whether it should also run only outside the Idle
     throttle, same as everything else in the full pipeline.

2. **states/airborne.lua** and wherever else you want a WallRun transition
   - add a check against `SensorExt.data.wallRun.side`, matching the
     pattern already in `states/optional/wall_run.lua`'s own comments/use
     of that data.

3. **core/engine_sync.lua** - `wall_run.lua` reads `syncData.verticalVelocity`,
   which EngineSync does not provide. Add it before re-enabling.
