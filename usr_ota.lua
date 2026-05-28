local sys = require("sys")
local proto = require("usr_protocol")
local ota = {}

-- 1. Pure-Lua standard CRC32 (polynomial 0xEDB88320)
local function crc32_file(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local crc = 0xFFFFFFFF
    local chunk_size = 1024
    
    while true do
        local bytes = f:read(chunk_size)
        if not bytes or #bytes == 0 then break end
        
        for i = 1, #bytes do
            local b = string.byte(bytes, i)
            crc = bit.bxor(crc, b)
            for j = 1, 8 do
                if bit.band(crc, 1) ~= 0 then
                    crc = bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
                else
                    crc = bit.rshift(crc, 1)
                end
            end
        end
    end
    f:close()
    return bit.bnot(crc)
end

-- 2. Hex encoder helper
local function to_hex(str)
    local hex = {}
    for i = 1, #str do
        table.insert(hex, string.format("%02x", string.byte(str, i)))
    end
    return table.concat(hex)
end

-- 3. 启动 4G 模组 OTA 升级
function ota.start(url)
    if not url or url == "" then
        log.error("OTA", "Empty URL provided for OTA")
        return false
    end
    
    log.info("OTA", "Starting direct HTTP FOTA from: " .. url)
    
    local code, headers, body = http.request("GET", url, nil, nil, {fota = true}).wait()
    log.info("OTA", "FOTA HTTP Response Code: " .. tostring(code))
    
    local status_name = "unknown"
    if code == 200 then
        status_name = "success"
        log.info("OTA", "Upgrade package downloaded successfully. Rebooting in 3s...")
        sys.timerStart(function()
            log.info("OTA", "System Rebooting for OTA update...")
            rtos.reboot()
        end, 3000)
    else
        status_name = "error_download_" .. tostring(code)
        log.error("OTA", "FOTA Failed: HTTP download error " .. tostring(code))
    end

    sys.publish("FOTA_STATE", status_name, code)
    return true
end

-- 4. 启动单片机 (MCU) IAP 升级
function ota.start_mcu(url)
    if not url or url == "" then
        log.error("OTA", "Empty MCU URL provided")
        sys.publish("FOTA_STATE", "error_mcu_empty_url", -1)
        return false
    end
    
    local file_path = "/mcu_fw.bin"
    log.info("OTA", "Downloading MCU binary from: " .. url)
    
    -- 使用 dst 属性直接将包流式保存到本地 flash 文件系统，防止内存溢出
    local code, headers, body = http.request("GET", url, nil, nil, {dst = file_path}).wait()
    log.info("OTA", "MCU download result code: " .. tostring(code))
    
    if code ~= 200 then
        log.error("OTA", "MCU download FAILED. Code: " .. tostring(code))
        sys.publish("FOTA_STATE", "error_mcu_download", code)
        return false
    end
    
    -- 获取文件大小
    local file_size = lfs.fileSize(file_path)
    if not file_size or file_size == 0 or file_size > (110 * 1024) then
        log.error("OTA", "Invalid MCU file size: " .. tostring(file_size))
        sys.publish("FOTA_STATE", "error_mcu_size", file_size)
        return false
    end
    
    -- 计算 CRC32
    local file_crc = crc32_file(file_path)
    if not file_crc then
        log.error("OTA", "MCU CRC32 calculation failed")
        sys.publish("FOTA_STATE", "error_mcu_crc", 0)
        return false
    end
    
    log.info("OTA", string.format("MCU FW verified. Size: %d bytes, CRC32: %u. Starting UART flashing...", file_size, file_crc))
    
    -- (1) 发送 OU (Start) 指令给单片机
    local mid = "9999"
    local init_payload = string.format("size=%d;crc=%u", file_size, file_crc)
    local resp = proto.request_mcu(mid, "OU", init_payload, 2000, 3)
    if not resp then
        log.error("OTA", "MCU rejected IAP initialization (OU Command)")
        sys.publish("FOTA_STATE", "error_mcu_init_rejected", 0)
        return false
    end
    
    -- (2) 开始分块读取并发送 OD (Data) 指令
    local f = io.open(file_path, "rb")
    if not f then
        sys.publish("FOTA_STATE", "error_mcu_read_fail", 0)
        return false
    end
    
    local block_idx = 0
    local chunk_size = 128
    local success = true
    
    while true do
        local chunk = f:read(chunk_size)
        if not chunk or #chunk == 0 then break end
        
        local hex_chunk = to_hex(chunk)
        local data_payload = string.format("block=%d;len=%d;data=%s", block_idx, #chunk, hex_chunk)
        
        -- 对每个分包进行带重试的发送，最多重试 5 次，每次 1.5s 响应
        local data_resp = proto.request_mcu(mid, "OD", data_payload, 1500, 5)
        if not data_resp then
            log.error("OTA", "Failed to transmit block " .. block_idx)
            success = false
            break
        end
        
        block_idx = block_idx + 1
        -- 释放 CPU 给系统其他任务喘息
        sys.wait(10)
    end
    f:close()
    
    if not success then
        sys.publish("FOTA_STATE", "error_mcu_transmission", block_idx)
        return false
    end
    
    -- (3) 发送 OE (End) 指令，触发 MCU 校验及搬运重启
    log.info("OTA", "All blocks sent successfully. Sending commit command (OE)...")
    local end_resp = proto.request_mcu(mid, "OE", "status=commit", 3000, 3)
    if not end_resp then
        log.error("OTA", "MCU failed to commit and jump (OE Command)")
        sys.publish("FOTA_STATE", "error_mcu_commit_failed", 0)
        return false
    end
    
    log.info("OTA", "MCU Upgrade completed successfully. MCU is now rebooting.")
    sys.publish("FOTA_STATE", "success", 0)
    return true
end

return ota
