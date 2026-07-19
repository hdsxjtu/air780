local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")
local proto = require("usr_protocol")
local ota = require("usr_ota")
local focus_log = require("usr_log")
local mobile = _G.mobile
local raw_log = log
local log = {
    info = function() end,
    warn = raw_log.warn,
    error = raw_log.error
}

-- ========================================================================
-- 核心架构说明 (Architecture Overview):
-- 本文件仅负责：1. 业务逻辑分发 (handle_sa_command)  2. 四大任务调度
-- 底层协议封装、串口锁、字符串解析等已移至 usr_protocol.lua
-- ========================================================================

local app = {}
local netc = nil            -- 全局网络连接句柄 (UDP Socket)
local last_mcu_alive = true -- 记录单片机是否正常（心跳用）
local last_lat, last_lng = config.LAT, config.LNG -- GPS/LBS 坐标缓存
local mcu_is_busy = false    -- 业务锁：记录当前模组是否正占用串口与单片机交互
local boot_synced = false    -- 握手标志：开机由于系统响应解锁

-- [[ 新增：指令队列机制，防止丢包 ]]
local sa_cmd_queue = {}
local last_processed_mid = ""
local suppress_uart_cg_mid = nil
local last_ota_mid = nil -- 新增：用于记录下发升级指令的 MID，以便异步回调时回传结果
local last_ota_cmd = nil -- 新增：记录升级指令类型 (FD/FU/OU)，确保回调使用正确的命令名
local last_mcu_fw_crc = nil -- 新增：用于缓存已下载固件的 CRC，以便刷写时免除重复计算
local pending_hb_mid = nil
local last_hb_ack_mid = nil
local hb_miss_count = 0
local net_ready_reported = false
local last_mcu_net_state = nil
local network_gate_failed = false
local usb_closed_after_netcfg = false

local function reset_heartbeat_state()
    pending_hb_mid = nil
    last_hb_ack_mid = nil
    hb_miss_count = 0
    network_gate_failed = false
    proto.last_tx_time = os.time()
end

-- [[ 新增：获取唯一设备 ID (优先使用 config.DEVICE_ID，最后使用 ADDR) ]]
local function get_device_id()
    if config.DEVICE_ID then
        return config.DEVICE_ID
    end
    return tostring(config.ADDR or "1")
end

local function get_device_type()
    return tostring(config.TYPE or "TY")
end

local function id_matches_local(payload_id, current_devid)
    if payload_id == current_devid then
        return true
    end
    return payload_id == (get_device_type() .. current_devid)
end

-- [[ 新增：解析 MCU 帧动态纠正本地 ID 认知 ]]
local function sync_mcu_identity(mcu_payload)
    if not mcu_payload then return end
    local explicit_type = string.match(mcu_payload, "TYPE=([A-Z]+)")
    local type_part, addr_part = string.match(mcu_payload, "ID=([A-Z]*)(%d+)")
    if addr_part then
        local learned_addr = tonumber(addr_part)
        local learned_type = explicit_type or ((type_part ~= "") and type_part or config.TYPE or "TY")
        local changed = false

        if config.ADDR ~= learned_addr then
            config.ADDR = learned_addr
            changed = true
        end
        if config.TYPE ~= learned_type then
            config.TYPE = learned_type
            changed = true
        end

        if changed then
            config.save()
        end
    end
end

-- Save IP/Port config only. New server takes effect on next 4G reboot.
local function sync_ip_port(payload_map)
    if not payload_map then return end
    if payload_map.SIP1 or payload_map.SIP2 or payload_map.SIP3 or payload_map.SIP4 or payload_map.SPT then
        local s1 = tonumber(payload_map.SIP1) or config.SIP1 or 0
        local s2 = tonumber(payload_map.SIP2) or config.SIP2 or 0
        local s3 = tonumber(payload_map.SIP3) or config.SIP3 or 0
        local s4 = tonumber(payload_map.SIP4) or config.SIP4 or 0
        local spt = tonumber(payload_map.SPT) or config.SPT or 0
        
        if config.SIP1 ~= s1 or config.SIP2 ~= s2 or config.SIP3 ~= s3 or config.SIP4 ~= s4 or config.SPT ~= spt then
            config.SIP1 = s1
            config.SIP2 = s2
            config.SIP3 = s3
            config.SIP4 = s4
            config.SPT  = spt
            config.save()
            log.info("APP", "IP/Port saved, effective after reboot: " .. string.format("%d.%d.%d.%d:%d", s1, s2, s3, s4, spt))
        end
    end
