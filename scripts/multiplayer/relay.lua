local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"

local RELAY_MESSAGES = {}



local relay = {}

-- Ctor for peer-to-peer relay
relay.start = function( port )
    if not port then port = 0 end
    relay.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )

    -- TODO: revise boilerplate requirements

    -- return self, since this is the "constructor"
    return relay
end

relay.update = function ()
    local event = relay.host:service()
    while event do
        if event.type == "receive" then
            relay.process(event)
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            -- TODO: Consider what this event might represent
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- TODO: If we are hosting, give the ship an AI or disable/destroy it
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = relay.host:service()
    end
end

relay.process = function( event )
    -- preprocess the event
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n]+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    -- if this is a relay-specific message,
    -- process it now
    if RELAY_MESSAGES[msg_type] ~= nil then

    end

    -- we're still here, keep processing

    -- determine if we are a peer or a host
    if relay.hosting ~= nil then
        -- we are the host
        -- TODO: handle the message like a server would
    else
        -- we are just a relay
        relay.respond( event.peer, msg_type, msg_data )
    end
end

relay.respond = function ( recipient, msg_type, msg_data )
    -- TODO HERE: appropriate response
    -- or, failing that, a generic error message
    -- send it to the recipient
end

return relay
