PROJECT = "LBS_LOC_DEMO"
VERSION = "1.0.0"

local sys = require("sys")
local lbsLoc = require("lbsLoc")

-- Define task to perform LBS request
sys.taskInit(function()
    log.info("LBS", "Waiting for network (IP_READY)...")
    sys.waitUntil("IP_READY")
    log.info("LBS", "Network ready. Requesting Cell Info...")

    -- Trigger cell info update. 
    -- 15 seconds timeout, usually returns much faster if successful.
    mobile.reqCellInfo(15)
    
    -- Wait for the cell info to be updated
    sys.waitUntil("CELL_INFO_UPDATE", 15000)
    
    log.info("LBS", "Cell Info updated or timed out. Starting LBS request...")

    -- Perform LBS request
    lbsLoc.request(function(result, lat, lng, addr)
        if result == 0 then
            log.info("LBS", "Success!")
            log.info("LBS", "Latitude:", lat)
            log.info("LBS", "Longitude:", lng)
            if addr then
                log.info("LBS", "Address:", addr)
            end
        else
            log.info("LBS", "Failed with code:", result)
        end
    end)
    
    -- Loop for periodic updates
    while true do
        sys.wait(60000) -- Wait 1 minute
        log.info("LBS", "Requesting update...")
        
        mobile.reqCellInfo(15)
        sys.waitUntil("CELL_INFO_UPDATE", 15000)
        
        lbsLoc.request(function(result, lat, lng, addr)
            if result == 0 then
                log.info("LBS", "Update Success:", lat, lng)
            else
                log.info("LBS", "Update Failed:", result)
            end
        end)
    end
end)

-- Start the system scheduler
sys.run()