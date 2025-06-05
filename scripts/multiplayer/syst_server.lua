--
-- luacheck: globals MULTIPLAYER_P2P_UPDATE MULTIPLAYER_P2P_SYNC (Hook functions passed by name)
local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local mp_equip = require "equipopt.templates.multiplayer"
local ai_setup = require "ai.core.setup"

-- NOTE: This is a listen server
--  it can't play like a client, but it relays the simulation
local server = {}
--[[
        server.players = { player_id = pilot, ... }
        server.world_state = { player_id = player_info, ... }
  
        server.start()
        server.synchronize_player( peer, sender_info )
        server.update()
--]]

-- make sure a name is unique by adding random numbers until it is
local function shorten( name )
    local newname = name:sub(1, math.min(name:len(), 16))
    if server.players[name] then
        newname = shorten( newname .. tostring(rnd.rnd(1,999)) )
    end

    return newname
end

local function random_spawn_point( xmax, ymax )
    xmax = 400 or xmax
    ymax = 800 or ymax
    return vec2.new( rnd.rnd(-xmax, xmax), rnd.rnd(-ymax, ymax) )
end

local function pick_one(t)
    return t[rnd.rnd(1, #t)]
end

local function pick_key(t)
    local key_pool = {}
    for k, _v in pairs(t) do
        table.insert(key_pool, k)
    end
    return pick_one(key_pool)
end

local function _sanitize_name( suggest )
    local word = suggest:match( "%w+" )
    return word or "SuspiciousPlayer"
end

local function ok_shiptype ( shiptype )
    if pcall( function() ship.get(shiptype) end ) then
        return true
    else
        return false
    end
end

local function assignPilotToPlayer( playerID, new_ship )
    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "remote_control", clear_allies = true, clear_enemies = true }
    )
    server.players[playerID] = pilot.add(
        new_ship,
        mplayerfaction,
        random_spawn_point(),
        playerID,
        { naked = true }
    )
    mp_equip( server.players[playerID] )
    ai_setup.setup( server.players[playerID] )
    server.playerinfo[playerID] = {}
    hook.pilot(
        server.players[playerID],
        "death",
        "MULTIPLAYER_SCORE_KEEPER"
    )
end

local REGISTRATIONS = {}
-- registers a player, returns the players unique ID
local function registerPlayer( playernicksuggest, shiptype, outfits )
    playernicksuggest = _sanitize_name( playernicksuggest )
    if server.players[playernicksuggest] then
        -- prevent double registration
          return nil
    end
    -- create a unique registration ID
    local playerID = shorten( playernicksuggest )

    -- spawn the pilot server-side
    if playernicksuggest == server.hostnick then
        server.players[playerID] = player.pilot()
    else
        print("ADDING PLAYER " .. playerID .. " IN " .. tostring(shiptype) )
        assignPilotToPlayer( playerID, shiptype )
    end

    REGISTRATIONS[playerID] = { ship = shiptype, outfits = outfits }

    return playerID
end

-- sends a message IFF we have a defined handler to receive it
local function sendMessage( peer, key, data, reliability )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end
    reliability = reliability or "unsequenced"

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    if peer:state() ~= "connected" then
        print("error: REFUSING TO SERVICE PEER IN STATE: " .. peer:state() )
        return nil
    end
    return peer:send( message, 0, reliability )
end

local function broadcast( key, data, reliability )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end

    reliability = reliability or "unsequenced"

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    return server.host:broadcast( message, 0, reliability )
end

local MESSAGE_HANDLERS = {}

-- REGISTERED maps peer:index() to player_id
local REGISTERED = {}
local function is_registered( player_id )
    for pindex, plid in pairs(REGISTERED) do
        if plid == player_id then
            return true
        end
    end
    return false
end
-- get the peer from a player id
local function get_peer( player_id )
    for pindex, plid in pairs(REGISTERED) do
        if
            plid == player_id 
        then
            local some_peer = server.host:get_peer(pindex)
            if
                some_peer
                and some_peer:state() == "connected"
            then
                return some_peer
            end
        end
    end
    return nil
end
-- player wants to join the server
MESSAGE_HANDLERS[common.REQUEST_KEY] = function ( peer, data )
    -- peer wants to register as <data>[1] in <data>[2]
    if data and #data >= 2 then
        local player_id = registerPlayer(data[1], data[2], common.unmarshal_outfits(data) )
        if player_id then
            -- ACK: REGISTERED <player_id>
            print("REGISTERED <" .. player_id .. "> in a " .. tostring(data[2]))
            sendMessage( peer, common.REGISTRATION_KEY, player_id, "reliable" )
            REGISTERED[peer:index()] = player_id
            return
        end
    end
    if peer:state() == "connected" then
        peer:send("ERROR: This nickname is reserved, please reconnect with another name or wait until the nickname is no longer in use.")
    end
