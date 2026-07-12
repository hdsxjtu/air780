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
-- 2/3 are not used in this MCU-controlled firmware
config.POWER_MODE      = 1              -- Light Sleep only; MCU controls physical power-off
config.NETWORK_ENABLE  = true           -- true: enable cellular networking
config.BOOT_HOLD_FLYMODE = true         -- hold flight mode early, then release before network start
config.BOOT_NETWORK_DELAY_MS = 2000     -- configurable delay before 4G attach; default 2 seconds
config.APPLY_EDRX_ON_BOOT = false       -- avoid forced flight-mode reconnect on every boot
config.BLUE_LED_ENABLE = false          -- LED=1 enables diagnostic blink; default off for battery builds
config.BOOT_LED_BLINK = false           -- legacy alias, kept for old config files
config.PSM_AFTER_REPORT = false         -- legacy guard, must remain false
config.REPORT_TX_WAIT_MS = 20000        -- legacy timer-task value; active MR flow is MCU driven
config.STARTUP_TS_PROBE = false         -- avoid extra UDP probe right after socket connect
config.BOOT_MCU_SYNC_ENABLE = false     -- avoid CG sync at boot; server CG can still query later
config.BOOT_SIMULATE_MR = true          -- send one simulated MR after server link is ready for bench testing
config.FIRST_REPORT_DELAY_MS = 0        -- network is already delayed before app.start()
config.HEARTBEAT_START_DELAY_MS = 0      -- start NAT keepalive immediately after boot sync
config.SERVER_CONNECT_DELAY_MS = 0      -- connect server immediately after delayed network attach
config.NAT_INTERVAL    = 45 * 1000      -- 45s UDP heartbeat keeps carrier NAT mapping alive
config.REPORT_INTERVAL    = 60 * 60 * 1000 -- legacy interval; MCU now owns report scheduling
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
        f:write(string.format('{"ADDR":%d,"REPORT_INTERVAL":%d,"TYPE":"%s","LAT":"%s","LNG":"%s","SIP1":%d,"SIP2":%d,"SIP3":%d,"SIP4":%d,"SPT":%d,"BOOT_NETWORK_DELAY_MS":%d,"LED":%d}', 
            config.ADDR or 1, config.REPORT_INTERVAL or (60 * 60 * 1000), config.TYPE or "TY", config.LAT or "", config.LNG or "",
            config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0, config.SPT or 0,
            config.BOOT_NETWORK_DELAY_MS or 2000, config.BLUE_LED_ENABLE and 1 or 0))
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
        local boot_delay = string.match(content, '"BOOT_NETWORK_DELAY_MS":(%d+)')
        local boot_led = string.match(content, '"BOOT_LED_BLINK":(%d+)')
        local led = string.match(content, '"LED":(%d+)')
        
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
        if boot_delay then config.BOOT_NETWORK_DELAY_MS = tonumber(boot_delay) end
        if led then
            config.BLUE_LED_ENABLE = (tonumber(led) == 1)
        elseif boot_led then
            config.BLUE_LED_ENABLE = (tonumber(boot_led) == 1)
        end
        config.BOOT_LED_BLINK = config.BLUE_LED_ENABLE
        
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
