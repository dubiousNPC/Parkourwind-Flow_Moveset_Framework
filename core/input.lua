---@omw-context player
--- START OF FILE core/input.lua ---

local input = require('openmw.input')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')

-- No input.registerAction here.
--
-- That API publishes into the ENGINE'S shared action-binding registry, which
-- every mod using it competes over; AcrobaticsEnhanced documents refusing it
-- after confirming a clash with Character Panel. FLOW's only consumer was the
-- sprint hotkey, and that is gone - vanilla already distinguishes walking from
-- running, so main.lua reads the engine's own run flag instead. Nothing here
-- touches the shared registry.

local InputManager = {
    intents = {
        moveVector = util.vector2(0, 0),
        jump = false,
        crouch = false,
        interact = false,
        -- Edge-triggered (true only on the frame the level signal goes
        -- false->true). Sole consumer is main.lua's idle-throttle bypass, so
        -- a keypress never waits out the throttle interval. Roll's tap
        -- detection used to live here too, but moved to a proper engine
        -- trigger handler in states/airborne.lua - polled edges could drop a
        -- tap completed inside a single frame.
        jumpPressed = false
    }
}

local wasJumpHeld = false

function InputManager.update()
    -- UI Lock Check
    if I.UI.getMode() ~= nil then
        InputManager.reset()
        return
    end

    -- Movement Vector.
    --
    -- [BUGFIX] Read from the raw ACTIONS, not self.controls. Once a state
    -- calls I.Controls.overrideMovementControls(true) the engine stops
    -- writing player input into self.controls - the script owns those fields
    -- from then on - so self.controls.sideMovement/movement read back as
    -- whatever the script last wrote, i.e. 0.
    --
    -- LedgeHang overrides movement controls on enter(), which meant
    -- moveVector was pinned at (0,0) for the entire hang. That silently
    -- disabled every directional branch in that state: Shimmy (moveVector.x)
    -- never fired at all and never reached the log, and the wall-kick
    -- (moveVector.y < 0) was equally dead. Action state is unaffected by the
    -- control override, so it stays correct throughout.
    local mx, my = 0, 0
    if input.isActionPressed(input.ACTION.MoveRight) then mx = mx + 1 end
    if input.isActionPressed(input.ACTION.MoveLeft) then mx = mx - 1 end
    if input.isActionPressed(input.ACTION.MoveForward) then my = my + 1 end
    if input.isActionPressed(input.ACTION.MoveBackward) then my = my - 1 end
    InputManager.intents.moveVector = util.vector2(mx, my)

    -- Actions
    local jumpHeld = input.isActionPressed(input.ACTION.Jump)

    InputManager.intents.jump = jumpHeld
    InputManager.intents.crouch = input.isActionPressed(input.ACTION.Sneak)
    InputManager.intents.interact = input.isActionPressed(input.ACTION.Activate)

    InputManager.intents.jumpPressed = jumpHeld and not wasJumpHeld

    wasJumpHeld = jumpHeld
end

function InputManager.reset()
    InputManager.intents.moveVector = util.vector2(0, 0)
    InputManager.intents.jump = false
    InputManager.intents.crouch = false
    InputManager.intents.interact = false
    InputManager.intents.jumpPressed = false
    wasJumpHeld = false
end

return InputManager
