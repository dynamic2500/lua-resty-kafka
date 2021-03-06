-- Copyright (C) Dejiang Zhu(doujiang24)


local response = require "resty.kafka.response"
local request = require "resty.kafka.request"

local to_int32 = response.to_int32
local setmetatable = setmetatable
local tcp = ngx.socket.tcp
local pid = ngx.worker.pid

local sasl = require "resty.kafka.sasl"

local _M = {}
local mt = { __index = _M }

function sasl_auth(sock, broker)
    local _, err = _sasl_handshake(sock, broker)
    if  err then
        return err
    end
    local _, err = _sasl_auth(sock, broker)
    if err then
        return err
    end
    return
end

function _M.new(self, host, port, socket_config, sasl_config)
    return setmetatable({
        host = host,
        port = port,
        config = socket_config,
        auth = sasl_config,
    }, mt)
end


function _M.send_receive(self, request)
    local config = self.config
    local sock, err = tcp()
    if not sock then
        return nil, err, true
    end
    sock:settimeout(config.socket_timeout)
    local ok, err = sock:connect(self.host, self.port)
    if not ok then
        return nil, err, true
    end

    local times, err = sock:getreusedtimes()
    if not times then
        return nil , err, true
    end
    if config.ssl and times == 0  then
        local _, err = sock:sslhandshake(true, self.host, config.ssl_verify) --reused conn
        if err then
            return nil, "failed to do SSL handshake with " ..
                        self.host .. ":" .. tostring(self.port) .. ": " .. err, true
        end
    end
    if self.auth and times == 0  then -- SASL AUTH
        local err = sasl_auth(sock, self)
        if  err then
            return nil, "failed to do " .. self.auth.mechanism .." auth with " ..
                        self.host .. ":" .. tostring(self.port) .. ": " .. err, true

        end
    end
    local data, err, f  = _sock_send_recieve(sock, request)
    sock:setkeepalive(config.keepalive_timeout, config.keepalive_size)
    return data, err, f
end



function _sock_send_recieve(sock, request)
    local bytes, err = sock:send(request:package())
    if not bytes then
        return nil, err, true
    end

    local len, err = sock:receive(4)
    if not len then
        if err == "timeout" then
            sock:close()
            return nil, err
        end
        return nil, err, true
    end

    local data, err = sock:receive(to_int32(len))
    if not data then
        if err == "timeout" then
            sock:close()
            return nil, err
        end
        return nil, err, true
    end
    -- sock:setkeepalive(config.keepalive_timeout, config.keepalive_size)
    return response:new(data, request.api_version), nil, true
end

function _sasl_handshake_decode(resp)
    local err_code =  resp:int16()
    local error_msg =  resp:string()
    if err_code ~= 0 then
        return err_code, error_msg
    else
        return 0, nil
    end
end

function _sasl_auth_decode(resp)
    local err_code = resp:int16()
    local error_msg  = resp:nullable_string()
    local auth_bytes  = resp:bytes()
    if err_code ~= 0 then
        return err_code, error_msg
    else
        return 0, nil
    end
end

function _sasl_auth(sock, brk)
    local cli_id = "worker" .. pid()
    local req = request:new(request.SaslAuthenticateRequest, 0, cli_id, request.API_VERSION_V1)
    local msg = sasl.encode(brk.auth.mechanism, nil, brk.auth.user, brk.auth.password)
    req:bytes(msg)
    local resp, err = _sock_send_recieve(sock, req, brk.config)
    if not resp  then
        return nil , err
    else
        return _sasl_auth_decode(resp)
    end
end


function _sasl_handshake(sock, brk)
    local cli_id = "worker" .. pid()
    local req = request:new(request.SaslHandshakeRequest, 0, cli_id, request.API_VERSION_V1)
    req:string(brk.auth.mechanism)
    local resp, err = _sock_send_recieve(sock, req, brk.config)
    if not resp  then
        return  nil, err
    else
        return _sasl_handshake_decode(resp)
    end
end


return _M
