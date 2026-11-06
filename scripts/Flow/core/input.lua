---@omw-context player
-- Input intents, sampled once per frame.

local input = require('openmw.input')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local InputManager = {
    intents = {
        moveVector = nil,
        jump = false,
        crouch = false,
        jumpPressed = false
    }
}

local wasJumpHeld = false
-- Set by latchJump: jump reads as released until the key really is.
local jumpLatched = false

-- The nine possible move vectors, built once.
local MOVE = {}
for x = -1, 1 do
    MOVE[x] = {}
    for y = -1, 1 do MOVE[x][y] = util.vector2(x, y) end
end
InputManager.intents.moveVector = MOVE[0][0]

function InputManager.update()
    if I.UI.getMode() ~= nil then
        InputManager.reset()
        return
    end

    local mx, my = 0, 0
    if input.isActionPressed(input.ACTION.MoveRight) then mx = mx + 1 end
    if input.isActionPressed(input.ACTION.MoveLeft) then mx = mx - 1 end
    if input.isActionPressed(input.ACTION.MoveForward) then my = my + 1 end
    if input.isActionPressed(input.ACTION.MoveBackward) then my = my - 1 end
    InputManager.intents.moveVector = MOVE[mx][my]

    local jumpHeld = input.isActionPressed(input.ACTION.Jump)
    if jumpLatched then
        if jumpHeld then jumpHeld = false else jumpLatched = false end
    end

    InputManager.intents.jump = jumpHeld
    InputManager.intents.crouch = input.isActionPressed(input.ACTION.Sneak)

    InputManager.intents.jumpPressed = jumpHeld and not wasJumpHeld

    wasJumpHeld = jumpHeld
end

-- A jump held across a hand-over from another mod (see main.lua, yield) is
-- that mod's input, not a request to FLOW: ignore it until it is let go.
function InputManager.latchJump()
    jumpLatched = true
end

function InputManager.reset()
    InputManager.intents.moveVector = MOVE[0][0]
    InputManager.intents.jump = false
    InputManager.intents.crouch = false
    InputManager.intents.jumpPressed = false
    wasJumpHeld = false
end

return InputManager
