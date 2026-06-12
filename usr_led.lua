-- usr_led.lua
-- Hardware Driver for Status LED

local sys = require("sys")
local config = require("usr_config")

local led = {}

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

-- Blink LED once (BLOCKING usually, but here we just toggle)
function led.blink(duration_ms)
    led.on()
    sys.wait(duration_ms or 200)
    led.off()
end

return led
