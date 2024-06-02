local maintainer = require("maintainer")
local utils = require("utils")

local aspectMaintainer = maintainer.new()
aspectMaintainer.config = {
    meAddress = { label = "ME Address", type = "string", value = nil },
    redstone = { label = "Redstone component", type = "string", value = nil },
    ignoreRedstoneInput = { label = "Ingore redstone input", type = "int", value = 0 },
    outputWhenLow = { label = "Redstone on low essentia", type = "int", value = 0 }
}

function aspectMaintainer:shouldTick()
    if self.config.ignoreRedstoneInput.value ~= 0 then return true end
    if not self.config.redstone.value then return true end
    local redstone = require("component").proxy(self.config.redstone.value)
    if not redstone then return true end
    for i = 0, 5 do
        if redstone.getInput(i) > 0 then return true end
    end
    return false
end

function aspectMaintainer:setEssentiaWarning(isLow)
    if not self.config.redstone.value then return end
    local redstone = require("component").proxy(self.config.redstone.value)
    if not redstone then return end
    local value = 0
    if isLow == (self.config.outputWhenLow.value ~= 0) then value = 15 end
    for side = 0, 5 do
        redstone.setOutput(side, value)
    end
end

function aspectMaintainer:initAllAspects(me, toStock, batch, alert, group)
    local patterns = me.getCraftables{ name = "thaumicenergistics:crafting.aspect" }
    for _, pattern in pairs(patterns) do
        local label = string.gsub(pattern.getItemStack().aspect, "^%l", string.upper)
        local item = self:addItem(label, toStock, batch, group)
        item.alert = alert
        item.dirty = true
    end
end

function aspectMaintainer:findPattern(me, label)
    local data = me.getCraftables({ aspect = string.lower(label) })[1]
    if not data then return nil, "No pattern ["..label.."] found" end
    return data
end

function aspectMaintainer:craftAspectIfNeeded(aspect, amount, me)
    if aspect.disabled then
        aspect.status = nil
        if aspect.statusVal ~= maintainer.enumStatus.cancelled then
            aspect.statusVal = maintainer.enumStatus.cancelled
            return true
        end
        return false
    end

    aspect.pattern = aspect.pattern or self:findPattern(me, aspect.label)
    if not aspect.pattern then
        aspect.statusVal = self.enumStatus.cancelled
        return true
    end

    if amount == 0 then
        aspect.timeoutTick = aspect.timeoutTick + 1
        if aspect.timeoutTick <= 1 then return false end
    end
    aspect.timeoutTick = 0

    if aspect.stocked ~= amount then aspect.dirty = true end
    aspect.stocked = amount

    if aspect.status and aspect.status.isDone() then
        aspect.statusVal = self.enumStatus.idle
        aspect.status = nil
    end

    if not aspect.status and amount < aspect.toStock and (not self.checkCpus or not self:isItemAlreadyCrafting(me, aspect.label)) then
        local status = aspect.pattern.request(aspect.batch)
        -- Things that can happen that should be looked out for:
        -- 1) Pattern has been removed/changed. isDone() returns false, string;   isCanceled() returns true, string
        -- 2) No available CPUs.                isDone() returns false, string;   isCanceled() returns true, string
        -- 3) Not enough resources.             isDone() returns false, string;   isCanceled() returns true, string
        -- 4) Craft starts successfully.        isDone() returns false            isCanceled() returns false
        -- The string being "request failed (missing resources?)"
        local _, err = status.isCanceled()
        if err then
            aspect.statusVal = self.enumStatus.cancelled
            -- Recheck pattern for case 1)
            aspect.pattern = self:findPattern(me, aspect.label)
        else
            aspect.statusVal = self.enumStatus.crafting
            aspect.status = status
        end
    elseif aspect.status and aspect.status.isCanceled() then
        aspect.statusVal = self.enumStatus.cancelled
        aspect.status = nil
    elseif not aspect.status then aspect.statusVal = self.enumStatus.idle end

    return true
end

function aspectMaintainer:tick()
    if not self:shouldTick() then return false end
    local me = nil
    if self.config.meAddress.value then me = require("component").proxy(self.config.meAddress.value) end
    if not me then return false end
    local stockedEssentia = me.getEssentiaInNetwork()
    local stockedEssentiaMap = {}
    for _, ess in pairs(stockedEssentia) do
        local label = string.match(ess.label, "%w+")
        stockedEssentiaMap[label] = ess.amount
    end
    local alert = false
    local aspectList = self:getRawItemList()
    for _, aspect in pairs(aspectList) do
        local label = aspect.label
        local amount = stockedEssentiaMap[label] or 0
        self:craftAspectIfNeeded(aspect, amount, me)
        if not aspect.alert then aspect.alert = 512 end
        if amount < aspect.alert then alert = true end
    end
    self:setEssentiaWarning(alert)
end

function aspectMaintainer:getRenderTable(width)
    return {
        { x = 6, label = "Aspect", get = function(item)
            local res = item.label
            if item.disabled then res = res .. " (D)" end
            return res
        end },
        { x = width - 9, label = "Batch", get = function(item) return utils.shortNumString(item.batch) end }, -- width - shortNumStringLen - padding
        { x = width - 20, label = "To Stock", get = function(item) return "/ " .. utils.shortNumString(item.toStock) end },   -- batch - "/ " - shortNumString - padding
        { x = width - 29, label = "Stocked", get = function(item) return utils.shortNumString(item.stocked) end },     -- toStock - shortNumString - padding
        { x = width - 38, label = "Alert", get = function(item) return utils.shortNumString(item.alert) or "512" end }
    }
end

function aspectMaintainer:createItemForm(inputForm, item)
    inputForm.addField("label", "Aspect name", item and item.label)
    inputForm.addField("stock", "To Stock", item and tostring(item.toStock) or "0", inputForm.anyNumber)
    inputForm.addField("batch", "Batch size", item and tostring(item.batch) or "0", inputForm.anyNumber)
    inputForm.addField("group", "Group", item and item.groupLabel)
    inputForm.addField("alert", "Alert", item and item.alert)
    return function(res)
        if res then
            local stock = tonumber(res["stock"]) or -1
            local batch = tonumber(res["batch"]) or -1
            if stock < 0 or batch < 1 then return end
            if res["label"] == "__init__" then
                local me = nil
                if self.config.meAddress.value then me = require("component").proxy(self.config.meAddress.value) end
                if me then
                    self:initAllAspects(me, stock, batch, tonumber(res["alert"]), res["group"])
                    return
                end
            end
            if item then self:removeItem(item.label, item.groupLabel) end
            item = self:addItem(res["label"], stock, batch, res["group"])
            item.alert = tonumber(res["alert"])
            item.dirty = true
        end
    end
end

function aspectMaintainer:serialize()
    local res = {}
    for _, elem in pairs(self:getRawItemList()) do
        local t = { label = elem.label, toStock = elem.toStock, batch = elem.batch, group = elem.groupLabel, disabled = elem.disabled }
        if elem.alert then t.alert = elem.alert end
        table.insert(res, t)
    end
    return res
end

function aspectMaintainer:unserialize(data)
    if not data then return false end
    for _, elem in pairs(data) do
        local item = self:addItem(elem.label, elem.toStock, elem.batch, elem.group)
        item.alert = elem.alert or 512
    end
    return true
end

return aspectMaintainer