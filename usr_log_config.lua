-- Focused log controls for field debugging.
-- Default focus: registration/network status only.

local cfg = {}

cfg.ENABLE_FILTER = true
cfg.INFO_DEFAULT = false
cfg.WARN_ERROR_ALWAYS = true

cfg.ALLOW_INFO = {
    MAIN = false,
    NETSTAT = true,
    NET = true,
    HB = true,
    CONFIG = false,
    PM = false,
    UART = false,
    BOOT = false,
    ["OTA:FD"] = false,
    ["OTA:FU"] = false,
    ["OTA:4G"] = false,

    -- Raw packet logs are noisy. Enable only when tracing protocol bytes.
    UDP_TX = false,
    UDP_RX = false,
    UART_TX = false,
    PROTO = false,
    APP = false,
    CYCLE = false,
    LBS = false,
}

cfg.STARTUP_CONFIG_SUMMARY = false

return cfg
