local sys   = require("sys")
local proto = require("usr_protocol")
local ota   = {}

-- 获取文件大小 (标准 io，不依赖 lfs 模块)
local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- ============================================================
-- 本地固件文件路径 & 大小限制
-- ============================================================
local MCU_FW_PATH    = "/mcu_fw.bin"
local MCU_FW_MAX_SIZE = 110 * 1024   -- 110 KB (运行区上限)

-- ============================================================
-- 内部工具: CRC32 (polynomial 0xEDB88320)
-- ============================================================
local function crc32_file(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local crc = 0xFFFFFFFF
    local chunk_count = 0
    while true do
        local bytes = f:read(1024)
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
        chunk_count = chunk_count + 1
        -- 每 1KB 让出 CPU 给看门狗（嵌入式Lua CRC很慢，必须高频让步）
        sys.wait(5)
    end
    f:close()
    return bit.bnot(crc)
end

-- 内部工具: 字节串转16进制字符串
local function to_hex(str)
    local hex = {}
    for i = 1, #str do
        table.insert(hex, string.format("%02x", string.byte(str, i)))
    end
    return table.concat(hex)
end

-- ============================================================
-- 命令 1: FD — Firmware Download (强制下载)
-- 从服务器 HTTP 下载固件到本地 /mcu_fw.bin
-- 只操作4G模组本地存储，完全不接触单片机
--
-- 成功: publish("FOTA_STATE", "fd_ok",   文件大小)
-- 失败: publish("FOTA_STATE", "fd_error_xxx", 错误码)
-- ============================================================
function ota.download(url)
    if not url or url == "" then
        log.error("OTA:FD", "Empty URL")
        sys.publish("FOTA_STATE", "fd_error_empty_url", -1)
        return false
    end

    log.info("OTA:FD", "Downloading: " .. url)

    -- 诊断：下载前文件系统状态
    local f_before = io.open(MCU_FW_PATH, "rb")
    if f_before then
        local old_size = f_before:seek("end")
        f_before:close()
        log.info("OTA:FD", "[DIAG] Old file exists, size=" .. tostring(old_size))
    else
        log.info("OTA:FD", "[DIAG] No old file at " .. MCU_FW_PATH)
    end

    -- 删除旧文件
    local rm_ok, rm_err = os.remove(MCU_FW_PATH)
    log.info("OTA:FD", string.format("[DIAG] Remove old: ok=%s err=%s", tostring(rm_ok), tostring(rm_err)))

    -- 流式写入本地文件系统
    local code = http.request("GET", url, nil, nil, {dst = MCU_FW_PATH}).wait()
    log.info("OTA:FD", "HTTP result: " .. tostring(code))

    if code == 200 then
        -- 诊断：下载后立即检查
        local f_after = io.open(MCU_FW_PATH, "rb")
        if f_after then
            local new_size = f_after:seek("end")
            f_after:close()
            log.info("OTA:FD", string.format("[DIAG] File created OK, size=%d bytes", new_size))
        else
            log.error("OTA:FD", "[DIAG] File NOT FOUND after download!")
        end
    end

    if code ~= 200 then
        log.error("OTA:FD", "Download FAILED. HTTP code: " .. tostring(code))
        pcall(os.remove, MCU_FW_PATH)
        sys.publish("FOTA_STATE", "fd_error_http", code)
        return false
    end

    -- 校验文件大小
    local fsize = file_size(MCU_FW_PATH)
    if not fsize or fsize == 0 or fsize > MCU_FW_MAX_SIZE then
        log.error("OTA:FD", "Invalid file size: " .. tostring(fsize))
        pcall(os.remove, MCU_FW_PATH)
        sys.publish("FOTA_STATE", "fd_error_size", fsize or 0)
        return false
    end

    -- 计算并验证 CRC32
    log.info("OTA:FD", "[DIAG] Starting CRC32, file=" .. tostring(fsize) .. " bytes ...")
    local crc_start = os.clock()
    local crc = crc32_file(MCU_FW_PATH)
    local crc_elapsed = os.clock() - crc_start
    log.info("OTA:FD", string.format("[DIAG] CRC32 done in %.3fs, result=%s", crc_elapsed, tostring(crc)))
    if not crc then
        log.error("OTA:FD", "CRC32 calculation failed")
        pcall(os.remove, MCU_FW_PATH)
        sys.publish("FOTA_STATE", "fd_error_crc", 0)
        return false
    end

    log.info("OTA:FD", string.format("Download OK. Size=%d bytes, CRC32=%u", fsize, crc))
    sys.publish("FOTA_STATE", "fd_ok", {size = fsize, crc = crc})
    return true
end

-- ============================================================
-- 命令 2: FU — Firmware Upgrade (强制升级)
-- 使用本地已存储的 /mcu_fw.bin 对单片机执行 IAP 刷写
-- 自动发送 BOOT 命令让 MCU 进入 bootloader，无需手动操作
-- 传输失败时自动发 RESET，使单片机回到救砖状态供下次重试
--
-- 成功: publish("FOTA_STATE", "fu_ok",   0)
-- 失败: publish("FOTA_STATE", "fu_error_xxx", 错误信息)
-- ============================================================
function ota.flash()
    -- 检查本地固件文件是否存在且有效
    local fsize = file_size(MCU_FW_PATH)
    if not fsize or fsize == 0 or fsize > MCU_FW_MAX_SIZE then
        log.error("OTA:FU", "No valid firmware at " .. MCU_FW_PATH .. " (size=" .. tostring(fsize) .. ")")
        sys.publish("FOTA_STATE", "fu_error_no_file", 0)
        return false
    end

    -- 重新校验 CRC（防止文件在存储期间损坏）
    local file_crc = crc32_file(MCU_FW_PATH)
    if not file_crc then
        log.error("OTA:FU", "CRC32 failed on local file")
        sys.publish("FOTA_STATE", "fu_error_crc", 0)
        return false
    end

    log.info("OTA:FU", string.format("Starting flash. Size=%d, CRC32=%u", fsize, file_crc))

    local mid = "9999"

    -- ----------------------------------------------------------
    -- (0) 自动进入 BOOT 模式：发送 BOOT 命令给 MCU APP
    --     APP 收到后写 RTC 魔术字 0xB007B007 → 复位
    --     Bootloader 启动后检测魔术字 → 留在救砖模式
    -- ----------------------------------------------------------
    log.info("OTA:FU", "Sending BOOT to MCU APP (force enter bootloader)...")
    local boot_resp = proto.request_mcu(mid, "BOOT", "", 700, 3)
    if not boot_resp then
        log.error("OTA:FU", "BOOT failed — MCU may be offline")
        sys.publish("FOTA_STATE", "fu_error_ou", 0)
        return false
    end
    log.info("OTA:FU", "BOOT ACK received, MCU is rebooting into bootloader...")
    -- 等待 MCU 复位 + Bootloader 初始化 (约 2s)
    sys.wait(2500)

    -- ----------------------------------------------------------
    -- (1) OU: 通知 Boot 准备升级 → Boot 擦除 APP 运行区
    --     超时 5s，最多重试 3 次
    -- ----------------------------------------------------------
    local init_payload = string.format("size=%d;crc=%u", fsize, file_crc)
    local ou_resp = proto.request_mcu(mid, "OU", init_payload, 5000, 3)
    if not ou_resp then
        log.error("OTA:FU", "OU rejected by Boot (MCU not in boot mode?)")
        sys.publish("FOTA_STATE", "fu_error_ou", 0)
        return false
    end
    log.info("OTA:FU", "OU OK — APP run area erased")

    -- ----------------------------------------------------------
    -- (2) OD: 分块发送固件数据（128字节/块）
    --     每块超时 2s，失败重试 5 次
    -- ----------------------------------------------------------
    local f = io.open(MCU_FW_PATH, "rb")
    if not f then
        log.error("OTA:FU", "Cannot open " .. MCU_FW_PATH)
        proto.request_mcu(mid, "RESET", "", 500, 1)  -- 复位，APP区已擦，Boot自然留下
        sys.publish("FOTA_STATE", "fu_error_open_file", 0)
        return false
    end

    local block_idx = 0
    local tx_ok = true

    while true do
        local chunk = f:read(128)
        if not chunk or #chunk == 0 then break end

        local payload = string.format("block=%d;len=%d;data=%s",
                                      block_idx, #chunk, to_hex(chunk))
        local od_resp = proto.request_mcu(mid, "OD", payload, 2000, 5)

        if not od_resp then
            log.error("OTA:FU", "Block " .. block_idx .. " failed after 5 retries")
            tx_ok = false
            break
        end

        block_idx = block_idx + 1
        sys.wait(10)   -- 让出 CPU，防止看门狗超时
    end
    f:close()

    if not tx_ok then
        -- OD 失败 → RESET → Boot 因 APP 区已擦而自动留在救砖模式 → 可重新 FU
        log.error("OTA:FU", "Transmission failed at block " .. block_idx .. ", sending RESET")
        proto.request_mcu(mid, "RESET", "", 500, 1)
        sys.publish("FOTA_STATE", "fu_error_tx", block_idx)
        return false
    end

    log.info("OTA:FU", "All " .. block_idx .. " blocks sent. Sending OE...")

    -- ----------------------------------------------------------
    -- (3) OE: 提交 → Boot 校验 CRC → 直接跳转 APP（不再复位）
    --     超时 8s（Boot 侧需要做 CRC 计算）
    -- ----------------------------------------------------------
    local oe_resp = proto.request_mcu(mid, "OE", "status=commit", 8000, 3)
    if not oe_resp then
        log.error("OTA:FU", "OE commit failed, sending RESET")
        proto.request_mcu(mid, "RESET", "", 500, 1)
        sys.publish("FOTA_STATE", "fu_error_oe", 0)
        return false
    end

    log.info("OTA:FU", "MCU upgrade complete! Boot is jumping to APP.")
    sys.publish("FOTA_STATE", "fu_ok", 0)
    return true
end

-- ============================================================
-- 4G 模组自身 FOTA 升级（保留原有功能）
-- ============================================================
function ota.start(url)
    if not url or url == "" then
        log.error("OTA:4G", "Empty URL")
        sys.publish("FOTA_STATE", "4g_error_empty_url", -1)
        return false
    end
    log.info("OTA:4G", "Starting 4G FOTA from: " .. url)
    local code = http.request("GET", url, nil, nil, {fota = true}).wait()
    log.info("OTA:4G", "FOTA HTTP code: " .. tostring(code))
    if code == 200 then
        log.info("OTA:4G", "Downloaded OK, sending status then rebooting...")
        -- 先发状态给服务器，再等待网络flush，最后重启
        sys.publish("FOTA_STATE", "4g_ok", code)
        sys.wait(3000)  -- 等待 UDP 报文发出
        rtos.reboot()
    else
        log.error("OTA:4G", "FOTA failed: " .. tostring(code))
        sys.publish("FOTA_STATE", "4g_error_http", code)
    end
    return code == 200
end

return ota
