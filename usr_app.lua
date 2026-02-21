local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")
-- pm is global

local app = {}

function app.start()
    -- Hardware Init
    led.init()
    uart.init()
    
    -- Main Loop Task
    sys.taskInit(function()
        -- Indication: System Power On
        led.blink(200) 
        
        log.info("APP", "Tracker Started")
        
        -- log.info("APP", "Waiting for Network...")
        -- log.info("APP", "Waiting for Network...")
        -- Check if we have an IP address
        if socket.localIP() == "0.0.0.0" or socket.localIP() == nil then
            sys.waitUntil("IP_READY")
        end
        log.info("APP", "Network Ready")
        
        -- Enable Low Power Mode (PSM) NOW, after we are sure we have network
        -- MOVED to end of loop to prevent early sleep
        -- pm.power(pm.WORK_MODE, config.POWER_MODE)
        
        while true do
            -- 1. Wake Up
            led.blink(200) -- Blink briefly
            
            -- 2. Get Location
            local res, lat, lng = lbs.getLocation()
            if res == 0 then
                -- Log simplified info
                log.info("APP", "Loc: " .. lat .. "," .. lng)
                
                -- Send to MCU: "LBS:lat,lng\r\n"
                uart.send("LBS:" .. lat .. "," .. lng .. "\r\n")
            else
                log.info("APP", "Loc Failed: " .. res)
                uart.send("LBS:ERROR," .. res .. "\r\n")
            end
            
            -- 3. Check Commands (Simulation)
            -- http_client.checkCommands()...
            
            -- 4. Sleep
            log.info("APP", "Sleep " .. (config.REPORT_INTERVAL/1000) .. "s")
            
            -- Enable Low Power Mode (PSM) JUST BEFORE SLEEPing
            -- This ensures we don't sleep while waiting for LBS
            pm.power(pm.WORK_MODE, config.POWER_MODE)
            
            -- If in PSM mode (3), we MUST use a hardware timer to wake up
            -- sys.wait() alone might not set the RTC alarm for deep sleep
            if config.POWER_MODE == 3 then
                pm.dtimerStart(0, config.REPORT_INTERVAL)
            end
            
            -- 5. Wait/Sleep
            -- If PSM enabled, device will likely power down here and REBOOT on timer
            sys.wait(config.REPORT_INTERVAL)
        end
    end)
end

return app
