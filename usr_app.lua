local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")
local proto = require("usr_protocol")

-- ========================================================================
-- 核心架构说明 (Architecture Overview):
-- 本文件仅负责：1. 业务逻辑分发 (handle_sa_command)  2. 四大任务调度
-- 底层协议封装、串口锁、字符串解析等已移至 usr_protocol.lua
-- ========================================================================

local app = {}
local netc = nil            -- 全局网络连接句柄 (UDP Socket)
local last_mcu_alive = true -- 记录单片机是否正常（心跳用）
local last_lat, last_lng = nil, nil -- GPS/LBS 坐标缓存

-- [[ 内部逻辑：静默刷新 GPS 缓存 ]]
local function update_gps_cache()
    sys.taskInit(function()
        local res, lat, lng = lbs.getLocation()
        if res == 0 then
            last_lat, last_lng = lat, lng
            log.info("APP", "GPS Cache Updated: " .. lat .. "," .. lng)
        end
    end)
end

-- [[ 业务中枢：处理服务器指令 (SA 帧) ]]
local function handle_sa_command(sock, frame)
    if frame.type ~= "CMD" then return end
    local payload_map = proto.parse_payload(frame.payload)
    
    -- 1. 严格 ID 校验 (基准：config.ADDR)
    local current_devid = "DEV" .. (config.ADDR or "0")
    if payload_map.devID and payload_map.devID ~= current_devid then
        log.error("APP", "ID Mismatch: expected " .. current_devid .. " but got " .. payload_map.devID)
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";ack=" .. proto.ACK_ID_MISMATCH) 
        return 
    end

    -- 2. 针对 CG/CS 指令的处理
    if frame.cmd == "CG" or frame.cmd == "CS" then
        if frame.cmd == "CS" then
            if payload_map.RPT_INT then
                config.REPORT_INTERVAL = tonumber(payload_map.RPT_INT) * 60 * 1000
                log.info("APP", "Local REPORT_INTERVAL updated to " .. config.REPORT_INTERVAL .. "ms")
            end
            if payload_map.ADDR then
                config.ADDR = tonumber(payload_map.ADDR)
                log.info("APP", "Local ADDR updated to " .. config.ADDR)
                -- 地址更新后，后续回复将自动使用新 ID
            end
        end

        proto.am_tx(frame.id, "CMD", frame.cmd, frame.payload)
        
        local ack_line = proto.wait_for_uart_line(3000, function(l)
            return string.find(l, "MA,1," .. frame.id) and string.find(l, ",RSP," .. frame.cmd)
        end)
        
        if ack_line then
            local p6 = proto.split_n(ack_line, ",", 6)
            local mcu_payload = p6[6] or ""
            if mcu_map.ADDR then config.ADDR = tonumber(mcu_map.ADDR) end
            
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, mcu_payload)
        else
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end

    -- 3. 针对 MS/MG 指令的处理 (二阶段 ACK)
    elseif frame.cmd == "MS" or frame.cmd == "MG" then
        proto.am_tx(frame.id, "CMD", frame.cmd, "devID=" .. current_devid)
        
        local first_resp = proto.wait_for_uart_line(3000, function(l)
            return string.find(l, "MA,1," .. frame.id) and (string.find(l, ",ACK," .. frame.cmd) or string.find(l, ",RSP," .. frame.cmd))
        end)
        
        if first_resp then
            local p6 = proto.split_n(first_resp, ",", 6)
            local mcu_type = p6[4] or "RSP"
            local mcu_payload = proto.parse_payload(p6[6])
            local mcu_ack = mcu_payload.ack or "0"
            
            proto.as_tx(sock, frame.id, mcu_type, frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. mcu_ack)
            
            if mcu_type == "ACK" and mcu_ack == proto.ACK_SUCCESS then
                sys.publish("PENDING_SERVER_MID", frame.id)
            end
        else
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end
    elseif frame.cmd == "MD" then
        update_gps_cache() -- 仅在查状态时触发静默刷新
        proto.as_tx(sock, frame.id, "RSP", "MD", proto.modem_payload(current_devid, last_mcu_alive, last_lat, last_lng))
    end
end

-- ========================================================================
-- 四大并行独立任务
-- ========================================================================

-- [[ 任务 1：核心网络任务 ]]
local function network_task()
    while true do
        if socket.localIP() == "0.0.0.0" or socket.localIP() == nil then
            sys.waitUntil("IP_READY")
        end
        log.info("APP", "Network Ready, connecting to " .. config.SERVER_IP)
        netc = socket.create(nil, "udp_app")
        socket.config(netc, nil, true)

        if socket.on then
            socket.on(netc, function(id, event)
                if event == socket.EVENT_RX then
                    local succ, data = socket.rx(netc)
                    if succ and type(data) == "string" and #data > 0 then
                        local frame = proto.parse_sa_frame(data)
                        if frame then handle_sa_command(netc, frame) end
                    end
                elseif event == socket.EVENT_CLOSE then
                    sys.publish("SOCKET_CLOSED")
                end
            end)
            
            sys.taskInit(function()
                sys.wait(2000)
                local current_devid = "DEV" .. (config.ADDR or "0")
                proto.am_tx(proto.next_id(), "CMD", "CG", "devID=" .. current_devid)
            end)
        end

        if socket.connect(netc, config.SERVER_IP, config.SERVER_PORT) then
            pm.power(pm.WORK_MODE, config.POWER_MODE)
            sys.waitUntil("SOCKET_CLOSED", 86400000)
        else
            sys.wait(5000)
        end
        if netc then socket.close(netc) netc = nil end
    end
