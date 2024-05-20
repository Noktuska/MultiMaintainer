local component = require("component")
local eventHandler = require("eventHandler")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local inputForm = require("inputForm")
--local maintainer = require("maintainer")

local gpu = component.gpu
if not gpu then return error("Program needs GPU to run") end

local me = component.me_interface
if not me then return error("Not connected to ME network") end

local redstone = component.redstone
if not redstone then return error("Need redstone component") end

local main = {}

local w, h = gpu.getResolution()
local function clearScreen()
    gpu.fill(1, 1, w, h, " ")
end

local needRedraw = true

local levelMaintainer = require("levelMaintainer")
local aspectMaintainer = require("aspectMaintainer")
local beeMaintainer = nil

local config = {
    backBg = { type = "hex", value = 0x252526, desc = "Background (color)" },
    mainBg = { type = "hex", value = 0x1E1E1E, desc = "Main Background (color)" },
    mainFg = { type = "hex", value = 0xFFFFFF, desc = "Main Text (color)" },
    mainAreaBg = { type = "hex", value = 0x3C3C3C, desc = "Main Area BG (color)" },
    groupBg = { type = "hex", value = 0x464646, desc = "Item Group (color)" },
    tabsBgUnsel = { type = "hex", value = 0x2D2D2D, desc = "Unselected Tab BG (color)" },
    tabsFgUnsel = { type = "hex", value = 0x969690, desc = "Unselected Tab Text (color)" },
    contextMenuBg = { type = "hex", value = 0x252526, desc = "Context Menu BG (color)" },
    craftingFg = { type = "hex", value = 0xDCDC8B, desc = "In Progress (color)" },
    cancelledFg = { type = "hex", value = 0xEA8070, desc = "Cancel (color)" },
    tickMaxCount = { type = "int", value = 4, desc = "Tick delay" },
    refreshRate = { type = "int", value = 1, desc = "Redraw delay" }
}

local function createConfigMenu(cfg)
    if not cfg then return end
    for _, v in pairs(cfg) do
        local str = nil
        local matcher = function(_) return true end
        if v.type == "hex" then
            str = string.format("%x", v.value)
            if #str < 6 then str = string.rep("0", 6 - #str) .. str end
            matcher = function(str) return string.match(str, "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]") end
        elseif v.type == "int" then
            str = tostring(v.value)
            matcher = function(str) return tonumber(str) end
        elseif v.type == "string" then
            str = v.value
        end
        inputForm.addField(v.desc, str, matcher)
    end
    inputForm.create(gpu, nil, function(res)
        if res then
            for k, v in pairs(cfg) do
                if res[v.desc] then
                    local value = res[v.desc]
                    if v.type == "hex" then cfg[k].value = tonumber(value, 16) or cfg[k].value
                    elseif v.type == "int" then cfg[k].value = tonumber(value) or cfg[k].value
                    elseif v.type == "string" then cfg[k].value = value end
                end
            end
        end
        inputForm.clear()
        needRedraw = true
    end)
end

local curMenu = 1
local tabs = {
    level_maintainer = 1,
    aspect_maintainer = 2,
    bee_maintainer = 3,
    config = 4,
    size = 4,
}
tabs[1] = {
    label = "Items",
    maintainer = levelMaintainer,
    callback = function(...) if curMenu ~= tabs.level_maintainer then curMenu = tabs.level_maintainer end end
}
tabs[2] = {
    label = "Aspects",
    maintainer = aspectMaintainer,
    callback = function(...) if curMenu ~= tabs.aspect_maintainer then curMenu = tabs.aspect_maintainer end end
}
tabs[3] = {
    label = "Bees",
    maintainer = beeMaintainer,
    callback = function(...) if curMenu ~= tabs.bee_maintainer then curMenu = tabs.bee_maintainer end end
}
tabs[4] = {
    label = "Config",
    maintainer = nil,
    callback = function() createConfigMenu(config) end
}
tabs[5] = {
    label = "Maintainer Config",
    maintainer = nil,
    callback = function() createConfigMenu(tabs[curMenu].maintainer) end
}

local searchStr = ""
local scroll = 0

local running = true

