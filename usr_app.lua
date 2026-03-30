local sys = require("sys")
local config = require("usr_config")
local led = require("usr_led")
local lbs = require("usr_lbs")
local uart = require("usr_uart")

-- ========================================================================
-- 核心架构说明 (Architecture Overview):
-- 1. 本程序采用“多任务并发”架构，通过 sys.taskInit 启动四个并行的任务人。
-- 2. 任务之间通过 sys.publish (发信号) 和 sys.waitUntil (等信号) 进行沟通。
-- 3. 所有的 sys.wait (休眠) 都会触发硬件底层的自动降功耗，实现“快心跳、慢采样”。
-- ========================================================================

local app = {}
local netc = nil            -- 全局网络连接句柄 (UDP Socket)
local next_msg_id = 3334    -- mid 计数器 (3334-6666 用于模组主动心跳)
local last_mcu_alive = true -- 记录单片机是否正常（心跳用）
local imei = ""             -- 设备唯一标识 (devID)，启动后会与单片机自动同步
local uart_locked = false   -- UART 串口资源互斥锁

-- 协议 ACK 状态码定义 (§3.7)
local ACK_OFFLINE     = "0" -- 单片机未响应或忙碌
local ACK_SUCCESS     = "1" -- 指令执行成功/已受理
local ACK_ID_MISMATCH = "2" -- 设备 ID 不匹配，拒绝执行


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

-- 生成下一个消息 ID (3334-6666 循环，用于 4G 模组自主发起)
local function next_id()
    next_msg_id = next_msg_id + 1
    if next_msg_id > 6666 then
        next_msg_id = 3334
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

-- ========================================================================
-- 核心工具：串口收发与同步 (UART Utilities)
-- ========================================================================

-- [[ 核心逻辑：等待串口回复 ]]
-- 逻辑：向单片机发指令后，任务会在这里“睡觉”等待，直到串口有符合 matcher 的行返回或超时。
local function wait_for_uart_line(timeout_ms, matcher)
    local end_time = mcu.ticks() + timeout_ms
    while mcu.ticks() < end_time do
        -- 这里是“睡觉”点：sys.waitUntil 会让出 CPU，直到串口驱动发出 "UART_RECV" 信号
        local ok, line = sys.waitUntil("UART_RECV", 500)
        if ok and line and matcher(line) then
            return line
        end
    end
    return nil -- 超时未等到
end

-- 向 MCU 发送 AM 帧
-- 协议 §3.4：MCU 可能处于休眠状态，必须先发 0x00 唤醒字节，
-- 等待 10ms 使 MCU 完成唤醒，再发送正式帧内容。
-- [[ 核心逻辑：带资源保护的串口发送 ]]
-- 协议 §3.4：MCU 可能处于休眠状态，必须先发 0x00 唤醒字节，并等待 10ms。
-- 此处增加了信号驱动锁，防止多个任务同时操作串口导致字节交织冲突。
local function am_tx(mid, frame_type, cmd, payload)
    -- 1. 锁等待：如果串口正在被占，就阻塞等待解锁信号
    while uart_locked do
        sys.waitUntil("UART_UNLOCK", 500)
    end
    
    -- 2. 上锁
    uart_locked = true
    
    -- 3. 发送序列
    local message = build_frame("AM", mid, frame_type, cmd, payload)
    uart.send("\x00")          -- 唤醒字节
    sys.wait(10)               -- [挂起点] 等待 MCU 完成唤醒
    uart.send(message .. "\r\n")
    log.info("UART_TX", message)
    
    -- 4. 解锁并广播信号
    uart_locked = false
    sys.publish("UART_UNLOCK")
end

