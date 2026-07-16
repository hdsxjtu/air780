-- Global Project Info
-- Note: Must be defined as literals for LuatTools to recognize them
PROJECT = "TRACKER_PRO"
VERSION = "1.0.89"

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
    if config.BOOT_HOLD_FLYMODE and mobile and mobile.flymode then
        mobile.flymode(0, true)
        log.info("PM", "Boot hold flight mode enabled")
    end

    sys.wait(1000) 
    log.info("MAIN", "System Started")
    
    -- 1. 关闭 USB 以降低静态功耗
    if pm.USB then
        pm.power(pm.USB, false)
    end
    
    -- 2. eDRX setup is optional. For battery boot, avoid forcing a detach/reattach cycle.
    if config.APPLY_EDRX_ON_BOOT and mobile and mobile.config then
        log.info("NET_CONF", "Applying eDRX configuration...")
        mobile.config(mobile.CONF_EDRX, 1, 5, 3)
        log.info("NET_CONF", "eDRX configuration applied.")
    end
    
    if config.BOOT_NETWORK_DELAY_MS and config.BOOT_NETWORK_DELAY_MS > 0 then
        log.info("PM", "Delay network start: " .. tostring(config.BOOT_NETWORK_DELAY_MS) .. "ms")
        sys.wait(config.BOOT_NETWORK_DELAY_MS)
    end

    if config.NETWORK_ENABLE ~= false and config.BOOT_HOLD_FLYMODE and mobile and mobile.flymode then
        mobile.flymode(0, false)
        log.info("PM", "Flight mode released, network can attach")
    end
    
    -- 设置模块为 Light Sleep 模式已移至 usr_app.lua
    -- 确保网络建立并进入持久连接后再开启休眠
    
    -- 3. 启用 PWRKEY 唤醒（保留作为备选唤醒手段）
    if pm.PWK_MODE then
        pm.power(pm.PWK_MODE, true)
    end
    
    -- 4. 配置完成后，最后启动应用业务
    app.start()
end)

-- Start Scheduler
sys.run()
