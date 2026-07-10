-- Global Project Info
-- Note: Must be defined as literals for LuatTools to recognize them
PROJECT = "TRACKER_PRO"
VERSION = "1.0.76"

log.info("MAIN", "PROJECT: " .. PROJECT .. " VERSION: " .. VERSION)

-- 初始化 LED 并立即关闭，防止上电瞬间闪烁或长亮
local led = require("usr_led")
led.init()
led.off()

local sys = require("sys")
local config = require("usr_config")
-- pm is global
local app = require("usr_app")

-- 初始化功耗管理
-- 启动延时，防止模块在极端情况下启动即休眠导致无法维护
sys.taskInit(function()
    sys.wait(1000) 
    log.info("MAIN", "System Started")
    
    -- 设置模块为 Light Sleep 模式已移至 usr_app.lua
    -- 确保网络建立并进入持久连接后再开启休眠
    
    -- 启用 PWRKEY 唤醒（保留作为备选唤醒手段）
    if pm.PWK_MODE then
        pm.power(pm.PWK_MODE, true)
    end
    
    -- Start Application
    app.start()
end)

-- Start Scheduler
sys.run()
