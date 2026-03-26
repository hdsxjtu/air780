local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")

local app = {}
local netc = nil
local next_msg_id = 9000
local pending_report_id = nil
local last_mcu_alive = true

local LONG_TO_SHORT = {
    REPORT_INTERVAL = "RPT_INT",
    ALARM_BARO_A_LOW = "PRA_L",
    ALARM_BARO_A_HIGH = "PRA_H",
    ALARM_BARO_B_LOW = "PRB_L",
    ALARM_BARO_B_HIGH = "PRB_H",
    ALARM_METHANE_LOW = "CH4_L",
    ALARM_METHANE_HIGH = "CH4_H",
    ALARM_TEMPERATURE_LOW = "TMP_L",
    ALARM_TEMPERATURE_HIGH = "TMP_H",
    ALARM_BATTERY_LOW = "BAT_L",
}

local SHORT_TO_LONG = {}
for long_name, short_name in pairs(LONG_TO_SHORT) do
    SHORT_TO_LONG[short_name] = long_name
end

local PARAM_ORDER = {
    "RPT_INT", "PRA_L", "PRA_H", "PRB_L", "PRB_H",
    "CH4_L", "CH4_H", "TMP_L", "TMP_H", "BAT_L",
}

-- Utility to get string parts separated by comma
local function split(str, reps)
    local resultStrList = {}
    string.gsub(str, '[^' .. reps .. ']+', function(w)
        table.insert(resultStrList, w)
    end)
    return resultStrList
end

local function split_n(str, sep, max_parts)
    local parts = {}
    local start_pos = 1
    local sep_len = string.len(sep)

    while #parts < max_parts - 1 do
        local pos = string.find(str, sep, start_pos, true)
        if not pos then
            break
        end
        table.insert(parts, string.sub(str, start_pos, pos - 1))
        start_pos = pos + sep_len
    end

    table.insert(parts, string.sub(str, start_pos))
    return parts
end

local function next_id()
    next_msg_id = next_msg_id + 1
    if next_msg_id > 9999 then
        next_msg_id = 9000
    end
    return tostring(next_msg_id)
end

local function parse_payload(payload)
    local result = {}
    for segment in string.gmatch(payload or "", "[^;]+") do
        local eq_pos = string.find(segment, "=", 1, true)
        if eq_pos then
            local key = string.sub(segment, 1, eq_pos - 1)
            local value = string.sub(segment, eq_pos + 1)
            result[key] = value
        end
    end
    return result
end

local function build_frame(header, mid, frame_type, cmd, payload)
    return table.concat({header, "1", mid, frame_type, cmd, payload or ""}, ",")
end

local function frame_tx(sock, header, mid, frame_type, cmd, payload)
    local message = build_frame(header, mid, frame_type, cmd, payload)
    socket.tx(sock, message)
    log.info("UDP_TX", message)
end

local function as_tx(sock, mid, frame_type, cmd, payload)
    frame_tx(sock, "AS", mid, frame_type, cmd, payload)
end

local function mr_payload(imei, mcu_line)
    return "did=" .. imei .. ";gv=4G" .. config.VERSION .. ";" .. mcu_line
end

local function rsp_payload(imei, suffix)
    return "did=" .. imei .. ";gv=4G" .. config.VERSION .. ";" .. suffix
end

local function modem_payload(imei, mcu_alive)
    local rsrp = -99
    if mobile and mobile.rsrp then
        rsrp = mobile.rsrp()
    end
    local mdead = mcu_alive and "0" or "1"
    return "did=" .. imei .. ";gv=4G" .. config.VERSION .. ";mod=Air780E;rsrp=" .. tostring(rsrp) .. ";net=4G;mdead=" .. mdead
end

