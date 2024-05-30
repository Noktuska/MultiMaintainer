local utils = require("utils")

local maintainer = {
    enumStatus = {
        idle = 0,
        crafting = 1,
        cancelled = 2
    }
}

local function newItem(o)
    local item = {
        label = nil,
        pattern = nil,
        stocked = 0,
        toStock = 0,
        batch = 0,
        craftStatus = nil,
        statusStr = "",
        statusVal = maintainer.enumStatus.idle,
        timeoutTick = 0,
        disabled = false,
        groupLabel = nil
    }
    for k, v in pairs(o) do item[k] = v end
    return item
end

local function newGroup(o)
    local group = {
        items = {},
        sortedItemIndices = {},
        groupLabel = ""
    }
    if o then for k, v in pairs(o) do group[k] = v end end
    return group
end

function maintainer.new(o)
    o = o or {}
    setmetatable(o, { __index = maintainer })
    o.logs = {}
    o.items = {}
    o.groups = {}
    o.sortedGroupIndices = {}
    return o
end

function maintainer:addItem(label, toStock, batch, groupLabel, _item)
    local group = self.groups[groupLabel]
    if not group then
        group = newGroup{ label = groupLabel }
        self.groups[groupLabel] = group
        table.insert(self.sortedGroupIndices, groupLabel)
        table.sort(self.sortedGroupIndices)
    end
    if group.items[label] then return nil end
    local item = _item or newItem{ label = label, toStock = toStock, batch = batch, groupLabel = groupLabel }
    self.items[label] = item
    group.items[label] = item
    table.insert(group.sortedItemIndices, label)
    table.sort(group.sortedItemIndices)
    group.dirty = true
    item.dirty = true
    return item
end

function maintainer:removeItem(label, groupLabel)
    if not groupLabel then -- If groupLabel is not given search for it
        for _, group in pairs(self.groups) do
            if group[label] then groupLabel = group.label break end
        end
        if not groupLabel then return nil end
    end
    local group = self.groups[groupLabel]
    if not group or not group.items[label] then return nil end
    utils.removeByValue(group.sortedItemIndices, label)
    local oldItem = group.items[label]
    self.items[label] = nil
    group.items[label] = nil
    if #group.sortedItemIndices == 0 then -- If no items are left remove the group altogether
        utils.removeByValue(self.sortedGroupIndices, groupLabel)
        self.groups[groupLabel] = nil
    end
    group.dirty = true
    return oldItem
end

function maintainer:moveGroup(label, oldGroupLabel, newGroupLabel)
    local item = self:removeItem(label, oldGroupLabel)
    self:addItem(label, nil, nil, newGroupLabel, item)
    item.groupLabel = newGroupLabel
end

function maintainer:getRawItemList()
    local res = {}
    for _, groupLabel in pairs(self.sortedGroupIndices) do
        local group = self.groups[groupLabel]
        for _, label in pairs(group.sortedItemIndices) do
            table.insert(res, group.items[label])
        end
    end
    return res
end

function maintainer:getVisibleList(filter, offset, height)
    filter = filter or ""
    offset = offset or 0
    height = height or math.huge
    local res = {}
    local function match(str) return string.match(string.lower(str), string.lower(filter)) end
    local function insertWithOffset(elem)
        if height > 0 then
            if offset > 0 then offset = offset - 1 else table.insert(res, elem) height = height - 1 end
        end
    end
    for _, groupLabel in pairs(self.sortedGroupIndices) do
        local group = self.groups[groupLabel]
        if match(groupLabel) then
            insertWithOffset{ type = "group", elem = group }
            if group.isOpen then
                for _, label in pairs(group.sortedItemIndices) do
                    insertWithOffset{ type = "item", elem = group.items[label] }
                end
            end
        else
            local hasValidItem = false
            for _, label in pairs(group.sortedItemIndices) do
                if match(label) then
                    hasValidItem = true
                    break
                end
            end
            if hasValidItem then
                insertWithOffset{ type = "group", elem = group }
                if group.isOpen then
                    for _, label in pairs(group.sortedItemIndices) do
                        if match(label) then
                            insertWithOffset{ type = "item", elem = group.items[label] }
                        end
                    end
                end
            end
        end
    end
    return res
end

function maintainer:log(...)
    local msg = {...}
    for _, elem in pairs(msg) do
        table.insert(self.logs, elem)
    end
    while #self.logs > 20 do
        table.remove(self.logs, 1)
    end
    self.logsDirty = true
end

function maintainer:tick(me) end

function maintainer:getRenderTable(width) return {} end

function maintainer:createAddItemForm(inputForm) return false end

function maintainer:serialize()
    local res = {}
    for _, elem in pairs(self:getRawItemList()) do
        table.insert({ label = elem.label, toStock = elem.toStock, batch = elem.batch, group = elem.group, disabled = elem.disabled })
    end
    return res
end

function maintainer:unserialize(data)
    if not data then return false end
    for _, elem in pairs(data) do
        local item = self:addItem(elem.label, elem.toStock, elem.batch, elem.group)
        item.id = elem.id
        item.disabled = elem.disabled or false
    end
    return true
end

return maintainer