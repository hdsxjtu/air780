local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")
local proto = require("usr_protocol")
local mobile = _G.mobile

-- ========================================================================
-- 核心架构说明 (Architecture Overview):
-- 本文件仅负责：1. 业务逻辑分发 (handle_sa_command)  2. 四大任务调度
-- 底层协议封装、串口锁、字符串解析等已移至 usr_protocol.lua
-- ========================================================================

local app = {}
local netc = nil            -- 全局网络连接句柄 (UDP Socket)
local last_mcu_alive = true -- 记录单片机是否正常（心跳用）
local last_lat, last_lng = nil, nil -- GPS/LBS 坐标缓存
local mcu_is_busy = false    -- 业务锁：记录当前模组是否正占用串口与单片机交互
local boot_synced = false    -- 握手标志：开机由于系统响应解锁
local last_mcu_ready = false -- 记录开机握手是否真正成功

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
    
    -- 1. 模组忙阻判定 (同步未完成或正在进行业务)
    local current_devid = "DEV" .. (config.ADDR or "0")
    if not boot_synced or mcu_is_busy then
        log.warn("APP", "System Startup/Busy, rejecting SA command: " .. (frame.id or "N/A"))
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. proto.ACK_BUSY)
        return
    end

    -- 2. 严格 ID 校验 (基准：config.ADDR)
    local current_devid = "DEV" .. (config.ADDR or "0")
    if payload_map.devID and payload_map.devID ~= current_devid then
        log.error("APP", "ID Mismatch: expected " .. current_devid .. " but got " .. payload_map.devID)
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";ack=" .. proto.ACK_ID_MISMATCH) 
        return 
    end

    -- 3. 针对 CG/CS 指令的处理
    mcu_is_busy = true
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

        local resp_line = proto.request_mcu(frame.id, frame.cmd, frame.payload, 1500, 3)
        
        if resp_line then
            local p6 = proto.split_n(resp_line, ",", 6)
            local mcu_payload = p6[6] or ""
            last_mcu_alive = true
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, mcu_payload)
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end

    -- 3. 针对 MS/MG 指令的处理 (二阶段 ACK)
    elseif frame.cmd == "MS" or frame.cmd == "MG" then
        local first_resp = proto.request_mcu(frame.id, frame.cmd, "devID=" .. current_devid, 1500, 3)
        
        if first_resp then
            local p6 = proto.split_n(first_resp, ",", 6)
            local mcu_type = p6[4] or "RSP"
            local mcu_payload = proto.parse_payload(p6[6])
            local mcu_ack = mcu_payload.ack or "0"
            last_mcu_alive = true
            
            proto.as_tx(sock, frame.id, mcu_type, frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. mcu_ack)
            
            if mcu_type == "ACK" and mcu_ack == proto.ACK_SUCCESS then
                sys.publish("PENDING_SERVER_MID", frame.id)
            end
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. current_devid .. ";gv=4G" .. config.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end
    elseif frame.cmd == "MD" then
        update_gps_cache() -- 仅在查状态时触发静默刷新
        proto.as_tx(sock, frame.id, "RSP", "MD", proto.modem_payload(current_devid, last_mcu_alive, last_lat, last_lng))
    end
    mcu_is_busy = false
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
        
        local rxbuff = zbuff.create(1024)
        netc = socket.create(nil, function(sc, event)
            log.info("udp_event", string.format("%08X", event))
            
            -- 注意：demo 中使用的是 socket.EVENT (或者是具体的 RX 常量)
            -- 只要有事件进来，由于是无连接的 UDP，大概率是收到了数据
            if event == socket.EVENT or event == socket.EVENT_RX or event == socket.EVENT_RECV then
                -- 在调用底层 rx 之前，强制将游标复位到 0！
                -- 因为 clear() 在某些旧固件中仅仅清空内容但不移动游标，导致第二包追加到了第一包后面
                rxbuff:seek(0, 0) 
                
                local ok, len = socket.rx(sc, rxbuff)
                if ok and len and len > 0 then
                    local data = rxbuff:toStr(0, len)
                    log.info("UDP_RX", "Len: " .. tostring(len) .. " Data: " .. tostring(data))
                    
                    if type(data) == "string" and #data > 0 then
                        local frame = proto.parse_sa_frame(data)
                        if frame then 
                            sys.publish("SA_FRAME_RX", frame) -- 解耦：推送到独立协程处理
                        else
                            log.error("UDP_RX", "Parse failed. Not a valid SA frame.")
                        end
                    end
                else
                    log.warn("UDP_RX", "socket.rx returned failure")
                end
            elseif event == socket.EVENT_CLOSE then
                log.error("UDP_EVENT", "Socket closed by remote or network!")
                sys.publish("SOCKET_CLOSED")
            end
        end)
        
        socket.config(netc, nil, true)

        if socket.connect(netc, config.SERVER_IP, config.SERVER_PORT) then
            -- 成功连接服务器
            sys.publish("SOCKET_CONNECTED")
            sys.waitUntil("SOCKET_CLOSED", 86400000)
        else
            sys.wait(5000)
        end
        if netc then socket.close(netc) netc = nil end
    end