local function parse_sa_frame(data)
    -- New protocol: SA,<ver>,<mid>,<type>,<cmd>,<payload>
    local p6 = split_n(data, ",", 6)
    if #p6 == 6 and p6[1] == "SA" then
        return {
            ver = p6[2],
            id = p6[3],
            type = p6[4],
            cmd = p6[5],
            payload = p6[6],
        }
    end

    -- Compatibility: SA,<ver>,<mid>,<src>,<dst>,<type>,<cmd>,<payload>
    local p8 = split_n(data, ",", 8)
    if #p8 == 8 and p8[1] == "SA" then
        return {
            ver = p8[2],
            id = p8[3],
            type = p8[6],
            cmd = p8[7],
            payload = p8[8],
        }
    end

    return nil
end

local function wait_for_uart_line(timeout_ms, matcher)
    local elapsed = 0
    while elapsed < timeout_ms do
        local wait_ms = math.min(500, timeout_ms - elapsed)
        local ok, line = sys.waitUntil("UART_RECV", wait_ms)
        elapsed = elapsed + wait_ms
        if ok and line and matcher(line) then
            return line
        end
    end
    return nil
end

local function wait_for_ack(timeout_ms)
    return wait_for_uart_line(timeout_ms, function(line)
        return line == "ACK:0"
    end)
end

local function collect_config_params(timeout_ms)
    local values = {}
    local elapsed = 0

    while elapsed < timeout_ms do
        local wait_ms = math.min(500, timeout_ms - elapsed)
        local ok, line = sys.waitUntil("UART_RECV", wait_ms)
        elapsed = elapsed + wait_ms

        if ok and line then
            if string.sub(line, 1, 7) == "CONFIG:" then
                local body = string.sub(line, 8)
                if body == "END" then
                    break
                end

                local kv = split(body, ",")
                local long_name = kv[1]
                local short_name = LONG_TO_SHORT[long_name]
                if short_name and kv[2] then
                    values[short_name] = kv[2]
                end
            elseif line == "ACK:0" then
                -- Ignore ack lines during config collection.
            elseif string.sub(line, 1, 4) == "ERR:" then
                return nil
            end
        end
    end

    local result = {}
    for _, key in ipairs(PARAM_ORDER) do
        if values[key] then
            table.insert(result, key .. "=" .. values[key])
        end
    end

    if #result == 0 then
        return nil
    end

    return table.concat(result, ",")
end

local function find_set_param(payload_map)
    for key, value in pairs(payload_map) do
        if key ~= "did" and key ~= "gv" and key ~= "ack" and key ~= "params" then
            return key, value
        end
    end
    return nil, nil
end

local function send_measure_event(sock, imei, line)
    local report_id = pending_report_id or next_id()
    pending_report_id = nil
    as_tx(sock, report_id, "EVT", "MR", mr_payload(imei, line))
end

local function send_measure_event_with_temp_socket(imei, line)
    if not (config.SERVER_IP and config.SERVER_PORT) then
        return
    end

    local temp_netc = socket.create(nil, "udp_gps")
    socket.config(temp_netc, nil, true)
    if socket.connect(temp_netc, config.SERVER_IP, config.SERVER_PORT) then
        send_measure_event(temp_netc, imei, line)
        sys.wait(500)
        socket.close(temp_netc)
    end
end

local function handle_legacy_command(sock, imei, data, mcu_alive)
    local parts = split(data, ",")
    if #parts < 2 then
        return false
    end

    local cmd = parts[1]
    local target_id = parts[2]
    if target_id ~= imei then
        return true
    end

    if cmd == "GET:GPS" then
        local res, lat, lng = lbs.getLocation()
        if res == 0 then
            socket.tx(sock, "GPS:" .. imei .. "," .. lat .. "," .. lng .. ",0,0,0")
        end
        return true
    end

    if cmd == "GET:MODEM" then
        local rsrp = -99
        if mobile and mobile.rsrp then
            rsrp = mobile.rsrp()
        end
        local is_dead = mcu_alive and "0" or "1"
        socket.tx(sock, "MODEM:" .. imei .. ",Air780E,V" .. config.VERSION .. "," .. rsrp .. ",4G," .. is_dead)
        return true
    end

    return false
