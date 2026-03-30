-- config.lua
-- Global Configuration

local config           = {}

-- ============================================================
-- ★ 快速配置区 — 服务器地址（借用临时服务器时在此修改）★
-- ============================================================
config.SERVER_IP       = "192.168.2.5" -- << 修改这里：服务器 IP
config.SERVER_PORT     = 520       -- << 修改这里：服务器 UDP 端口
-- ============================================================

-- Project Info
config.PROJECT         = "TRACKER_PRO"
config.VERSION         = "1.0.0"

-- Hardware Definitions
config.LED_PIN         = 27 -- GPIO 27 (NetStatus)
config.UART_ID         = 1 -- 主 UART
config.UART_BAUD       = 9600 -- 9600波特率可唤醒MCU的LPUART Stop模式

-- Power Management
-- 0: Normal(全速)  1: Light Sleep(轻度休眠，网络保持在线，可远程唤醒)
-- 2: Balanced      3: PSM Deep Sleep(深度休眠，网络断开，无法远程唤醒)
config.POWER_MODE      = 1 -- Light Sleep：保持网络在线，服务器可随时下发命令

-- Timing Configuration
config.HEARTBEAT_INTERVAL = 5 * 60 * 1000 -- 【轻量】心跳周期间隔 (ms)，仅维持 UDP 映射，建议 5 分钟。固定值，与 RPT_INT 无关。
config.REPORT_INTERVAL    = 60 * 60 * 1000 -- 【重量】定时采样间隔 (ms)，唤醒 MCU 采气。对应协议中的 RPT_INT 参数，单位：分钟（此处默认 60m）。
config.ADDR               = 1              -- 【配置】设备物理地址（site_id），与单片机同步。
config.LBS_TIMEOUT        = 30000          -- LBS 定位超时

return config