end

-- [[ 任务 2：定时上报任务 ]]
local function timer_task()
    -- 第一阶段：开机强制同步 (100% 解决地址/间隔未知问题)
    sys.waitUntil("SOCKET_CONNECTED")
    log.info("APP", "Network Ready. Starting Initial MCU Handshake...")
    
    mcu_is_busy = true
    for i = 1, 20 do
        log.info("APP", "Syncing Config Attempt " .. i .. "/20")
        local current_devid = "DEV" .. (config.ADDR or "0")
        local sync_line = proto.request_mcu(proto.next_id(), "CG", "devID=" .. current_devid, 1000, 1)
        
        if sync_line then
            local p6 = proto.split_n(sync_line, ",", 6)
            local mcu_map = proto.parse_payload(p6[6])
            if mcu_map.ADDR then config.ADDR = tonumber(mcu_map.ADDR) end
            if mcu_map.RPT_INT then config.REPORT_INTERVAL = tonumber(mcu_map.RPT_INT) * 60 * 1000 end
            log.info("APP", "Initial Sync SUCCESS. Correct ADDR=" .. config.ADDR)
            last_mcu_ready = true
            break
        end
        sys.wait(1000)
    end
    mcu_is_busy = false
    boot_synced = true            -- 无论是否成功同步，都解锁系统响应，防止模组死等
    sys.publish("BOOT_SYNC_DONE") -- 通知心跳任务可以开始了

    if not last_mcu_ready then
        log.error("APP", "Initial Sync FAILED after 20 tries - Using default config")
        -- 这里不再重复发送离线状态，因为紧接着第二阶段就会跑一次带 LBS 定位的完整检测，
        -- 如果单片机依然离线，下面会把带着经纬度的完美离线状态打包发过去。
    end

    -- 第二阶段：正常周期循环 (开机立即执行一次 MG)
    while true do
        log.info("APP", "--- Starting Reporting Cycle ---")
        local current_devid = "DEV" .. (config.ADDR or "0")

        -- 2. 同步定位 (解开忙锁，避免基站定位的 10~30 秒内拒接服务器指令)
        local res, lat, lng = lbs.getLocation()
        if res == 0 then last_lat, last_lng = lat, lng end

        -- 1. 等待串口业务空闲并上锁
        local wait_count = 0
        while mcu_is_busy and wait_count < 20 do sys.wait(500) wait_count = wait_count + 1 end
        mcu_is_busy = true

        -- 3. 触发采样 (MG)
        log.info("APP", "Triggering MCU Measurement")
        local mg_resp = proto.request_mcu(proto.next_id(), "MG", "devID=" .. current_devid, 1500, 3)
        last_mcu_alive = (mg_resp ~= nil)

        if not last_mcu_alive then
            log.error("APP", "MCU Offline confirmed")
            proto.as_tx(netc, proto.next_id(), "EVT", "MD", proto.modem_payload(current_devid, false, last_lat, last_lng))
        end

        mcu_is_busy = false
        
        -- 4. 周期休眠
        log.info("APP", "Cycle finished. Sleeping for " .. (config.REPORT_INTERVAL / 60000) .. " min")
        sys.wait(config.REPORT_INTERVAL)
    end
end

-- [[ 任务 3：链路维持心跳 ]]
local function heartbeat_task()
    -- 心跳也要等待首次握手结果，否则发出的 devID 可能是错的
    sys.waitUntil("BOOT_SYNC_DONE")
    
    while true do
        sys.wait(config.HEARTBEAT_INTERVAL)
        if netc then
            local current_devid = "DEV" .. (config.ADDR or "0")
            -- 回归标准协议心跳（不带经纬度以省电），确保在工具中“看得见”
            log.info("TRACE", "---- SECRECY HEARTBEAT SENDING NOW ----")
            proto.as_tx(netc, proto.next_id(), "EVT", "MD", proto.modem_payload(current_devid, last_mcu_alive, nil, nil))
        end
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
                        
                        -- ACK 直接调用协议统一下发 (内置 0x00 唤醒及保护)
                        local real_devid = "DEV" .. (config.ADDR or "0")
                        proto.am_tx(mcu_mid, "ACK", "MR", "devID=" .. real_devid .. ";ack=" .. proto.ACK_SUCCESS)
                    end
                end
            end
        end
    end
end

-- [[ 任务 5：下发指令处理任务 (协程解耦) ]]
local function sa_command_task()
    while true do
        local result, frame = sys.waitUntil("SA_FRAME_RX")
        if result and frame and netc then
            handle_sa_command(netc, frame)
        end
    end
end

function app.start()
    led.init(); uart.init()
    if config.POWER_MODE > 0 then
        pm.request(pm.LIGHT) -- 恢复为您最熟悉的 PM 库底座控制
    end
    uart.onReceive(function(line) sys.publish("UART_RECV", line) end)
    sys.taskInit(network_task); sys.taskInit(heartbeat_task)
    sys.taskInit(timer_task); sys.taskInit(uart_task); sys.taskInit(sa_command_task)
    sys.taskInit(function() while true do led.blink(100); sys.wait(10000) end end)
end

return app
