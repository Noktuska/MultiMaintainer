local event = require("event")
local keyboard = require("keyboard")

local inputForm = {
    created = false,
    maxInputLen = 32
}

local evTouch = nil
local evKey = nil
local evClipboard = nil
local minWidth = 1
local minHeight = 1
local focusIndex = 1
local fields = {}
local fieldAccept = nil
local fieldCancel = nil

local function render(gpu, cfg)
    gpu.setBackground(cfg.bg)
    gpu.setForeground(cfg.fg)

    local w = minWidth + 8
    local h = minHeight * 2 + 3

    local ww, hh = gpu.getResolution()
    local x = (ww - w) / 2
    local y = (hh - h) / 2
    gpu.fill(x, y, w, h, " ")

    for i, field in ipairs(fields) do
        local yy = y + 2 * (i - 1) + 1
        gpu.setBackground(cfg.bg)
        gpu.setForeground(cfg.fg)
        gpu.set(ww / 2 - #field.label, yy, field.label..":")
        if i == focusIndex then gpu.setBackground(cfg.fieldBgFocus) else gpu.setBackground(cfg.fieldBg) end
        gpu.setForeground(cfg.fieldFg)
        gpu.fill(ww / 2 + 2, yy, inputForm.maxInputLen, 1, " ")
        gpu.set(ww / 2 + 2, yy, field.str)

        if not field.rect then
            field.rect = { left = ww / 2 + 2, right = ww / 2 + 2 + inputForm.maxInputLen, top = yy-1, bottom = yy }
        end
    end

    local strAccept = "Accept"
    local strCancel = "Cancel"

    fieldAccept = { left = x, right = x + w / 2, top = y + h - 2, bottom = y + h -1}
    fieldCancel = { left = x + w / 2, right = x + w, top = y + h - 2, bottom = y + h -1}

    gpu.setBackground(cfg.bgAccept)
    gpu.fill(x, y + h - 1, w / 2, 1, " ")
    gpu.set(x + (w / 2 - #strAccept) / 2, y + h - 1, strAccept)
    gpu.setBackground(cfg.bgCancel)
    gpu.fill(x + w / 2, y + h - 1, w - w / 2, 1, " ")
    gpu.set(x + w / 2 + (w / 2 - #strCancel) / 2, y + h - 1, strCancel)
end

function inputForm.clear()
    minWidth = 1
    minHeight = 1
    if evTouch then event.cancel(evTouch) end
    if evKey then event.cancel(evKey) end
    if evClipboard then event.cancel(evClipboard) end
    evTouch = nil
    evKey = nil
    evClipboard = nil
    focusIndex = 1
    fieldAccept = nil
    fieldCancel = nil
    fields = {}
    inputForm.created = false
end

function inputForm.addField(id, label, default, acceptFun)
    table.insert(fields, { id = id, label = label, str = default or "", acceptFun = acceptFun, focus = false})
    local w = 2 + 2 * inputForm.maxInputLen
    if #label > inputForm.maxInputLen then w = 2 * #label end
    if minWidth < w then minWidth = w end
    minHeight = minHeight + 1
end

function inputForm.create(gpu, config, callback)
    local cfg = {
        bg = 0x252526,
        fg = 0xFFFFFF,
        fieldBg = 0x464640,
        fieldFg = 0xFFFFFF,
        fieldBgFocus = 0x898983,
        bgAccept = 0x16825D,
        bgCancel = 0xEA8070
    }
    if config then
        for k, v in pairs(config) do cfg[k] = v end
    end

    render(gpu, cfg)

    inputForm.created = true

    local function accept()
        local res = {}
        for _, field in pairs(fields) do
            if field.acceptFun and not field.acceptFun(field.str) then return end
            res[field.id] = field.str
        end
        callback(res)
    end

    evTouch = event.listen("touch", function(_, _, x, y, _)
        for i, field in ipairs(fields) do
            if field.rect and x >= field.rect.left and x < field.rect.right and y >= field.rect.top and y < field.rect.bottom then
                focusIndex = i
                return
            end
        end
        if fieldAccept and x >= fieldAccept.left and x < fieldAccept.right and y >= fieldAccept.top and y < fieldAccept.bottom then
            accept()
        end
        if fieldCancel and x >= fieldCancel.left and x < fieldCancel.right and y >= fieldCancel.top and y < fieldCancel.bottom then
            callback(nil)
        end
    end)
    evKey = event.listen("key_down", function(_, _, char, code, _)
        if code == keyboard.keys.tab then
            focusIndex = focusIndex + 1
            if focusIndex > #fields then focusIndex = 1 end
            render(gpu, cfg)
            return
        elseif code == keyboard.keys.enter then
            accept()
            return
        end
        local focus = fields[focusIndex]
        if not focus then return end
        if char >= 32 and char <= 126 then focus.str = focus.str..string.char(char) end
        if code == keyboard.keys.back and #focus.str > 0 then focus.str = string.sub(focus.str, 1, #focus.str - 1) end
        render(gpu, cfg)
    end)
    evClipboard = event.listen("clipboard", function(_, _, str, _)
        local focus = fields[focusIndex]
        if not focus then return end
        focus.str = focus.str .. str
    end)
end

function inputForm.anyNumber(str)
    return tonumber(str)
end

return inputForm