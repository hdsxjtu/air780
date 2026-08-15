-- usr_config.lua
-- Global configuration for Air780E firmware.

local config = {}

-- ============================================================
-- A. Default server, code-only.
-- Used when SIP1~SIP4 are all 0.0.0.0. If MCU/server writes SIP/SPT,
-- the saved address wins on next 4G reboot.
-- ============================================================
config.SERVER_IP   = "frp-arm.com" -- default domain
config.SERVER_PORT = 36297         -- default UDP/FRP port

-- ============================================================
-- B. Fixed firmware/hardware settings, code-only.
-- Do not expose these as field parameters unless hardware changes.
-- ============================================================
config.PROJECT   = "TRACKER_PRO" -- Luat project name
config.DEVICE_ID = nil           -- nil: use numeric ADDR as device ID

config.LED_PIN     = 27    -- blue LED GPIO, active low
config.UART_ID     = 1     -- UART connected to MCU
config.UART_BAUD   = 9600  -- MCU protocol baudrate
config.LBS_TIMEOUT = 30000 -- LBS location timeout, ms

-- ============================================================
-- C. Boot and power behavior, code-only.
-- These control Air780E runtime behavior. Most changes require firmware
-- download; some saved parameters below may override specific values.
-- ============================================================
config.POWER_MODE = 0                 -- initial mode: 0 normal, 1 light sleep
config.LOW_POWER_AFTER_NETSTAT = true -- after NETCFG log, enter light sleep
config.DEBUG_KEEP_AWAKE = false       -- true keeps normal mode and USB logging
config.NETWORK_ENABLE = true          -- false disables cellular network task
config.BOOT_HOLD_FLYMODE = true       -- hold flight mode during early boot delay
config.BOOT_NETWORK_DELAY_MS = 2000   -- saved to json; delay before network attach
config.APPLY_EDRX_ON_BOOT = false     -- false avoids detach/reattach on every boot
config.USB_ENABLE = false             -- false closes USB after NETCFG is printed
config.USB_CLOSE_AFTER_NETSTAT_MS = 500 -- wait after NETCFG before closing USB, ms

-- ============================================================
-- D. LED and debug frames, mixed.
-- BLUE_LED_ENABLE is saved below. The others are code-only.
-- ============================================================
config.BOOT_LED_BLINK = true      -- legacy alias; synced from BLUE_LED_ENABLE
config.LED_PACKET_BLINK = true    -- blink 20ms when protocol packet TX/RX occurs
config.DIAG_FRAME_ENABLE = true   -- false hides DG crash/reset frames from server

-- ============================================================
-- E. Legacy/test behavior, code-only.
-- Keep false unless deliberately testing old flows.
-- ============================================================
config.PSM_AFTER_REPORT = false       -- legacy guard; MCU now owns power-off
config.BOOT_MCU_SYNC_ENABLE = false   -- true queries MCU CG during 4G boot
config.BOOT_SIMULATE_MR = false       -- true sends fake boot MR, production false
config.FIRST_REPORT_DELAY_MS = 0      -- legacy MG cycle delay

-- ============================================================
-- F. Network timing and retry policy, code-only.
-- These affect 4G/server link only, not MCU MR retry rules.
-- ============================================================
config.REPORT_TX_WAIT_MS = 20000       -- wait for MCU report completion after MG
config.HEARTBEAT_START_DELAY_MS = 0    -- delay before periodic HB starts
config.SERVER_CONNECT_DELAY_MS = 0     -- delay after IP_READY before socket connect
config.RESET_SAVED_SERVER_TO_DEFAULT = false -- true clears SIP/SPT at boot

config.NAT_INTERVAL = 30 * 1000        -- periodic HB interval after online, ms
config.NET_CHECK_START_DELAY_MS = 5000 -- after socket ready, wait before HB gate
config.NET_CHECK_HB_TRIES = 3          -- boot HB gate attempts
config.NET_CHECK_HB_TIMEOUT_MS = 5000  -- one HB ACK wait timeout, ms
config.HB_ACK_MISS_LIMIT = 3           -- online missed HB limit

--- @brief Maximum wait time for cellular IP before reporting net=0 to the MCU.
--- @note Covers SIM/base-station/APN/IP failures before the server socket is attempted.
config.NET_IP_READY_TIMEOUT_MS = 30 * 1000 -- wait cellular IP before notifying MCU net=0
config.SOCKET_CONNECT_FAIL_LIMIT = 3   -- consecutive socket connect failures
config.SOCKET_RETRY_MIN_MS = 10 * 1000 -- socket retry backoff minimum
config.SOCKET_RETRY_MAX_MS = 5 * 60 * 1000 -- socket retry backoff maximum

-- ============================================================
-- G. Field/server parameters, saved to /usr_config.json.
-- These are saved to /usr_config.json.
-- Server or MCU may update them.
-- New SIP/SPT takes effect on next 4G reboot.
-- ============================================================
config.ADDR = 1      -- site/device numeric address
config.TYPE = "TY"   -- device type prefix

config.SIP1 = 0      -- custom server IP octet 1; 0.0.0.0 means use default
config.SIP2 = 0      -- custom server IP octet 2
config.SIP3 = 0      -- custom server IP octet 3
config.SIP4 = 0      -- custom server IP octet 4
config.SPT  = 0      -- custom server port; 0 means use default

config.REPORT_INTERVAL = 60 * 60 * 1000 -- legacy MG interval, ms
config.BLUE_LED_ENABLE = true           -- server/CG visible LED master switch

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
