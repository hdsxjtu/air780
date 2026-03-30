-- usr_lbs.lua
-- Service for Base Station Positioning

local sys = require("sys")
local success_lbs, lbsLoc = pcall(require, "lbsLoc")
if not success_lbs then lbsLoc = nil end
local mobile = _G.mobile
local config = require("usr_config")

local lbs = {}

-- Perform a synchronous-like LBS request
-- Returns: result_code, lat, lng, addr
function lbs.getLocation()
    -- 1. Trigger cell info update (Required for LBS in new firmware)
    if mobile and mobile.reqCellInfo then
        mobile.reqCellInfo(15)
        
        -- 2. Wait for update
        local result = sys.waitUntil("CELL_INFO_UPDATE", config.LBS_TIMEOUT)
        if not result then
            log.warn("LBS", "Cell Info Update Timed Out")
        end
    else
        log.warn("LBS", "Mobile/LBS hardware not available on this platform")
    end
    
    -- DEBUG: Print cell info (Simplified)
    -- local cell_info = mobile.getCellInfo()
    -- if not cell_info then log.warn("LBS", "No Cell Info") end
    
    -- 3. Request LBS
    if not lbsLoc then return -99, 0, 0 end
    
    local ret_lat, ret_lng, ret_result = nil, nil, -1
    
    -- Wrap asynchronous callback into a synchronous wait
    -- We use a custom message "LBS_DONE" to unblock
    lbsLoc.request(function(res, lat, lng, addr)
        ret_result = res
        ret_lat = lat
        ret_lng = lng
        sys.publish("LBS_DONE")
    end)
    
    -- Wait for the callback to finish
    if sys.waitUntil("LBS_DONE", config.LBS_TIMEOUT) then
        return ret_result, ret_lat, ret_lng
    else
        return -99, nil, nil -- Timeout
    end
end

return lbs
