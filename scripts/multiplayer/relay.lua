local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local syst_server = require "multiplayer.syst_server"

local relay = {}

-- Your Oracle IP (The "Super Peer")
local root_relay_addr = "89.168.87.174:60939"
local root_peer = nil

-- Protocol Constants
local CMD_ADVERTISE = "advertise"
local CMD_FIND = "find"
local CMD_HEARTBEAT = "heartbeat"
local CMD_DEADVERTISE = "deadvertise"
local RSP_FOUND = "found"
local RSP_NOT_FOUND = "not_found"

local RELAY_MESSAGES = {}

-- Helper: Send a formatted message to a specific peer
local function send_msg(peer, cmd, arg)
    if peer then
        peer:send(cmd .. "\n" .. (arg or "") .. "\n")
    end
end

-- ====================================================
-- HANDLERS (Incoming Messages)
-- These handle messages from ANYONE (Root server OR other players)
-- ====================================================

-- 1. Someone wants to tell us they are hosting a system
RELAY_MESSAGES[CMD_ADVERTISE] = function ( peer, data )
    if data and #data >= 1 then
        local sys_name = data[1]
        -- We store the peer as the string representation (IP:Port)
        -- This allows us to redirect others to them
        print(fmt.f("Relay: Registering host for {syst} from {addr}", { syst = sys_name, addr = tostring(peer) }))
        relay.peers[sys_name] = peer

        -- Acknowledge receipt
        send_msg(peer, "advertise_ack", sys_name)
    end
end

-- 2. Someone is looking for a system
RELAY_MESSAGES[CMD_FIND] = function ( peer, data )
    if data and #data >= 1 then
        local sys_name = data[1]
        local host_peer = relay.peers[sys_name]

        if host_peer then
            -- We know who has it! Tell the requester.
            -- host_peer is an ENet peer object. tostring(peer) usually returns "IP:Port"
            print(fmt.f("Relay: Serving query for {syst}", { syst = sys_name }))
            send_msg(peer, RSP_FOUND, tostring(host_peer))
        else
            -- We don't know.
            send_msg(peer, RSP_NOT_FOUND)
        end
    end
end

-- 3. Someone stopped hosting
RELAY_MESSAGES[CMD_DEADVERTISE] = function ( peer, data )
    if data and #data >= 1 then
        local sys_name = data[1]
        if relay.peers[sys_name] == peer then
            print(fmt.f("Relay: Removing host for {syst}", { syst = sys_name }))
            relay.peers[sys_name] = nil
            send_msg(peer, "deadvertise_ack", sys_name)
        end
    end
end

-- 4. Responses to OUR queries (from Root or other Peers)
RELAY_MESSAGES[RSP_FOUND] = function ( peer, data )
    if data and #data >= 1 then
        local target_address = data[1]
        print("Relay: Host found at " .. target_address)
        -- In a real implementation, we might automatically connect here.
        -- For now, we log it so find_peer logic can use it.
        relay.last_found_address = target_address
    end
end

RELAY_MESSAGES[RSP_NOT_FOUND] = function ( peer, data )
    -- print("Relay: Host not found.")
end

-- ====================================================
-- CORE LOGIC
-- ====================================================

-- Start the relay (Listen for connections AND connect to root)
relay.start = function( port )
    -- Listen on all interfaces (0.0.0.0) to act as a server/relay for others
    if not port then port = 0 end
    relay.host = enet.host_create( "*:"..port )

    if not relay.host then
        print("Error: Could not bind port " .. port)
        return nil
    end

    -- Initialize peer table
    relay.peers = {}

    -- Try to connect to the Root Relay (Oracle)
    -- This makes us part of the global mesh
    print("Relay: Connecting to Root Server...")
    root_peer = relay.host:connect(root_relay_addr)

    -- We also act as a system server logic holder
    relay.server = syst_server.create()

    return relay
end

-- Start hosting the current system
relay.open = function ()
    relay.hosting = true
    relay.server.start()

    local syst = system.cur():nameRaw()

    -- Advertise to EVERYONE we are connected to
    -- (The Root Relay, plus any peers directly connected to us)
    relay.broadcast(CMD_ADVERTISE, syst)

    -- Register ourselves locally so we know we are the host
    relay.peers[syst] = relay.host:get_socket_address() -- Or "localhost"
end

relay.close = function ()
    relay.hosting = nil
    relay.server.stop()

    local syst = system.cur():nameRaw()
    relay.broadcast(CMD_DEADVERTISE, syst)
end

-- Broadcast a message to all connected peers (Root + Clients)
relay.broadcast = function ( cmd, arg )
    local msg = cmd .. "\n" .. (arg or "") .. "\n"
    relay.host:broadcast(msg)
end

relay.update = function ()
    if not relay.host then return end

    local event = relay.host:service(0)
    while event do
        if event.type == "receive" then
            relay.process(event)
        elseif event.type == "connect" then
            print("Relay: Connection established with " .. tostring(event.peer))
        elseif event.type == "disconnect" then
            print("Relay: Disconnected from " .. tostring(event.peer))

            -- Handle Host cleanup
            -- If a peer disconnects, remove the systems they hosted
            for k, v in pairs(relay.peers) do
                if v == event.peer then
                    relay.peers[k] = nil
                end
            end

            -- Auto-reconnect to root if dropped
            if event.peer == root_peer then
                print("Relay: Lost connection to Root. Reconnecting...")
                root_peer = relay.host:connect(root_relay_addr)
            end
        end
        event = relay.host:service(0)
    end
end

relay.process = function ( event )
    local lines = {}
    for line in event.data:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    if #lines == 0 then return end

    local msg_type = lines[1]
    local msg_data = {}
    for i=2, #lines do table.insert(msg_data, lines[i]) end

    -- 1. Check if it's a Relay Message (Advertise/Find)
    if RELAY_MESSAGES[msg_type] ~= nil then
        RELAY_MESSAGES[msg_type]( event.peer, msg_data )
        return
    end

    -- 2. If not a relay msg, and we are hosting, it's a Game Message
    if relay.hosting then
        relay.server.handleMessage( event.peer, msg_type, msg_data )
    else
        -- We are just a relay/client, we don't process game logic
        -- But if we were a "dumb router", we might forward this.
        -- For now, drop unknown messages.
    end
end

-- Try to find the peer hosting <syst_name>
relay.find_peer = function ( syst_name )
    -- 1. Check local cache
    local host_peer = relay.peers[syst_name]
    if host_peer then
        -- If it's an ENet peer object (connected), return it
        -- If it's a string (from Root), we might need to connect
        return host_peer
    end

    -- 2. Ask everyone (Root + connected peers)
    relay.broadcast(CMD_FIND, syst_name)

    -- 3. Check if we received a 'found' response recently (async)
    if relay.last_found_address then
        local addr = relay.last_found_address
        relay.last_found_address = nil -- consume it
        return addr
    end

    return nil
end

return relay
