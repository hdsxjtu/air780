-- main.lua
-- Entry Point

-- Global Project Info
-- Note: Must be defined as literals for LuatTools to recognize them
PROJECT = "TRACKER_PRO"
VERSION = "2.0.0"

local sys = require("sys")
local config = require("usr_config")
-- pm is global
local app = require("usr_app")

-- Initialize Power Management (PSM)
-- Wait for system to stabilize (prevent immediate sleep/crash loop)
sys.taskInit(function()
    sys.wait(3000) 
    log.info("MAIN", "System Started")
    
    -- Initialize Power Management (PSM) AFTER startup
    -- Moved to usr_app.lua to ensure network is ready first
    -- pm.power(pm.WORK_MODE, config.POWER_MODE)
    
    -- Enable PWRKEY Wakeup from PSM (Important!)
    if pm.PWK_MODE then
        pm.power(pm.PWK_MODE, true)
    end
    
    -- Start Application
    app.start()
end)

-- Start Scheduler
sys.run()