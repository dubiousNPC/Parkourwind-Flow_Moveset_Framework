---@omw-context player
--- START OF FILE core/debug_hud.lua ---

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
    -- Gate lives HERE, not just in main.lua's onUpdate: states/vault.lua,
    -- states/mantle.lua and states/ledge_hang.lua all call DebugHUD.update()
    -- directly on entry, which would otherwise spawn (and permanently strand)
    -- the HUD even with the debug setting off.
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

-- element:update() is a full UI layout redraw crossing the Lua/engine
-- boundary - by a wide margin the most expensive thing FLOW does per frame
-- when the HUD is on. Cache the last strings written and only redraw when
-- something actually changed; a state/sensor readout is static for most
-- consecutive frames, so this skips the large majority of redraws.
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

-- Called when the debug setting is turned off, so the HUD doesn't linger
-- on screen after being disabled mid-session.
function DebugHUD.destroy()
    if not DebugHUD.element then return end
    -- Defensive: destroy() on a UI Element is the documented teardown, but
    -- guard anyway so a missing binding can't error out the frame.
    if DebugHUD.element.destroy then
        DebugHUD.element:destroy()
    end
    DebugHUD.element = nil
    DebugHUD.lastState = nil
    DebugHUD.lastSensor = nil
    DebugHUD.lastAction = nil
end

return DebugHUD