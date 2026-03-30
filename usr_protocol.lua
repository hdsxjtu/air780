local sys = require("sys")
local config = require("usr_config")
local mobile = require("mobile")
local uart = require("usr_uart")

local proto = {}

-- 协议 ACK 状态码定义 (§3.7)
proto.ACK_OFFLINE     = "0" -- 单片机未响应或忙碌
proto.ACK_SUCCESS     = "1" -- 指令执行成功/已受理
proto.ACK_ID_MISMATCH = "2" -- 设备 ID 不匹配，拒绝执行

local uart_locked = false
local next_msg_id = 3334    -- mid 计数器 (3334-6666 用于模组主动心跳)

-- 辅助函数：按分隔符拆分字符串
function proto.split(str, reps)
    local resultStrList = {}
    string.gsub(str, '[^' .. reps .. ']+', function(w)
        table.insert(resultStrList, w)
    end)
    return resultStrList
end

-- 辅助函数：按分隔符拆分字符串为固定数量的片段
function proto.split_n(str, sep, max_parts)
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
function proto.next_id()
    next_msg_id = next_msg_id + 1
    if next_msg_id > 6666 then
        next_msg_id = 3334
    end
    return tostring(next_msg_id)
end

-- 解析 payload 字符串 (did=XXX;gv=YYY) 为表结构
function proto.parse_payload(payload)
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
function proto.build_frame(header, mid, frame_type, cmd, payload)
    return table.concat({header, "1", mid, frame_type, cmd, payload or ""}, ",")
end

-- 向服务器发送 AS 帧
function proto.as_tx(sock, mid, frame_type, cmd, payload)
    if sock then
        local message = proto.build_frame("AS", mid, frame_type, cmd, payload)
        socket.tx(sock, message)
        log.info("UDP_TX", message)
    end
end

-- 构建模组状态 (MD) 的载荷部分
function proto.modem_payload(imei, mcu_alive, lat, lng)
    local rsrp = -99
    if mobile and mobile.rsrp then
        rsrp = mobile.rsrp()
    end
    local mdead = mcu_alive and "0" or "1"
    local payload = "devID=" .. imei .. ";gv=4G" .. config.VERSION .. ";mod=Air780E;rsrp=" .. tostring(rsrp) .. ";net=4G;mdead=" .. mdead
    if lat and lng then
        payload = payload .. ";lat=" .. lat .. ";lng=" .. lng
    end
    return payload
end

-- 解析服务器下发的 SA 帧
function proto.parse_sa_frame(data)
    local p6 = proto.split_n(data, ",", 6)
    if #p6 == 6 and p6[1] == "SA" then
        local clean_payload = string.gsub(p6[6] or "", "[\r\n]", "")
        return {ver = p6[2], id = p6[3], type = p6[4], cmd = p6[5], payload = clean_payload}
    end
    return nil
end

-- [[ 核心逻辑：等待串口回复 ]]
function proto.wait_for_uart_line(timeout_ms, matcher)
    local end_time = mcu.ticks() + (timeout_ms or 1500)
    while mcu.ticks() < end_time do
        -- 缩短单次订阅时间为 200ms，以提高响应灵敏度
        local ok, line = sys.waitUntil("UART_RECV", 200)
        if ok and line then
            if matcher(line) then
                return line
            else
                -- 如果收到了 MA 开头的帧但不是当前请求等待的，重新发布，防止丢包
                if string.find(line, "^MA,1,") then
                    sys.publish("UART_RECV", line)
                end
            end
        end
    end
    return nil
end

-- [[ 高级逻辑：带重试的 MCU 请求 (3 次尝试，每次 1.5s) ]]
function proto.request_mcu(mid, cmd, payload, timeout_ms, retries)
    local max_retries = retries or 3
    local wait_ms = timeout_ms or 1500
    
    for i = 1, max_retries do
        log.info("PROTO", "MCU Request: " .. cmd .. " (Try " .. i .. "/" .. max_retries .. ")")
        proto.am_tx(mid, "CMD", cmd, payload)
        
        local resp = proto.wait_for_uart_line(wait_ms, function(l)
            -- 寻找符合当前指令和 MID 的 RSP 或 ACK
            return string.find(l, "MA,1," .. mid) and (string.find(l, ",RSP," .. cmd) or string.find(l, ",ACK," .. cmd))
        end)
        
        if resp then
            return resp -- 成功拿到应答，直接返回
        end
        log.warn("PROTO", "MCU Request Timeout: " .. cmd .. " (Attempt " .. i .. " failed)")
    end
    
    log.error("PROTO", "MCU Request Failed: " .. cmd .. " after " .. max_retries .. " retries")
    return nil -- 三次全失败
end

-- [[ 核心逻辑：带资源保护的串口发送 ]]
function proto.am_tx(mid, frame_type, cmd, payload)
    while uart_locked do
        sys.waitUntil("UART_UNLOCK", 500)
    end
    uart_locked = true
    
    local message = proto.build_frame("AM", mid, frame_type, cmd, payload)
    uart.send("\x00")
    sys.wait(10)
    uart.send(message .. "\r\n")
    log.info("UART_TX", message)
    
    uart_locked = false
    sys.publish("UART_UNLOCK")
end

-- 导出串口锁状态，供其他单个发送逻辑使用
function proto.is_uart_locked()
    return uart_locked
end

function proto.set_uart_locked(state)
    uart_locked = state
    if not state then
        sys.publish("UART_UNLOCK")
    end
end

return proto
