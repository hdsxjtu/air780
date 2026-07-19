local focus = {}
local installed = false

function focus.install()
    if installed then
        return
    end
    installed = true
    -- Air780E/LuatOS exposes log as a protected rotatable object.
    -- Do not replace log.info/log.warn/log.error here, or boot will crash.
end

function focus.network_status(config, target_ip, target_port, stage)
    local local_ip = "nil"
    if socket and socket.localIP then
        local_ip = tostring(socket.localIP())
    end

    local imei = ""
    if mobile and mobile.imei then
        imei = tostring(mobile.imei())
    end

    local rsrp = ""
    if mobile and mobile.rsrp then
        rsrp = tostring(mobile.rsrp())
    end

    local saved_server = string.format("%d.%d.%d.%d:%d",
        config.SIP1 or 0, config.SIP2 or 0, config.SIP3 or 0, config.SIP4 or 0, config.SPT or 0)
    local target = tostring(target_ip or "") .. ":" .. tostring(target_port or "")
    local default_server = tostring(config.SERVER_IP or "") .. ":" .. tostring(config.SERVER_PORT or "")

    log.info("NETCFG", "========== 4G PARAMS ==========")
    log.info("NETCFG", "stage      : " .. tostring(stage or ""))
    log.info("NETCFG", "device_ip  : " .. local_ip)
    log.info("NETCFG", "imei       : " .. imei)
    log.info("NETCFG", "rsrp       : " .. rsrp)
    log.info("NETCFG", "id/type    : " .. tostring(config.ADDR or "") .. " / " .. tostring(config.TYPE or ""))
    log.info("NETCFG", "report_ms  : " .. tostring(config.REPORT_INTERVAL or ""))
    log.info("NETCFG", "led        : " .. (config.BLUE_LED_ENABLE and "1" or "0"))
    log.info("NETCFG", "usb_after  : " .. (config.USB_ENABLE ~= false and "on" or "off"))
    log.info("NETCFG", "target     : " .. target)
    log.info("NETCFG", "saved_sip  : " .. saved_server)
    log.info("NETCFG", "default    : " .. default_server)
    log.info("NETCFG", "================================")
end

return focus
