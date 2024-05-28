local component = require("component")
local eventHandler = require("eventHandler")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local inputForm = require("inputForm")
--local maintainer = require("maintainer")

local gpu = component.gpu
if not gpu then return error("Program needs GPU to run") end

--local me = component.me_interface
--if not me then return error("Not connected to ME network") end

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
local beeMaintainer = require("beeMaintainer")

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
    for k, v in pairs(cfg) do
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
        inputForm.addField(k, v.desc or v.label, str, matcher)
    end
    inputForm.create(gpu, nil, function(res)
        if res then
            for k, v in pairs(cfg) do
                if res[k] then
                    local value = res[k]
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
    config_maintainer = 5,
    size = 5,
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
    callback = function() createConfigMenu(tabs[curMenu].maintainer.config) end
}

local searchStr = ""
local scroll = 0

local running = true

local saveDataLocation = "multi_maintainer"
local function saveData()
    local f = io.open(saveDataLocation .. ".data", "w")
    
    if f then
        local data = {}
        data.config = config

        f:write(serialization.serialize(data))
        f:close()
    end

    for i = 1, tabs.size do
        local maintainer = tabs[i].maintainer
        if maintainer then
            f = io.open(saveDataLocation .. "_" .. tabs[i].label .. ".data")

            if f then
                local maintainerData = {}
                maintainerData.data = maintainer:serialize()
                maintainerData.config = maintainer.config or {}

                f:write(serialization.serialize(maintainerData))
                f:close()
            end
        end
    end

    return true
end

local function loadData()
    local f = io.open(saveDataLocation .. ".data", "r")

    if f then
        local str = f:read(math.huge)
        if str then
            local data = serialization.unserialize(str)
            
            if data.config then
                for k, v in pairs(data.config) do config[k] = v end
            end
        end

        f:close()
    end

    for i = 1, tabs.size do
        local maintainer = tabs[i].maintainer
        if maintainer then
            f = io.open(saveDataLocation .. "_" .. tabs[i].label .. ".data")
            if f then
                local str = f:read(math.huge)
                if str then
                    local data = serialization.unserialize(str)
                    maintainer:unserialize(data.data)
                    for k, v in pairs(data.config) do
                        maintainer.config[k] = v
                    end
                end

                f:close()
            end
        end
    end

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
            gpu.setBackground(config.mainBg.value)
            gpu.setForeground(config.mainFg.value)
        else
            gpu.setBackground(config.tabsBgUnsel.value)
            gpu.setForeground(config.tabsFgUnsel.value)
        end
        local val = " "..tab.label.." "
        gpu.set(x, 1, val)
        local newx = x + #val
        eventHandler.registerButton("bt"..val, eventHandler.rect(x, 1, newx - x, 1), function()
            tab.callback()
            needRedraw = true
        end)
        x = newx
    end
end

function main.drawSearchbar()
    gpu.setBackground(config.mainBg.value)
    gpu.fill(1, 2, w, 1, " ")
    if searchStr == "" then
        gpu.setForeground(config.tabsFgUnsel.value)
        gpu.set(2, 2, "Search...")
    else
        gpu.setForeground(config.mainFg.value)
        gpu.set(2, 2, searchStr)
    end
end

local contextMenu = nil
local mainArea = eventHandler.rect(2, 4, w * 3 / 5, h - 5)
local mainAreaDirty = true
function main.drawMainArea()
    if contextMenu or inputForm.created then return end
    gpu.setBackground(config.mainAreaBg.value)
    gpu.setForeground(config.mainFg.value)
    if mainAreaDirty then gpu.fill(mainArea.left, mainArea.top, mainArea.right - mainArea.left, mainArea.bottom - mainArea.top, " ") end

    local curMaintainer = tabs[curMenu].maintainer
    local renderTable = curMaintainer:getRenderTable(mainArea.right - mainArea.left)

    for _, column in pairs(renderTable) do
        gpu.set(column.x, mainArea.top, column.label)
    end

    local y = mainArea.top + 1
    local lasty = y
    local list = curMaintainer:getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)
    for i, line in ipairs(list) do
        if line.type == "group" and (line.elem.dirty or mainAreaDirty) then
            local group = line.elem
            gpu.setBackground(config.groupBg.value)
            gpu.fill(2, y + i - 1, mainArea.right - mainArea.left, 1, " ")
            local groupStr = ">  "..group.label
            if group.isOpen then groupStr = "V  "..group.label end
            gpu.set(3, y + i - 1, groupStr)
            mainAreaDirty = true    -- Redraw rest of the GUI incase opening/closing Group shifted elements
            group.dirty = false
        elseif line.type == "item" and (line.elem.dirty or mainAreaDirty) then
            local item = line.elem
            gpu.setBackground(config.mainAreaBg.value)
            gpu.fill(2, y + i - 1, mainArea.right - mainArea.left, 1, " ")
            for _, column in pairs(renderTable) do
                gpu.set(column.x, y + i - 1, column.get(item) or "INVALID")
            end
            item.dirty = false
        end
        lasty = y + i - 1
    end

    if mainAreaDirty then
        gpu.setBackground(config.mainAreaBg.value)
        gpu.setForeground(config.mainFg.value)
        gpu.fill(mainArea.left, lasty + 1, mainArea.right - mainArea.left, mainArea.bottom - lasty - 1, " ")
    end

    mainAreaDirty = false
