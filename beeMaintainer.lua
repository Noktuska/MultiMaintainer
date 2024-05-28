local maintainer = require("maintainer")
local utils = require("utils")
local component = require("component")
local wireless = require("wireless")

local beeMaintainer = maintainer.new()
beeMaintainer.tickIndex = 0
beeMaintainer.diffList = {}
beeMaintainer.apiaryList = {}
beeMaintainer.busy = false
beeMaintainer.config = {
    meAddress = { label = "Main ME Address", type = "string", value = nil },
    beeMeAddress = { label = "Apiary ME Address", type = "string", value = nil },
    redstoneAddress = { label = "Apiary Controller Address", type = "string", value = nil },
    robotAddr = { label = "Robot Address", type = "string", value = nil },
    slots = { label = "Apiary Slots", type = "int", value = 0 }
}

local enumState = {
    off = 0,
    on = 1,
    pulse = 2,
    input = 3,
    output = 4,
    operating = 5
}

function beeMaintainer:setApiaryState(...)
    if not self.config.robotAddr.value then return false, "No robot address defined" end
    local modem = component.modem
    if not modem then return false, "No modem installed" end

    local get, err = wireless.send(self.config.robotAddr.value, 42)
    if not get then return false, err end

    while not get() do
        coroutine.yield(true, false)
    end

    return true, true
end

function beeMaintainer:asyncDoWork()
    self.busy = true
    if not self.stateRoutine then self.stateRoutine = coroutine.create(beeMaintainer.setApiaryState) end
    local res, val = coroutine.resume(self.stateRoutine, self, enumState.off, enumState.output, enumState.pulse, enumState.input, enumState.on)
    if not res then
        self.stateRoutine = nil
        return false, val
    end
    if not val then return true, "Waiting..." end

    -- REMOVING QUEENS FROM APIARY
    local t = component.transposer
    if not t then return false, "No transposer connected" end

    local sideInterface = nil
    local sideChest = nil
    local sideInput = nil
    for i = 0, 5 do
        local inv = t.getInventoryName(i)
        if string.match(inv, "Interface") then sideInterface = i end
        if string.match(inv, "Chest") then sideChest = i end
        if string.match(inv, "blockmachine") then sideInput = i end
    end

    if not sideInterface or not sideChest or not sideInput then return false, "Not all Transposer sides connected" end

    local chestSlots = t.getInventorySize(sideChest)
    for i = 1, chestSlots do
        local stack = t.getStackInSlot(sideChest, i)
        -- Remove any queens that are on the to remove list
        if stack then for _, elem in pairs(self.queensToRemove) do
            if stack.label == elem .. " Queen" then
                repeat local moved = t.transferItem(sideChest, sideInterface, 1, i) os.sleep(1) until moved > 0
            end
        end end
        -- If it wasn't on the to remove list put it back into the input bus
        stack = t.getStackInSlot(sideChest, i)
        if stack then
            repeat local moved = t.transferItem(sideChest, sideInput, 1, i) os.sleep(1) until moved > 0
        end
    end

    -- ADDING NEW BEES TO APIARY
    local subMe = component.proxy(self.config.beeMeAddress.value)
    local db = component.database
    if not subMe then return false, "Not connected to Apiary ME subnet" end
    if not db then return false, "No database connected" end

    for _, elem in pairs(self.queensToAdd) do
        local queenFound = subMe.store({ label = elem .. " Queen" }, db.address, 1, 1)
        if queenFound then
            subMe.setInterfaceConfiguration(1, db.address, 1, 1)
            repeat local moved = t.transferItem(sideInterface, sideInput, 1, 1) os.sleep(1) until moved > 0
        end
    end

    -- TURNIN ON APIARY
    local finish = coroutine.create(beeMaintainer.setApiaryState)
    while coroutine.status(finish) ~= "dead" do
        coroutine.resume(finish, enumState.off, enumState.operating, enumState.on)
        os.sleep(1)
    end

    return true
end