local saveDataLocation = "multi_maintainer.data"
local function saveData()
    local f = io.open(saveDataLocation, "w")
    if not f then return false end

    local data = {}
    data.config = config
    for i = 1, tabs.size do
        local maintainer = tabs[i].maintainer
        if maintainer then
            data[maintainer.label].data = maintainer:serialize()
            data[maintainer.label].config = maintainer.config
        end
    end

    f:write(serialization.serialize(data))
    f:close()
    return true
end

local function loadData()
    local f = io.open(saveDataLocation, "r")
    if not f then return false end

    local str = f:read(math.huge)
    if not str then f:close() return false end
    local data = serialization.unserialize(str)
    
    if data.config then
        for k, v in pairs(data.config) do config[k] = v end
    end
    for i = 1, tabs.size do
        local maintainer = tabs[i].maintainer
        if maintainer and data[maintainer.label] then
            maintainer:unserialize(data[maintainer.label].data)
            for k, v in pairs(data[maintainer.label].config) do
                maintainer.config[k] = v
            end
        end
    end

    f:close()
    return true
end

local function isMeOnline()
    local redstone = component.redstone
    if not redstone then return false end
    for i = 0, 5 do
        if redstone.getInput(i) > 0 then return true end
    end
    return false
end

function main.drawTabs()
    local x = 2
    local sel = curMenu
    for i = 1, tabs.size do
        local tab = tabs[i]
        if i == sel then
            gpu.setBackground(config.mainBg)
            gpu.setForeground(config.mainFg)
        else
            gpu.setBackground(config.tabsBgUnsel)
            gpu.setForeground(config.tabsFgUnsel)
        end
        local val = " "..tab.label.." "
        gpu.set(x, 1, val)
        local newx = x + #val
        eventHandler.registerButton("bt"..val, eventHandler.rect(x, 1, newx - x, 1), tab.callback)
        x = newx
    end
end

function main.drawSearchbar()
    gpu.setBackground(config.mainBg)
    gpu.fill(1, 2, w, 1, " ")
    if searchStr == "" then
        gpu.setForeground(config.tabsFgUnsel)
        gpu.set(2, 2, "Search...")
    else
        gpu.setForeground(config.mainFg)
        gpu.set(2, 2, searchStr)
    end
end

local contextMenu = nil
local mainArea = eventHandler.rect(2, 4, w * 3 / 5, h - 5)
local mainAreaDirty = true
function main.drawMainArea()
    if contextMenu or inputForm.created then return end
    gpu.setBackground(config.mainAreaBg)
    gpu.setForeground(config.mainFg)
    if mainAreaDirty then gpu.fill(mainArea.left, mainArea.top, mainArea.right - mainArea.left, mainArea.bottom - mainArea.top, " ") end

    local curMaintainer = tabs[curMenu].maintainer
    local renderTable = curMaintainer:getRenderTable(mainArea.right - mainArea.left)

    for _, column in pairs(renderTable) do
        gpu.set(column.x, mainArea.top, column.label)
    end

    local y = levelMaintainer.top + 1
    local list = levelMaintainer:getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)
    for i, line in ipairs(list) do
        if line.type == "group" and (line.elem.dirty or mainAreaDirty) then
            local group = line.elem
            gpu.setBackground(config.groupBg)
            gpu.fill(2, y + i - 1, mainArea.right - mainArea.left, 1, " ")
            local groupStr = ">  "..group.label
            if group.isOpen then groupStr = "V  "..group.label end
            gpu.set(3, y + i - 1, groupStr)
            mainAreaDirty = true    -- Redraw rest of the GUI incase opening/closing Group shifted elements
            group.dirty = false
        elseif line.type == "item" and (line.elem.dirty or mainAreaDirty) then
            local item = line.elem
            gpu.setBackground(config.mainAreaBg)
            gpu.fill(2, y + i - 1, mainArea.right - mainArea.left, 1, " ")
            for _, column in pairs(renderTable) do
                gpu.set(column.x, y, column.get(item) or "INVALID")
            end
            item.dirty = false
        end
    end

    mainAreaDirty = false
end