end

local resync_players = {}
local context_sync = {}
local context_limit = 16
-- player wants to sync
MESSAGE_HANDLERS[common.REQUEST_UPDATE] = function ( peer, data )
    -- peer just wants an updated world state
    local player_id
    if #data >= 1 then
        player_id = data[1]:match( "%w+" )
        -- before we do anything, let's make sure we didn't already update this player recently
        if context_sync[player_id] == nil then
            context_sync[player_id] = 0
        elseif context_sync[player_id] > context_limit then
            print(fmt.f("INFO: player with id {mpid} already received too many updates in this context at {val}", { mpid = player_id, val=context_sync[player_id] } ))
            context_sync[player_id] = context_sync[player_id] + 1 -- increment counter for debug message
            return
        else
            -- we now assume the player will be updated in this context
            context_sync[player_id] = context_sync[player_id] + 1
        end

      --print("player'id: " .. player_id)
        if player_id and server.players[player_id] then
            -- update pilots
            local known_pilots = {}
            known_pilots[player_id] = true
            for ii, line in ipairs( data ) do
                if ii > 1 then
                    for opid, opship in string.gmatch(line, "(%w+)=([%w|%s|']+)") do
                        if
                            server.players[opid]    -- we know this pilot
                            and server.players[opid]:exists()   -- it exists
                            and opship == server.players[opid]:ship():nameRaw() -- the ship is correct
                        then
                            known_pilots[opid] = true
                        end
                    end
                end
            end

            for opid, opplt in pairs( server.players ) do
                -- need to synchronize creation of a new pilot
                if not known_pilots[opid] then
                    if opplt:exists() then
                       local message_data = fmt.f(
                           "{opid}\n{ship_type}\n{outfits}\n",
                           {
                               opid = opid,
                               ship_type = opplt:ship():nameRaw(),
                               outfits = common.marshal_outfits( opplt:outfitsList() ),
                           }
                       )
                       if server.npcs[opid] then
                           sendMessage( peer, common.ADD_NPC, message_data )
                       elseif opid ~= server.hostnick then
                           sendMessage( peer, common.ADD_PILOT, message_data, "reliable" )
                       end
                    else
                       -- player is dead
                        resync_players[opid] = 99
                    end
                end
            end

            -- synchronize this players info
            local in_sync = server.synchronize_player( peer, data[1] )
            local reliability = "unreliable"
            if not in_sync then
                reliability = "reliable"
            end

            -- send this player the requested world state
            sendMessage( peer, common.RECEIVE_UPDATE, server.world_state, reliability )
            return
        end
    end
    local emsg
    if not player_id then
        emsg =  "ERROR: Unsupported operation 2: Please use a valid nickname." 
    elseif not server.players[player_id] then
        emsg =  "ERROR: Unsupported operation 3: Please register before attempting to synchronize." 
        peer:disconnect()
        return
    end
    if peer:state() == "connected" then
        peer:send( emsg  )
    end
    print( emsg )
    for k,v in pairs( data ) do
        print(tostring(k) .. ": " .. tostring(v))
    end
end

-- when you are the host, you can edit this file with the cheats you want to implement on your server here
local cheat_codes = {}

MESSAGE_HANDLERS[common.SEND_MESSAGE] = function ( peer, data )
    -- peer wants to broadcast <data>[1] as a message
    if data and #data >= 1 then
        -- cheats section
        local secret = data[1]:match("[%w|_]+")
        if secret and cheat_codes[secret] then
            print(secret .. " activated by " .. peer)
            cheat_codes[secret]()
        end
        local plid = REGISTERED[peer:index()]
        if server.players[plid] then
            local message =  data[1] .. '\n' .. server.players[plid]:name()
            return broadcast( common.SEND_MESSAGE, message )
        end
    end
end

