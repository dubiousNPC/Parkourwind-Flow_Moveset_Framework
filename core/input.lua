---@omw-context player
-- Input intents, sampled once per frame.

local input = require('openmw.input')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local InputManager = {
    intents = {
        moveVector = util.vector2(0, 0),
        jump = false,
        crouch = false,
        interact = false,
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