end

local function parse_bool_flag(value)
    if value == nil then return nil end
    local s = string.lower(tostring(value))
    if s == "1" or s == "true" or s == "on" or s == "yes" then return true end
    if s == "0" or s == "false" or s == "off" or s == "no" then return false end
    return nil
end

local function sync_power_params(payload_map)
    if not payload_map then return false end
    local modified = false

    local delay_s = tonumber(payload_map.NDL or payload_map.NETD or payload_map.BOOTD)
    if delay_s then
        local delay_ms = math.max(0, math.min(delay_s, 300)) * 1000
        if config.BOOT_NETWORK_DELAY_MS ~= delay_ms then
            config.BOOT_NETWORK_DELAY_MS = delay_ms
            modified = true
            log.info("APP", "BOOT_NETWORK_DELAY_MS updated to " .. tostring(delay_ms))
        end
    end

    local led_enabled = parse_bool_flag(payload_map.LED or payload_map.BLINK or payload_map.BLED)
    if led_enabled ~= nil and config.BLUE_LED_ENABLE ~= led_enabled then
        config.BLUE_LED_ENABLE = led_enabled
        config.BOOT_LED_BLINK = led_enabled
        if led_enabled then
            led.start(net_ready_reported and "online" or "waiting_network")
        else
            led.status("off")
            led.off()
        end
        modified = true
        log.info("APP", "BLUE_LED_ENABLE updated to " .. tostring(led_enabled))
    end

    return modified
end


-- [[ 内部逻辑：静默刷新 GPS 缓存 ]]
local function is_local_4g_param(key)
    return key == "LED" or key == "BLINK" or key == "BLED"
end

local function has_mcu_param(payload_map)
    if not payload_map then return false end
    for key, _ in pairs(payload_map) do
        if key ~= "ID" and key ~= "TYPE" and key ~= "imei" and not is_local_4g_param(key) then
            return true
        end
    end
    return false
end

local function strip_local_4g_params(payload)
    local kept = {}
    for segment in string.gmatch(payload or "", "[^;]+") do
        local eq_pos = string.find(segment, "=", 1, true)
        local key = eq_pos and string.sub(segment, 1, eq_pos - 1) or segment
        if not is_local_4g_param(key) then
            table.insert(kept, segment)
        end
    end
    return table.concat(kept, ";")
end

local function append_4g_config_fields(payload)
    local result = payload or ""
    if not string.find(result, "gv=", 1, true) then
        result = result .. ";gv=4G" .. _G.VERSION
    end
    if not string.find(result, "LED=", 1, true) then
        result = result .. ";LED=" .. (config.BLUE_LED_ENABLE and "1" or "0")
    end
    return result
end

local function update_gps_cache()
    if last_lat and last_lng then
        return -- 已经有GPS信息，不再定位
    end
    sys.taskInit(function()
        local res, lat, lng = lbs.getLocation()
        if res == 0 and lat and lng and lat ~= "" and lng ~= "" then
            last_lat, last_lng = lat, lng
            config.LAT, config.LNG = lat, lng
            config.save()
            log.info("APP", "GPS Cache Updated: " .. lat .. "," .. lng)
        end
    end)
end