local function toggleOutfit( plid, message, on )
    if #message >= 2 then
        local playerID
        for ii, activated_line in ipairs( message ) do
            if ii == 1 then
                playerID = activated_line
                if plid ~= playerID then
                    print("WARNING: Peer trying to activate wrong person's outfit: " .. tostring(plid))
                    return
                end
                resync_players[plid] = -30
            else    -- don't fully trust the client
                local outf = activated_line
                local clplt = server.players[playerID]
                if on then
                    print(fmt.f("{pilot} wants to activate {outfit}", { pilot=tostring(clplt), outfit=tostring(outf) } ))
                end
                if clplt and clplt:exists() then
                    local memo = clplt:memory()._o
                    if memo then
                    --  for ii, mm in pairs(memo) do
                    --      print(fmt.f("memo {ii}={mm}", { ii = ii, mm = mm } ) )
                    --  end
                        local outno = memo[outf]
                        if outno then
                            clplt:outfitToggle(outno, on)
                        end
                        if on then
                            print("activate " .. tostring(outno))
                        --  for kk, vv in pairs(clplt:outfits()) do
                        --      print(fmt.f("{kk}: {vv}", { kk=kk, vv=vv } ) )
                        --  end
                        end
                    end
                end
            end
        end
    end
end

local function outfit_handler ( peer, data )
    if data and #data >= 2 then
        local plid = REGISTERED[peer:index()]
        local activedata = ''
        for ii, dline in ipairs( data ) do
            activedata = activedata .. dline .. '\n'
        end
        if plid == data[1] then
            return server.host:broadcast( common.ACTIVATE_OUTFIT .. '\n' .. activedata, 0, "unreliable" )
        end
    end
end

MESSAGE_HANDLERS[common.ACTIVATE_OUTFIT] = function ( peer, data )
    local plid = REGISTERED[peer:index()]
    if not plid then
        print("Peer registration not found for peer #" .. tostring(peer:index()))
        for pk, pv in pairs(REGISTERED) do
            print(fmt.f("{pk}: {pv}", {pk=pk, pv=pv}))
        end
    end
    toggleOutfit( plid, data , true )
    return outfit_handler( peer, data )
end
MESSAGE_HANDLERS[common.DEACTIVATE_OUTFIT] = function ( peer, data )
    local plid = REGISTERED[peer:index()]
    if not plid then
        print("Peer registration not found for peer #" .. tostring(peer:index()))
        for pk, pv in pairs(REGISTERED) do
            print(fmt.f("{pk}: {pv}", {pk=pk, pv=pv}))
        end
    end
    toggleOutfit( plid, data , false )
    return outfit_handler( peer, data)
end

local handled_frame = {}


server.handleMessage = function ( peer, msg_type, msg_data )
    if handled_frame[peer:index()] == msg_type then
        print( "INFO: Already handled a " .. msg_type .. " from peer " .. tostring(peer:index()) )
    end
    handled_frame[event.peer] = msg_type

    return MESSAGE_HANDLERS[msg_type]( peer, msg_data )
end

server.handleMsgRaw = function ( event )
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n]+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    return server.handleMessage( event.peer, msg_type, msg_data )
end

local function handleMessage ( event )
    print("WARNING: Using defunct local handleMessage, use server.HandleMsgRaw instead")
    return server.handleMsgRaw( event )
end

-- create a ready-to-start server
server.create = function ( port )
    if not port then port = 0 end -- get a random port
    server.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )
    local message = "P2P host is running on: " .. server.host:get_socket_address()
    print( message )

    return server
end

-- start a new listenserver
server.start = function( port )
    -- reset any hooks
    server.stop()
    if server.host == nil then
        print( "ERROR: No server host!" )
        return "NO_SERVER_HOST"
    end
    local message = "P2P SERVER HAS STARTED ON: " .. server.host:get_socket_address()
    print( message )
    player.omsgAdd( "#b"..message.."#0" )
    pilot.comm( "SERVER INFO", "#y" .. message .. "#0" )
    -- TODO: npcs should be the npcs in the game, check update too!
    server.players     = {}
    server.npcs        = {}
    server.playerinfo  = {}
    -- register yourself
    server.hostnick = _sanitize_name( player.name():gsub(' ', '_') )
    registerPlayer( server.hostnick, player:pilot():ship():nameRaw() , player:pilot():outfitsList() )
    -- update world state with yourself (weird)
    server.world_state = server.refresh()

    server.hook = hook.update("MULTIPLAYER_P2P_UPDATE")
    server.pinghook = hook.timer(1, "MULTIPLAYER_P2P_SYNC")
    -- NOTE: This server has no inputhook, because it runs on a client

    player.cinematics(
        false,
        {
            abort = _("Autonav disabled in multiplayer."),
            no2x = true,
            gui = false -- TODO: Is this right?
        }
    )
end

server.stop = function ()
    if server.hook ~= nil then
        print("P2P Server hook has been removed.")
        hook.rm( server.hook )
    end
    if server.pinghook ~= nil then
        hook.rm( server.pinghook )
    end
