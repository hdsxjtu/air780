-- usr_led.lua
-- Hardware Driver for Status LED

local sys = require("sys")
local config = require("usr_config")

local led = {}
local current_status = "off"
local task_started = false
local activity_busy = false

-- Initialize the LED GPIO
function led.init()
    gpio.setup(config.LED_PIN, 1) -- Default OFF (High)
    gpio.set(config.LED_PIN, 1)   -- Force OFF immediately (Active Low)
end

-- Turn LED On
function led.on()
    gpio.set(config.LED_PIN, 0) -- Active Low
    -- log.info("LED", "Set GPIO " .. config.LED_PIN .. " to 0 (ON)")
end

-- Turn LED Off
function led.off()
    gpio.set(config.LED_PIN, 1) -- Active Low
    -- log.info("LED", "Set GPIO " .. config.LED_PIN .. " to 1 (OFF)")
end

local function enabled()
    return config.BLUE_LED_ENABLE ~= false
end

function led.activity(duration_ms)
    if not enabled() or activity_busy then
        return
    end
    activity_busy = true
    led.on()
    sys.wait(duration_ms or 20)
    led.off()
    activity_busy = false
end

function led.offline_hint()
    if not enabled() or activity_busy then
        return
    end
    activity_busy = true
    for i = 1, 5 do
        led.on()
        sys.wait(20)
        led.off()
        sys.wait(180)
    end
    activity_busy = false
end

-- Legacy name kept for existing packet hooks.
function led.blink(duration_ms)
    led.activity(duration_ms)
end

function led.boot_marker()
    led.off()
end

function led.status(status)
    current_status = status or "off"
    if config.BLUE_LED_ENABLE == false then
        current_status = "off"
    end
end

function led.start(initial_status)
    if task_started then
        led.status(initial_status or current_status)
        return
    end
    task_started = true
    led.status(initial_status or "boot")

    sys.taskInit(function()
        while true do
            if config.BLUE_LED_ENABLE == false or current_status == "off" then
                led.off()
                sys.wait(1000)
            elseif current_status == "boot" then
                -- Boot: keep off. Data activity and offline hints are the only visible signals.
                led.boot_marker()
                current_status = "waiting_network"
            elseif current_status == "waiting_network" or current_status == "hb_check" then
                -- Not ready: mostly off, with one 3-blink hint every 60 seconds.
                led.off()
                sys.wait(60000)
                led.offline_hint()
            elseif current_status == "online" then
                -- Online but idle: off. Packets call led.activity().
                led.off()
                sys.wait(1000)
            elseif current_status == "fail" then
                -- Failed: same as cannot network, 3 slow blinks every 60 seconds.
                led.off()
                sys.wait(60000)
                led.offline_hint()
            else
                led.off()
                sys.wait(1000)
            end
        end
    end)
end

return led