-- [[ 业务中枢：处理服务器指令 (SA 帧) ]]
local function handle_sa_command(sock, frame)
    if frame.type ~= "CMD" then return end
    log.info("APP", "SA command received: " .. tostring(frame.cmd) .. ", mid=" .. tostring(frame.id))
    
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
    if not payload_map.ID or not id_matches_local(payload_map.ID, current_devid) or not payload_map.imei or payload_map.imei ~= local_imei then
        log.error("APP", "ID/IMEI Mismatch: expected " .. current_devid .. "/" .. local_imei .. " but got " .. tostring(payload_map.ID) .. "/" .. tostring(payload_map.imei))
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_ID_MISMATCH) 
        return 
    end

    -- 2. 模组忙阻判定
    if not boot_synced or mcu_is_busy then
        log.warn("APP", "System Startup/Busy, rejecting SA command: " .. (frame.id or "N/A"))
        proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";ack=" .. proto.ACK_BUSY)
        return
    end

    -- 3. 针对需要单片机参与的命令 (CG/CS/MS/MG/RESET/BOOT)：加忙锁
    if frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "PS" or frame.cmd == "MS" or frame.cmd == "MG" or frame.cmd == "RESET" or frame.cmd == "BOOT" then
        mcu_is_busy = true
    end

    if frame.cmd == "CS" and sync_power_params(payload_map) then
        config.save()
    end

    if frame.cmd == "CS" and not has_mcu_param(payload_map) then
        proto.as_tx(sock, frame.id, "RSP", "CS", "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";LED=" .. (config.BLUE_LED_ENABLE and "1" or "0") .. ";ack=" .. proto.ACK_SUCCESS)
        mcu_is_busy = false
        return
    end

    if frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "PS" or frame.cmd == "RESET" or frame.cmd == "BOOT" then
        local retry_count = 1
        local mcu_request_payload = (frame.cmd == "CS") and strip_local_4g_params(frame.payload) or frame.payload
        if frame.cmd == "CG" then
            suppress_uart_cg_mid = frame.id
            sys.taskInit(function(mid)
                sys.wait(5000)
                if suppress_uart_cg_mid == mid then
                    suppress_uart_cg_mid = nil
                end
            end, frame.id)
        end
        local resp_line = proto.request_mcu(frame.id, frame.cmd, mcu_request_payload, 1500, retry_count)
        
        if resp_line then
            local p6 = proto.split_n(resp_line, ",", 6)
            local mcu_payload = p6[6] or ""
            last_mcu_alive = true
            
            -- 如果是 CS 或 CG 指令且执行成功，此时将 MCU 确领并返回的新参数同步到 4G 模组本地并保存
            if frame.cmd == "CS" or frame.cmd == "CG" then
                local mcu_map = proto.parse_payload(mcu_payload)
                local is_success = true
                if frame.cmd == "CS" then
                    if mcu_map.ack and tonumber(mcu_map.ack) ~= 1 then
                        is_success = false
                    end
                end

                if is_success then
                    local source_map = (frame.cmd == "CS") and payload_map or mcu_map
                    local modified = false
                    if source_map.RPT then
                        local new_rpt = tonumber(source_map.RPT) * 60 * 1000
                        if config.REPORT_INTERVAL ~= new_rpt then
                            config.REPORT_INTERVAL = new_rpt
                            log.info("APP", frame.cmd .. " Success: Local REPORT_INTERVAL updated to " .. config.REPORT_INTERVAL .. "ms")
                            modified = true
                            sys.publish("REPORT_INTERVAL_UPDATED")
                        end
                    end
                    if source_map.ADDR then
                        local new_addr = tonumber(source_map.ADDR)
                        if config.ADDR ~= new_addr then
                            config.ADDR = new_addr
                            log.info("APP", frame.cmd .. " Success: Local ADDR updated to " .. config.ADDR)
                            modified = true
                        end
                    end
                    if source_map.ID then
                        local type_part, addr_part = string.match(source_map.ID, "([A-Z]*)(%d+)")
                        if addr_part then
                            local new_addr = tonumber(addr_part)
                            local new_type = source_map.TYPE or ((type_part ~= "") and type_part or config.TYPE or "TY")
                            if config.ADDR ~= new_addr then
                                config.ADDR = new_addr
                                log.info("APP", frame.cmd .. " Success: Local ADDR updated to " .. config.ADDR)
                                modified = true
                            end
                            if config.TYPE ~= new_type then
                                config.TYPE = new_type
                                log.info("APP", frame.cmd .. " Success: Local TYPE updated to " .. config.TYPE)
                                modified = true
                            end
                        end
                    end
                    if source_map.TYPE and config.TYPE ~= source_map.TYPE then
                        config.TYPE = source_map.TYPE
                        log.info("APP", frame.cmd .. " Success: Local TYPE updated to " .. config.TYPE)
                        modified = true
                    end
                    -- Save custom IP/Port for next 4G reboot.
                    sync_ip_port(source_map)
                    if sync_power_params(source_map) then
                        modified = true
                    end

                    if modified then
                        config.save()
                    end
                end
            end

            -- CG: 不在此处转发，由 uart_task 作为唯一出口并注入 gv
            -- CS: MCU 的 ack 需要返回给服务器，在此统一转发
            if frame.cmd == "CG" or frame.cmd == "CS" or frame.cmd == "PS" then
                local final_payload = (frame.cmd == "PS") and mcu_payload or append_4g_config_fields(mcu_payload)
                proto.as_tx(sock, frame.id, "RSP", frame.cmd, final_payload)
            end
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";LED=" .. (config.BLUE_LED_ENABLE and "1" or "0") .. ";ack=" .. proto.ACK_OFFLINE)
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
            
            proto.as_tx(sock, frame.id, mcu_type, frame.cmd, "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";ack=" .. mcu_ack)
            
            if mcu_type == "ACK" and mcu_ack == proto.ACK_SUCCESS then
                sys.publish("PENDING_SERVER_MID", frame.id)
            end
        else
            last_mcu_alive = false
            proto.as_tx(sock, frame.id, "RSP", frame.cmd, "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";gv=4G" .. _G.VERSION .. ";LED=" .. (config.BLUE_LED_ENABLE and "1" or "0") .. ";ack=" .. proto.ACK_OFFLINE)
        end
    elseif frame.cmd == "MD" then
        -- 1. 立即回复一阶段 ACK，防止服务器超时
        proto.as_tx(sock, frame.id, "ACK", "MD", "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS)
        
        -- 2. 启动异步后台定位并在完成后上报 RSP
        sys.taskInit(function()
            local res, lat, lng = lbs.getLocation()
            local report_lat, report_lng
            if res == 0 and lat and lng and lat ~= "" and lng ~= "" then
                last_lat, last_lng = lat, lng
                config.LAT, config.LNG = lat, lng
                config.save()
                report_lat, report_lng = lat, lng
            else
                report_lat = last_lat or "-1"
                report_lng = last_lng or "-1"
            end
            proto.as_tx(sock, frame.id, "RSP", "MD", proto.modem_payload(current_devid, get_device_type(), last_mcu_alive, report_lat, report_lng))
        end)
    -- ----------------------------------------------------------------
    -- FD: Firmware Download — 强制下载固件到4G模组本地，不碰单片机
    -- 服务端发: SA,1,XXXX,CMD,FD,ID=1;url=http://xxx/fw.bin
    -- ----------------------------------------------------------------
    elseif frame.cmd == "FD" then
        if payload_map.url then
            log.info("APP", "[FD] URL: " .. payload_map.url .. " size=" .. tostring(payload_map.size) .. " crc=" .. tostring(payload_map.crc))
            proto.as_tx(sock, frame.id, "RSP", "FD",
                "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS .. ";status=downloading")
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
                "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_ERROR)
        end
    -- ----------------------------------------------------------------
    -- FU: Firmware Upgrade — 自动让MCU进入BOOT模式后刷写
    -- 自动发送 BOOT → MCU复位 → Bootloader 救砖模式 → OU/OD/OE
    -- 服务端发: SA,1,XXXX,CMD,FU,ID=1
    -- ----------------------------------------------------------------
    elseif frame.cmd == "FU" then
        log.info("APP", "[FU] Starting MCU flash from local firmware")
        proto.as_tx(sock, frame.id, "RSP", "FU",
            "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS .. ";status=flashing")
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
                "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS .. ";status=downloading")
            sys.taskInit(function()
                last_ota_mid = frame.id
                last_ota_cmd = "OU"
                sys.wait(500)
                ota.start(payload_map.url)
            end)
        else
            log.warn("APP", "[OU] Missing url in payload")
            proto.as_tx(sock, frame.id, "RSP", "OU",
                "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_ERROR)
        end
    end
    mcu_is_busy = false
end

-- ========================================================================
-- 四大并行独立任务
-- ========================================================================

-- [[ 任务 1：核心网络任务 ]]
local function notify_mcu_network_result(ok, reason)
    local next_state = ok and 1 or 0
    if last_mcu_net_state == next_state then
        net_ready_reported = ok
        return
    end

    local wait_count = 0
    while mcu_is_busy and wait_count < 20 do
        sys.wait(100)
        wait_count = wait_count + 1
    end

    mcu_is_busy = true
    local current_devid = get_device_id()
    local payload = "ID=" .. current_devid .. ";net=" .. (ok and "1" or "0")
    proto.am_tx(proto.next_id(), "EVT", "NR", payload)
    last_mcu_net_state = next_state
    net_ready_reported = ok
    mcu_is_busy = false
end

local function report_network_failed(reason)
    network_gate_failed = true
    led.status("fail")
    notify_mcu_network_result(false, reason)
end

local function network_task()
    local connect_fail_count = 0
    local retry_delay_ms = config.SOCKET_RETRY_MIN_MS or 10000
    while true do
        if socket.localIP() == "0.0.0.0" or socket.localIP() == nil then
            led.status("waiting_network")
            sys.waitUntil("IP_READY")
        end

        if config.SERVER_CONNECT_DELAY_MS and config.SERVER_CONNECT_DELAY_MS > 0 then
            if mobile and mobile.rrcRelease then
                mobile.rrcRelease(true)
            end
            sys.wait(config.SERVER_CONNECT_DELAY_MS)
        end

        local target_ip = config.SERVER_IP
        local target_port = config.SERVER_PORT
        
        -- Use the MCU/saved server when any SIP segment is non-zero; otherwise use the default server.
        local is_custom_ip = (config.SIP1 and config.SIP1 ~= 0) or 
                             (config.SIP2 and config.SIP2 ~= 0) or 
                             (config.SIP3 and config.SIP3 ~= 0) or 
                             (config.SIP4 and config.SIP4 ~= 0)
                             
        if is_custom_ip then
            target_ip = string.format("%d.%d.%d.%d", config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0)
            target_port = (config.SPT and config.SPT > 0) and config.SPT or config.SERVER_PORT
        else
            target_ip = config.SERVER_IP
            target_port = config.SERVER_PORT
        end

        focus_log.network_status(config, target_ip, target_port, "IP_READY")
        if not usb_closed_after_netcfg and pm then
            usb_closed_after_netcfg = true
            sys.wait(config.USB_CLOSE_AFTER_NETSTAT_MS or 0)
            if config.USB_ENABLE == false and pm.USB then
                pm.power(pm.USB, false)
            end
            if config.LOW_POWER_AFTER_NETSTAT and pm.WORK_MODE then
                pm.power(pm.WORK_MODE, 1)
            end
        end
        local connect_started_at = os.time()
        
        local rxbuff = zbuff.create(1024)
        netc = socket.create(nil, function(sc, event)
            -- 只要有事件进来，由于是无连接的 UDP，大概率是收到了数据
            if event == socket.EVENT or event == socket.EVENT_RX or event == socket.EVENT_RECV then
                -- 必须循环读取，直到读空，防止 UDP 缓冲区堆积导致丢包 (关键加固)
                while true do
                    rxbuff:seek(0, 0)
                    local ok, len = socket.rx(sc, rxbuff)
                    if ok and len and len > 0 then
                        local data = rxbuff:toStr(0, len)
                        if config.BLUE_LED_ENABLE and config.LED_PACKET_BLINK then
                            sys.taskInit(led.blink, 20)
                        end
                        local frame = proto.parse_sa_frame(data)
                        if frame then
                            if frame.type == "ACK" and frame.cmd == "HB" then
                                local hb_map = proto.parse_payload(frame.payload)
                                if hb_map.ack == "1" then
                                    last_hb_ack_mid = frame.id
                                    hb_miss_count = 0
                                    sys.publish("HB_ACK", frame.id)
                                end
                            else
                                table.insert(sa_cmd_queue, frame)
                                sys.publish("SA_QUEUE_READY")
                            end
                        end
                    else
                        break
                    end
                end
            elseif event == socket.EVENT_CLOSE then
                log.error("NET", "Socket closed by remote or network!")
                sys.publish("SOCKET_CLOSED")
            end
        end)
        
        socket.config(netc, nil, true)
 
        if socket.connect(netc, target_ip, target_port) then
            connect_fail_count = 0
            -- Server socket is ready.
            proto.set_debug_socket(netc)
            reset_heartbeat_state()
            sys.publish("SOCKET_CONNECTED")

            sys.waitUntil("SOCKET_CLOSED", 86400000)
            if os.time() - connect_started_at >= 300 then
                retry_delay_ms = config.SOCKET_RETRY_MIN_MS or 10000
            end
        else
            connect_fail_count = connect_fail_count + 1
            log.warn("NET", "Socket connect failed, count=" .. tostring(connect_fail_count))
            if connect_fail_count >= (config.SOCKET_CONNECT_FAIL_LIMIT or 3) then
                connect_fail_count = 0
                log.error("NET", "Socket connect failed too many times, notify MCU net=0")
                report_network_failed("socket_connect_failed")
            end
        end
        proto.set_debug_socket(nil)
        if netc then socket.close(netc) netc = nil end
        log.warn("NET", "Retry socket after " .. tostring(retry_delay_ms) .. "ms")
        sys.wait(retry_delay_ms)
        retry_delay_ms = math.min(retry_delay_ms * 2, config.SOCKET_RETRY_MAX_MS or 300000)
    end
end

-- [[ 任务 2：定时上报任务 ]]
local function disabled_deep_sleep(reason)
    log.warn("PM", "Deep sleep is disabled; MCU controls physical power-off: " .. tostring(reason))
end

local function timer_task()
    -- 第一阶段：开机获取到网络，在 log 提示并闪烁指示灯 3 次，每次 100ms
    sys.waitUntil("SOCKET_CONNECTED")
    log.info("NET", "Network Ready. Connection established successfully!")
    
    sys.wait(5000)
    boot_synced = false
    -- 尝试温和同步一次单片机参数 (CG)
    local current_devid = get_device_id()
    if config.BOOT_MCU_SYNC_ENABLE ~= false then
        mcu_is_busy = true
        local sync_line = proto.request_mcu(proto.next_id(), "CG", "ID=" .. current_devid, 1500, 1)
        if sync_line then
            local p6 = proto.split_n(sync_line, ",", 6)
            local mcu_map = proto.parse_payload(p6[6])
            local modified = false
            if mcu_map.ADDR then
                config.ADDR = tonumber(mcu_map.ADDR)
                modified = true
            end
            if mcu_map.ID then
                local grabbed_addr = string.match(mcu_map.ID, "(%d+)")
                if grabbed_addr then
                    config.ADDR = tonumber(grabbed_addr)
                    modified = true
                end
            end
            if mcu_map.TYPE and config.TYPE ~= mcu_map.TYPE then
                config.TYPE = mcu_map.TYPE
                modified = true
            end
            if mcu_map.RPT then
                config.REPORT_INTERVAL = tonumber(mcu_map.RPT) * 60 * 1000
                modified = true
                sys.publish("REPORT_INTERVAL_UPDATED")
            end
            if modified then
                config.save()
            end
            log.info("BOOT", "MCU Sync SUCCESS. Active ID: " .. get_device_id())
        else
            log.info("BOOT", "MCU Sync TIMEOUT. Active ID: " .. get_device_id())
        end
        mcu_is_busy = false
    else
        log.info("BOOT", "MCU Sync skipped for low-power boot")
    end
    
    boot_synced = true
    sys.publish("BOOT_SYNC_DONE") -- 通知心跳任务可以开始了

    if mobile and mobile.rrcRelease then
        mobile.rrcRelease(true)
    end

    -- 第二阶段：正常周期循环 (开机立即执行一次 MG)
    if config.FIRST_REPORT_DELAY_MS and config.FIRST_REPORT_DELAY_MS > 0 then
        log.info("CYCLE", "First MG delayed " .. tostring(config.FIRST_REPORT_DELAY_MS) .. "ms")
        sys.waitUntil("REPORT_INTERVAL_UPDATED", config.FIRST_REPORT_DELAY_MS)
    end

    while true do
        local current_devid = get_device_id()

        -- 1. 等待串口业务空闲并上锁
        local wait_count = 0
        while mcu_is_busy and wait_count < 20 do sys.wait(500) wait_count = wait_count + 1 end
        mcu_is_busy = true

        -- 3. 触发采样 (MG)
        log.info("CYCLE", "Trigger MG (ID=" .. current_devid .. ")")
        local mg_resp = proto.request_mcu(proto.next_id(), "MG", "ID=" .. current_devid, 700, 3)
        last_mcu_alive = (mg_resp ~= nil)

        if not last_mcu_alive then
            log.error("CYCLE", "MCU Offline! Report EVT,MD")
            proto.as_tx(netc, proto.next_id(), "EVT", "MD", proto.modem_payload(current_devid, get_device_type(), false, last_lat, last_lng))
            if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
            if false then
                sys.wait(2000)
                disabled_deep_sleep("mcu_offline_reported")
                return
            end
        end
        -- 注意：如果单片机在线，它随后会通过串口主动上报 MR 帧，

        mcu_is_busy = false

        if false then
            local ok = sys.waitUntil("REPORT_TX_DONE", config.REPORT_TX_WAIT_MS or 20000)
            disabled_deep_sleep(ok and "report_uploaded" or "report_wait_timeout")
            return
        end
        
        -- 4. 周期休眠
        log.info("CYCLE", "Sleep " .. (config.REPORT_INTERVAL / 60000) .. " min")
        sys.waitUntil("REPORT_INTERVAL_UPDATED", config.REPORT_INTERVAL)
    end
end

-- [[ 任务 3：链路维持心跳 (极致续航) ]]
local function network_ready_task()
    while true do
        sys.waitUntil("SOCKET_CONNECTED")
        led.status("waiting_network")

        local current_devid = get_device_id()
        local ok = false
        local tries = config.NET_CHECK_HB_TRIES or 3
        local timeout_ms = config.NET_CHECK_HB_TIMEOUT_MS or 5000
        local start_delay_ms = config.NET_CHECK_START_DELAY_MS or 0

        if start_delay_ms > 0 then
            sys.wait(start_delay_ms)
        end

        for i = 1, tries do
            local hb_mid = proto.next_id()
            pending_hb_mid = hb_mid
            proto.as_tx(netc, hb_mid, "EVT", "HB", "ID=" .. current_devid .. ";TYPE=" .. get_device_type())
            local got, ack_mid = sys.waitUntil("HB_ACK", timeout_ms)
            if got and ack_mid == hb_mid then
                ok = true
                break
            end
        end

        if ok then
            net_ready_reported = true
            boot_synced = true
            sys.publish("BOOT_SYNC_DONE")
            notify_mcu_network_result(true)
            led.status("online")
        else
            log.error("NET", "HB gate failed. MCU notified net=0")
            boot_synced = true
            sys.publish("BOOT_SYNC_DONE")
            report_network_failed("no_hb_ack")
        end

        if ok and config.BOOT_SIMULATE_MR and netc then
            local sim_payload = "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";sim=1;MCU:25.0,0.00,25.0,0.00,25.0,0.0,25.0,1013.0,0x0000,3.70,3.70,0x00,0x00,0x08"
            proto.as_tx(netc, proto.next_id(), "EVT", "MR", sim_payload)
            log.info("APP", "Simulated MR sent after network ready")
        end
    end
end

local function heartbeat_task()
    -- 心跳也要等待首次握手结果，否则发出的 ID 可能是错的
    sys.waitUntil("BOOT_SYNC_DONE")

    if config.HEARTBEAT_START_DELAY_MS and config.HEARTBEAT_START_DELAY_MS > 0 then
        log.info("HB", "First heartbeat delayed " .. tostring(config.HEARTBEAT_START_DELAY_MS) .. "ms")
        sys.wait(config.HEARTBEAT_START_DELAY_MS)
    end
    
    while true do
        if netc then
            local now = os.time()
            local elapsed = now - (proto.last_tx_time or 0)
            local interval = (config.NAT_INTERVAL and config.NAT_INTERVAL > 0) and (config.NAT_INTERVAL / 1000) or 300
            local remain_sec = interval - elapsed
            
            if remain_sec <= 0 then
                -- 升级为标准 AS 协议帧心跳，确保全链路报文格式统一
                local current_devid = get_device_id()
                proto.as_tx(netc, proto.next_id(), "EVT", "HB", "ID=" .. current_devid .. ";TYPE=" .. get_device_type())
                
                -- 发送完数据后立即请求释放 RRC 连接，回到浅休眠状态
                if mobile and mobile.rrcRelease then
                    mobile.rrcRelease(true)
                end
                
                -- 发完后挂起一个完整间隔
                sys.wait(interval * 1000)
            else
                -- 睡完剩下的时间
                sys.wait(remain_sec * 1000)
            end
        else
            sys.wait(5000)
        end
    end
end

-- [[ 任务 4：串口监听任务 ]]
local function heartbeat_socket_task()
    while true do
        if not netc then
            sys.waitUntil("SOCKET_CONNECTED")
            reset_heartbeat_state()
        end

        while not boot_synced do
            sys.wait(100)
        end

        if config.HEARTBEAT_START_DELAY_MS and config.HEARTBEAT_START_DELAY_MS > 0 then
            log.info("HB", "First heartbeat delayed " .. tostring(config.HEARTBEAT_START_DELAY_MS) .. "ms")
            sys.wait(config.HEARTBEAT_START_DELAY_MS)
        end

        while netc do
            local now = os.time()
            local elapsed = now - (proto.last_tx_time or 0)
            local interval = (config.NAT_INTERVAL and config.NAT_INTERVAL > 0) and (config.NAT_INTERVAL / 1000) or 30
            local remain_sec = interval - elapsed

            if remain_sec <= 0 then
                local current_devid = get_device_id()
                local hb_mid = proto.next_id()
                pending_hb_mid = hb_mid
                proto.as_tx(netc, hb_mid, "EVT", "HB", "ID=" .. current_devid .. ";TYPE=" .. get_device_type())
                local got, ack_mid = sys.waitUntil("HB_ACK", config.NET_CHECK_HB_TIMEOUT_MS or 5000)
                if got and ack_mid == hb_mid then
                    hb_miss_count = 0
                    network_gate_failed = false
                    notify_mcu_network_result(true)
                    led.status("online")
                else
                    hb_miss_count = hb_miss_count + 1
                    log.warn("HB", "ACK missed: " .. tostring(hb_mid) .. ", miss=" .. tostring(hb_miss_count))
                    if hb_miss_count >= (config.HB_ACK_MISS_LIMIT or 3) then
                        log.error("HB", "ACK missed too many times, notify MCU net=0")
                        report_network_failed("hb_ack_lost")
                    end
                end
                if mobile and mobile.rrcRelease then
                    mobile.rrcRelease(true)
                end
                sys.wait(interval * 1000)
            else
                sys.wait(remain_sec * 1000)
            end
        end
    end
end

local function uart_task()
    while true do
        local result, line = sys.waitUntil("UART_RECV", 30000)
        if result and line then
            if string.find(line, "^MA,1,") then
                local p6 = proto.split_n(line, ",", 6)
                if #p6 == 6 then
                    local mcu_mid, mcu_type, mcu_cmd, mcu_payload = p6[3], p6[4], p6[5], p6[6]
                    last_mcu_alive = true
                    
                    -- 【动态认主】截获单片机主动吐出的 ID 前缀与数字（例如 FJ5 或 TY5）并同步认知
                    sync_mcu_identity(mcu_payload)
                    
                    if mcu_cmd == "MR" then
                        local current_devid = get_device_id()
                        local final_payload = mcu_payload
                        
                        proto.as_tx(netc, mcu_mid, mcu_type, "MR", final_payload)
                        if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
                        sys.publish("REPORT_TX_DONE")
                        
                        proto.am_tx(mcu_mid, "ACK", "MR", "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS)
                    elseif mcu_cmd == "CG" then
                        local cg_suppressed = false
                        if suppress_uart_cg_mid == mcu_mid then
                            suppress_uart_cg_mid = nil
                            cg_suppressed = true
                            local mcu_map = proto.parse_payload(mcu_payload)
                            sync_ip_port(mcu_map)
                        end
                        -- 统一注入 gv，作为 CG 帧的唯一转发出口（包括 MCU 主动上报和响应服务器指令两种情况）
                        if not cg_suppressed then
                            local final_cg = append_4g_config_fields(mcu_payload)
                            proto.as_tx(netc, mcu_mid, mcu_type, "CG", final_cg)
                            if mobile and mobile.rrcRelease then mobile.rrcRelease(true) end
                        
                        -- Save IP/Port params for next 4G reboot.
                            local mcu_map = proto.parse_payload(mcu_payload)
                            sync_ip_port(mcu_map)
                        end
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
        local payload = "ID=" .. current_devid .. ";TYPE=" .. get_device_type() .. ";ack=" .. proto.ACK_SUCCESS .. ";status=" .. status_str
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
    if config.BLUE_LED_ENABLE then
        led.start("boot")
    else
        led.off()
    end
    if config.DEBUG_KEEP_AWAKE == true then
        config.POWER_MODE = 0
        log.warn("PM", "DEBUG_KEEP_AWAKE=true, skip Light Sleep for USB logging")
    end
    if config.POWER_MODE ~= 1 then
        log.warn("PM", "WORK_MODE stays normal for debug")
    else
        -- WORK_MODE=1: Light Sleep. Deep sleep/PSM is disabled by design.
        pm.power(pm.WORK_MODE, config.POWER_MODE)
    end
    uart.onReceive(function(line) sys.publish("UART_RECV", line) end)

    if config.NETWORK_ENABLE == false then
        log.warn("PM", "NETWORK_ENABLE=false, cellular network tasks are disabled")
        if mobile and mobile.flymode then
            mobile.flymode(0, true)
        end
        sys.taskInit(uart_task)
        return
    end

    sys.taskInit(network_task)
    sys.taskInit(network_ready_task)
    sys.taskInit(heartbeat_socket_task)
    sys.taskInit(sa_command_task)
    sys.taskInit(uart_task)
end

return app
