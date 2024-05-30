local wireless = require("wireless")
local component = require("component")
local sides = require("sides")

local r = component.redstone
if not r then print("Need redstone component") return end
r.setOutput(sides.right, 0)

local robot = component.robot
if not robot then print("This file can only be run on a robot!") return end

print("Please ensure the IAADDS is in the following state:")
print("Input / Normal")
_ = io.read()

local enumState = {
    off = 0,
    on = 1,
    pulse = 2,
    input = 3,
    output = 4,
    operating = 5,
    normal = 6,
    swarmer = 7,

    [0] = "Off",
    [1] = "On",
    [2] = "Pulse",
    [3] = "Input",
    [4] = "Output",
    [5] = "Operating",
    [6] = "Normal",
    [7] = "Swarmer"
}

--local isOn = false
local state = enumState.input -- input -> output -> operating
local opState = enumState.normal -- normal -> swarmer

while true do
    local listener, err = wireless.listen(82)
    if not listener then print(err) break end

    local res = nil
    repeat
        os.sleep(1)
        res = listener.get()
    until res

    if not res then break end

    print("Received " .. tostring(#res - 4) .. " commands")

    for i = 5, #res do
        local op = res[i]

        print("Executing command: " .. enumState[op])

        if op == enumState.off then
            r.setOutput(sides.right, 0)
            os.sleep(6)
        elseif op == enumState.on then
            r.setOutput(sides.right, 15)
            os.sleep(1)
        elseif op == enumState.pulse then
            r.setOutput(sides.right, 15)
            os.sleep(1)
            r.setOutput(sides.right, 0)
            os.sleep(1)
        elseif op >= enumState.input and op <= enumState.operating then
            local diff = op - state
            if diff < 0 then diff = diff + 3 end
            for _ = 1, diff do
                robot.use(sides.front)
                state = state + 1
                if state > enumState.operating then state = enumState.input end
            end
        elseif op >= enumState.normal and op <= enumState.swarmer then
            if op ~= opState then
                robot.use(sides.front, sides.front, true)
                opState = op
            end
        end
    end

    listener.respond(true)
end