local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")

local app = {}
local netc = nil
local next_msg_id = 9000
local last_mcu_alive = true
local imei = ""

-- 建立短码与长参数名的映射表（用于协议解析）
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

-- 全量参数排序（用于返回 CFG_ALL）
local PARAM_ORDER = {
    "RPT_INT", "PRA_L", "PRA_H", "PRB_L", "PRB_H",
    "CH4_L", "CH4_H", "TMP_L", "TMP_H", "BAT_L",
}

-- Utility functions
-- 辅助函数：按分隔符拆分字符串
local function split(str, reps)
    local resultStrList = {}
    string.gsub(str, '[^' .. reps .. ']+', function(w)
        table.insert(resultStrList, w)
    end)
    return resultStrList
end

-- 辅助函数：按分隔符拆分字符串为固定数量的片段
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

-- 生成下一个消息 ID (9000-9999 循环)
local function next_id()
    next_msg_id = next_msg_id + 1
    if next_msg_id > 9999 then
        next_msg_id = 9000
    end
    return tostring(next_msg_id)
end

-- 解析 payload 字符串 (did=XXX;gv=YYY) 为表结构
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

-- 构建协议帧：头,版本,MID,类型,命令,载荷
local function build_frame(header, mid, frame_type, cmd, payload)
    return table.concat({header, "1", mid, frame_type, cmd, payload or ""}, ",")
end

-- 向服务器发送 AS 帧
local function as_tx(sock, mid, frame_type, cmd, payload)
    if sock then
        local message = build_frame("AS", mid, frame_type, cmd, payload)
        socket.tx(sock, message)
        log.info("UDP_TX", message)
    end
end

-- 构建测量上报 (MR) 的载荷部分
local function mr_payload(mcu_line)
    return "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";" .. mcu_line
end

-- 构建模组状态 (MD) 的载荷部分
local function modem_payload(mcu_alive)
    local rsrp = -99
    if mobile and mobile.rsrp then
        rsrp = mobile.rsrp()
    end
    local mdead = mcu_alive and "0" or "1"
    return "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";mod=Air780E;rsrp=" .. tostring(rsrp) .. ";net=4G;mdead=" .. mdead
end

-- 解析服务器下发的 SA 帧
local function parse_sa_frame(data)
    local p6 = split_n(data, ",", 6)
    if #p6 == 6 and p6[1] == "SA" then
        -- 网络调试助手发送的内容经常附带隐藏的回车换行符，必须将它们剔除
        local clean_payload = string.gsub(p6[6] or "", "[\r\n]", "")
        return {ver = p6[2], id = p6[3], type = p6[4], cmd = p6[5], payload = clean_payload}
    end
    return nil
end

-- 等待串口数据返回特定格式的行（超时退出）
local function wait_for_uart_line(timeout_ms, matcher)
    local end_time = mcu.ticks() + timeout_ms
    while mcu.ticks() < end_time do
        local ok, line = sys.waitUntil("UART_RECV", 500)
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

-- 从串口收集配置参数：支持旧的 CONFIG: 格式和新的 MA RSP 格式
local function collect_config_params(timeout_ms)
    local values = {}
    local end_time = mcu.ticks() + timeout_ms
    while mcu.ticks() < end_time do
        local ok, line = sys.waitUntil("UART_RECV", 500)
        if ok and line then
            if string.sub(line, 1, 2) == "MA" then
                -- 处理 V1.1 协议帧: MA,1,mid,RSP,CG,payload
                local p6 = split_n(line, ",", 6)
                if #p6 == 6 and p6[5] == "CG" then
                    local payload_map = parse_payload(p6[6])
                    -- 如果 payload 包含 params=CFG_ALL，则参数就在这一行
                    for k, v in pairs(payload_map) do
                        if k ~= "devID" and k ~= "params" and k ~= "gv" then
                            values[k] = v
                        end
                    end
                    -- 如果是单行全量返回，直接结束
                    if string.find(p6[6], "params=CFG_ALL") then break end
                end
            elseif string.sub(line, 1, 7) == "CONFIG:" then
                -- 兼容旧的 CONFIG:key,value 格式
                local body = string.sub(line, 8)
                if body == "END" then break end
                local kv = split(body, ",")
                local short_name = LONG_TO_SHORT[kv[1]] or kv[1]
                if short_name and kv[2] then values[short_name] = kv[2] end
            elseif line == "ACK:0" then
                -- 忽略通用应答
            elseif string.sub(line, 1, 4) == "ERR:" then
                return nil
            end
        end
    end
    local result = {}
    for _, key in ipairs(PARAM_ORDER) do
        if values[key] then table.insert(result, key .. "=" .. values[key]) end
    end
    return #result > 0 and table.concat(result, ",") or nil
end

local function find_set_param(payload_map)
    for key, value in pairs(payload_map) do
        if key ~= "devID" and key ~= "gv" and key ~= "ack" and key ~= "params" then
            return key, value
        end
    end
    return nil, nil