end

-- [[ 任务 2：定时上报任务 ]]
local function timer_task()
    while true do
        sys.wait(config.REPORT_INTERVAL)
        log.info("APP", "--- Starting Periodic Reporting Cycle ---")
        
        local current_devid = "DEV" .. (config.ADDR or "0")

        -- 1. 同步参数 (CG)
        log.info("APP", "Step 1: Syncing Config from MCU")
        proto.am_tx(proto.next_id(), "CMD", "CG", "devID=" .. current_devid)
        local sync_line = proto.wait_for_uart_line(3000, function(l)
             return string.find(l, "MA,1") and string.find(l, ",RSP,CG")
        end)
        if sync_line then
            local p6 = proto.split_n(sync_line, ",", 6)
            local mcu_map = proto.parse_payload(p6[6])
            if mcu_map.ADDR then config.ADDR = tonumber(mcu_map.ADDR) end
            if mcu_map.RPT_INT then config.REPORT_INTERVAL = tonumber(mcu_map.RPT_INT) * 60 * 1000 end
            log.info("APP", "Sync Success. ADDR=" .. config.ADDR)
            last_mcu_alive = true
        else
            log.warn("APP", "Sync Timeout")
        end

        -- 2. 采集定位 (GPS/LBS)
        log.info("APP", "Step 2: Collecting LBS Location")
        local res, lat, lng = lbs.getLocation()
        if res == 0 then
            log.info("APP", "LBS Fix: " .. lat .. "," .. lng)
            last_lat, last_lng = lat, lng -- 仅更新缓存，供 MD 查询使用
        else
            log.warn("APP", "LBS Fail: " .. res)
        end

        -- 3. 触发采样 (MG)
        log.info("APP", "Step 3: Triggering MCU Measurement")
        local mcu_responded = false
        for retry = 1, 3 do
            proto.am_tx(proto.next_id(), "CMD", "MG", "devID=" .. current_devid)
            local end_time = mcu.ticks() + 2000
            while mcu.ticks() < end_time do
                local ok, line = sys.waitUntil("UART_RECV", 500)
                if ok and line then
                    local p6 = proto.split_n(line, ",", 6)
                    -- 匹配 MA,1,MID,ACK,MG 或 MA,1,MID,RSP,MG (如果是立刻回复结果的话)
                    if #p6 >= 5 and p6[1] == "MA" and (p6[4] == "ACK" or p6[4] == "RSP") and p6[5] == "MG" then
                        mcu_responded = true; break
                    elseif string.find(line, "^MA,1,") then
                        -- 其他非目标报文重新分发
                        sys.publish("UART_RECV", line)
                    end
                end
            end
            if mcu_responded then break end
            log.warn("APP", "MCU MG Retry " .. retry)
        end

        if not mcu_responded then
            log.error("APP", "MCU Offline confirmed after 3 retries")
            last_mcu_alive = false
            -- 主动离线告警：带上位置信息
            proto.as_tx(netc, proto.next_id(), "EVT", "MD", proto.modem_payload(current_devid, false, last_lat, last_lng))
        else
            last_mcu_alive = true
        end
    end
end

-- [[ 任务 3：链路维持心跳 ]]
local function heartbeat_task()
    while true do
        sys.wait(config.HEARTBEAT_INTERVAL)
        if netc then
            local current_devid = "DEV" .. (config.ADDR or "0")
            proto.as_tx(netc, proto.next_id(), "RSP", "MD", proto.modem_payload(current_devid, last_mcu_alive))
        end
        pm.request(pm.LIGHT_SLEEP)
    end
end

-- [[ 任务 4：串口监听任务 ]]
local function uart_task()
    while true do
        local result, line = sys.waitUntil("UART_RECV", 30000)
        if result and line then
            if string.find(line, "^MA,1,") then
                local p6 = proto.split_n(line, ",", 6)
                if #p6 == 6 then
                    local mcu_mid, mcu_type, mcu_cmd, mcu_payload = p6[3], p6[4], p6[5], p6[6]
                    last_mcu_alive = true
                    if mcu_cmd == "MR" then
                        local updated_payload = string.gsub(mcu_payload, "(devID=[^;]+;)", "%1gv=4G" .. config.VERSION .. ";")
                        proto.as_tx(netc, mcu_mid, mcu_type, "MR", updated_payload)
                        
                        -- ACK 受保护发送
                        local current_devid = "DEV" .. (config.ADDR or "0")
                        while proto.is_uart_locked() do sys.waitUntil("UART_UNLOCK", 100) end
                        proto.set_uart_locked(true)
                        uart.send("AM,1," .. mcu_mid .. ",ACK,MR,devID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS .. "\r\n")
                        proto.set_uart_locked(false)
                    end
                end
            end
        end
    end
end

function app.start()
    led.init(); uart.init()
    uart.onReceive(function(line) sys.publish("UART_RECV", line) end)
    sys.taskInit(network_task); sys.taskInit(heartbeat_task)
    sys.taskInit(timer_task); sys.taskInit(uart_task)
    sys.taskInit(function() while true do led.blink(100); sys.wait(10000) end end)
end

return app
