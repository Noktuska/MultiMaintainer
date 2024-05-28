local wireless = {}
local event = require("event")

function wireless.listen(port)
    local modem = require("component").modem
    if not modem then return false, "No modem installed" end

    if not modem.isOpen(port) then modem.open(port) end

    local result = nil
    local respSender = nil
    local ev = require("event").listen("modem_message", function(_, receiver, sender, ...)
        respSender = sender
        modem.send(sender, port, "pong")
        result = {receiver, sender, ...}
    end)

    return { 
        get = function()
            if result then event.cancel(ev) end
            return result
        end,
        respond = function(...)
            if respSender then modem.send(respSender, port, ...) end
        end
    }
end

function wireless.send(addr, port, ...)
    local modem = require("component").modem
    if not modem then return false, "No modem installed" end

    if not modem.isOpen(port) then modem.open(port) end

    local result = nil
    local valid = false
    local ev = require("event").listen("modem_message", function(_, _, sender, _, _, ...)
        local msg = {...}
        if sender == addr then
            if msg[1] == "pong" then
                valid = true
            else
                result = msg
            end
        end
    end)

    modem.send(addr, port, ...)

    if not valid then os.sleep(1) end
    if not valid then
        event.cancel(ev)
        return false, "No response"
    end

    return function()
        if result then event.cancel(ev) end
        return result
    end
end

return wireless