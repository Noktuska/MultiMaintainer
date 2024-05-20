local maintainer = require("maintainer")
local utils = require("utils")

local levelMaintainer = maintainer.new()
levelMaintainer.config = {
    meAddress = { label = "ME Address", type = "string", value = nil },
    craftsPerTick = { label = "Crafts per tick", type = "int", value = 10 },
    legacyTick = { label = "Legacy crafting method", type = "int", value = 0 }
}

local iterator = nil

function levelMaintainer:findPattern(me, filter)
    local data = me.getCraftables(filter)[1]
    if not data then return nil, "No pattern ["..filter.label.."] found" end
    return data
end

function levelMaintainer:craftItemIfNeeded(curItem, amount, me)
    if curItem.disabled then
        curItem.status = nil
        if curItem.statusVal ~= maintainer.enumStatus.cancelled then
            curItem.statusVal = maintainer.enumStatus.cancelled
            return true
        end
        return false
    end

    local filter = { label = curItem.label }
    if curItem.id then filter.name = curItem.id end
    if curItem.damage then filter.damage = curItem.damage end
    curItem.pattern = curItem.pattern or self:findPattern(me, filter)
    if not curItem.pattern then
        curItem.statusVal = levelMaintainer.enumStatus.cancelled
        return true
    end

    if amount == 0 then
        curItem.timeoutTick = curItem.timeoutTick + 1
        if curItem.timeoutTick <= 1 then return false end
    end
    curItem.timeoutTick = 0

    curItem.stocked = amount

    if curItem.status and curItem.status.isDone() then
        curItem.statusVal = levelMaintainer.enumStatus.idle
        curItem.status = nil
    end

    if not curItem.status and amount < curItem.toStock and (not levelMaintainer.checkCpus or not levelMaintainer.isItemAlreadyCrafting(me, curItem.label)) then
        local status = curItem.pattern.request(curItem.batch)
        -- Things that can happen that should be looked out for:
        -- 1) Pattern has been removed/changed. isDone() returns false, string;   isCanceled() returns true, string
        -- 2) No available CPUs.                isDone() returns false, string;   isCanceled() returns true, string
        -- 3) Not enough resources.             isDone() returns false, string;   isCanceled() returns true, string
        -- 4) Craft starts successfully.        isDone() returns false            isCanceled() returns false
        -- The string being "request failed (missing resources?)"
        local _, err = status.isCanceled()
        if err then
            curItem.statusVal = levelMaintainer.enumStatus.cancelled
            -- Recheck pattern for case 1)
            curItem.pattern = levelMaintainer.findPattern(me, filter)
        else
            curItem.statusVal = levelMaintainer.enumStatus.crafting
            curItem.status = status
        end
    elseif curItem.status and curItem.status.isCanceled() then
        curItem.statusVal = levelMaintainer.enumStatus.cancelled
        curItem.status = nil
    else curItem.statusVal = levelMaintainer.enumStatus.idle end

    return true
end

function levelMaintainer:legacyTick(me)
    local items = self:getRawItemList()
    if #items == 0 then return false end
    if not self.curItemTick then self.curItemTick = 0 end
    if items[self.curItemTick] then items[self.curItemTick].active = false end
    self.curItemTick = self.curItemTick + 1
    local curItem = items[self.curItemTick]
    curItem.active = true
    local filter = { label = curItem.label }
    if curItem.id then filter.name = curItem.id end
    if curItem.damage then filter.damage = curItem.damage end
    local stocked = me.getItemsInNetwork(filter)[1]
    if not stocked then return false end
    return self:craftItemIfNeeded(curItem, stocked.size, me)
end

function levelMaintainer:tick(me)
    if self.config.meAddress.value then me = require("component").proxy(self.config.meAddress.value) or me end

    if self.config.legacyTick.value ~= 0 then
        iterator = nil
        return self:legacyTick(me)
    end

    if not iterator then iterator = me.allItems() end

    local i = 0
    local dirty = false
    for stack in iterator do
        local item = self.items[stack.label]
        if item and (not item.id or item.id == stack.name) and (not item.damage or item.damage == stack.damage) then
            dirty = self:craftItemIfNeeded(item, stack.size, me) or dirty
        end
        i = i + 1
        if i >= self.config.craftsPerTick.value then return dirty end
    end

    iterator = nil
    return dirty
end

function levelMaintainer:getRenderTable(width)
    return {
        { x = 3, label = "Item", get = function(item)
            local res = item.label
            if item.id then
                res = res .. " [" .. item.id
                if item.damage then res = res .. "|" .. tostring(item.damage) end
                res = res .. "]"
            end
            if item.disabled then res = res .. " (D)" end
            return res
        end },
        { x = width - 9, label = "Batch", get = function(item) return utils.shortNumString(item.batch) end }, -- width - shortNumStringLen - padding
        { x = width - 20, label = "To Stock", get = function(item) return "/ " .. utils.shortNumString(item.toStock) end },   -- batch - "/ " - shortNumString - padding
        { x = width - 29, label = "Stocked", get = function(item) return utils.shortNumString(item.stocked) end }     -- toStock - shortNumString - padding
    }
end

function levelMaintainer:createItemForm(inputForm, item)
    inputForm.addField("label", "Item label", item and item.label)
    inputForm.addField("stock", "To Stock", item and tostring(item.toStock) or "0", inputForm.anyNumber)
    inputForm.addField("batch", "Batch size", item and tostring(item.batch) or "0", inputForm.anyNumber)
    inputForm.addField("id", "ID (optional)", item and item.id)
    inputForm.addField("damage", "Damage (optional)", item and tostring(item.damage))
    inputForm.addField("group", "Group", item and item.groupLabel)
    return function(res)
        if res then
            if res["stock"] < 0 or res["batch"] < 1 then return end
            item = item or self:addItem(res["label"], tonumber(res["stock"]), tonumber(res["batch"]), res["group"])
            item.label = res["label"]
            item.toStock = tonumber(res["stock"])
            item.batch = tonumber(res["batch"])
            item.id = res["id"]
            item.damage = res["damage"]
            if item.id == "" then item.id = nil end
            if item.damage == "" then item.damage = nil end
            if item.groupLabel ~= res["group"] then
                self:moveGroup(item.label, item.groupLabel, res["group"])
            end
            item.dirty = true
        end
    end
end

function levelMaintainer:serialize()
    local res = {}
    for _, elem in pairs(self:getRawItemList()) do
        local t = { label = elem.label, toStock = elem.toStock, batch = elem.batch, group = elem.group, disabled = elem.disabled }
        if elem.id then t.id = elem.id end
        if elem.damage then t.damage = elem.damage end
        table.insert(res, t)
    end
    return res
end

function levelMaintainer:unserialize(data)
    if not data then return false end
    for _, elem in pairs(data) do
        local item = self:addItem(elem.label, elem.toStock, elem.batch, elem.group)
        item.id = elem.id
        item.damage = elem.damage
        item.disabled = elem.disabled or false
    end
    return true
end

return levelMaintainer