end

local function handle_sa_command(sock, imei, frame)
    if frame.type ~= "CMD" then
        return
    end

    local payload_map = parse_payload(frame.payload)
    if payload_map.did and payload_map.did ~= imei then
        return
    end

    if frame.cmd == "CG" then
        uart.send("GET:CONFIG\r\n")
        local params = collect_config_params(5000)
        if params then
            as_tx(sock, frame.id, "RSP", "CG", rsp_payload(imei, "params=" .. params))
        end
        return
    end

    if frame.cmd == "CS" then
        local param_key, param_value = find_set_param(payload_map)
        if not param_key or not param_value then
            return
        end

        local long_name = SHORT_TO_LONG[param_key] or param_key
        uart.send("SET:CONFIG," .. long_name .. "," .. param_value .. "\r\n")
        local ack_line = wait_for_ack(3000)
        local ack_value = ack_line and "0" or "1"
        as_tx(sock, frame.id, "RSP", "CS", rsp_payload(imei, "ack=" .. ack_value))
        return
    end

    if frame.cmd == "MS" or frame.cmd == "MG" then
        pending_report_id = frame.id
        as_tx(sock, frame.id, "ACK", frame.cmd, rsp_payload(imei, "ack=1"))

        if frame.cmd == "MS" then
            uart.send("START:MEASURE\r\n")
        else
            uart.send("GET:MCU\r\n")
        end

        wait_for_ack(1000)
        return
    end

    if frame.cmd == "MD" then
        as_tx(sock, frame.id, "RSP", "MD", modem_payload(imei, last_mcu_alive))
        return
    end
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
                    
                    -- 1. Trigger periodic MCU measurement.
                    local mcu_alive = false
                    for retry = 1, 3 do
                        local cycle_id = next_id()
                        pending_report_id = cycle_id
                        log.info("APP", "Requesting MCU Data (Retry " .. retry .. ")")
                        uart.send("GET:MCU\r\n")

                        if wait_for_ack(2000) then
                            mcu_alive = true
                            break
                        else
                            pending_report_id = nil
                        end
                    end
                    
                    if not mcu_alive then
                        -- MCU Dead Alert
                        log.error("APP", "MCU is DEAD (3 timeouts)")
                        local evt_id = next_id()
                        as_tx(netc, evt_id, "EVT", "MD", modem_payload(imei, false))
                        log.info("UDP_TX", "MCU Dead Alert via AS/MD")
                    end

                    last_mcu_alive = mcu_alive
                    
                    -- 2. Wait for Server Downlink Commands (Wait 5 seconds)
                    log.info("APP", "Waiting 5s for Server Commands...")
                    local end_time = os.time() + 5
                    while os.time() < end_time do
                        local result, udp_data = sys.waitUntil("UDP_RECV", 1000)
                        if result and udp_data then
                            if not handle_legacy_command(netc, imei, udp_data, mcu_alive) then
                                local frame = parse_sa_frame(udp_data)
                                if frame then
                                    handle_sa_command(netc, imei, frame)
                                end
                            end
                        end
                        
                        -- Also check if MCU initiated an unsolicited message.
                        local ur, uline = sys.waitUntil("UART_RECV", 100)
                        if ur and uline then
                            if string.sub(uline, 1, 4) == "MCU:" then
                                last_mcu_alive = true
                                send_measure_event(netc, imei, uline)
                                data_sent = true
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
                if netc == nil and string.sub(line, 1, 4) == "MCU:" then
                    last_mcu_alive = true
                    -- If we receive an async measurement while socket is closed,
                    -- reopen a temporary socket and report it with AS protocol.
                    log.info("APP", "Received ASYNC MCU Alert! Waking up socket.")
                    send_measure_event_with_temp_socket(imei, line)
                end
            end
        end
    end)
end

return app
