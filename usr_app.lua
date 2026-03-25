local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")

local app = {}
local netc = nil

-- Utility to get string parts separated by comma
local function split(str, reps)
    local resultStrList = {}
    string.gsub(str, '[^' .. reps .. ']+', function(w)
        table.insert(resultStrList, w)
    end)
    return resultStrList
end

function app.start()
    led.init()
    uart.init()
    
    local imei = ""
    if mobile and mobile.imei then
        imei = mobile.imei()
    else
        imei = "DEV888" -- Fallback
    end
    
    -- Register UART receive handler
    uart.onReceive(function(line)
        log.info("UART_RX", line)
        sys.publish("UART_RECV", line)
    end)
    
    sys.taskInit(function()
        led.blink(200)
        log.info("APP", "V3 Tracker Started. IMEI: " .. imei)
        
        if socket.localIP() == "0.0.0.0" or socket.localIP() == nil then
            sys.waitUntil("IP_READY")
        end
        log.info("APP", "Network Ready")
        
        while true do
            -- AWAKE CYCLE BEGINS
            led.blink(200)
            
            -- Keep track of whether we sent a successful UDP message this cycle
            local data_sent = false
            
            -- Setup UDP Socket
            if config.SERVER_IP and config.SERVER_PORT then
                netc = socket.create(nil, "udp_gps")
                socket.config(netc, nil, true)
                
                -- Setup socket receive event (standard LuatOS socket.on)
                socket.on(netc, function(id, event)
                    if event == socket.EVENT_RX then
                        local succ, data = socket.rx(netc)
                        if succ and data and #data > 0 then
                            log.info("UDP_RX", data)
                            sys.publish("UDP_RECV", data)
                        end
                    end
                end)
                
                local is_connected = socket.connect(netc, config.SERVER_IP, config.SERVER_PORT)
                if is_connected then
                    log.info("APP", "UDP Connected")
                    
                    -- 1. Try to get MCU Data (Max 3 retries)
                    local mcu_alive = false
                    for retry = 1, 3 do
                        log.info("APP", "Requesting MCU Data (Retry " .. retry .. ")")
                        uart.send("GET:MCU\r\n")
                        
                        -- Wait for MCU Response up to 3 seconds
                        local result, line = sys.waitUntil("UART_RECV", 3000)
                        if result and line then
                            if string.sub(line, 1, 4) == "MCU:" then
                                mcu_alive = true
                                -- Inject Device ID and 4G Version
                                -- Original: MCU:STM32L431,V1.0.0,...
                                -- New: MCU:<IMEI>,<AirOS_V>,STM32L431,V1.0.0,...
                                local payload = "MCU:" .. imei .. ",AirOS_" .. config.VERSION .. "," .. string.sub(line, 5)
                                socket.tx(netc, payload)
                                log.info("UDP_TX", "Forwarded MCU Data: " .. payload)
                                data_sent = true
                                break
                            end
                        end
                    end
                    
                    if not mcu_alive then
                        -- MCU Dead Alert
                        log.error("APP", "MCU is DEAD (3 timeouts)")
                        local rsrp = -99
                        if mobile and mobile.rsrp then rsrp = mobile.rsrp() end
                        local dead_msg = "MODEM:" .. imei .. ",Air780E,V" .. config.VERSION .. "," .. rsrp .. ",4G,1"
                        socket.tx(netc, dead_msg)
                        log.info("UDP_TX", "MCU Dead Alert: " .. dead_msg)
                    end
                    
                    -- 2. Wait for Server Downlink Commands (Wait 5 seconds)
                    log.info("APP", "Waiting 5s for Server Commands...")
                    local end_time = os.time() + 5
                    while os.time() < end_time do
                        local result, udp_data = sys.waitUntil("UDP_RECV", 1000)
                        if result and udp_data then
                            -- Process Server Command
                            -- Extract command and remove DeviceID
                            local parts = split(udp_data, ",")
                            if #parts >= 2 then
                                local cmd = parts[1]
                                local target_id = parts[2]
                                
                                if target_id == imei then
                                    if cmd == "GET:GPS" then
                                        local res, lat, lng = lbs.getLocation()
                                        if res == 0 then
                                            socket.tx(netc, "GPS:" .. imei .. "," .. lat .. "," .. lng .. ",0,0,0")
                                        end
                                    elseif cmd == "GET:MODEM" then
                                        local rsrp = -99
                                        if mobile and mobile.rsrp then rsrp = mobile.rsrp() end
                                        local is_dead = mcu_alive and "0" or "1"
                                        socket.tx(netc, "MODEM:" .. imei .. ",Air780E,V" .. config.VERSION .. "," .. rsrp .. ",4G," .. is_dead)
                                    elseif string.find(cmd, "SET:") == 1 or string.find(cmd, "GET:") == 1 or string.find(cmd, "START:") == 1 then
                                        -- It's an MCU command. Strip target_id and forward to UART.
                                        -- Reconstruct string without target_id
                                        local mcu_cmd = cmd
                                        for i = 3, #parts do
                                            mcu_cmd = mcu_cmd .. "," .. parts[i]
                                        end
                                        mcu_cmd = mcu_cmd .. "\r\n"
                                        uart.send(mcu_cmd)
                                        log.info("UART_TX", "Forwarded to MCU: " .. mcu_cmd)

                                        -- Reply immediately to server so long MCU actions (e.g. methane measure)
                                        -- don't cause server-side timeout/retry.
                                        local cmd_no_crlf = string.gsub(mcu_cmd, "\r\n", "")
                                        local fast_ack = "ACK:" .. imei .. "," .. cmd_no_crlf .. ",1"
                                        socket.tx(netc, fast_ack)
                                        log.info("UDP_TX", "Immediate ACK: " .. fast_ack)
                                        
                                        -- START: commands may take >20s on MCU side. Don't block here.
                                        -- Final MCU data will be forwarded asynchronously when received.
                                        if string.find(cmd, "START:") ~= 1 then
                                            -- For non-START commands, still try to forward immediate MCU reply.
                                            local r, ack_line = sys.waitUntil("UART_RECV", 3000)
                                            if r and ack_line then
                                                -- Forward back to server, injecting ID
                                                -- e.g., MCU replies CONFIG:ALARM_TEMP,50 -> CONFIG:IMEI,ALARM_TEMP,50
                                                local colon_pos = string.find(ack_line, ":")
                                                if colon_pos then
                                                    local prefix = string.sub(ack_line, 1, colon_pos)
                                                    local suffix = string.sub(ack_line, colon_pos + 1)
                                                    local fwd_msg = prefix .. imei .. "," .. suffix
                                                    socket.tx(netc, fwd_msg)
                                                    log.info("UDP_TX", "Forwarded MCU Reply: " .. fwd_msg)
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        
                        -- Also check if MCU initiated an unsolicited message (e.g. Alarm report_type=1)
                        local ur, uline = sys.waitUntil("UART_RECV", 100)
                        if ur and uline then
                            if string.sub(uline, 1, 4) == "MCU:" then
                                local payload = "MCU:" .. imei .. ",AirOS_" .. config.VERSION .. "," .. string.sub(uline, 5)
                                socket.tx(netc, payload)
                                log.info("UDP_TX", "Forwarded Async MCU Data: " .. payload)
                            end
                        end
                    end
                    
                    socket.close(netc)
                    netc = nil
                else
                    log.error("APP", "UDP Connect Failed")
                end
            end
            
            -- AWAKE CYCLE ENDS -> SLEEP
            log.info("APP", "Sleep " .. (config.REPORT_INTERVAL/1000) .. "s")
            pm.power(pm.WORK_MODE, config.POWER_MODE)
            if config.POWER_MODE == 3 then
                pm.dtimerStart(0, config.REPORT_INTERVAL)
            end
            sys.wait(config.REPORT_INTERVAL)
        end
    end)
    
    -- Background task to catch and forward asynchronous MCU alarms when we are NOT in the active cycle
    -- above, but the network is somehow still up or just to maintain logic.
    sys.taskInit(function()
        while true do
            local result, line = sys.waitUntil("UART_RECV")
            if result and line then
                if netc == nil and (string.sub(line, 1, 4) == "MCU:" or string.find(line, ":")) then
                    -- If we receive an alarm while socket is closed, we should quickly open it and send!
                    log.info("APP", "Received ASYNC MCU Alert! Waking up socket.")
                    if config.SERVER_IP and config.SERVER_PORT then
                        local temp_netc = socket.create(nil, "udp_gps")
                        socket.config(temp_netc, nil, true)
                        if socket.connect(temp_netc, config.SERVER_IP, config.SERVER_PORT) then
                            local payload = line
                            if string.sub(line, 1, 4) == "MCU:" then
                                payload = "MCU:" .. imei .. ",AirOS_" .. config.VERSION .. "," .. string.sub(line, 5)
                            else
                                local colon_pos = string.find(line, ":")
                                if colon_pos then
                                    payload = string.sub(line, 1, colon_pos) .. imei .. "," .. string.sub(line, colon_pos + 1)
                                end
                            end
                            socket.tx(temp_netc, payload)
                            log.info("UDP_TX", "Sent Async Payload: " .. payload)
                            sys.wait(500)
                            socket.close(temp_netc)
                        end
                    end
                end
            end
        end
    end)
end

return app
