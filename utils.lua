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

return utils