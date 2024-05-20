local event = require("event")

local eventHandler = {}

local buttons = {}

local evList = {}
table.insert(evList, event.listen("touch", function(_, addr, x, y, bt, name)
    for _, button in pairs(buttons) do
        if x >= button.rect.left and x < button.rect.right and y >= button.rect.top and y < button.rect.bottom then
            button.callback(addr, x, y, bt, name)
            return
        end 
    end
end))

function eventHandler.registerButton(id, rect, callback)
    if buttons[id] then eventHandler.cancel(id) end
    buttons[id] = { rect = rect, callback = callback }
    return true
end

function eventHandler.free()
    for _, ev in pairs(evList) do
        event.cancel(ev)
    end
end

function eventHandler.cancel(id)
    if buttons[id] then
        buttons[id] = nil
        return true
    end
    return false
end

function eventHandler.rect(x, y, width, height)
    return { left = x, top = y, right = x + width, bottom = y + height }
end

return eventHandler