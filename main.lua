-- Global Project Info
-- Note: Must be defined as literals for LuatTools to recognize them
PROJECT = "TRACKER_PRO"
VERSION = "1.0.110"

-- Keep startup logs focused; LuatTools reads PROJECT/VERSION from the literals above.

-- 初始化 LED 并立即关闭，防止上电瞬间闪烁或长亮
local led = require("usr_led")
led.init()
led.off()

local sys = require("sys")
local focus_log = require("usr_log")
focus_log.install()
local config = require("usr_config")
-- pm is global
local app = require("usr_app")

-- 初始化功耗管理
-- 启动延时，防止模块在极端情况下启动即休眠导致无法维护
sys.taskInit(function()
    if config.BOOT_HOLD_FLYMODE and mobile and mobile.flymode then
        mobile.flymode(0, true)
    end

    sys.wait(1000) 
    
    -- 1. Keep USB log open first. It will close after NETCFG is printed.
    if pm.USB then
        pm.power(pm.USB, true)
    end
    
    -- 2. eDRX setup is optional. For battery boot, avoid forcing a detach/reattach cycle.
    if config.APPLY_EDRX_ON_BOOT and mobile and mobile.config then
        mobile.config(mobile.CONF_EDRX, 1, 5, 3)
    end
    
    if config.BOOT_NETWORK_DELAY_MS and config.BOOT_NETWORK_DELAY_MS > 0 then
        sys.wait(config.BOOT_NETWORK_DELAY_MS)
    end

    if config.NETWORK_ENABLE ~= false and config.BOOT_HOLD_FLYMODE and mobile and mobile.flymode then
        mobile.flymode(0, false)
    end
    
    -- 设置模块为 Light Sleep 模式已移至 usr_app.lua
    -- 确保网络建立并进入持久连接后再开启休眠
    
    -- 3. 启用 PWRKEY 唤醒（保留作为备选唤醒手段）
    if pm.PWK_MODE then
        pm.power(pm.PWK_MODE, true)
    end
    
    -- 4. Start application tasks after power/network setup
    app.start()
end)

-- Start Scheduler
sys.run()
