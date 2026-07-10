-- config.lua
-- Global Configuration

local config           = {}

-- ============================================================
-- ★ 快速配置区 — 服务器地址（借用临时服务器时在此修改）★
-- ============================================================
config.SERVER_IP       = "frp-arm.com" -- << 已改为域名地址
config.SERVER_PORT     = 36297         -- << 已同步更新端口
-- ============================================================

-- Project Info
config.PROJECT         = "TRACKER_PRO"
config.DEVICE_ID       = nil -- 置空此项，让系统完全跟随下面 config.ADDR 来动态生成 ID（实现默认DEV1，查到啥用啥）

-- Hardware Definitions
config.LED_PIN         = 27 -- GPIO 27 (NetStatus)
config.UART_ID         = 1 -- 主 UART
config.UART_BAUD       = 9600 -- 9600波特率可唤醒MCU的LPUART Stop模式

-- Power Management
-- 0: Normal(全速)  1: Light Sleep(轻度休眠，网络保持在线，可远程唤醒)
-- 2: Balanced      3: PSM Deep Sleep(深度休眠，网络断开，无法远程唤醒)
config.POWER_MODE      = 0 -- 请切换为 1 进行测试
config.NAT_INTERVAL    = 2 * 60 * 1000   -- 【防断连】测试用 2 分钟心跳，降低常驻功耗
config.REPORT_INTERVAL    = 60 * 60 * 1000 -- 【重量】定时采样间隔 (ms)，对应协议中的 RPT 参数。
config.ADDR               = 1              -- 【配置】设备物理地址（site_id），与单片机同步。
config.TYPE               = "TY"           -- 【配置】设备类型前缀 ("TY" or "FJ")，自动同步自 MCU。
config.SIP1               = 0              -- 【配置】服务器 IP 第 1 段
config.SIP2               = 0              -- 【配置】服务器 IP 第 2 段
config.SIP3               = 0              -- 【配置】服务器 IP 第 3 段
config.SIP4               = 0              -- 【配置】服务器 IP 第 4 段
config.SPT                = 0              -- 【配置】服务器端口号
config.LBS_TIMEOUT        = 30000          -- LBS 定位超时

local CONFIG_FILE = "/usr_config.json"

function config.save()
    local f = io.open(CONFIG_FILE, "w")
    if f then
        f:write(string.format('{"ADDR":%d,"REPORT_INTERVAL":%d,"TYPE":"%s","LAT":"%s","LNG":"%s","SIP1":%d,"SIP2":%d,"SIP3":%d,"SIP4":%d,"SPT":%d}', 
            config.ADDR or 1, config.REPORT_INTERVAL or (60 * 60 * 1000), config.TYPE or "TY", config.LAT or "", config.LNG or "",
            config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0, config.SPT or 0))
        f:close()
        log.info("CONFIG", string.format("Saved local config: ADDR=%s, TYPE=%s, RPT=%s, IP=%d.%d.%d.%d:%d", 
            tostring(config.ADDR), tostring(config.TYPE), tostring(config.REPORT_INTERVAL),
            config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0, config.SPT or 0))
        return true
    end
    return false
end

function config.load()
    local f = io.open(CONFIG_FILE, "r")
    if not f then 
        log.info("CONFIG", "No saved config found, using defaults")
        return false 
    end
    local content = f:read("*a")
    f:close()
    if content then
        local addr = string.match(content, '"ADDR":(%d+)')
        local rpt = string.match(content, '"REPORT_INTERVAL":(%d+)')
        local dev_type = string.match(content, '"TYPE":"(.-)"')
        local lat = string.match(content, '"LAT":"(.-)"')
        local lng = string.match(content, '"LNG":"(.-)"')
        local sip1 = string.match(content, '"SIP1":(%d+)')
        local sip2 = string.match(content, '"SIP2":(%d+)')
        local sip3 = string.match(content, '"SIP3":(%d+)')
        local sip4 = string.match(content, '"SIP4":(%d+)')
        local spt = string.match(content, '"SPT":(%d+)')
        
        if addr then config.ADDR = tonumber(addr) end
        if rpt then config.REPORT_INTERVAL = tonumber(rpt) end
        if dev_type and dev_type ~= "" then config.TYPE = dev_type end
        if lat and lat ~= "" then config.LAT = lat end
        if lng and lng ~= "" then config.LNG = lng end
        if sip1 then config.SIP1 = tonumber(sip1) end
        if sip2 then config.SIP2 = tonumber(sip2) end
        if sip3 then config.SIP3 = tonumber(sip3) end
        if sip4 then config.SIP4 = tonumber(sip4) end
        if spt then config.SPT = tonumber(spt) end
        
        log.info("CONFIG", string.format("Loaded saved config: ADDR=%s, TYPE=%s, RPT=%s, IP=%d.%d.%d.%d:%d", 
            tostring(config.ADDR), tostring(config.TYPE), tostring(config.REPORT_INTERVAL),
            config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0, config.SPT or 0))
        return true
    end
    return false
end

-- 自动恢复配置
config.load()

return config