function beeMaintainer:tick()
    if self.busy then
        self:asyncDoWork()
        return false
    end
    
    if self.config.slots.value < 1 or
        not self.config.robotAddr.value or
        not self.config.beeMeAddress.value or
        not self.config.redstoneAddress.value or
        not self.config.robotAddr.value then return false end

    local me = nil
    if self.config.meAddress.value then me = component.proxy(self.config.meAddress.value) end
    if not me then return false end

    local itemList = self:getRawItemList()
    if #itemList == 0 then return false end

    if itemList[self.tickIndex] then itemList[self.tickIndex].active = false end
    self.tickIndex = self.tickIndex + 1

    if self.tickIndex > #itemList then
        -- APIARY LOGIC
        local slots = self.config.slots.value - #self.apiaryList
        -- GET QUEENS TO REMOVE FROM APIARY
        self.queensToRemove = {}
        for _, elem in pairs(self.apiaryList) do
            local item = itemList[elem.itemLabel]
            if item.stocked >= item.batch then
                table.insert(self.queensToRemove, item.species)
                slots = slots + 1
            end
        end

        -- GET QUEENS TO ADD TO APIARY
        table.sort(self.diffList, function(l, r) return l.diff <= r.diff end) -- Sort items by how low they got on stock in compared to toStock
        self.queensToAdd = {}
        local i = 1
        while slots > 0 do  -- Try to fill the apiary
            local item = self.diffList[i] and self.diffList[i].item
            if not item then break end  -- Ran out of items on the itemList

            if item.batch ~= 0 and (item.stocked - item.toStock) / item.batch >= 0.5 then break end -- Still have over 50% between min and max stock

            for _ = 1, item.parallels do
                table.insert(self.queensToAdd, item.species)
                slots = slots - 1
                if slots == 0 then break end
            end
            i = i + 1
        end

        if #self.queensToAdd > 0 then
            self:asyncDoWork()
        end

        self.diffList = {}
        self.tickIndex = 0
        return true
    end

    local item = itemList[self.tickIndex]
    item.active = true

    local filter = { label = item.label }
    if item.id then filter.name = item.id end
    if item.damage then filter.damage = item.damage end
    local stack = me.getItemsInNetwork(filter)[1]

    if stack then
        item.stocked = stack.size
    elseif item.timeoutTick == 0 then
        item.timeoutTick = 1
    else
        item.stocked = 0
    end

    table.insert(self.diffList, { item = item, diff = item.stocked - item.toStock })
    return true
end

function beeMaintainer:getRenderTable(width)
    return {
        { x = 6, label = "Item", get = function(item)
            local res = item.label
            if item.id then
                res = res .. " [" .. item.id
                if item.damage then res = res .. "|" .. tostring(item.damage) end
                res = res .. "]"
            end
            if item.disabled then res = res .. " (D)" end
            if item.active then res = "--> "..res
            else res = "    "..res end
            return res
        end },
        { x = width - 9, label = "Batch", get = function(item) return utils.shortNumString(item.batch) end }, -- width - shortNumStringLen - padding
        { x = width - 20, label = "To Stock", get = function(item) return "/ " .. utils.shortNumString(item.toStock) end },   -- batch - "/ " - shortNumString - padding
        { x = width - 29, label = "Stocked", get = function(item) return utils.shortNumString(item.stocked) end },     -- toStock - shortNumString - padding
        { x = width - 47, label = "Bee Species", get = function(item) return item.species .. " Bee" end }
    }
end

function beeMaintainer:createItemForm(inputForm, item)
    inputForm.addField("label", "Item label", item and item.label)
    inputForm.addField("stock", "Minimum Stock", item and tostring(item.toStock) or "0", inputForm.anyNumber)
    inputForm.addField("batch", "Maximum Stock", item and tostring(item.batch) or "0", inputForm.anyNumber)
    inputForm.addField("species", "Bee Species", item and item.species)
    --inputForm.addField("priority", "Priority", item and tostring(item.priority) or "0", inputForm.anyNumber)
    inputForm.addField("parallels", "Parallels", item and tostring(item.parallels) or "1", inputForm.anyNumber)
    inputForm.addField("group", "Group", item and item.groupLabel)
    return function(res)
        if res then
            local stock = tonumber(res["stock"]) or -1
            local batch = tonumber(res["batch"]) or -1
            --local priority = tonumber(res["priority"]) or 0
            local parallels = tonumber(res["parallels"]) or 0
            if stock < 0 or batch < 1 or parallels < 1 then return end
            if item then self:removeItem(item.label, item.groupLabel) end
            item = self:addItem(res["label"], stock, batch, res["group"])
            item.species = res["species"] or "INVALID"
            --item.priority = priority
            item.parallels = parallels
            item.dirty = true
        end
    end
end

function beeMaintainer:serialize()
    local res = {}
    local items = self:getRawItemList()
    for _, item in pairs(items) do
        table.insert(res, {
            label = item.label, toStock = item.toStock, maxStock = item.batch, group = item.groupLabel, disabled = item.disabled,
            species = item.species, priority = item.priority, parallels = item.parallels
        })
    end
    return res
end

function beeMaintainer:unserialize(data)
    if not data then return end
    for _, elem in pairs(data) do
        local item = self:addItem(data.label, data.toStock, data.batch, data.group)
        item.species = data.species or "INVALID"
        item.priority = data.priority or 0
        item.parallels = data.parallels or 1
        item.disabled = data.disabled or false
    end
end

return beeMaintainer