local sideArea = eventHandler.rect(mainArea.right + 1, mainArea.top, w - mainArea.right - 2, mainArea.bottom - mainArea.top)
function main.drawSideArea()
    if contextMenu or inputForm.created then return end
    gpu.setBackground(config.mainAreaBg)
    gpu.setForeground(config.mainFg)
    gpu.fill(sideArea.left, sideArea.top, sideArea.right - sideArea.left, sideArea.bottom - sideArea.top, " ")

    local y = sideArea.top + 1
    gpu.set(sideArea.left, sideArea.top, "Current Jobs:")
    for _, item in pairs(levelMaintainer.getRawItemList()) do
        if item.statusVal ~= levelMaintainer.enumStatus.idle then
            if item.statusVal == levelMaintainer.enumStatus.crafting then gpu.setForeground(config.craftingFg)
            elseif item.statusVal == levelMaintainer.enumStatus.cancelled then gpu.setForeground(config.cancelledFg) end
            gpu.set(sideArea.left + 1, y, item.label)
            y = y + 1
        end
    end

    gpu.setForeground(config.mainFg)
    local mem = tostring(require("computer").freeMemory())
    local pow = nil
    if me and isMeOnline() then pow = tostring(math.floor(me.getAvgPowerUsage() / 2)) end
    gpu.set(sideArea.left, sideArea.bottom - 1, "Free RAM: "..mem)
    if pow then gpu.set((sideArea.left + sideArea.right) / 2, sideArea.bottom - 1, "AE2 Power Usage: "..pow.." EU/t") end
end

local function redraw()
    gpu.setBackground(config.backBg)
    clearScreen()
    main.drawTabs()
    main.drawSearchbar()
    main.drawMainArea()
    needRedraw = false
end

local function onScroll(_, _, dir)
    local oldScroll = scroll
    if dir > 0 then
        scroll = scroll - 1
    elseif dir < 0 then
        scroll = scroll + 1
    end
    if scroll < 0 then scroll = 0 end
    local list = levelMaintainer.getVisibleList(searchStr, 0, math.huge)
    local maxScroll = #list - (mainArea.bottom - mainArea.top) + 1
    if maxScroll < 0 then maxScroll = 0 end
    if scroll > maxScroll then scroll = maxScroll end
    if oldScroll ~= scroll then mainAreaDirty = true end
end

local function onKeyDown(code, char)
    if contextMenu or inputForm.created then return end
    if keyboard.isControlDown() and code == keyboard.keys.q then running = false return end
    if char >= 32 and char <= 126 then searchStr = searchStr..string.char(char) end
    if code == keyboard.keys.back and #searchStr > 0 then searchStr = string.sub(searchStr, 1, #searchStr - 1) end
    onScroll(0, 0, 0)
    main.drawSearchbar()
    mainAreaDirty = true
end

local function getMainElementAt(sely)
    local y = mainArea.top + 1
    local list = levelMaintainer.getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)
    if not list[sely - y + 1] then return nil end
    return list[sely - y + 1].type, list[sely - y + 1].elem
end

