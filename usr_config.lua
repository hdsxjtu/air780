-- usr_config.lua
-- Global configuration for Air780E firmware.

local config = {}

-- ============================================================
-- A. Default server
-- Used only when saved SIP1~SIP4 are 0.0.0.0.
-- ============================================================
config.SERVER_IP   = "frp-arm.com"
config.SERVER_PORT = 36297

-- ============================================================
-- B. Fixed firmware/hardware settings
-- These are code-level settings. Do not treat them as field params.
-- ============================================================
config.PROJECT   = "TRACKER_PRO"
config.DEVICE_ID = nil           -- nil: build device ID from TYPE + ADDR

config.LED_PIN   = 27            -- GPIO 27, active low
config.UART_ID   = 1
config.UART_BAUD = 9600
config.LBS_TIMEOUT = 30000

-- ============================================================
-- C. Firmware behavior switches
-- Usually changed only by firmware release.
-- ============================================================
config.POWER_MODE = 0                         -- keep normal until NETCFG is printed
config.LOW_POWER_AFTER_NETSTAT = true         -- enter light sleep after formatted params
config.DEBUG_KEEP_AWAKE = false               -- true keeps normal mode for USB debug
config.NETWORK_ENABLE = true
config.BOOT_HOLD_FLYMODE = true
config.BOOT_NETWORK_DELAY_MS = 2000
config.APPLY_EDRX_ON_BOOT = false
config.USB_ENABLE = false
config.USB_CLOSE_AFTER_NETSTAT_MS = 500

config.BOOT_LED_BLINK = true                  -- legacy alias of BLUE_LED_ENABLE
config.LED_PACKET_BLINK = true                -- online LED dips on packet activity

config.PSM_AFTER_REPORT = false
config.REPORT_TX_WAIT_MS = 20000
config.BOOT_MCU_SYNC_ENABLE = false
config.BOOT_SIMULATE_MR = false
config.FIRST_REPORT_DELAY_MS = 0
config.HEARTBEAT_START_DELAY_MS = 0
config.SERVER_CONNECT_DELAY_MS = 0
config.RESET_SAVED_SERVER_TO_DEFAULT = false  -- true clears saved SIP/SPT on boot

config.NAT_INTERVAL = 30 * 1000
config.NET_CHECK_START_DELAY_MS = 5000
config.NET_CHECK_HB_TRIES = 3
config.NET_CHECK_HB_TIMEOUT_MS = 5000
config.HB_ACK_MISS_LIMIT = 4
config.SOCKET_CONNECT_FAIL_LIMIT = 3
config.SOCKET_RETRY_MIN_MS = 10 * 1000
config.SOCKET_RETRY_MAX_MS = 5 * 60 * 1000

-- ============================================================
-- D. Field/server parameters
-- These are saved to /usr_config.json.
-- Server or MCU may update them.
-- New SIP/SPT takes effect on next 4G reboot.
-- ============================================================
config.ADDR = 1
config.TYPE = "TY"

config.SIP1 = 0
config.SIP2 = 0
config.SIP3 = 0
config.SIP4 = 0
config.SPT  = 0

config.REPORT_INTERVAL = 60 * 60 * 1000
config.BLUE_LED_ENABLE = true

local CONFIG_FILE = "/usr_config.json"

function config.save()
    local f = io.open(CONFIG_FILE, "w")
    if f then
        f:write(string.format(
            '{"ADDR":%d,"REPORT_INTERVAL":%d,"TYPE":"%s","LAT":"%s","LNG":"%s","SIP1":%d,"SIP2":%d,"SIP3":%d,"SIP4":%d,"SPT":%d,"BOOT_NETWORK_DELAY_MS":%d,"LED":%d}',
            config.ADDR or 1,
            config.REPORT_INTERVAL or (60 * 60 * 1000),
            config.TYPE or "TY",
            config.LAT or "",
            config.LNG or "",
            config.SIP1 or 0,
            config.SIP2 or 0,
            config.SIP3 or 0,
            config.SIP4 or 0,
            config.SPT or 0,
            config.BOOT_NETWORK_DELAY_MS or 2000,
            config.BLUE_LED_ENABLE and 1 or 0
        ))
        f:close()
        return true
    end
    return false
end

function config.load()
    local f = io.open(CONFIG_FILE, "r")
    if not f then
        return false
    end

    local content = f:read("*a")
    f:close()
    if not content then
        return false
    end

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

    return true
end

config.load()

if config.RESET_SAVED_SERVER_TO_DEFAULT then
    config.SIP1 = 0
    config.SIP2 = 0
    config.SIP3 = 0
    config.SIP4 = 0
    config.SPT = 0
    config.save()
end

return config