end

-- 向 MCU 发送 AM 帧
-- 协议 §3.4：MCU 可能处于休眠状态，必须先发 0x00 唤醒字节，
-- 等待 10ms 使 MCU 完成唤醒，再发送正式帧内容。
local function am_tx(mid, frame_type, cmd, payload)
    local message = build_frame("AM", mid, frame_type, cmd, payload)
    uart.send("\x00")          -- 唤醒字节
    sys.wait(10)               -- 等待 MCU 就绪
    uart.send(message .. "\r\n")
    log.info("UART_TX", message)
end

-- 处理服务器下发的具体命令任务
local function handle_sa_command(sock, frame)
    if frame.type ~= "CMD" then return end
    local payload_map = parse_payload(frame.payload)
    if payload_map.devID and payload_map.devID ~= imei then return end

    if frame.cmd == "CG" then
        -- 查询参数命令：改为发送 AM 帧
        local mid_mcu = next_id()
        am_tx(mid_mcu, "CMD", "CG", "devID=" .. imei)
        local params = collect_config_params(5000)
        if params then
            as_tx(sock, frame.id, "RSP", "CG", "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";params=" .. params)
        end
    elseif frame.cmd == "CS" then
        -- 设置参数命令：改为发送 AM 帧
        local param_key, param_value
        for k, v in pairs(payload_map) do
            if k ~= "devID" and k ~= "gv" then param_key, param_value = k, v break end
        end
        if param_key and param_value then
            local mid_mcu = next_id()
            local payload = "devID=" .. imei .. ";" .. param_key .. "=" .. param_value
            am_tx(mid_mcu, "CMD", "CS", payload)
            local ack_line = wait_for_uart_line(3000, function(l) return l == "ACK:0" end)
            as_tx(sock, frame.id, "RSP", "CS", "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";ack=" .. (ack_line and "0" or "1"))
        end
    elseif frame.cmd == "MS" or frame.cmd == "MG" then
        -- 采样命令：先回 ACK，触发测量后再等 MR 上报
        as_tx(sock, frame.id, "ACK", frame.cmd, "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";ack=1")
        
        local mid_mcu = next_id()
        am_tx(mid_mcu, "CMD", frame.cmd, "devID=" .. imei)
        -- 将服务器的 MID 发布出去，让串口监听任务能关联上报
        sys.publish("PENDING_SERVER_MID", frame.id)
    elseif frame.cmd == "MD" then
        -- 链路查询命令
        as_tx(sock, frame.id, "RSP", "MD", modem_payload(last_mcu_alive))
    end
end

-- Task 1: Persistent Network Connection and Downlink Listener
-- 任务一：持久网络连接及下行监听任务
-- 负责建立 UDP 长连接，维持在线状态，处理服务器发来的数据
local function network_task()
    while true do
        if socket.localIP() == "0.0.0.0" or socket.localIP() == nil then
            sys.waitUntil("IP_READY")
        end
        log.info("APP", "Network Ready, connecting to " .. config.SERVER_IP)

        netc = socket.create(nil, "udp_app")
        socket.config(netc, nil, true)

        if socket.on then
            -- 真机/新固件：异步回调，有数据时主动通知
            socket.on(netc, function(id, event)
                if event == socket.EVENT_RX then
                    local succ, data = socket.rx(netc)
                    if succ and type(data) == "string" and #data > 0 then
                        log.info("UDP_RX", data)
                        local frame = parse_sa_frame(data)
                        if frame then handle_sa_command(netc, frame) end
                    end
                elseif event == socket.EVENT_CLOSE then
                    sys.publish("SOCKET_CLOSED")
                end
            end)
        else
            -- PC 模拟器兼容：启动后台轮询任务拉取下行数据
            log.warn("APP", "No socket.on, using polling rx (simulator mode)")
            sys.taskInit(function()
                while netc do
                    local succ, data = socket.rx(netc)
                    if succ and type(data) == "string" and #data > 0 then
                        log.info("UDP_RX", data)
                        local frame = parse_sa_frame(data)
                        if frame then handle_sa_command(netc, frame) end
                    end
                    sys.wait(200)
                end
            end)
        end

        if socket.connect(netc, config.SERVER_IP, config.SERVER_PORT) then
            log.info("APP", "UDP Connected to " .. config.SERVER_IP .. ":" .. config.SERVER_PORT)
            pm.power(pm.WORK_MODE, config.POWER_MODE)
            -- 真机靠 socket.on CLOSE 事件触发；模拟器中该事件不会来，设超长超时兜底
            sys.waitUntil("SOCKET_CLOSED", 86400000)
            log.warn("APP", "Socket closed, reconnecting...")
        else
            log.error("APP", "UDP Connect Failed, retry in 5s")
            sys.wait(5000)
        end

        if netc then socket.close(netc) netc = nil end
    end
end

-- Task 2: Periodic MCU Data Request (Timer-based)
-- 任务二：定时上报任务
-- 根据 RPT_INT 时间定期请求 MCU 数据，监控 MCU 是否在线
local function timer_task()
    while true do
        sys.wait(config.REPORT_INTERVAL)
        log.info("APP", "Periodic Report Cycle")
        
        local mcu_responded = false
        for retry = 1, 3 do
            local mid_mcu = next_id()
            am_tx(mid_mcu, "CMD", "MG", "devID=" .. imei)

            -- 协议 §3.4：MCU 收到 MG/MS 命令必须立即回 MA,ACK,MG/MS
            -- 4G 只以此帧作为 MCU 存活判定，不等 MR 数据（MR 是后续异步帧）
            local end_time = mcu.ticks() + 2000
            while mcu.ticks() < end_time do
                local ok, line = sys.waitUntil("UART_RECV", 500)
                if ok and line then
                    local p6 = split_n(line, ",", 6)
                    if #p6 >= 5 and p6[1] == "MA" and p6[4] == "ACK"
                       and (p6[5] == "MG" or p6[5] == "MS") then
                        -- 收到 MCU 对采样命令的即时 ACK → MCU 在线
                        mcu_responded = true
                        break
                    elseif string.sub(line, 1, 2) == "MA" then
                        -- 其他 MA 帧（如异步 EVT MR）：重新发布给 uart_task 处理
                        sys.publish("UART_RECV", line)
                    end
                end
            end

            if mcu_responded then break end
            log.warn("APP", "MCU MG Timeout, retry " .. retry)
        end

        if not mcu_responded then
            log.error("APP", "MCU Dead Detection")
            last_mcu_alive = false
            -- 连续三次超时，上报主板离线告警
            as_tx(netc, next_id(), "EVT", "MD", modem_payload(false))
        else
            last_mcu_alive = true
        end
    end
end

-- Task 3: UART Listener for MCU Reports (Forwarding MR)
-- 任务三：串口监听任务 (负责转发 MR 数据和协议确认)
-- 实时接收 MCU 发来的 "MCU:..." 测量数据，并转发给服务器
local function uart_task()
    local pending_mid = nil
    -- 订阅来自服务器命令任务关联的 MID
    sys.subscribe("PENDING_SERVER_MID", function(mid) pending_mid = mid end)
    
    while true do
        local result, line = sys.waitUntil("UART_RECV", 30000)
        if result and line then
            if string.sub(line, 1, 2) == "MA" then
                -- V1.1 协议: 接收单片机上报的 MA,1,mid,EVT,MR,... 数据
                local p6 = split_n(line, ",", 6)
                if #p6 == 6 and p6[4] == "EVT" and p6[5] == "MR" then
                    last_mcu_alive = true
                    local mcu_mid = p6[3]
                    local mcu_payload = p6[6]
                    
                    -- 在 devID=... 后面动态插入 4G 网关版本信息 (gv=4G2.0.0)
                    local new_payload = string.gsub(mcu_payload, "(devID=[^;]+;)", "%1gv=4G" .. config.VERSION .. ";")
                    
                    local report_id = pending_mid or mcu_mid
                    pending_mid = nil
                    
                    -- 转发完整测量结果到服务器
                    as_tx(netc, report_id, "EVT", "MR", new_payload)
                    
                    -- 按照 V1.1 协议要求，给 MCU 回复 ACK 确认，防止 MCU 重发
                    uart.send("AM,1," .. mcu_mid .. ",ACK,MR,devID=" .. imei .. ";ack=1\r\n")
                end
            elseif string.sub(line, 1, 4) == "MCU:" then
                -- 兼容 V1.0 旧协议
                last_mcu_alive = true
                local report_id = pending_mid or next_id()
                pending_mid = nil
                
                as_tx(netc, report_id, "EVT", "MR", mr_payload(line))
                local mid_mcu = string.match(line, "mid=(%d+)") or "0000"
                uart.send("AM,1," .. mid_mcu .. ",ACK,MR,devID=" .. imei .. ";ack=1\r\n")
            elseif line == "ACK:0" then
                -- 常见的 MCU 响应
            end
        end
    end
end

-- 应用入口启动函数
function app.start()
    led.init()
    uart.init()
    
    -- 临时固定模组的长串数字 ID 为 DEV 格式，方便与服务器联调
    imei = "DEV8888"
    
    -- 注册串口底层数据接收回调并发布到 sys 消息中心
    uart.onReceive(function(line)
        log.info("UART_RX", line)
        sys.publish("UART_RECV", line)
    end)
    
    -- 启动三大核心并行任务
    sys.taskInit(network_task) -- 网络维持
    sys.taskInit(timer_task)   -- 定时上报
    sys.taskInit(uart_task)    -- 业务转发
    
    -- 状态指示闪烁任务
    sys.taskInit(function()
        while true do
            led.blink(100)
            sys.wait(10000)
        end
    end)
end

return app
