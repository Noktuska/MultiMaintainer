local maintainer = require("maintainer")
local utils = require("utils")
local component = require("component")
local wireless = require("wireless")

local beeMaintainer = maintainer.new()
beeMaintainer.tickIndex = 0
beeMaintainer.diffList = {}
beeMaintainer.apiaryList = {}
beeMaintainer.busy = false
beeMaintainer.timeout = 0
beeMaintainer.config = {
    meAddress = { label = "Main ME Address", type = "string", value = nil },
    beeMeAddress = { label = "Apiary ME Address", type = "string", value = nil },
    robotAddr = { label = "Robot Address", type = "string", value = nil },
    slots = { label = "Apiary Slots", type = "int", value = 0 },
    timeout = { label = "Apiary timeout", type = "int", value = 40 }
}

local enumState = {
    off = 0,
    on = 1,
    pulse = 2,
    input = 3,
    output = 4,
    operating = 5,
    normal = 6,
    swarmer = 7
}

function beeMaintainer:setApiaryState(...)
    if not self.config.robotAddr.value then return false, "No robot address defined" end
    local modem = component.modem
    if not modem then return false, "No modem installed" end

    local get, err = wireless.send(self.config.robotAddr.value, 82, ...)
    if not get then return false, err end

    while not get() do coroutine.yield(true, false) end

    return true
end