local function onContextMenuClick(option)
    if not contextMenu then return end
    local curMaintainer = tabs[curMenu].maintainer
    local function addItem()
        local callback = curMaintainer.createItemForm(inputForm)
        if callback then
            inputForm.create(gpu, nil, function(res)
                callback(res)
                if res then saveData() end
                inputForm.clear()
            end)
        end
    end
    if contextMenu.id == "onGroup" then
        if option == 0 then     -- Add Item
            addItem()
        elseif option == 1 then -- Modify Group
            local id, group = getMainElementAt(contextMenu.top)
            if id == "group" and group then
                inputForm.addField("group", "Group name", group.label)
                inputForm.create(gpu, nil, function(res)
                    if res then group.label = res["Group name"] group.dirty = true saveData() end
                    inputForm.clear()
                end)
            end
        elseif option == 2 then -- Delete Group
            local id, group = getMainElementAt(contextMenu.top)
            if id == "group" and group then
                levelMaintainer.removeGroup(group.label)
                saveData()
            end
        elseif option == 3 then -- Disable Group
            local id, group = getMainElementAt(contextMenu.top)
            if id == "group" and group then
                for _, item in group.items do
                    item.disable = true
                end
                saveData()
            end
        elseif option == 4 then -- Enable group
            local id, group = getMainElementAt(contextMenu.top)
            if id == "group" and group then
                for _, item in group.items do
                    item.disable = false
                end
                saveData()
            end
        end
    elseif contextMenu.id == "onItem" then
        if option == 0 then     -- Add Item
            addItem()
        elseif option == 1 then -- Modify Item
            local id, item = getMainElementAt(contextMenu.top)
            if id == "item" and item then
                local callback = curMaintainer:createItemForm(inputForm, item)
                if callback then
                    inputForm.create(gpu, nil, function(res)
                        callback(res)
                        if res then saveData() end
                        inputForm.clear()
                    end)
                end
            end
        elseif option == 2 then -- Delete Item
            local id, item = getMainElementAt(contextMenu.top)
            if id == "item" and item then
                levelMaintainer.removeItem(item.label)
                saveData()
            end
        elseif option == 3 then -- Disable/Enable Item
            local id, item = getMainElementAt(contextMenu.top)
            if id == "item" and item then
                item.disable = not item.disable
                if not item.disable then item.statusVal = levelMaintainer.enumStatus.idle end
                saveData()
            end
        end
    elseif contextMenu.id == "onAir" then
        if option == 0 then
            addItem()
        end
    end
end

local function createContextMenu(x, y, id, options)
    local width = 1
    local height = #options
    for _, str in ipairs(options) do
        if #str > width then width = #str end
    end
    gpu.setBackground(config.contextMenuBg)
    gpu.setForeground(config.mainFg)
    gpu.fill(x, y, width, height, " ")
    for i, str in ipairs(options) do
        gpu.set(x, y + i - 1, str)
    end
    contextMenu = eventHandler.rect(x, y, width, height)
    contextMenu.id = id
end

local function destroyContextMenu()
    contextMenu = nil
    needRedraw = true
end

local function onMainAreaClick(_, mx, my, bt, _)
    if inputForm.created then return end

    if contextMenu then
        if mx >= contextMenu.left and mx < contextMenu.right and my >= contextMenu.top and my < contextMenu.bottom then
            onContextMenuClick(my - contextMenu.top)
        end
        destroyContextMenu()
        return
    end

    local y = mainArea.top + 1
    local line = levelMaintainer.getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)[my - y + 1]
    if line then
        if line.type == "group" then
            local group = line.elem
            if bt == 0 then
                group.isOpen = not group.isOpen
                group.dirty = true
                return
            elseif bt == 1 then
                createContextMenu(mx, my, "onGroup", {
                    "Add Item",
                    "Modify group",
                    "Delete group",
                    "Disable group",
                    "Enable group"
                })
                return
            end
        elseif line.type == "item" then
            if bt == 1 then
                createContextMenu(mx, my, "onItem", {
                    "Add Item",
                    "Modify Item",
                    "Delete Item",
                    "Disable/Enable Item"
                })
                return
            end
        end
    end
    if bt == 1 then
        createContextMenu(mx, my, "onAir", {
            "Add Item"
        })
    end
end

loadData()

local ev = event.listen("key_down", function(_, _, char, code, _) onKeyDown(code, char) end)
local ev2 = event.listen("scroll", function(_, _, x, y, dir, _) onScroll(x, y, dir) end)
eventHandler.registerButton("btMainArea", mainArea, onMainAreaClick)

local tickCounter = 0
while running do
    if needRedraw and not inputForm.created then redraw() end

    tickCounter = tickCounter + 1
    if isMeOnline() and tickCounter >= config.tickMaxCount.value then
        for i = 1, tabs.size do
            local maintainer = tabs[i].maintainer
            if maintainer then
                maintainer:tick(me)
            end
        end
        --levelMaintainer.tick(me)
        --local redstone = component.redstone
        ----local essAlert = 15
        --if levelMaintainer.essentiaAlert then essAlert = 0 end
        --if redstone then redstone.setOutput(require("sides").east, essAlert) end
        tickCounter = 0
    end
    --if dirty then main.drawMainArea() end
    main.drawMainArea()
    main.drawSideArea()

    os.sleep()
end

event.cancel(ev)
event.cancel(ev2)
eventHandler.free()

saveData()