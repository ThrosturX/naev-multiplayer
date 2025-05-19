local common = require "multiplayer.common"
local conf = require "conf"
local enet = require "enet"
local fmt = require "format"
local syst_server = require "multiplayer.syst_server"

local relay = {}
local default_relay = conf.relay_server or "localhost:60939"
local RELAY_MESSAGES = {}

-- <peer> advertises to be hosting <data>
RELAY_MESSAGES.advertise = function ( peer, data )
    if data and #data >= 1 then
        if relay.peers[data] ~= nil then
            print(fmt.f("Warning: replacing existing host for {syst} at {addr}", { syst = data[0], addr = peer }))
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

local function broadcast ( key, data, reliability )
    if not RELAY_MESSAGES.key then
        print("error: " .. tostring(key) .. " not found in RELAY_MESSAGES.")
        return nil
    end

    reliability = reliability or "unsequenced"
    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    return relay.host:broadcast( message, 0, reliability )
end

-- Ctor for peer-to-peer relay
relay.start = function( port )
    if not port then port = 0 end
    relay.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )

    -- TODO: revise boilerplate requirements (and add bootstrap peer?)
    relay.peers = {}
    relay.server = syst_server.create()

    -- return self, since this is the "constructor"
    return relay
end

-- opens the server for hosting
relay.open = function ()
    relay.hosting = true
    relay.server.start()

    local syst = system.cur():nameRaw()
    -- advertise to peers that we are hosting <syst>
    relay.advertise( syst )
end

relay.close = function()
    relay.hosting = nil
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
    print( fmt.f("WARNING: Not able to respond to message of type {mtype} from {mrec} containing {mdat}", { mtype = msg_type, mrec = recipient, mdat = msg_data }) )
end

-- try to find the peer hosting <syst_name>
relay.find_peer = function ( syst_name )
    -- 0. (optional) request up-to-date information

    -- 1. find the peer that hosts syst_name
    local host_peer = relay.peers[syst_name]
    if host_peer ~= nil then
        return host_peer
    end

    return nil
end

relay.advertise = function ( syst_name )
    return broadcast( "advertise", syst_name )
end

relay.deadvertise = function ( syst_name )
    return broadcast( "deadvertise", syst_name )
end

return relay
