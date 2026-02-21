-- usr_uart.lua
-- UART Driver for MCU Communication

local sys = require("sys")
local config = require("usr_config")

local uart_drv = {}

-- Initialize UART
function uart_drv.init()
    local result = uart.setup(
        config.UART_ID,
        config.UART_BAUD,
        8,
        1
    )
    if result ~= 0 then
        log.error("UART", "Setup failed: " .. result)
    else
        log.info("UART", "Setup success")
    end
end

-- Send Data
function uart_drv.send(data)
    uart.write(config.UART_ID, data)
end

return uart_drv
