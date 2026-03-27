-- config.lua
-- Global Configuration

local config = {}

-- ============================================================
-- ★ 快速配置区 — 服务器地址（借用临时服务器时在此修改）★
-- ============================================================
config.SERVER_IP   = "192.168.2.5"   -- << 修改这里：服务器 IP
config.SERVER_PORT = 520             -- << 修改这里：服务器 UDP 端口
-- ============================================================

-- Project Info
config.PROJECT = "TRACKER_PRO"
config.VERSION = "2.0.0"

-- Hardware Definitions
config.LED_PIN   = 27      -- GPIO 27 (NetStatus)
config.UART_ID   = 1       -- 主 UART
config.UART_BAUD = 9600               -- 9600波特率可唤醒MCU的LPUART Stop模式

-- Power Management
-- 0: Normal(全速)  1: Light Sleep(轻度休眠，网络保持在线，可远程唤醒)
-- 2: Balanced      3: PSM Deep Sleep(深度休眠，网络断开，无法远程唤醒)
config.POWER_MODE = 1      -- Light Sleep：保持网络在线，服务器可随时下发命令

-- Timing Configuration (Unit: ms)
config.REPORT_INTERVAL = 5 * 60 * 1000  -- 定时上报周期：5 分钟
config.LBS_TIMEOUT     = 30000          -- LBS 定位超时

return config
