local common = require "multiplayer.common"
local syst_server = require "multiplayer.syst_server"
local enet = require "enet"
local fmt = require "format"

local relay = {}
local RELAY_MESSAGES = {}

-- <peer> advertises to be hosting <data>
RELAY_MESSAGES.advertise = function ( peer, data )
    if data and #data >= 1 then
        if relay.peers[data] ~= nil then
            print(fmt.f("Warning, replacing existing host for {syst} at {addr}", { syst = data[0], addr = peer }))
        end
        relay.peers[data] = tostring(peer)
    end
end

-- <peer> announces end of service for <data>
RELAY_MESSAGES.deadvertise = function ( peer, data )
    if data and #data >= 1 then
        if relay.peers[data] == tostring(peer) then
            relay.peers[data] = nil
        end
    end
end



-- Ctor for peer-to-peer relay
relay.start = function( port )
    if not port then port = 0 end
    relay.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )

    -- TODO: revise boilerplate requirements
    relay.peers = {}
    relay.server = syst_server.create()

    -- return self, since this is the "constructor"
    return relay
end

-- opens the server for hosting
relay.open = function ()
    relay.server.start()

    local syst = system.cur():nameRaw()
    -- advertise to peers that we are hosting <syst>
    relay.advertise( syst )
end

relay.close = function()
    relay.server.stop()

    local syst = system.cur():nameRaw()
    -- unadvertise ourselves as hosting <syst>
    relay.deadvertise ( syst )
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

relay.process = function ( event )
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
    if RELAY_MESSAGES.msg_type ~= nil then
        RELAY_MESSAGES.msg_type( event.peer, msg_data )
    end

    -- we're still here, keep processing

    -- determine if we are a peer or a host
    if relay.hosting ~= nil then
        -- we are the host
        -- TODO: handle the message like a server would
        relay.server.handleMessage( event.peer, msg_type, msg_data )
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

-- try to join the peer hosting <syst_name>
relay.join = function ( syst_name )
    return "ERR_NOT_IMPLEMENTED"
end

relay.advertise = function ( syst_name )
    -- TODO MESSAGE HERE
    local message = fmt.f( "{key}\n{msgdata}\n", { key = "advertise", msgdata = syst_name } )
    relay.host:broadcast( message, 0, "unsequenced" )
end

relay.deadvertise = function ( syst_name )
    local message = fmt.f( "{key}\n{msgdata}\n", { key = "deadvertise", msgdata = syst_name } )
    relay.host:broadcast( message, 0, "unsequenced" )
end

return relay