---Does work related to setting up the Apiary or breeding Queens. Function uses a coroutine to not block the thread while waiting
---@return boolean - Whether or not the function call worked as expected
---@return string|boolean|nil - If the function did not work as expected an error string or nil is returned. Otherwise it returns true if the coroutine terminated
function beeMaintainer:asyncDoWork()
    if not self.asyncState then self.asyncState = 0 end

    local chk, err = self:setApiaryState(enumState.off, enumState.output, enumState.pulse, enumState.input, enumState.on)
    if not chk then return false, err end

    self:log("Apiary configured, moving old queens")

    local t = component.transposer
    if not t then return false, "No transposer fulfills the requirements to edit the Mega Apiary" end

    local sideInterface = nil
    local sideChest = nil
    local sideInput = nil
    local sideApiary = nil
    for i = 0, 5 do
        local inv = t.getInventoryName(i)
        if inv then
            if string.match(inv, "Interface") then sideInterface = i end
            if string.match(inv, "Chest") then sideChest = i end
            if string.match(inv, "blockmachine") then
                if t.getInventorySize(i) == 21 then sideApiary = i
                else sideInput = i end
            end
        end
    end
    
    if not sideInterface or not sideChest or not sideInput or not sideApiary then return false, "Not all Transposer sides connected" end

    local function ensureMove(...)
        local count = ({...})[3] or 1
        local totalMoved = 0
        repeat
            local moved = t.transferItem(...)
            if moved == 0 then coroutine.yield(true, false) end
            totalMoved = totalMoved + moved
        until totalMoved == count
    end

    local function findSlot(side, pattern)
        local it = t.getAllStacks(side)
        local i = 1
        for stack in it do
            if stack.label and string.match(stack.label, pattern) then return i end
            i = i + 1
        end
        return nil
    end

    local function findSlotAsync(side, pattern)
        repeat
            local slot = findSlot(side, pattern)
            if slot then return slot end
            coroutine.yield(true, false)
        until slot
    end

    -- BREED NEW QUEENS
    self:log("Checking queen parallels...")
    local subMe = component.proxy(self.config.beeMeAddress.value)
    local db = component.database
    if not subMe then return false, "Not connected to Apiary ME subnet" end
    if not db then return false, "No database connected" end
    for _, elem in pairs(self.queensToAdd) do
        local item = self.items[elem.itemLabel]

        local queenList = subMe.getItemsInNetwork{ label = elem.species .. " Queen" }
        local queenCount = 0
        for _, stack in pairs(queenList) do
            queenCount = queenCount + stack.size
        end

        if queenCount == 0 then return false, "No " .. elem.species .. " Queen in subnet" end
        -- BREED NEW QUEENS
        if queenCount < item.parallels then
            self:log("Found " .. tostring(queenCount) .. " " .. elem.species .. " Queen(s), need " .. tostring(item.parallels))

            -- Turn on apiary in swarmer mode
            self:log("Turning apiary into swarmer mode")
            self:setApiaryState(enumState.off, enumState.input, enumState.swarmer, enumState.on)

            self:log("Moving queen into apiary")
            db.clear(1)
            subMe.store({ label = elem.species .. " Queen" }, db.address, 1, 1)
            subMe.setInterfaceConfiguration(1, db.address, 1, 1)
            ensureMove(sideInterface, sideInput, 1, 1)
            subMe.setInterfaceConfiguration(1)

            self:setApiaryState(enumState.pulse, enumState.operating, enumState.on)

            -- Count princesses in output and stop apiary once we have enough
            repeat
                local it = t.getAllStacks(sideChest)
                local princessCount = 0
                for stack in it do
                    if stack.label and stack.size and string.match(stack.label, "Princess") then princessCount = princessCount + stack.size end
                end
                self:log("Found " .. tostring(princessCount) .. " Princess(es)")
                if princessCount < item.parallels - queenCount - 1 then coroutine.yield(true, false) end
            until princessCount >= item.parallels - queenCount - 1

            self:log("Turning apiary back into normal mode")
            self:setApiaryState(enumState.off, enumState.output, enumState.pulse, enumState.normal)

            -- Find queen in output and breed enough drones until drone >= princesses
            self:log("Moving queen into apiary to breed drones")
            local queenSlot = findSlotAsync(sideChest, elem.species .. " Queen")

            ensureMove(sideChest, sideApiary, 1, queenSlot)  -- Queen from chest into apiary
            local droneCount = 0
            repeat
                repeat
                    local foundDrone = false
                    local it = t.getAllStacks(sideApiary)   -- Snapshot of all items in apiary
                    local curSlot = 1
                    for stack in it do
                        if curSlot >= 12 and stack.label and stack.size then    -- If there is an item in any output slot
                            if stack.label == elem.species .. " Princess" then
                                t.transferItem(sideApiary, sideApiary, 1, curSlot)  -- Move Princess back into input to make another queen
                            elseif stack.label == elem.species .. " Drone" then
                                if not foundDrone then      -- If no drone so far found...
                                    t.transferItem(sideApiary, sideApiary, 1, curSlot)  -- Move 1 to input to make another queen
                                    droneCount = droneCount + stack.size - 1            -- Add the rest to the output
                                    t.transferItem(sideApiary, sideChest, stack.size - 1, curSlot)
                                    foundDrone = true
                                else           -- If we already made a queen move other drones to output
                                    droneCount = droneCount + stack.size
                                    t.transferItem(sideApiary, sideChest, stack.size, curSlot)
                                end
                            end
                        end
                        curSlot = curSlot + 1
                    end
                    self:log("Found drones: " .. tostring(foundDrone) .. ", count: " .. tostring(droneCount))
                    if not foundDrone then coroutine.yield(true, false) end     -- Pause coroutine if still waiting for queen to breed
                until foundDrone
                local queenSlot = findSlotAsync(sideApiary, elem.species .. " Queen")
                if droneCount < item.parallels - queenCount then   -- If not done move queen to input to make another generation of drones
                    ensureMove(sideApiary, sideApiary, 1, queenSlot)
                else                                                -- Else move queen to output
                    ensureMove(sideApiary, sideInterface, 1, queenSlot)
                end
            until droneCount >= item.parallels - queenCount     -- Repeat until we have a drone for each new princess

            self:log("Turning princesses into queens and outputting them")
            repeat
                local princessSlot = findSlot(sideChest, elem.species .. " Princess")
                local droneSlot = findSlot(sideChest, elem.species .. " Drone")
                if princessSlot and droneSlot then
                    ensureMove(sideChest, sideApiary, 1, princessSlot)
                    ensureMove(sideChest, sideApiary, 1, droneSlot)
                    local queenSlot = findSlotAsync(sideApiary, elem.species .. " Queen")
                    ensureMove(sideApiary, sideInterface, 1, queenSlot)     -- Move final queens to subnet interface
                end
            until not princessSlot or not droneSlot

            self:log("Deleting overflow princesses and drones")
            local it = t.getAllStacks(sideChest)
            local curSlot = 1
            for stack in it do
                if stack.label and stack.size and (stack.label == elem.species .. " Drone" or stack.label == elem.species .. " Princess") then
                    ensureMove(sideChest, sideInterface, stack.size, curSlot)
                end
                curSlot = curSlot + 1
            end
        end
    end

    self:log("Removing old queens from apiary")
    local curSlot = 1
    local it = t.getAllStacks(sideChest)
    for stack in it do
        -- Remove any queens that are on the to remove list
        if stack.label and stack.size then
            local moved = false
            for _, elem in pairs(self.queensToRemove) do
                if stack.label == elem .. " Queen" then
                    ensureMove(sideChest, sideInterface, 1, curSlot)
                    moved = true
                    self:log("Removed " .. stack.label .. " Queen")
                    -- Reset crafting state and update apiaryList
                    for i = 1, #self.apiaryList do
                        if self.apiaryList[i].species .. " Queen" == stack.label then
                            self.items[self.apiaryList[i].itemLabel].statusVal = self.enumStatus.idle
                            table.remove(self.apiaryList, i)
                            break
                        end
                    end
                    break
                end
            end

            -- If it wasn't on the to remove list put it back into the input bus
            if not moved then
                ensureMove(sideChest, sideInput, 1, curSlot)
                self:log("Kept " .. stack.label .. " Queen")
            end
        end
        
        curSlot = curSlot + 1
    end

    -- ADDING NEW BEES TO APIARY
    for _, elem in pairs(self.queensToAdd) do
        self:log("Adding " .. elem.species .. " Queen to apiary")
        local item = self.items[elem.itemLabel]
        -- Clear database slot
        db.clear(1)
        -- Make sure the queen is in the Subnet
        
        local queenFound = (#subMe.getItemsInNetwork{ label = elem.species .. " Queen" } > 0)
        if queenFound then
            -- Add Queen to database and set it to stock in interface
            subMe.store({ label = elem.species .. " Queen" }, db.address, 1, 1)
            subMe.setInterfaceConfiguration(1, db.address, 1, 1)
            -- Try to move queen into input bus as the interface might have a delay when stocking
            ensureMove(sideInterface, sideInput, 1, 1)
            -- Mark item as crafting and update apiaryList
            item.statusVal = self.enumStatus.crafting
            table.insert(self.apiaryList, elem)
        end
    end
    -- Reset interface
    subMe.setInterfaceConfiguration(1)

    if #self.apiaryList == 0 then
        -- TURN OFF APIARY SINCE ITS EMPTY
        chk, err = self:setApiaryState(enumState.off)
        if not chk then return false, err end
    else
        -- TURN ON APIARY
        chk, err = self:setApiaryState(enumState.off, enumState.operating, enumState.on)
        if not chk then return false, err end
    end

    self:log("Done!")
    self.asyncRoutine = nil
    self.timeout = self.config.timeout.value
    return true, true
end

function beeMaintainer:tick()
    if self.asyncRoutine then
        local chk, val = coroutine.resume(self.asyncRoutine)
        if not chk then
            self.asyncRoutine = nil
            self:log("ERROR: " .. tostring(val))
            self.timeout = self.config.timeout.value * 5
        end
        return false
    end

    if self.timeout > 0 then
        self.timeout = self.timeout - 1
        return false
    end
    
    if self.config.slots.value < 1 or
        not self.config.robotAddr.value or
        not self.config.beeMeAddress.value or
        not self.config.robotAddr.value then return false end

    local me = nil
    if self.config.meAddress.value then me = component.proxy(self.config.meAddress.value) end
    if not me then return false end

    self:log("Start tick")

    local itemList = self:getRawItemList()
    if #itemList == 0 then return false end

    if itemList[self.tickIndex] then
        itemList[self.tickIndex].active = false
        itemList[self.tickIndex].dirty = true
    end
    self.tickIndex = self.tickIndex + 1

    if self.tickIndex > #itemList then
        self:log("Apiary logic...")
        -- APIARY LOGIC
        local slots = self.config.slots.value - #self.apiaryList
        -- GET QUEENS TO REMOVE FROM APIARY
        self.queensToRemove = {}
        for _, elem in pairs(self.apiaryList) do
            local item = self.items[elem.itemLabel]
            if item.stocked >= item.batch or item.disabled then
                table.insert(self.queensToRemove, item.species)
                slots = slots + 1
            end
        end
        self:log("Removing " .. #self.queensToRemove .. " Queen(s)")

        -- GET QUEENS TO ADD TO APIARY
        table.sort(self.diffList, function(l, r) return l.diff <= r.diff end) -- Sort items by how low they got on stock in compared to toStock
        self.queensToAdd = {}
        local i = 1
        while slots > 0 do  -- Try to fill the apiary
            local item = self.diffList[i] and self.diffList[i].item
            if not item then break end  -- Ran out of items on the itemList

            if item.batch ~= 0 and (item.stocked - item.toStock) / item.batch >= 0.5 then break end -- Still have over 50% between min and max stock

            if item.statusVal == self.enumStatus.idle then
                for _ = 1, item.parallels do
                    table.insert(self.queensToAdd, { itemLabel = item.label, species = item.species })
                    slots = slots - 1
                    if slots == 0 then break end
                end
            end
            i = i + 1
        end

        -- Do apiary logic if 1) we need to add/swap any queens or 2) All Queens are done producing
        if #self.queensToAdd > 0 or (#self.queensToRemove > 0 and #self.queensToRemove == #self.apiaryList) then
            self:log("Adding " .. #self.queensToAdd .. " Queens to apiary")

            -- Modifying the apiary as well as breeding new Queens takes time so we do it "async" with a coroutine
            self.asyncRoutine = coroutine.create(beeMaintainer.asyncDoWork)
            coroutine.resume(self.asyncRoutine, self)
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
    item.dirty = true

    self:log("Checked item " .. item.label .. " [" .. item.stocked .. "]")

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
            local status = self.enumStatus.idle
            if item then status = item.statusVal end
            if item then self:removeItem(item.label, item.groupLabel) end
            item = self:addItem(res["label"], stock, batch, res["group"])
            item.species = res["species"] or "INVALID"
            --item.priority = priority
            item.parallels = parallels
            item.dirty = true
            item.statusVal = status
        end
    end
end

function beeMaintainer:serialize()
    local res = { items = {}, apiaryList = self.apiaryList }
    local items = self:getRawItemList()
    for _, item in pairs(items) do
        table.insert(res.items, {
            label = item.label, toStock = item.toStock, maxStock = item.batch, group = item.groupLabel, disabled = item.disabled,
            species = item.species, priority = item.priority, parallels = item.parallels,
            status = item.statusVal
        })
    end
    return res
end

function beeMaintainer:unserialize(data)
    if not data then return end
    for _, elem in pairs(data.items) do
        local item = self:addItem(elem.label, elem.toStock, elem.maxStock, elem.group)
        item.species = elem.species or "INVALID"
        item.priority = elem.priority or 0
        item.parallels = elem.parallels or 1
        item.disabled = elem.disabled or false
        item.statusVal = elem.status or self.enumStatus.idle
    end
    if data.apiaryList then self.apiaryList = data.apiaryList end
end

return beeMaintainer