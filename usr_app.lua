local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")
local proto = require("usr_protocol")
local ota = require("usr_ota")
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

-- [[ 新增：指令队列机制，防止丢包 ]]
local sa_cmd_queue = {}
local last_processed_mid = ""
local last_ota_mid = nil -- 新增：用于记录下发升级指令的 MID，以便异步回调时回传结果
local last_ota_cmd = nil -- 新增：记录升级指令类型 (FD/FU/OU)，确保回调使用正确的命令名
local last_mcu_fw_crc = nil -- 新增：用于缓存已下载固件的 CRC，以便刷写时免除重复计算

-- [[ 新增：获取唯一设备 ID (优先使用 config.DEVICE_ID，最后使用 ADDR) ]]
local function get_device_id()
    if config.DEVICE_ID then
        return config.DEVICE_ID
    end
    return tostring(config.ADDR or "1")
end

-- [[ 内部逻辑：静默刷新 GPS 缓存 ]]
local function update_gps_cache()
    if last_lat and last_lng then
        return -- 已经有GPS信息，不再定位
    end
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
    
    local current_devid = get_device_id()

    -- 0. 重复指令判定
    if frame.id == last_processed_mid then
        log.warn("APP", "Duplicate MID detected, skipping: " .. frame.id)
        return
    end
    last_processed_mid = frame.id

    -- 1. 严格 ID 校验和 IMEI 校验 (强制要求指令必须携带 IMEI 且完全匹配，防重名风险)
    local local_imei = mobile and mobile.imei and mobile.imei() or ""
    if not payload_map.ID or payload_map.ID ~= current_devid or not payload_map.imei or payload_map.imei ~= local_imei then
        log.error("APP", "ID/IMEI Mismatch: expected " .. current_devid .. "/" .. local_imei .. " but got " .. tostring(payload_map.ID) .. "/" .. tostring(payload_map.imei))
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_ID_MISMATCH) 
        return 
    end
    
    -- 2. 模组忙阻判定
    if not boot_synced or mcu_is_busy then
        log.warn("APP", "System Startup/Busy, rejecting SA command: " .. (frame.id or "N/A"))
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_BUSY)
        return
    end

    -- 3. 针对需要单片机参与的命令 (CG/CS/MS/MG/RESET/BOOT)：加忙锁
    if frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "MS" or frame.cmd == "MG" or frame.cmd == "RESET" or frame.cmd == "BOOT" then
        mcu_is_busy = true
    end

    if frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "RESET" or frame.cmd == "BOOT" then
        local retry_count = (frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "RESET" or frame.cmd == "BOOT") and 1 or 3
        local resp_line = proto.request_mcu(frame.id, frame.cmd, frame.payload, 1500, retry_count)
        
        if resp_line then
            local p6 = proto.split_n(resp_line, ",", 6)
            local mcu_payload = p6[6] or ""
            last_mcu_alive = true
            
            -- 如果是 CS 指令且执行成功，此时将 MCU 确领并返回的新参数同步到 4G 模组本地并保存
            if frame.cmd == "CS" then
                local mcu_map = proto.parse_payload(mcu_payload)
                local modified = false
                if mcu_map.RPT then
                    config.REPORT_INTERVAL = tonumber(mcu_map.RPT) * 60 * 1000
                    log.info("APP", "CS Success: Local REPORT_INTERVAL updated to " .. config.REPORT_INTERVAL .. "ms")
                    modified = true
                end
                if mcu_map.ADDR then
                    config.ADDR = tonumber(mcu_map.ADDR)
                    log.info("APP", "CS Success: Local ADDR updated to " .. config.ADDR)
                    modified = true
                elseif mcu_map.ID then
                    local grabbed_addr = string.match(mcu_map.ID, "(%d+)")
                    if grabbed_addr then
                        config.ADDR = tonumber(grabbed_addr)
                        log.info("APP", "CS Success: Local ADDR (from ID) updated to " .. config.ADDR)
                        modified = true
                    end
                end
                if modified then
                    config.save()
                end
            end

            local final_payload = mcu_payload
            if frame.cmd == "CG" or frame.cmd == "CS" then
                final_payload = string.gsub(mcu_payload, "(ID=[^;]+;)", "%1gv=4G" .. _G.VERSION .. ";")
            end
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, final_payload)
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end

    -- 针对 MS/MG 指令的处理 (二阶段 ACK)
    elseif frame.cmd == "MS" or frame.cmd == "MG" then
        local first_resp = proto.request_mcu(frame.id, frame.cmd, "ID=" .. current_devid, 1500, 3)
        
        if first_resp then
            local p6 = proto.split_n(first_resp, ",", 6)
            local mcu_type = p6[4] or "RSP"
            local mcu_payload = proto.parse_payload(p6[6])
            local mcu_ack = mcu_payload.ack or "0"
            last_mcu_alive = true
            
            proto.as_tx(sock, frame.id, mcu_type, frame.cmd, "ID=" .. current_devid .. ";gv=4G" .. _G.VERSION .. ";ack=" .. mcu_ack)
            
            if mcu_type == "ACK" and mcu_ack == proto.ACK_SUCCESS then
                sys.publish("PENDING_SERVER_MID", frame.id)
            end
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_OFFLINE)
        end
    elseif frame.cmd == "MD" then
        update_gps_cache() 
        proto.as_tx(sock, frame.id, "RSP", "MD", proto.modem_payload(current_devid, last_mcu_alive, last_lat, last_lng))
    -- ----------------------------------------------------------------
    -- FD: Firmware Download — 强制下载固件到4G模组本地，不碰单片机
    -- 服务端发: SA,1,XXXX,CMD,FD,ID=1;url=http://xxx/fw.bin
    -- ----------------------------------------------------------------
    elseif frame.cmd == "FD" then
        if payload_map.url then
            log.info("APP", "[FD] URL: " .. payload_map.url .. " size=" .. tostring(payload_map.size) .. " crc=" .. tostring(payload_map.crc))
            proto.as_tx(sock, frame.id, "RSP", "FD",
                "ID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS .. ";status=downloading")
            sys.taskInit(function()
                last_ota_mid = frame.id
                last_ota_cmd = "FD"
                sys.wait(500)
                local ok = ota.download(payload_map.url, tonumber(payload_map.size), tonumber(payload_map.crc))
                -- 结果由 FOTA_STATE 事件回调上报，此处无需重复
            end)
        else
            log.warn("APP", "[FD] Missing url in payload")
            proto.as_tx(sock, frame.id, "RSP", "FD",
                "ID=" .. current_devid .. ";ack=" .. proto.ACK_ERROR .. ";status=missing_url")
        end

    -- ----------------------------------------------------------------
    -- FU: Firmware Upgrade — 自动让MCU进入BOOT模式后刷写
    -- 自动发送 BOOT → MCU复位 → Bootloader 救砖模式 → OU/OD/OE
    -- 服务端发: SA,1,XXXX,CMD,FU,ID=1
    -- ----------------------------------------------------------------
    elseif frame.cmd == "FU" then
        log.info("APP", "[FU] Starting MCU flash from local firmware")
        proto.as_tx(sock, frame.id, "RSP", "FU",
            "ID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS .. ";status=flashing")
        sys.taskInit(function()
            last_ota_mid = frame.id
            last_ota_cmd = "FU"
            sys.wait(500)
            local ok = ota.flash(last_mcu_fw_crc)
            -- 结果由 FOTA_STATE 事件回调上报
        end)

    -- ----------------------------------------------------------------
    -- OU: 4G模组自身FOTA（保留旧功能，target=4g）
    -- ----------------------------------------------------------------
    elseif frame.cmd == "OU" then
        if payload_map.url then
            log.info("APP", "[OU] 4G FOTA URL: " .. payload_map.url)
            proto.as_tx(sock, frame.id, "RSP", "OU",
                "ID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS .. ";status=downloading")
            sys.taskInit(function()
                last_ota_mid = frame.id
                last_ota_cmd = "OU"
                sys.wait(500)
                ota.start(payload_map.url)
            end)
        else
            log.warn("APP", "[OU] Missing url in payload")
            proto.as_tx(sock, frame.id, "RSP", "OU",
                "ID=" .. current_devid .. ";ack=" .. proto.ACK_ERROR)
        end
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
                -- 必须循环读取，直到读空，防止 UDP 缓冲区堆积导致丢包 (关键加固)
                while true do
                    rxbuff:seek(0, 0)
                    local ok, len = socket.rx(sc, rxbuff)
                    if ok and len and len > 0 then
                        local data = rxbuff:toStr(0, len)
                        log.info("UDP_RX", "Drained Packet: " .. data)
                        local frame = proto.parse_sa_frame(data)
                        if frame then
                            table.insert(sa_cmd_queue, frame)
                            sys.publish("SA_QUEUE_READY")
                        end
                    else
                        break
                    end
                end
            elseif event == socket.EVENT_CLOSE then
                log.error("UDP_EVENT", "Socket closed by remote or network!")
                sys.publish("SOCKET_CLOSED")
            end
        end)
        
        socket.config(netc, nil, true)

        if socket.connect(netc, config.SERVER_IP, config.SERVER_PORT) then
            -- 成功连接服务器
            proto.set_debug_socket(netc)
            sys.publish("SOCKET_CONNECTED")
            sys.waitUntil("SOCKET_CLOSED", 86400000)
        else
            sys.wait(5000)
        end
        proto.set_debug_socket(nil)
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
        log.info("APP", ">>> [BOOT_SYNC] Attempt #" .. i .. " / 20 - Requesting CG <<<")
        local current_devid = get_device_id()
        local sync_line = proto.request_mcu(proto.next_id(), "CG", "ID=" .. current_devid, 1500, 1)
        
        if sync_line then
            local p6 = proto.split_n(sync_line, ",", 6)
            local mcu_map = proto.parse_payload(p6[6])
            
            local modified = false
            -- 单片机的 ADDR 仅用于物理区分
            if mcu_map.ADDR then 
                config.ADDR = tonumber(mcu_map.ADDR) 
                modified = true
            elseif mcu_map.ID then
                -- 【动态认主】如果在应答头里发现它叫 5，直接认领
                local grabbed_addr = string.match(mcu_map.ID, "(%d+)")
                if grabbed_addr then 
                    config.ADDR = tonumber(grabbed_addr) 
                    modified = true
                end
            end
            
            if mcu_map.RPT then 
                config.REPORT_INTERVAL = tonumber(mcu_map.RPT) * 60 * 1000 
                modified = true
            end

            if modified then
                config.save()
            end
            
            local current_devid = get_device_id()
            log.info("APP", "Initial Sync Handshake hit. Active ID=" .. current_devid)
            last_mcu_ready = true
            sys.publish("BOOT_SYNC_DONE")
            break
        end
        sys.wait(1000)
    end
    mcu_is_busy = false
    boot_synced = true            -- 无论是否成功同步，都解锁系统响应，防止模组死等
    sys.publish("BOOT_SYNC_DONE") -- 通知心跳任务可以开始了

    if not last_mcu_ready then
        log.error("APP", "Initial Sync FAILED after 20 tries - Using default config")
    else
        -- 初始握手成功，发包后立即释放 RRC 节省开机功耗
        if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
    end

    -- 第二阶段：正常周期循环 (开机立即执行一次 MG)
    while true do
        log.info("APP", "--- Starting Reporting Cycle ---")
        local current_devid = get_device_id()

        -- 2. 同步定位 (仅在本地没有 GPS/LBS 数据时获取，避免重复定位消耗功耗)
        if not last_lat or not last_lng then
            local res, lat, lng = lbs.getLocation()
            if res == 0 then last_lat, last_lng = lat, lng end
        end

        -- 1. 等待串口业务空闲并上锁
        local wait_count = 0
        while mcu_is_busy and wait_count < 20 do sys.wait(500) wait_count = wait_count + 1 end
        mcu_is_busy = true

        -- 3. 触发采样 (MG)
        log.info("APP", "Triggering MCU Measurement")
        local current_devid = get_device_id()
        local mg_resp = proto.request_mcu(proto.next_id(), "MG", "ID=" .. current_devid, 700, 3)
        last_mcu_alive = (mg_resp ~= nil)

        if not last_mcu_alive then
            log.error("APP", "MCU Offline confirmed")
            proto.as_tx(netc, proto.next_id(), "EVT", "MD", proto.modem_payload(current_devid, false, last_lat, last_lng))
            if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
        end
        -- 注意：如果单片机在线，它随后会通过串口主动上报 MR 帧，
        -- 届时 uart_task 会负责转发 MR 并执行 rrcRelease，此处只需静候。

        mcu_is_busy = false
        
        -- 4. 周期休眠
        log.info("APP", "Cycle finished. Sleeping for " .. (config.REPORT_INTERVAL / 60000) .. " min")
        sys.wait(config.REPORT_INTERVAL)
    end
end

-- [[ 任务 3：链路维持心跳 (极致续航) ]]
local function heartbeat_task()
    -- 心跳也要等待首次握手结果，否则发出的 ID 可能是错的
    sys.waitUntil("BOOT_SYNC_DONE")
    
    while true do
        sys.wait(1000) -- 每 1 秒检查一次
        if netc then
            local now = os.time()
            local elapsed = now - (proto.last_tx_time or 0)
            local interval = (config.NAT_INTERVAL and config.NAT_INTERVAL > 0) and (config.NAT_INTERVAL / 1000) or 30
            
            if elapsed >= interval then
                -- 升级为标准 AS 协议帧心跳，确保全链路报文格式统一
                local current_devid = get_device_id()
                proto.as_tx(netc, proto.next_id(), "EVT", "HB", "ID=" .. current_devid)
                
                -- 发送完数据后立即请求释放 RRC 连接，回到浅休眠状态
                if mobile and mobile.rrcRelease then
                    mobile.rrcRelease(true)
                end
            end
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
                    
                    -- 【动态认主】截获单片机主动吐出的 ID（例如 5）并纠正自己的认知
                    local learned_addr = string.match(mcu_payload, "ID=(%d+)")
                    if learned_addr then 
                        local learned = tonumber(learned_addr)
                        if config.ADDR ~= learned then
                            config.ADDR = learned
                            config.save()
                        end
                    end
                    
                    if mcu_cmd == "MR" then
                        local current_devid = get_device_id()
                        local final_payload = mcu_payload
                        
                        proto.as_tx(netc, mcu_mid, mcu_type, "MR", final_payload)
                        if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
                        
                        proto.am_tx(mcu_mid, "ACK", "MR", "ID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS)
                    end
                end
            end
        end
    end
end

-- [[ 任务 5：下发指令处理任务 (协程解耦 + 队列化防止丢帧) ]]
local function sa_command_task()
    while true do
        if #sa_cmd_queue == 0 then
            sys.waitUntil("SA_QUEUE_READY")
        end
        
        while #sa_cmd_queue > 0 do
            local frame = table.remove(sa_cmd_queue, 1)
            if frame and netc then
                handle_sa_command(netc, frame)
            end
        end
    end
end

-- [[ 任务 6：处理 OTA 状态回调 (异步上报给服务器) ]]
sys.subscribe("FOTA_STATE", function(status_name, result)
    log.info("APP", "OTA Status Event: " .. status_name .. ", result: " .. tostring(result))
    if status_name == "fd_ok" then
        if type(result) == "table" then
            last_mcu_fw_crc = result.crc
        else
            last_mcu_fw_crc = result
        end
    end

    if last_ota_mid and netc then
        local current_devid = get_device_id()
        -- 使用原始指令类型 (FD/FU/OU)，而非统一写死 OU
        local rsp_cmd = last_ota_cmd or "OU"
        local status_str = status_name
        if status_name == "fu_progress" then
            status_str = "flashing_" .. tostring(result) .. "%"
        end
        local payload = "ID=" .. current_devid .. ";ack=" .. proto.ACK_SUCCESS .. ";status=" .. status_str
        if status_name == "fd_ok" and type(result) == "table" then
            -- CRC 转 uint32 十六进制显示 (兼容负数)
            local crc_u32 = result.crc
            if crc_u32 < 0 then crc_u32 = crc_u32 + 0x100000000 end
            payload = payload .. ";size=" .. tostring(result.size) .. ";crc=0x" .. string.format("%08X", crc_u32)
        elseif status_name == "fd_ok" and type(result) == "number" then
            -- 兼容旧版 (只发CRC数字)
            local crc_u32 = result
            if crc_u32 < 0 then crc_u32 = crc_u32 + 0x100000000 end
            payload = payload .. ";crc=0x" .. string.format("%08X", crc_u32)
        elseif result and status_name ~= "fu_progress" then
            payload = payload .. ";val=" .. tostring(result)
        end
        proto.as_tx(netc, last_ota_mid, "RSP", rsp_cmd, payload)
    end
end)

function app.start()
    led.init(); uart.init()
    if config.POWER_MODE > 0 then
        -- 使用 pm.power 设置工作模式为 1 (Light Sleep) 或 2 (Auto-Idle)
        pm.power(pm.WORK_MODE, config.POWER_MODE)
        log.info("PM", "Work Mode set to: " .. config.POWER_MODE)
    end
    uart.onReceive(function(line) sys.publish("UART_RECV", line) end)
    sys.taskInit(network_task); sys.taskInit(heartbeat_task)
    sys.taskInit(timer_task); sys.taskInit(uart_task); sys.taskInit(sa_command_task)
end

return app
