-- config.lua
-- Global Configuration

local config = {}

-- Project Info
config.PROJECT = "TRACKER_PRO"
config.VERSION = "2.0.0"

-- Hardware Definitions
config.LED_PIN = 27 -- GPIP 27 (NetStatus Pin 16)
config.UART_ID = 1 -- Main UART
config.UART_BAUD = 115200

-- Power Management
-- 0: Off, 1: Low, 2: Balanced, 3: Ultra Low (PSM)
config.POWER_MODE = 3 

-- Timing Configuration (Unit: ms)
config.REPORT_INTERVAL =5* 60 * 1000 -- 5 Minute
config.LBS_TIMEOUT = 30000              -- LBS Request timeout

-- Server Configuration for UDP GPS Reporting
config.SERVER_IP = "112.125.89.8"    -- Replace with actual Server IP
config.SERVER_PORT = 34934              -- Replace with actual Server Port

return config