-- [[ 业务中枢：处理服务器指令 (SA 帧) ]]
-- 逻辑：UDP 收到服务器数据后，会调用此函数。它是 4G 模组的“大脑”。
local function handle_sa_command(sock, frame)
    if frame.type ~= "CMD" then return end
    local payload_map = parse_payload(frame.payload)
    
    -- --- 第一步：严格 ID 校验 (拦截器) ---
    -- 如果服务器发来的 devID 与本设备不符，直接由于 4G 模组拦截，不发给单片机。
    if payload_map.devID and payload_map.devID ~= imei then
        log.error("APP", "ID Mismatch: expected " .. imei .. " but got " .. payload_map.devID)
        as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. imei .. ";ack=" .. ACK_ID_MISMATCH) 
        return 
    end

    -- --- 第二步：针对 CG/CS 指令的处理 ---
    if frame.cmd == "CG" or frame.cmd == "CS" then
        -- 如果是写配置 (CS)，模组先检查 RPT_INT，如果是改采样周期，本地也要同步。
        if frame.cmd == "CS" then
            if payload_map.RPT_INT then
                config.REPORT_INTERVAL = tonumber(payload_map.RPT_INT) * 60 * 1000
                log.info("APP", "Local REPORT_INTERVAL updated to " .. config.REPORT_INTERVAL .. "ms")
            end
        end

        -- --- 第三步：转发给单片机与其交互 ---
        -- 调用 am_tx 发送。注意：am_tx 内部会自动执行 0x00 唤醒逻辑。
        am_tx(frame.id, "CMD", frame.cmd, frame.payload)
        
        -- 在这里睡觉等待单片机的确认响应 (MA 帧)
        local ack_line = wait_for_uart_line(3000, function(l)
            -- 匹配特定的指令 ID 和命令类型 (匹配 MA,1,ID,RSP,CMD)
            return string.find(l, "MA,1," .. frame.id) and string.find(l, ",RSP," .. frame.cmd)
        end)
        
        if ack_line then
            -- 拿到了单片机的回复，解析数据
            local p6 = split_n(ack_line, ",", 6)
            local mcu_payload = p6[6] or ""
            local mcu_map = parse_payload(mcu_payload)
            
            -- 自同步逻辑：从单片机的回复里拉取最新的 RPT_INT 和 devID 以防 4G 模组丢配置。
            if mcu_map.RPT_INT then
                config.REPORT_INTERVAL = tonumber(mcu_map.RPT_INT) * 60 * 1000
            end
            if mcu_map.devID then
                imei = mcu_map.devID
            end
            
            -- 将单片机给出的答案返回给服务器
            as_tx(sock, frame.id, "RSP", frame.cmd, mcu_payload)
        else
            -- 单片机没理你，回复服务器：ack=0 (单片机离线)
            as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";ack=" .. ACK_OFFLINE)
        end
    elseif frame.cmd == "MS" or frame.cmd == "MG" then
        -- 采样命令：透传服务器单号，不再盲目回 ACK
        am_tx(frame.id, "CMD", frame.cmd, "devID=" .. imei)
        
        -- 等待 MCU 的第一个反馈
        local first_resp = wait_for_uart_line(3000, function(l)
            return string.find(l, "MA,1," .. frame.id) and (string.find(l, ",ACK," .. frame.cmd) or string.find(l, ",RSP," .. frame.cmd))
        end)
        
        if first_resp then
            local p6 = split_n(first_resp, ",", 6)
            local mcu_type = p6[4] or "RSP"
            local mcu_payload = parse_payload(p6[6])
            local mcu_ack = mcu_payload.ack or "0"
            
            -- 将 MCU 的真实状态（受理或拒绝）透传给服务器
            as_tx(sock, frame.id, mcu_type, frame.cmd, "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";ack=" .. mcu_ack)
            
            -- 只有当 MCU 明确回复 ACK(ack=1) 时，才建立 PENDING_SERVER_MID 关联，等待后续 MR
            if mcu_type == "ACK" and mcu_ack == ACK_SUCCESS then
                sys.publish("PENDING_SERVER_MID", frame.id)
            end
        else
            -- 串口超时无应答，向上位机回复拒绝执行
            as_tx(sock, frame.id, "RSP", frame.cmd, "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";ack=" .. ACK_OFFLINE)
        end
    elseif frame.cmd == "MD" then
        -- 链路查询命令
        as_tx(sock, frame.id, "RSP", "MD", modem_payload(last_mcu_alive))
    end
end

-- ========================================================================
-- 四大并行独立任务 (Parallel Tasks Context)
-- ========================================================================

-- [[ 任务 1：核心网络任务 ]]
-- 负责 UDP 链路的建立、重连和服务器下行数据的监听分配。
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
            
            -- 联网成功后，立即向单片机发起一次 CG 链路查询，同步初始配置值（如 RPT_INT）
            sys.taskInit(function()
                sys.wait(2000) -- 等待网络稳定
                log.info("APP", "Startup Sync: Querying MCU for config")
                local sync_mid = next_id()
                am_tx(sync_mid, "CMD", "CG", "devID=" .. imei)
                -- 这里通过已注册的 UART 监听自动处理返回，不需要重复等待
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

-- Task 2: Periodic MCU Data Request (Timer-based, High Power)
-- 任务二：定时上报任务（由于涉及单片机唤醒和传感器测量，设置为长周期，如 1 小时）
local function timer_task()
    while true do
        sys.wait(config.REPORT_INTERVAL)
        log.info("APP", "Long Period Measurement Cycle")
        
        local mcu_responded = false
        for retry = 1, 3 do
            local mid_mcu = next_id()
            am_tx(mid_mcu, "CMD", "MG", "devID=" .. imei)

            local end_time = mcu.ticks() + 2000
            while mcu.ticks() < end_time do
                local ok, line = sys.waitUntil("UART_RECV", 500)
                if ok and line then
                    local p6 = split_n(line, ",", 6)
                    if #p6 >= 5 and p6[1] == "MA" and p6[4] == "ACK" and (p6[5] == "MG" or p6[5] == "MS") then
                        mcu_responded = true
                        break
                    elseif string.find(line, "^MA,1,") then
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

-- Task 3: Lightweight Link Maintenance (Heartbeat, Low Power)
-- 任务 3：链路维持心跳（仅 4G 发包，不唤醒单片机，频率建议 2 分钟）
local function heartbeat_task()
    while true do
        sys.wait(config.HEARTBEAT_INTERVAL)
        -- 仅在网络连接正常时发送心跳报文 (MD: Link Check)
        if netc then
            log.info("APP", "Heartbeat: Keep NAT Alive")
            as_tx(netc, next_id(), "RSP", "MD", modem_payload(last_mcu_alive))
        end
        -- 提醒模组进入轻度休眠（Light Sleep）
        pm.request(pm.LIGHT_SLEEP)
    end
end

-- 任务 4：串口监听任务 (负责转发所有从单片机主动或被动发回的数据)
local function uart_task()
    while true do
        local result, line = sys.waitUntil("UART_RECV", 30000)
        if result and line then
            if string.find(line, "^MA,1,") then
                -- V1.1 协议: 格式 MA,1,mid,type,cmd,payload
                local p6 = split_n(line, ",", 6)
                if #p6 == 6 then
                    local mcu_mid = p6[3]
                    local mcu_type = p6[4]
                    local mcu_cmd = p6[5]
                    local mcu_payload = p6[6]
                    
                    last_mcu_alive = true
                    
                    -- 处理测量结果（MR）的上送
                    if mcu_cmd == "MR" then
                        -- 插入 4G 模组版本信息（gv=...）
                        local updated_payload = string.gsub(mcu_payload, "(devID=[^;]+;)", "%1gv=4G" .. config.VERSION .. ";")
                        
                        -- 透明转发：直接使用单片机带上来的 mid
                        -- 若 mid 为 0001-3333 则为 MCU 事件，3334-6666 为 4G 定时任务，6667-9999 为服务器下发
                        as_tx(netc, mcu_mid, mcu_type, "MR", updated_payload)
                        
                        -- 根据协议，MR 需要 4G 回应 ACK
                        -- 此单次发送也受锁保护，防止截断正在进行的 am_tx 指令
                        while uart_locked do sys.waitUntil("UART_UNLOCK", 100) end
                        uart_locked = true
                        uart.send("AM,1," .. mcu_mid .. ",ACK,MR,devID=" .. imei .. ";ack=" .. ACK_SUCCESS .. "\r\n")
                        uart_locked = false
                        sys.publish("UART_UNLOCK")
                    end
                end
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
    
    -- 启动核心并行任务
    sys.taskInit(network_task)   -- 网络维持
    sys.taskInit(heartbeat_task) -- 链路心跳（轻量）
    sys.taskInit(timer_task)     -- 定时上报（重量）
    sys.taskInit(uart_task)      -- 业务转发
    
    -- 状态指示闪烁任务
    sys.taskInit(function()
        while true do
            led.blink(100)
            sys.wait(10000)
        end
    end)
end

return app