end

local FPS = 60
-- synchronize one player update after receiving
server.synchronize_player = function( peer, player_info_str )
    if peer == nil then
        print("error: peer is nil")
        return nil
    end
    print( player_info_str )
    local frames_passed = peer:round_trip_time() / (1000 / FPS)
    local ppinfo = common.unmarshal( player_info_str )
    local ppid = ppinfo.id
    --print("sync player " .. ppid .. " to health " .. tostring(ppinfo.armour) )
    if ppid and server.players[ppid] and server.players[ppid]:exists() then
        -- sync direction always
        server.players[ppid]:setDir(ppinfo.dir)
        -- validation
        local dist2 = vec2.dist2(
            vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)),
            server.players[ppid]:pos()
        )
        local stats = server.players[ppid]:stats()
        local fudge = 16
        local speed2 = math.min(
            stats.speed_max * stats.speed_max,
            (math.abs(ppinfo.velx) + fudge) * (math.abs(ppinfo.vely) + fudge)
        ) * 3
        local mdiff = (
            math.abs( vec2.new( math.abs(ppinfo.velx) + fudge, math.abs(ppinfo.vely) + fudge):mod() * fudge ) + fudge 
        ) * frames_passed
        if dist2 >= speed2 or dist2 > (mdiff * mdiff) then
            print("WARNING: Refusing to synchronize player " .. ppid)
            local rsp = resync_players[ppid]
            if not rsp then
                resync_players[ppid] = 1
                return false
            elseif rsp < 2 then
                resync_players[ppid] = rsp + 1
                return false
            end
            resync_players[ppid] = nil
            --[[
            if rnd.rnd(0, 160) == 0 then
                common.sync_player( ppid, ppinfo, server.players )
            end
            server.players[ppid]:setHealth(ppinfo.armour - 1, ppinfo.shield, ppinfo.stress + 1)
            ]]--
            -- respawn the player in the right ship
            local message_data = fmt.f(
               "{ppid}\n{ship_type}\n{outfits}\n",
               {
                   ppid = ppid,
                   ship_type = server.players[ppid]:ship():nameRaw(),
                   outfits = common.marshal_outfits( server.players[ppid]:outfitsList() ),
               }
            )
            sendMessage( peer, common.ADD_PILOT, message_data, "reliable" )
            local syncline = fmt.f(
                "{ppid} {energy} {heat} {armour} {shield} {stress}",
                {
                    ppid = ppid,
                    energy = 5,
                    heat = 250,
                    armour = 100,
                    shield = 80,
                    stress = 0,
                }
            )
            sendMessage( peer, common.SYNC_PLAYER, syncline, "reliable" )
            server.players[ppid]:fillAmmo()
            return false
        else
            -- server side sync
            server.players[ppid]:setPos(vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)))
            server.players[ppid]:setVel(vec2.new(tonumber(ppinfo.velx), tonumber(ppinfo.vely)))
          --server.players[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        end
        server.playerinfo[ppid] = ppinfo
        
        -- server authority on health
        local armour, shield, stress = server.players[ppid]:health()
        ppinfo.armour = armour
        ppinfo.shield = shield
        ppinfo.stress = stress
        local syncline = fmt.f(
            "{ppid} {energy} {heat} {armour} {shield} {stress}",
            {
                ppid = ppid,
                energy = server.players[ppid]:energy(),
                heat = server.players[ppid]:temp(),
                armour = armour,
                shield = shield,
                stress = stress,
            }
        )
        if ppinfo.armour > armour * 1.02 or ppinfo.shield > shield * 1.02 or math.abs(ppinfo.stress - stress) > 8 then
            broadcast( common.SYNC_PLAYER, syncline, "unreliable" )
        elseif math.abs(rnd.threesigma()) >= 2.5 then
            sendMessage( peer, common.SYNC_PLAYER, syncline, "reliable" )
        end
        common.sync_player( ppid, ppinfo, server.players )
        server.players[ppid]:fillAmmo()
    end
    if resync_players[ppid] then
        resync_players[ppid] = nil
    end
    return true
end

-- TODO: get the "npcs" from the game
server.refresh = function()
    handled_frame = {}
    local world_state = ""

    for nid, _bool in pairs(server.npcs) do
        local pplt = server.players[nid]
        if pplt and pplt:exists() then
            local accel = 1
            local primary = 0
            local secondary = 0
            local target = pplt:target()
            if target then
              server.playerinfo[nid].target = target:name()
              server.playerinfo[nid].accel = rnd.rnd()
              server.playerinfo[nid].primary = rnd.rnd(0, 1)
              server.playerinfo[nid].secondary = rnd.rnd(0, 1)
            end
        else
            server.npcs[nid] = nil
            -- create a record of it being definitely dead "this frame"
            -- this shouldn't be necessary but might help later
            local syncline = fmt.f(
                "{ppid} {energy} {heat} {armour} {shield} {stress}",
                {
                    ppid = nid,
                    energy = 0,
                    heat = 750,
                    armour = 0,
                    shield = 0,
                    stress = 100,
                }
            )
            broadcast( common.SYNC_PLAYER, syncline, "unreliable" )
            server.playerinfo[nid] = nil
        end
    end


    server.players[server.hostnick] = player.pilot()
    for ppid, pplt in pairs(server.players) do
        if pplt:exists() then
            local accel = 0
            local primary = 0
            local secondary = 0
            local target = server.hostnick
            if server.playerinfo[ppid] then
               if server.playerinfo[ppid].accel then
                  accel = server.playerinfo[ppid].accel
               end
               if server.playerinfo[ppid].primary then
                  primary = server.playerinfo[ppid].primary
               end
               if server.playerinfo[ppid].secondary then
                  secondary = server.playerinfo[ppid].secondary
               end
               if server.playerinfo[ppid].target then
                   target = server.playerinfo[ppid].target
                end
            end
            local armour, shield, stress = pplt:health()
            local velx, vely = pplt:vel():get()
            local posx, posy = pplt:pos():get()
            world_state = world_state .. fmt.f("{id} {posx} {posy} {dir} {velx} {vely} {armour} {shield} {stress} {accel} {primary} {secondary} {target}\n", {
                id = ppid,
                posx = posx,
                posy = posy,
                dir = pplt:dir(),
                velx = velx,
                vely = vely,
                armour = armour,
                shield = shield,
                stress = stress,
                accel = accel,
                primary = primary,
                secondary = secondary,
                target = target,
            })
        else -- it died
            print("INFO: Player is dead: " .. tostring(ppid) )
            server.players[ppid]    = nil
            server.npcs[ppid]       = nil
            server.playerinfo[ppid] = nil
        end
    end

    server.world_state = world_state

    --  print("_________________")
    --  print("WORLD STATE START")
    --  print("~~~~~~~~~~~~~~~~~")
    --  print(world_state)
    --  print("_________________")
    --  print("WORLD STATE  END ")
    return world_state
end

-- do I need to explain this?
local valid_contexts_per_second = 30
local max_context_frames = 0
local this_context_frames = 1
server.update = function ()
    player.autonavReset()
    -- refresh our world state before updating clients
    server.refresh()

    -- validate the current context
    if this_context_frames >= max_context_frames then
        -- clear the context
        for cplid, _val in pairs(context_sync) do
            context_sync[cplid] = nil
        end
        -- calculate next context window
        max_context_frames = naev.fps() / valid_contexts_per_second
        this_context_frames = 1
    else
        -- increment the counter
        this_context_frames = this_context_frames + 1
    end

    -- handle requests from clients
    local event = server.host:service()
    while event do
        if event.type == "receive" then
            handleMessage( event )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            -- reserve an ID? nah...
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- TODO: Instead of cleanup, preserve the wreckage or something
            -- clean up
            local dc_player = REGISTERED[event.peer:index()]
            if dc_player then
                if server.players[dc_player] and server.players[dc_player]:exists() then
                    server.players[dc_player]:rm()
                end
                server.players[dc_player] = nil
                REGISTERED[event.peer:index()] = nil
            end
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = server.host:service()
    end
end

-- TODO: Revise this
server.check_players = function ()
    for ppid, pplt in pairs(server.players) do
        if pplt:exists() then
            local p_ship = pplt:ship():nameRaw()
            local peer = get_peer(ppid)
            if peer and pplt:exists() then
                sendMessage( peer, common.CHECK_SYNC, p_ship, "unreliable" )
            end
        end
    end
    local timer_sec = 3
    server.pinghook = hook.timer(timer_sec, "MULTIPLAYER_P2P_SYNC")
end

MULTIPLAYER_P2P_UPDATE = function() return server.update() end

MULTIPLAYER_P2P_SYNC = function () return server.check_players() end

local function num_players()
    local count = 0
    for ii, plid in pairs(server.players) do
        if not server.npcs[plid] and REGISTERED[plid] then
            count = count + 1
        end
    end
    return count
end

return server
