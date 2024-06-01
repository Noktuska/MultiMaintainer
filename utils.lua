local utils = {}

function utils.padStr(str, len)
    return string.rep(" ", len - #str) .. str
end

function utils.shortNumString(num)
    if num <= 999999 then return utils.padStr(string.format("%.0f", num), 8) end
    if num <= 999999999 then return utils.padStr(string.format("%.2f M", num / 1000000), 8) end
    if num <= 999999999999 then return utils.padStr(string.format("%.2f G", num / 1000000000), 8) end
    return tostring(num)
end

function utils.exists(t, pred)
    for _, elem in pairs(t) do
        if pred(elem) then return true end
    end
    return false
end

function utils.removeByValue(t, value)
    local i = 1
    for _, v in pairs(t) do
        if v == value then
            table.remove(t, i)
            return true
        end
        i = i + 1
    end
    return false
end

function utils.sendMessage(modem, addr, port, ...)
    if not modem.isOpen(port) then modem.open(port) end

    local result = nil
    local ev = require("event").listen("modem_message", function(_, _, sender, _, _, ...)
        if sender == addr then result = {...} end
    end)

    modem.send(addr, port, ...)

    local timeout = 3
    while not result do
        os.sleep(1)
        timeout = timeout - 1
    end

    if not result then return false, "Ping failed" end

    while result[1] == "pong" do
        os.sleep(1) -- TODO: Coroutine this to not wait
    end

    return result
end

return utils