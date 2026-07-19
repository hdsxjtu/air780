-- usr_uart.lua
-- UART Driver for MCU Communication

local sys = require("sys")
local config = require("usr_config")

local uart_drv = {}
local rx_cb = nil

-- Buffer for incoming data
local rx_buffer = ""

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
    end
    
    -- Setup UART receive callback
    uart.on(config.UART_ID, "receive", function(id, len)
        local s = uart.read(id, 1024)
        if #s > 0 then
            rx_buffer = rx_buffer .. s
            -- Process line by line
            while true do
                local i, j = string.find(rx_buffer, "\r\n")
                if i then
                    local line = string.sub(rx_buffer, 1, i - 1)
                    rx_buffer = string.sub(rx_buffer, j + 1)
                    if rx_cb then
                        rx_cb(line)
                    end
                else
                    break
                end
            end
            
            -- Prevent buffer from growing infinitely if no \r\n
            if string.len(rx_buffer) > 2048 then
                rx_buffer = ""
            end
        end
    end)
end

-- Send Data
function uart_drv.send(data)
    uart.write(config.UART_ID, data)
end

function uart_drv.onReceive(cb)
    rx_cb = cb
end

return uart_drv
