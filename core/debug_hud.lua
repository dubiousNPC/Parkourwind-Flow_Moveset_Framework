---@omw-context player
-- Debug HUD. Created lazily, only while the setting is on.

local ui = require('openmw.ui')
local util = require('openmw.util')

local Settings = require('settings')

local DebugHUD = {
    element = nil,
    lines = {
        state = "State: Init",
        sensor = "Sensor: Clear",
        lastAction = "Action: None"
    }
}

function DebugHUD.create()
    if not Settings.debugMode() then return end
    if DebugHUD.element then return end

    DebugHUD.element = ui.create({
        layer = "HUD",
        type = ui.TYPE.Flex,
        props = {
            relativePosition = util.vector2(0.7, 0.80), -- Moved up slightly to fit more text
            anchor = util.vector2(0, 1),
            size = util.vector2(350, 150), -- Increased height for multiline debug
            horizontal = false,
            arrange = ui.ALIGNMENT.End
        },
        content = ui.content({
            {
                type = ui.TYPE.Text,
                name = "StateLine",
                props = {
                    text = "",
                    textSize = 16,
                    textColor = util.color.rgb(0.8, 0.8, 1.0)
                }
            },
            {
                type = ui.TYPE.Text,
                name = "SensorLine",
                props = {
                    text = "",
                    textSize = 14,
                    textColor = util.color.rgb(1.0, 1.0, 0.8),
                    multiline = true, -- [NEW] Required for detailed sensor output
                    autoSize = true   -- [NEW] Allows text to expand the widget
                }
            },
            {
                type = ui.TYPE.Text,
                name = "ActionLine",
                props = {
                    text = "",
                    textSize = 18,
                    textColor = util.color.rgb(0.5, 1.0, 0.5)
                }
            }
        })
    })
end

function DebugHUD.update(stateName, sensorInfo, actionName)
    if not Settings.debugMode() then return end
    if not DebugHUD.element then DebugHUD.create() end
    if not DebugHUD.element then return end

    local stateText = "STATE: " .. tostring(stateName)
    local sensorText = tostring(sensorInfo)
    local dirty = false

    if DebugHUD.lastState ~= stateText then
        DebugHUD.element.layout.content.StateLine.props.text = stateText
        DebugHUD.lastState = stateText
        dirty = true
    end

    if DebugHUD.lastSensor ~= sensorText then
        DebugHUD.element.layout.content.SensorLine.props.text = sensorText
        DebugHUD.lastSensor = sensorText
        dirty = true
    end

    -- Only update if provided, allows persistence
    if actionName then
        local actionText = "LAST OP: " .. tostring(actionName)
        if DebugHUD.lastAction ~= actionText then
            DebugHUD.element.layout.content.ActionLine.props.text = actionText
            DebugHUD.lastAction = actionText
            dirty = true
        end
    end

    if dirty then
        DebugHUD.element:update()
    end
end

function DebugHUD.destroy()
    if not DebugHUD.element then return end
    if DebugHUD.element.destroy then
        DebugHUD.element:destroy()
    end
    DebugHUD.element = nil
    DebugHUD.lastState = nil
    DebugHUD.lastSensor = nil
    DebugHUD.lastAction = nil
end

return DebugHUD