end

local sideAreaTick = 0
local sideAreaDirty = true
local sideArea = eventHandler.rect(mainArea.right + 1, mainArea.top, w - mainArea.right - 2, mainArea.bottom - mainArea.top)
function main.drawSideArea()
    if contextMenu or inputForm.created then return end
    sideAreaTick = sideAreaTick + 1
    if sideAreaTick < 20 then return end
    sideAreaTick = 0
    gpu.setBackground(config.mainAreaBg.value)
    gpu.setForeground(config.mainFg.value)
    if sideAreaDirty then gpu.fill(sideArea.left, sideArea.top, sideArea.right - sideArea.left, sideArea.bottom - sideArea.top, " ")
    else gpu.fill(sideArea.left, sideArea.bottom - 1, sideArea.right - sideArea.left, 1, " ") end

    local curMaintainer = tabs[curMenu].maintainer
    local y = sideArea.top + 1
    gpu.set(sideArea.left, sideArea.top, "Current Jobs:")
    local items = curMaintainer:getRawItemList()
    for _, item in pairs(items) do
        if item.statusVal ~= curMaintainer.enumStatus.idle then
            if item.statusVal == curMaintainer.enumStatus.crafting then gpu.setForeground(config.craftingFg.value)
            elseif item.statusVal == curMaintainer.enumStatus.cancelled then gpu.setForeground(config.cancelledFg.value) end
            gpu.set(sideArea.left + 1, y, item.label)
            y = y + 1
        end
    end

    gpu.setForeground(config.mainFg.value)
    local mem = tostring(require("computer").freeMemory())
    local pow = nil
    --if me and isMeOnline() then pow = tostring(math.floor(me.getAvgPowerUsage() / 2)) end
    gpu.set(sideArea.left, sideArea.bottom - 1, "Free RAM: "..mem)
    if pow then gpu.set((sideArea.left + sideArea.right) / 2, sideArea.bottom - 1, "AE2 Power Usage: "..pow.." EU/t") end

    sideAreaDirty = false
end

local function redraw()
    gpu.setBackground(config.backBg.value)
    clearScreen()
    main.drawTabs()
    main.drawSearchbar()
    mainAreaDirty = true
    main.drawMainArea()
    sideAreaDirty = true
    main.drawSideArea()
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
    local list = tabs[curMenu].maintainer:getVisibleList(searchStr, 0, math.huge)
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
    local list = tabs[curMenu].maintainer:getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)
    if not list[sely - y + 1] then return nil end
    return list[sely - y + 1].type, list[sely - y + 1].elem
end

local function onContextMenuClick(option)
    if not contextMenu then return end
    local curMaintainer = tabs[curMenu].maintainer
    local function addItem()
        local callback = curMaintainer:createItemForm(inputForm)
        if callback then
            inputForm.create(gpu, nil, function(res)
                callback(res)
                if res then saveData() end
                inputForm.clear()
                needRedraw = true
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
                    needRedraw = true
                end)
            end
        elseif option == 2 then -- Delete Group
            local id, group = getMainElementAt(contextMenu.top)
            if id == "group" and group then
                curMaintainer:removeGroup(group.label)
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
                        needRedraw = true
                    end)
                end
            end
        elseif option == 2 then -- Delete Item
            local id, item = getMainElementAt(contextMenu.top)
            if id == "item" and item then
                curMaintainer:removeItem(item.label)
                saveData()
            end
        elseif option == 3 then -- Disable/Enable Item
            local id, item = getMainElementAt(contextMenu.top)
            if id == "item" and item then
                item.disable = not item.disable
                if not item.disable then item.statusVal = curMaintainer.enumStatus.idle end
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
    gpu.setBackground(config.contextMenuBg.value)
    gpu.setForeground(config.mainFg.value)
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
    local line = tabs[curMenu].maintainer:getVisibleList(searchStr, scroll, mainArea.bottom - mainArea.top - 1)[my - y + 1]
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
                maintainer:tick()
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